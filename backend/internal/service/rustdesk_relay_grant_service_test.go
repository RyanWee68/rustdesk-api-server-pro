package service

import (
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"
)

const testRelaySessionUUID = "123e4567-e89b-42d3-a456-426614174000"

// newRelayGrantFixture 创建双方均已审批且控制端持有效 token 的测试环境。
func newRelayGrantFixture(t *testing.T) (*RustdeskAdmissionService, core.RustdeskRelayGrantIssueRequest) {
	t.Helper()
	db := newAdmissionTestEngine(t)
	insertAdmissionDevice(t, db, "source", DeviceApprovalApproved, true, false, 1)
	insertAdmissionDevice(t, db, "target", DeviceApprovalApproved, true, false, 1)
	token := insertAdmissionToken(t, db, 1, "source", "uuid-1")
	return NewRustdeskAdmissionService(db, admissionTestConfig()), core.RustdeskRelayGrantIssueRequest{
		TargetID: "target", AccessToken: token, SessionUUID: testRelaySessionUUID,
		SourceIP: "192.0.2.10", TargetIP: "198.51.100.20",
	}
}

// TestRelayGrantRequiresIssueAndSingleUse 校验无票据、双方核销、重放和重复签发。
func TestRelayGrantRequiresIssueAndSingleUse(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	consume := func(ip string) core.RustdeskAdmissionResponse {
		t.Helper()
		resp, err := svc.ConsumeRelayGrant(core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: ip})
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	if got := consume(req.SourceIP); got.Allow || got.Code != errcode.ERR2315.Code {
		t.Fatalf("没有 hbbs 授权时仍可中继：%+v", got)
	}
	issued, err := svc.IssueRelayGrant(req)
	if err != nil || !issued.Allow || issued.SourceDeviceID != "source" || issued.DeviceID != "target" {
		t.Fatalf("签发失败：%+v %v", issued, err)
	}
	if got := consume("203.0.113.5"); got.Allow || got.Code != errcode.ERR2315.Code {
		t.Fatalf("IP 不匹配仍可中继：%+v", got)
	}
	for _, ip := range []string{req.SourceIP, req.TargetIP} {
		if got := consume(ip); !got.Allow || got.SourceDeviceID != "source" || got.DeviceID != "target" {
			t.Fatalf("合法会话端点被拒绝：%+v", got)
		}
	}
	for _, ip := range []string{req.SourceIP, req.TargetIP} {
		if got := consume(ip); got.Allow || got.Code != errcode.ERR2315.Code {
			t.Fatalf("会话核销后仍可重放：%+v", got)
		}
	}
	if got, err := svc.IssueRelayGrant(req); err != nil || got.Allow || got.Code != errcode.ERR2315.Code {
		t.Fatalf("重复签发重置状态：%+v %v", got, err)
	}
}

