package app

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/db"
	"rustdesk-api-server-pro/util"

	"github.com/pquerna/otp/totp"
)

// TestRustdeskClientSessionLifecycle 通过真实路由验证双版本登录、权限撤销、退出隔离及审计脱敏。
func TestRustdeskClientSessionLifecycle(t *testing.T) {
	for _, version := range []string{"1.4.9", "1.5.0"} {
		t.Run(version, func(t *testing.T) {
			engine := newInternalRouteTestEngine(t)
			if err := engine.Sync(new(model.User), new(model.AuthToken), new(model.SecurityAudit), new(model.CompatAPIAudit), new(model.OAuthLoginSession), new(model.VerifyCode)); err != nil {
				t.Fatal(err)
			}
			previous := db.DbEngine
			db.DbEngine = engine
			t.Cleanup(func() { db.DbEngine = previous })
			cfg := config.GetDefaultServerConfig()
			cfg.DebugMode = false
			application, err := newBaseApp(cfg, engine)
			if err != nil {
				t.Fatal(err)
			}
			application.Logger().SetLevel("error")
			SetClientRoute(application)
			if err := application.Build(); err != nil {
				t.Fatal(err)
			}
			password, err := util.Password("client-session-test-password")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := engine.Insert(&model.User{Id: 1, Username: "session-user", Name: "测试账号", Password: password, Status: 1}); err != nil {
				t.Fatal(err)
			}
			request := func(method, path, payload, token string, want int) *httptest.ResponseRecorder {
				t.Helper()
				req := httptest.NewRequest(method, path, strings.NewReader(payload))
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("X-RustDesk-Version", version)
				if token != "" {
					req.Header.Set("Authorization", "Bearer "+token)
				}
				response := httptest.NewRecorder()
				application.ServeHTTP(response, req)
				if response.Code != want {
					t.Fatalf("ERR-2398 客户端路由状态错误：%s %s %d，预期 %d", method, path, response.Code, want)
				}
				return response
			}
			for _, method := range []string{http.MethodGet, http.MethodPost} {
				options := request(method, "/api/login-options", "", "", http.StatusOK)
				var values []string
				if json.Unmarshal(options.Body.Bytes(), &values) != nil || len(values) != 1 || values[0] != "oidc/webauth" {
					t.Fatal("ERR-2398 真实登录选项路由响应格式错误")
				}
			}
			request(http.MethodPost, "/api/currentUser", `{}`, "", http.StatusUnauthorized)
			const loginPayload = `{"username":"session-user","password":"client-session-test-password","id":"session-source","uuid":"session-uuid","type":"account","autoLogin":true,"deviceInfo":{"os":"Windows","type":"desktop","name":"测试设备"}}`
			login := request(http.MethodPost, "/api/login", loginPayload, "", http.StatusOK)
			var result struct {
				Token string `json:"access_token"`
				Type  string `json:"type"`
				Error string `json:"error"`
			}
			if json.Unmarshal(login.Body.Bytes(), &result) != nil || result.Token == "" || result.Type != "access_token" {
				t.Fatalf("ERR-2398 登录未返回官方客户端需要的直接令牌响应：%s", result.Error)
			}
			var stored model.AuthToken
			if found, err := engine.Where("token_hash = ?", util.Sha256Hex(result.Token)).Get(&stored); err != nil || !found || stored.Token != "" || stored.IsAdmin || stored.RustdeskId != "session-source" {
				t.Fatal("ERR-2398 登录会话未按设备保存摘要或意外提升为管理员")
			}
			current := request(http.MethodPost, "/api/currentUser", `{"id":"session-source","uuid":"session-uuid"}`, result.Token, http.StatusOK)
			var user struct {
				Name string `json:"name"`
			}
			if json.Unmarshal(current.Body.Bytes(), &user) != nil || user.Name != "测试账号" {
				t.Fatal("ERR-2398 当前账号接口不是官方客户端需要的直接响应")
			}
			firstToken := result.Token
			login = request(http.MethodPost, "/api/login", loginPayload, "", http.StatusOK)
			if json.Unmarshal(login.Body.Bytes(), &result) != nil || result.Token == "" || result.Token == firstToken {
				t.Fatal("ERR-2398 重复登录没有签发独立会话")
			}
			request(http.MethodPost, "/api/currentUser", `{}`, firstToken, http.StatusUnauthorized)
			for _, invalid := range []string{`{"id":`, `{"id":123}`} {
				response := request(http.MethodPost, "/api/logout", invalid, result.Token, http.StatusBadRequest)
				if !strings.Contains(response.Body.String(), "ERR-6009") {
					t.Fatal("ERR-2398 无效退出请求缺少错误码")
				}
				request(http.MethodPost, "/api/currentUser", `{}`, result.Token, http.StatusOK)
			}
			if _, err := engine.ID(1).Cols("status").Update(&model.User{Status: 0}); err != nil {
				t.Fatal(err)
			}
			request(http.MethodPost, "/api/currentUser", `{}`, result.Token, http.StatusNotAcceptable)
			if _, err := engine.ID(1).Cols("status").Update(&model.User{Status: 1}); err != nil {
				t.Fatal(err)
			}
			request(http.MethodPost, "/api/currentUser", `{}`, result.Token, http.StatusOK)
			tokens := []model.AuthToken{
				{UserId: 1, RustdeskId: "shared-device", TokenHash: util.Sha256Hex("own-device-session"), Status: 1, Expired: time.Now().Add(time.Hour)},
				{UserId: 2, RustdeskId: "shared-device", TokenHash: util.Sha256Hex("other-user-session"), Status: 1, Expired: time.Now().Add(time.Hour)},
				{UserId: 1, RustdeskId: "shared-device", TokenHash: util.Sha256Hex("admin-session"), IsAdmin: true, Status: 1, Expired: time.Now().Add(time.Hour)},
				{UserId: 2, RustdeskId: "foreign-device", TokenHash: util.Sha256Hex("foreign-device-session"), Status: 1, Expired: time.Now().Add(time.Hour)},
			}
			if _, err := engine.Insert(&tokens); err != nil {
				t.Fatal(err)
			}
			request(http.MethodPost, "/api/currentUser", `{}`, "admin-session", http.StatusUnauthorized)
			for _, logout := range []struct{ method, path, payload string }{
				{http.MethodPost, "/api/logout", `{"id":"shared-device","uuid":"session-uuid"}`},
				{http.MethodGet, "/api/logout?id=shared-device", ""},
				{http.MethodDelete, "/api/logout?rustdesk_id=shared-device", ""},
			} {
				if _, err := engine.Where("token_hash = ?", tokens[0].TokenHash).Cols("status").Update(&model.AuthToken{Status: 1}); err != nil {
					t.Fatal(err)
				}
				request(logout.method, logout.path, logout.payload, result.Token, http.StatusOK)
				request(http.MethodPost, "/api/logout", `{"id":"foreign-device"}`, result.Token, http.StatusOK)
				for i, token := range tokens {
					var saved model.AuthToken
					if found, err := engine.Where("token_hash = ?", token.TokenHash).Get(&saved); err != nil || !found {
						t.Fatal("ERR-2398 无法读取退出后的会话")
					}
					want := 1
					if i == 0 {
						want = 0
					}
					if saved.Status != want {
						t.Fatalf("ERR-2398 退出越过账号或会话类型边界：%s 用例 %d，状态 %d", logout.method, i, saved.Status)
					}
				}
			}
			request(http.MethodPost, "/api/logout", `{}`, result.Token, http.StatusOK)
			request(http.MethodPost, "/api/currentUser", `{}`, result.Token, http.StatusUnauthorized)
			request(http.MethodPost, "/api/logout", `{"id":"shared-device"}`, "", http.StatusUnauthorized)
			const tfaSecret = "JBSWY3DPEHPK3PXP"
			if _, err := engine.ID(1).Cols("login_verify", "tfa_secret").Update(&model.User{LoginVerify: model.LOGIN_TFA_CHECK, TwoFactorAuthSecret: tfaSecret}); err != nil {
				t.Fatal(err)
			}
			pending := request(http.MethodPost, "/api/login", loginPayload, "", http.StatusOK)
			var challenge struct {
				Secret string `json:"secret"`
				Type   string `json:"type"`
			}
			if json.Unmarshal(pending.Body.Bytes(), &challenge) != nil || challenge.Secret == "" || challenge.Type != model.LOGIN_EMAIL_CHECK {
				t.Fatal("ERR-2398 真实路由未创建二次验证挑战")
			}
			otpCode, err := totp.GenerateCode(tfaSecret, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			payload, err := json.Marshal(map[string]string{"id": "session-source", "uuid": "session-uuid", "type": "email_code", "secret": challenge.Secret, "tfaCode": otpCode, "verificationCode": otpCode})
			if err != nil {
				t.Fatal(err)
			}
			verified := request(http.MethodPost, "/api/login", string(payload), "", http.StatusOK)
			var mfa struct {
				Token string `json:"access_token"`
				Error string `json:"error"`
			}
			if json.Unmarshal(verified.Body.Bytes(), &mfa) != nil || mfa.Token == "" {
				t.Fatal("ERR-2398 真实二次验证路由未完成登录")
			}
			request(http.MethodPost, "/api/currentUser", `{}`, mfa.Token, http.StatusOK)
			replayed := request(http.MethodPost, "/api/login", string(payload), "", http.StatusOK)
			var denied struct {
				Error string `json:"error"`
				Token string `json:"access_token"`
			}
			if json.Unmarshal(replayed.Body.Bytes(), &denied) != nil || denied.Token != "" || !strings.HasPrefix(denied.Error, "ERR-1006:") {
				t.Fatal("ERR-2398 二次验证路由重放未拒绝")
			}
			var audits []model.SecurityAudit
			if err := engine.Find(&audits); err != nil || len(audits) < 5 {
				t.Fatal("ERR-2398 缺少登录、撤销和退出审计")
			}
			encoded, err := json.Marshal(audits)
			if err != nil || strings.Contains(string(encoded), result.Token) || strings.Contains(string(encoded), firstToken) || strings.Contains(string(encoded), mfa.Token) || strings.Contains(string(encoded), challenge.Secret) || strings.Contains(string(encoded), "client-session-test-password") {
				t.Fatal("ERR-2398 会话审计包含原始凭据")
			}
		})
	}
}
