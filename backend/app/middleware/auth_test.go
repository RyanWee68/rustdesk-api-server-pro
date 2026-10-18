package middleware

import (
	"fmt"
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/util"

	_ "modernc.org/sqlite"
	"xorm.io/xorm"
)

// TestAuthTokenExpiryUsesDatabaseTimezone 验证 UTC 进程与东八区数据库之间不扩大令牌有效期。
func TestAuthTokenExpiryUsesDatabaseTimezone(t *testing.T) {
	previous := time.Local
	time.Local = time.UTC
	t.Cleanup(func() { time.Local = previous })
	engine, err := xorm.NewEngine("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Close()
	engine.SetMaxOpenConns(1)
	engine.SetMaxIdleConns(1)
	engine.DatabaseTZ = time.FixedZone("测试数据库时区", 8*60*60)
	engine.TZLocation = engine.DatabaseTZ
	if err := engine.Sync(new(model.AuthToken)); err != nil {
		t.Fatal(err)
	}
	for _, admin := range []bool{false, true} {
		for _, legacy := range []bool{false, true} {
			for _, active := range []bool{false, true} {
				t.Run(fmt.Sprintf("admin=%t/legacy=%t/active=%t", admin, legacy, active), func(t *testing.T) {
					token := fmt.Sprintf("fixture-%t-%t-%t", admin, legacy, active)
					ttl := -time.Hour
					if active {
						ttl = time.Hour
					}
					saved := model.AuthToken{UserId: 1, RustdeskId: "device", Expired: time.Now().Add(ttl), IsAdmin: admin, Status: 1}
					if legacy {
						saved.Token = token
					} else {
						saved.TokenHash = util.Sha256Hex(token)
					}
					if _, err := engine.Insert(&saved); err != nil {
						t.Fatal(err)
					}
					found, ok, err := getActiveAuthToken(engine, token, admin)
					if err != nil || ok != active {
						t.Fatal("ERR-2398 跨时区令牌有效期判断错误")
					}
					if ok && (found.Token != "" || found.TokenHash != util.Sha256Hex(token)) {
						t.Fatal("ERR-2398 有效历史令牌未安全迁移为摘要")
					}
					if _, ok, err := getActiveAuthToken(engine, token, !admin); err != nil || ok {
						t.Fatal("ERR-2398 令牌会话类型边界失效")
					}
				})
			}
		}
	}
}
