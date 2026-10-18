package service

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"rustdesk-api-server-pro/app/form/api"
	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/db"
	"rustdesk-api-server-pro/util"

	"github.com/kataras/iris/v12"
	"github.com/pquerna/otp/totp"
	_ "modernc.org/sqlite"
	"xorm.io/xorm"
)

// newLoginTestService 建立独立内存登录库，不使用业务配置或外部邮件服务。
func newLoginTestService(t *testing.T) (*UserService, *xorm.Engine) {
	t.Helper()
	engine, err := xorm.NewEngine("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	engine.SetMaxOpenConns(1)
	engine.SetMaxIdleConns(1)
	engine.DatabaseTZ = time.FixedZone("测试数据库时区", 8*60*60)
	engine.TZLocation = engine.DatabaseTZ
	if err := engine.Sync(new(model.User), new(model.AuthToken), new(model.VerifyCode)); err != nil {
		t.Fatal(err)
	}
	previous := db.DbEngine
	db.DbEngine = engine
	t.Cleanup(func() { db.DbEngine = previous; _ = engine.Close() })
	password, err := util.Password("login-test-password")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Insert(&model.User{Id: 1, Username: "login-test", Name: "测试用户", Password: password, Status: 1, TwoFactorAuthSecret: "JBSWY3DPEHPK3PXP"}); err != nil {
		t.Fatal(err)
	}
	cfg := config.GetDefaultServerConfig()
	cfg.SignKey = "login-test-signing-key-only"
	return &UserService{config: cfg}, engine
}

// assertLoginDenied 检查失败响应不包含令牌、挑战秘密或数据库错误细节。
func assertLoginDenied(t *testing.T, result iris.Map, code string) {
	t.Helper()
	message, ok := result["error"].(string)
	if !ok || !strings.HasPrefix(message, code+":") || result["access_token"] != nil || result["secret"] != nil || strings.Contains(message, "private-storage-detail") {
		t.Fatalf("ERR-2398 登录未按预期拒绝：期望 %s", code)
	}
}

// TestLoginStorageFailures 验证撤销或签发写入失败时不假报成功，且原有效会话不丢失。
func TestLoginStorageFailures(t *testing.T) {
	for _, operation := range []string{"UPDATE OF status", "INSERT"} {
		t.Run(operation, func(t *testing.T) {
			svc, engine := newLoginTestService(t)
			if _, err := engine.Insert(&model.AuthToken{UserId: 1, RustdeskId: "device", TokenHash: util.Sha256Hex("old-session"), Status: 1, Expired: time.Now().Add(time.Hour)}); err != nil {
				t.Fatal(err)
			}
			if _, err := engine.Exec("CREATE TRIGGER fail_write BEFORE " + operation + " ON auth_token BEGIN SELECT RAISE(FAIL, 'private-storage-detail'); END"); err != nil {
				t.Fatal(err)
			}
			result := svc.Login(api.LoginForm{Username: "login-test", Password: "login-test-password", RustdeskId: "device", Uuid: "device-uuid"})
			assertLoginDenied(t, result, "ERR-B010")
			var old model.AuthToken
			if found, err := engine.Where("token_hash = ?", util.Sha256Hex("old-session")).Get(&old); err != nil || !found || old.Status != 1 {
				t.Fatal("ERR-2398 签发失败破坏了原会话")
			}
			if count, err := engine.Count(new(model.AuthToken)); err != nil || count != 1 {
				t.Fatal("ERR-2398 签发失败遗留了新会话")
			}
		})
	}
}

// newMFATestChallenge 创建邮箱或 2FA 的合成待核销挑战，不发送邮件。
func newMFATestChallenge(t *testing.T, engine *xorm.Engine, kind int) (model.VerifyCode, api.LoginForm) {
	t.Helper()
	challenge := model.VerifyCode{UserId: 1, Type: kind, Uuid: "mfa-challenge", RustdeskId: "mfa-device", Code: "246810", Status: model.VC_STATUS_UNUSED, Expired: time.Now().Add(10 * time.Minute)}
	if _, err := engine.Insert(&challenge); err != nil {
		t.Fatal(err)
	}
	form := api.LoginForm{RustdeskId: challenge.RustdeskId, Uuid: "mfa-device-uuid", Secret: challenge.Uuid, VerificationCode: challenge.Code}
	if kind == model.VC_TYPE_2FA {
		code, err := totp.GenerateCode("JBSWY3DPEHPK3PXP", time.Now())
		if err != nil {
			t.Fatal(err)
		}
		form.TfaCode, form.VerificationCode = code, code
	}
	return challenge, form
}

// TestMFALoginRules 覆盖两种二次验证的有效期、账号、设备绑定及一次性使用边界。
func TestMFALoginRules(t *testing.T) {
	for _, kind := range []int{model.VC_TYPE_MAIL, model.VC_TYPE_2FA} {
		for _, rule := range []string{"expired", "missing-expiry", "disabled", "deleted-user", "used", "wrong-device", "wrong-secret", "wrong-code", "valid"} {
			t.Run(fmt.Sprintf("%d/%s", kind, rule), func(t *testing.T) {
				svc, engine := newLoginTestService(t)
				challenge, form := newMFATestChallenge(t, engine, kind)
				var err error
				switch rule {
				case "expired":
					_, err = engine.ID(challenge.Id).Cols("expired").Update(&model.VerifyCode{Expired: time.Now().Add(-time.Minute)})
				case "missing-expiry":
					_, err = engine.ID(challenge.Id).Cols("expired").Update(&model.VerifyCode{})
				case "disabled":
					_, err = engine.ID(1).Cols("status").Update(&model.User{Status: 0})
				case "deleted-user":
					_, err = engine.ID(1).Delete(new(model.User))
				case "used":
					_, err = engine.ID(challenge.Id).Cols("status").Update(&model.VerifyCode{Status: model.VC_STATUS_USED})
				case "wrong-device":
					form.RustdeskId = "another-device"
				case "wrong-secret":
					form.Secret = "another-secret"
				case "wrong-code":
					form.VerificationCode, form.TfaCode = "invalid", "invalid"
				}
				if err != nil {
					t.Fatal(err)
				}
				verify := svc.LoginVerifyByEmailCode
				if kind == model.VC_TYPE_2FA {
					verify = svc.LoginVerifyBy2FACode
				}
				result := verify(form)
				if rule != "valid" {
					code := "ERR-1006"
					if rule == "disabled" {
						code = "ERR-1012"
					}
					if rule == "deleted-user" {
						code = "ERR-1004"
					}
					assertLoginDenied(t, result, code)
					if count, err := engine.Count(new(model.AuthToken)); err != nil || count != 0 {
						t.Fatal("ERR-2398 验证失败仍产生了登录会话")
					}
					return
				}
				if token, ok := result["access_token"].(string); !ok || token == "" {
					t.Fatal("ERR-2398 有效二次验证未签发会话")
				}
				assertLoginDenied(t, verify(form), "ERR-1006")
				if count, err := engine.Count(new(model.AuthToken)); err != nil || count != 1 {
					t.Fatal("ERR-2398 重放产生了额外会话")
				}
			})
		}
	}
}

// TestMFAStorageRollback 验证三处写入任一失败均回滚挑战和原会话，可正常重试。
func TestMFAStorageRollback(t *testing.T) {
	for _, kind := range []int{model.VC_TYPE_MAIL, model.VC_TYPE_2FA} {
		for _, failure := range []string{"UPDATE OF status ON verify_code", "UPDATE OF status ON auth_token", "INSERT ON auth_token"} {
			t.Run(fmt.Sprintf("%d/%s", kind, failure), func(t *testing.T) {
				svc, engine := newLoginTestService(t)
				challenge, form := newMFATestChallenge(t, engine, kind)
				if _, err := engine.Insert(&model.AuthToken{UserId: 1, RustdeskId: form.RustdeskId, TokenHash: util.Sha256Hex("old-session"), Status: 1, Expired: time.Now().Add(time.Hour)}); err != nil {
					t.Fatal(err)
				}
				if _, err := engine.Exec("CREATE TRIGGER fail_write BEFORE " + failure + " BEGIN SELECT RAISE(FAIL, 'private-storage-detail'); END"); err != nil {
					t.Fatal(err)
				}
				verify := svc.LoginVerifyByEmailCode
				if kind == model.VC_TYPE_2FA {
					verify = svc.LoginVerifyBy2FACode
				}
				assertLoginDenied(t, verify(form), "ERR-B010")
				var saved model.VerifyCode
				if found, err := engine.ID(challenge.Id).Get(&saved); err != nil || !found || saved.Status != model.VC_STATUS_UNUSED {
					t.Fatal("ERR-2398 落库失败消耗了验证挑战")
				}
				var old model.AuthToken
				if found, err := engine.Where("token_hash = ?", util.Sha256Hex("old-session")).Get(&old); err != nil || !found || old.Status != 1 {
					t.Fatal("ERR-2398 落库失败撤销了原会话")
				}
				if _, err := engine.Exec("DROP TRIGGER fail_write"); err != nil {
					t.Fatal(err)
				}
				if token, ok := verify(form)["access_token"].(string); !ok || token == "" {
					t.Fatal("ERR-2398 数据库恢复后不能重试验证")
				}
			})
		}
	}
}

// TestMFAConcurrentReplay 验证同一挑战八路并发仅一次签发。
func TestMFAConcurrentReplay(t *testing.T) {
	for _, kind := range []int{model.VC_TYPE_MAIL, model.VC_TYPE_2FA} {
		t.Run(fmt.Sprint(kind), func(t *testing.T) {
			svc, engine := newLoginTestService(t)
			_, form := newMFATestChallenge(t, engine, kind)
			verify := svc.LoginVerifyByEmailCode
			if kind == model.VC_TYPE_2FA {
				verify = svc.LoginVerifyBy2FACode
			}
			var group sync.WaitGroup
			results := make(chan iris.Map, 8)
			for i := 0; i < 8; i++ {
				group.Add(1)
				go func() { defer group.Done(); results <- verify(form) }()
			}
			group.Wait()
			close(results)
			allowed := 0
			for result := range results {
				if token, ok := result["access_token"].(string); ok && token != "" {
					allowed++
				} else {
					assertLoginDenied(t, result, "ERR-1006")
				}
			}
			if count, err := engine.Count(new(model.AuthToken)); err != nil || allowed != 1 || count != 1 {
				t.Fatal("ERR-2398 同一挑战并发签发了多次会话")
			}
		})
	}
}

// TestMFATransactionRechecksExpiry 验证挑战在预校验后过期时，事务仍按入库时区拒绝核销。
func TestMFATransactionRechecksExpiry(t *testing.T) {
	previous := time.Local
	time.Local = time.UTC
	t.Cleanup(func() { time.Local = previous })
	svc, engine := newLoginTestService(t)
	challenge, form := newMFATestChallenge(t, engine, model.VC_TYPE_2FA)
	if _, err := engine.ID(challenge.Id).Cols("expired").Update(&model.VerifyCode{Expired: time.Now().Add(-time.Minute)}); err != nil {
		t.Fatal(err)
	}
	if token, err := svc.GetLoginToken(form, 1, challenge.Id); token != "" || err == nil || !strings.HasPrefix(err.Error(), "ERR-1006:") {
		t.Fatal("ERR-2398 事务未重新拒绝过期挑战")
	}
	if count, err := engine.Count(new(model.AuthToken)); err != nil || count != 0 {
		t.Fatal("ERR-2398 过期挑战核销产生了令牌")
	}
}

// TestTFAChallengeCreation 验证新挑战有明确有效期，数据库拒绝时不返回挑战秘密。
func TestTFAChallengeCreation(t *testing.T) {
	svc, engine := newLoginTestService(t)
	if _, err := engine.ID(1).Cols("login_verify").Update(&model.User{LoginVerify: model.LOGIN_TFA_CHECK}); err != nil {
		t.Fatal(err)
	}
	form := api.LoginForm{Username: "login-test", Password: "login-test-password", RustdeskId: "device"}
	result := svc.Login(form)
	if secret, ok := result["secret"].(string); !ok || secret == "" {
		t.Fatal("ERR-2398 未生成二次验证挑战")
	}
	var challenge model.VerifyCode
	if found, err := engine.Get(&challenge); err != nil || !found || !challenge.Expired.After(time.Now()) || challenge.Expired.After(time.Now().Add(11*time.Minute)) {
		t.Fatal("ERR-2398 二次验证挑战缺少有限有效期")
	}
	if _, err := engine.Exec("CREATE TRIGGER fail_challenge BEFORE INSERT ON verify_code BEGIN SELECT RAISE(FAIL, 'private-storage-detail'); END"); err != nil {
		t.Fatal(err)
	}
	assertLoginDenied(t, svc.Login(form), "ERR-B010")
}
