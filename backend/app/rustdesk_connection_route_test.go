package app

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/util"
)

// TestRustdeskConnectionRoute 校验新路由的内部鉴权、双端准入和凭据脱敏。
func TestRustdeskConnectionRoute(t *testing.T) {
	db := newInternalRouteTestEngine(t)
	if err := db.Sync(new(model.User), new(model.AuthToken), new(model.RustdeskRelayGrant)); err != nil {
		t.Fatal(err)
	}
	const secret = "0123456789abcdef0123456789abcdef"
	const token = "connection-test-sensitive-token"
	application, err := newBaseApp(&config.ServerConfig{
		HttpConfig:     &config.HttpConfig{Port: ":0"},
		RustdeskServer: &config.RustdeskServerConfig{InternalSecret: secret, AuthCacheSeconds: 30},
	}, db)
	if err != nil {
		t.Fatal(err)
	}
	SetInternalRoute(application)
	if err := application.Build(); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Insert(&model.User{Id: 1, Username: "connection-user", Status: 1, AllowRemoteAccess: true, AllowRelay: true}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"source", "target"} {
		if _, err := db.Insert(&model.Device{RustdeskId: id, Uuid: "uuid-" + id, UserId: 1, ApprovalStatus: "approved", AllowRelay: true}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Insert(&model.AuthToken{UserId: 1, RustdeskId: "source", Uuid: "uuid-source", TokenHash: util.Sha256Hex(token), Expired: time.Now().Add(time.Hour), Status: 1}); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Insert(&model.AuthToken{UserId: 1, RustdeskId: "target", Uuid: "uuid-target", TokenHash: util.Sha256Hex("target-login-token"), Expired: time.Now().Add(time.Hour), Status: 1}); err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(core.RustdeskConnectionRequest{TargetID: "target", AccessToken: token, Relay: true})
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name, header, value string
		status              int
	}{
		{"missing", "", "", http.StatusUnauthorized},
		{"wrong", "X-Internal-Secret", "wrong", http.StatusUnauthorized},
		{"secret", "X-Internal-Secret", secret, http.StatusOK},
		{"bearer", "Authorization", "Bearer " + secret, http.StatusOK},
	} {
		t.Run(test.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/internal/rustdesk/connection/check", bytes.NewReader(payload))
			req.Header.Set("Content-Type", "application/json")
			if test.header != "" {
				req.Header.Set(test.header, test.value)
			}
			out := httptest.NewRecorder()
			application.ServeHTTP(out, req)
			if out.Code != test.status {
				t.Fatalf("ERR-2398 路由状态错误：%d", out.Code)
			}
			var result core.RustdeskAdmissionResponse
			if err := json.Unmarshal(out.Body.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
			if test.status == http.StatusOK {
				if !result.Allow || result.SourceDeviceID != "source" || result.DeviceID != "target" {
					t.Fatalf("ERR-2398 双端准入结果错误：%+v", result)
				}
			} else if result.Allow || result.Code != "ERR-2301" {
				t.Fatalf("ERR-2398 内部密钥校验结果错误：%+v", result)
			}
		})
	}
	var audits []model.OperationAudit
	if err := db.Where("action = ?", "rustdesk_internal_connection_check").Find(&audits); err != nil {
		t.Fatal(err)
	}
	if len(audits) != 2 {
		t.Fatalf("ERR-2398 连接审计数量错误：%d", len(audits))
	}
	for _, audit := range audits {
		if audit.ResourceId != "target" || audit.Result != "allow" {
			t.Fatalf("ERR-2398 审计结果错误：%+v", audit)
		}
		if strings.Contains(audit.BeforeData+audit.AfterData, token) || strings.Contains(audit.BeforeData+audit.AfterData, secret) {
			t.Fatal("ERR-2398 审计泄露凭据")
		}
		if !strings.Contains(audit.BeforeData, "has_token") || !strings.Contains(audit.AfterData, "source_device_id") {
			t.Fatal("ERR-2398 审计缺少脱敏身份信息")
		}
	}
}

// TestRustdeskRelayGrantRoute 校验签发和核销只允许内部调用且审计不泄漏凭据。
func TestRustdeskRelayGrantRoute(t *testing.T) {
	db := newInternalRouteTestEngine(t)
	if err := db.Sync(new(model.User), new(model.AuthToken), new(model.RustdeskRelayGrant)); err != nil {
		t.Fatal(err)
	}
	const secret = "0123456789abcdef0123456789abcdef"
	const token = "relay-grant-sensitive-token"
	const sessionUUID = "123e4567-e89b-42d3-a456-426614174000"
	application, err := newBaseApp(&config.ServerConfig{
		HttpConfig:     &config.HttpConfig{Port: ":0"},
		RustdeskServer: &config.RustdeskServerConfig{InternalSecret: secret, AuthCacheSeconds: 30},
	}, db)
	if err != nil {
		t.Fatal(err)
	}
	SetInternalRoute(application)
	if err := application.Build(); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Insert(&model.User{Id: 1, Username: "relay-user", Status: 1, AllowRemoteAccess: true, AllowRelay: true}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"source", "target"} {
		if _, err := db.Insert(&model.Device{RustdeskId: id, Uuid: "uuid-" + id, UserId: 1, ApprovalStatus: "approved", AllowRelay: true}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Insert(&model.AuthToken{UserId: 1, RustdeskId: "source", Uuid: "uuid-source", TokenHash: util.Sha256Hex(token), Expired: time.Now().Add(time.Hour), Status: 1}); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Insert(&model.AuthToken{UserId: 1, RustdeskId: "target", Uuid: "uuid-target", TokenHash: util.Sha256Hex("target-login-token"), Expired: time.Now().Add(time.Hour), Status: 1}); err != nil {
		t.Fatal(err)
	}
	post := func(path string, payload interface{}, authorized bool) (int, core.RustdeskAdmissionResponse) {
		t.Helper()
		data, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(data))
		req.Header.Set("Content-Type", "application/json")
		if authorized {
			req.Header.Set("X-Internal-Secret", secret)
		}
		out := httptest.NewRecorder()
		application.ServeHTTP(out, req)
		var resp core.RustdeskAdmissionResponse
		if err := json.Unmarshal(out.Body.Bytes(), &resp); err != nil {
			t.Fatal(err)
		}
		return out.Code, resp
	}
	issue := core.RustdeskRelayGrantIssueRequest{
		TargetID: "target", AccessToken: token, SessionUUID: " " + sessionUUID + " ",
		SourceIP: "192.0.2.10", TargetIP: "198.51.100.20",
	}
	consume := core.RustdeskRelayGrantConsumeRequest{SessionUUID: " " + sessionUUID + " ", PeerIP: issue.SourceIP}
	if status, resp := post("/internal/rustdesk/relay/grant/issue", issue, false); status != http.StatusUnauthorized || resp.Allow {
		t.Fatalf("签发接口未受保护：%d %+v", status, resp)
	}
	if status, resp := post("/internal/rustdesk/relay/grant/consume", consume, false); status != http.StatusUnauthorized || resp.Allow {
		t.Fatalf("核销接口未受保护：%d %+v", status, resp)
	}
	if status, resp := post("/internal/rustdesk/relay/grant/consume", consume, true); status != http.StatusOK || resp.Allow || resp.Code != "ERR-2315" {
		t.Fatalf("未签发仍可核销：%d %+v", status, resp)
	}
	// 被控端先到时保留请求，随后由另一条 HTTP 连接完成授权签发。
	data, err := json.Marshal(core.RustdeskRelayGrantConsumeRequest{SessionUUID: sessionUUID, PeerIP: issue.TargetIP})
	if err != nil {
		t.Fatal(err)
	}
	early := httptest.NewRequest(http.MethodPost, "/internal/rustdesk/relay/grant/consume", bytes.NewReader(data))
	early.Header.Set("Content-Type", "application/json")
	early.Header.Set("X-Internal-Secret", secret)
	result := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		out := httptest.NewRecorder()
		application.ServeHTTP(out, early)
		result <- out
	}()
	select {
	case <-result:
		t.Fatal("签发之前核销请求过早返回")
	case <-time.After(75 * time.Millisecond):
	}
	if status, resp := post("/internal/rustdesk/relay/grant/issue", issue, true); status != http.StatusOK || !resp.Allow {
		t.Fatalf("签发失败：%d %+v", status, resp)
	}
	select {
	case out := <-result:
		var resp core.RustdeskAdmissionResponse
		if err := json.Unmarshal(out.Body.Bytes(), &resp); err != nil || out.Code != http.StatusOK || !resp.Allow {
			t.Fatalf("先到的核销请求失败：%d %+v %v", out.Code, resp, err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("HTTP 核销等待未按时结束")
	}
	if status, resp := post("/internal/rustdesk/relay/grant/consume", consume, true); status != http.StatusOK || !resp.Allow {
		t.Fatalf("核销失败：%d %+v", status, resp)
	}
	if status, resp := post("/internal/rustdesk/relay/grant/consume", consume, true); status != http.StatusOK || resp.Allow || resp.Code != "ERR-2315" {
		t.Fatalf("ERR-2398 重放未拒绝：%d %+v", status, resp)
	}
	var audits []model.OperationAudit
	if err := db.Where("action = ? or action = ?", "rustdesk_internal_relay_grant_issue", "rustdesk_internal_relay_grant_consume").Find(&audits); err != nil {
		t.Fatal(err)
	}
	if len(audits) != 5 {
		t.Fatalf("审计数量错误：%d", len(audits))
	}
	for _, audit := range audits {
		var request struct {
			SessionSHA256 string `json:"session_sha256"`
		}
		if err := json.Unmarshal([]byte(audit.BeforeData), &request); err != nil {
			t.Fatal(err)
		}
		if request.SessionSHA256 != util.Sha256Hex(sessionUUID) {
			t.Fatal("ERR-2398 签发、核销或拒绝审计缺少一致的会话摘要")
		}
		if strings.Contains(audit.BeforeData+audit.AfterData, token) || strings.Contains(audit.BeforeData+audit.AfterData, sessionUUID) {
			t.Fatal("中继审计泄漏凭据或会话 UUID")
		}
	}
}
