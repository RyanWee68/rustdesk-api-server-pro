package admin

import (
	"net/http/httptest"
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"

	"github.com/kataras/iris/v12"
	"github.com/kataras/iris/v12/mvc"
	_ "modernc.org/sqlite"
	"xorm.io/xorm"
)

// TestDeviceLoginUsernames 验证账号与系统登录名分离，并排除失效及后台会话。
func TestDeviceLoginUsernames(t *testing.T) {
	engine, err := xorm.NewEngine("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Close()
	engine.SetMaxOpenConns(1)
	engine.DatabaseTZ = time.FixedZone("测试时区", 8*60*60)
	engine.TZLocation = engine.DatabaseTZ
	if err := engine.Sync(new(model.AuthToken), new(model.User), new(model.Device)); err != nil {
		t.Fatal(err)
	}
	users := []model.User{{Id: 1, Username: "zhaowei", Name: "赵伟"}, {Id: 2, Username: "other"}}
	if _, err := engine.Insert(&users); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 13, 10, 0, 0, 0, time.UTC)
	tokens := []model.AuthToken{
		{UserId: 1, RustdeskId: "443005947", Status: 1, Expired: now.Add(time.Hour)},
		{UserId: 1, RustdeskId: "487921466", Status: 1, Expired: now.Add(time.Hour)},
		{UserId: 2, RustdeskId: "487921466", Status: 1, Expired: now.Add(time.Hour)},
		{UserId: 2, RustdeskId: "443005947", Status: 0, Expired: now.Add(time.Hour)},
		{UserId: 2, RustdeskId: "443005947", Status: 1, Expired: now},
		{UserId: 2, RustdeskId: "443005947", Status: 1, IsAdmin: true, Expired: now.Add(time.Hour)},
		{UserId: 1, RustdeskId: "expired", Status: 1, Expired: now.Add(-time.Second)},
		{UserId: 1, RustdeskId: "outside-page", Status: 1, Expired: now.Add(time.Hour)},
	}
	if _, err := engine.Insert(&tokens); err != nil {
		t.Fatal(err)
	}
	devices := []model.Device{
		{RustdeskId: "443005947", Username: "Administrator"},
		{RustdeskId: "487921466", Username: "wbf"},
		{RustdeskId: "expired"}, {RustdeskId: "no-login"},
	}
	if _, err := engine.Insert(&devices); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name       string
		actor      *model.User
		wantSecond string
	}{
		{"管理员读取最近有效账号", &model.User{IsAdmin: true}, "other"},
		{"普通用户只读本人账号", &users[0], "zhaowei"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := findDeviceLoginUsernames(engine, devices, tc.actor, now)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != 2 || got["443005947"].Username != "zhaowei" || got["443005947"].Name != "赵伟" || got["487921466"].Username != tc.wantSecond {
				t.Fatalf("ERR-2398 登录账号映射错误：%v", got)
			}
			if tc.actor.IsAdmin && got["487921466"].Name != "" {
				t.Fatal("ERR-2398 最近账号无昵称时不得沿用其他账号昵称")
			}
		})
	}
	for _, devices := range [][]model.Device{nil, devices} {
		got, err := findDeviceLoginUsernames(engine, devices, nil, now)
		if err != nil || len(got) != 0 {
			t.Fatalf("ERR-2398 未登录调用不应返回账号：%v %v", got, err)
		}
	}
	if got, err := findDeviceLoginUsernames(engine, nil, &users[0], now); err != nil || len(got) != 0 {
		t.Fatalf("ERR-2398 空分页不应读取其他设备：%v %v", got, err)
	}

	app := iris.New()
	ctx := app.ContextPool.Acquire(httptest.NewRecorder(), httptest.NewRequest("GET", "/devices/list", nil))
	defer app.ContextPool.Release(ctx)
	ctx.Values().Set(config.AdminUserKey, &model.User{IsAdmin: true})
	controller := DevicesController{basicController{Ctx: ctx, Db: engine}}
	// 用当前时间签发测试会话，以覆盖实际列表响应中的两列。
	if _, err := engine.Where("id > 0").Cols("expired").Update(&model.AuthToken{Expired: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	result := controller.HandleList().(mvc.Response).Object.(iris.Map)
	if result["code"] != 200 {
		t.Fatalf("ERR-2398 列表响应失败：%v", result)
	}
	records := result["data"].(iris.Map)["records"].([]iris.Map)
	found := false
	for _, row := range records {
		if row["rustdesk_id"] == "487921466" {
			found = true
			if row["username"] != "wbf" || row["rustdesk_username"] != "other" || row["rustdesk_nickname"] != "" {
				t.Fatalf("ERR-2398 列表混用了系统和客户端账号：%v", row)
			}
		}
		if _, exists := row["token"]; exists {
			t.Fatal("ERR-2398 列表不得返回令牌")
		}
	}
	if !found {
		t.Fatal("ERR-2398 列表遗漏设备")
	}
}
