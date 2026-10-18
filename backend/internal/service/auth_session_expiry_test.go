package service

import (
	"fmt"
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/util"

	_ "modernc.org/sqlite"
	"xorm.io/xorm"
)

// TestAuthSessionExpiryAcrossTimezones 验证临时凭据有效期与数据库时区一致，不调用真实认证服务。
func TestAuthSessionExpiryAcrossTimezones(t *testing.T) {
	previous := time.Local
	time.Local = time.UTC
	t.Cleanup(func() { time.Local = previous })
	for _, kind := range []string{"state", "ticket", "poll", "bind", "webauthn-register", "webauthn-login"} {
		for _, active := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/active=%t", kind, active), func(t *testing.T) {
				engine, err := xorm.NewEngine("sqlite", ":memory:")
				if err != nil {
					t.Fatal(err)
				}
				defer engine.Close()
				engine.SetMaxOpenConns(1)
				engine.SetMaxIdleConns(1)
				engine.DatabaseTZ = time.FixedZone("测试数据库时区", 8*60*60)
				engine.TZLocation = engine.DatabaseTZ
				if err := engine.Sync(new(model.OAuthLoginSession), new(model.WebauthnSession)); err != nil {
					t.Fatal(err)
				}
				ttl := -time.Minute
				if active {
					ttl = time.Minute
				}
				expiry := time.Now().Add(ttl)
				const key = "expiry-test-key"
				svc := NewOAuthProviderService(config.GetDefaultServerConfig(), engine)
				var allowed bool
				switch kind {
				case "state":
					if err := svc.setState(key, oauthStateEntry{ProviderName: "fixture", ExpiresAt: expiry}); err != nil {
						t.Fatal(err)
					}
					_, allowed = svc.popState(key)
				case "ticket":
					if err := svc.setTicket(key, oauthTicketEntry{Provider: "fixture", ExpiresAt: expiry}); err != nil {
						t.Fatal(err)
					}
					_, allowed = svc.popTicket(key)
				case "poll":
					if err := svc.setPollEntry(key, "", expiry); err != nil {
						t.Fatal(err)
					}
					if _, err := engine.Where("key_hash = ?", util.Sha256Hex(key)).Cols("result").Update(&model.OAuthLoginSession{Result: "fixture-cached-result"}); err != nil {
						t.Fatal(err)
					}
					_, allowed = svc.peekPollEntry(key)
					result, err := svc.ConsumePollAndExchange(key)
					if err != nil || (result != "") != active {
						t.Fatal("ERR-2398 过期轮询返回了缓存认证结果")
					}
				case "bind":
					if err := svc.setBindingTicket(key, oauthBindingEntry{Provider: "fixture"}, expiry); err != nil {
						t.Fatal(err)
					}
					_, _, allowed = svc.getBindingTicket(key)
				case "webauthn-register", "webauthn-login":
					sessionKind := "register"
					if kind == "webauthn-login" {
						sessionKind = "login"
					}
					if _, err := engine.Insert(&model.WebauthnSession{KeyHash: util.Sha256Hex(key), Kind: sessionKind, UserId: 1, Status: 1, ExpiresAt: expiry, Challenge: []byte(`{"challenge":"fixture"}`)}); err != nil {
						t.Fatal(err)
					}
					wa := &WebauthnService{db: engine}
					if sessionKind == "register" {
						_, err = wa.popSession(sessionKind, 1)
					} else {
						_, _, err = wa.peekLoginSession()
					}
					allowed = err == nil
				}
				if allowed != active {
					t.Fatal("ERR-2398 临时认证凭据跨时区有效期错误")
				}
			})
		}
	}
}