// TestRelayGrantRevocationAndExpiry 校验签发后撤销、禁用和超时仍会拒绝。
func TestRelayGrantRevocationAndExpiry(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*testing.T, *RustdeskAdmissionService, core.RustdeskRelayGrantIssueRequest)
		code   string
	}{
		{"token revoked", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("rustdesk_id = ?", "source").Cols("status").Update(&model.AuthToken{Status: 0}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2303.Code},
		{"target disabled", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("rustdesk_id = ?", "target").Cols("disabled").Update(&model.Device{Disabled: true}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2307.Code},
		{"source user disabled", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("id = ?", 1).Cols("status").Update(&model.User{Status: 0}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2308.Code},
		{"source relay disabled", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("rustdesk_id = ?", "source").Cols("allow_relay").Update(&model.Device{AllowRelay: false}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2309.Code},
		{"target relay disabled", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("rustdesk_id = ?", "target").Cols("allow_relay").Update(&model.Device{AllowRelay: false}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2309.Code},
		{"expired", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("session_uuid = ?", req.SessionUUID).Cols("expires_at").Update(&model.RustdeskRelayGrant{ExpiresAt: time.Now().Add(-time.Second).Unix()}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2315.Code},
	} {
		t.Run(tc.name, func(t *testing.T) {
			svc, req := newRelayGrantFixture(t)
			if got, err := svc.IssueRelayGrant(req); err != nil || !got.Allow {
				t.Fatalf("签发失败：%+v %v", got, err)
			}
			tc.change(t, svc, req)
			got, err := svc.ConsumeRelayGrant(core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.SourceIP})
			if err != nil || got.Allow || got.Code != tc.code {
				t.Fatalf("撤销后仍可核销：%+v %v", got, err)
			}
		})
	}
}

// TestRelayGrantRejectsMismatchedIPWithoutConsuming 校验错误来源地址不会占用合法端点名额。
func TestRelayGrantRejectsMismatchedIPWithoutConsuming(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	if got, err := svc.IssueRelayGrant(req); err != nil || !got.Allow {
		t.Fatalf("签发失败：%+v %v", got, err)
	}
	if got, err := svc.ConsumeRelayGrant(core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: "203.0.113.5"}); err != nil || got.Allow || got.Code != errcode.ERR2315.Code {
		t.Fatalf("错误来源地址仍可核销：%+v %v", got, err)
	}
	for _, ip := range []string{req.SourceIP, req.TargetIP} {
		if got, err := svc.ConsumeRelayGrant(core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: ip}); err != nil || !got.Allow {
			t.Fatalf("错误地址占用了合法端点名额：%+v %v", got, err)
		}
	}
}

// TestRelayGrantSameIPAndInvalidInput 校验同出口 IP 两端和畸形会话均不得签发。
func TestRelayGrantSameIPAndInvalidInput(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	for _, bad := range []core.RustdeskRelayGrantIssueRequest{
		{TargetID: req.TargetID, AccessToken: req.AccessToken, SessionUUID: "not-uuid", SourceIP: req.SourceIP, TargetIP: req.TargetIP},
		{TargetID: req.TargetID, AccessToken: req.AccessToken, SessionUUID: req.SessionUUID, SourceIP: "invalid", TargetIP: req.TargetIP},
		{TargetID: req.TargetID, AccessToken: req.AccessToken, SessionUUID: req.SessionUUID, SourceIP: req.SourceIP, TargetIP: "::ffff:192.0.2.10"},
	} {
		if got, err := svc.IssueRelayGrant(bad); err != nil || got.Allow || got.Code != errcode.ERR2315.Code {
			t.Fatalf("畸形会话被签发：%+v %v", got, err)
		}
	}
	req.TargetIP = req.SourceIP
	if got, err := svc.IssueRelayGrant(req); err != nil || got.Allow || got.Code != errcode.ERR2315.Code {
		t.Fatalf("同 IP 会话仍被签发：%+v %v", got, err)
	}
	var grant model.RustdeskRelayGrant
	if has, err := svc.db.Where("session_uuid = ?", req.SessionUUID).Get(&grant); err != nil || has {
		t.Fatalf("同 IP 会话仍被持久化：has=%v err=%v", has, err)
	}
}

// TestRelayGrantRejectsLegacySameIP 校验升级前遗留的同 IP 授权不能继续核销。
func TestRelayGrantRejectsLegacySameIP(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	var token model.AuthToken
	if has, err := svc.db.Where("rustdesk_id = ?", "source").Get(&token); err != nil || !has {
		t.Fatalf("找不到测试令牌：has=%v err=%v", has, err)
	}
	grant := model.RustdeskRelayGrant{
		SessionUUID: req.SessionUUID, SourceID: "source", TargetID: "target",
		SourceIP: req.SourceIP, TargetIP: req.SourceIP, TokenID: token.Id,
		ExpiresAt: time.Now().Add(relayGrantLifetime).Unix(),
	}
	if _, err := svc.db.Insert(&grant); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		got, err := svc.ConsumeRelayGrant(core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.SourceIP})
		if err != nil || got.Allow || got.Code != errcode.ERR2315.Code {
			t.Fatalf("遗留同 IP 会话第 %d 次仍可核销：%+v %v", i+1, got, err)
		}
	}
	var stored model.RustdeskRelayGrant
	if has, err := svc.db.Where("session_uuid = ?", req.SessionUUID).Get(&stored); err != nil || !has || stored.SourceUsed || stored.TargetUsed {
		t.Fatalf("拒绝后遗留会话状态被修改：has=%v grant=%+v err=%v", has, stored, err)
	}
}
