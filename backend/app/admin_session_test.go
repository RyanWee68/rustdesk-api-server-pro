package app

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/util"
)

// TestAdminPasswordLoginRoles 验证真实管理路由登录后正确返回角色，且普通账号不会提升权限。
func TestAdminPasswordLoginRoles(t *testing.T) {
	for _, admin := range []bool{true, false} {
		role := "R_USER"
		if admin {
			role = "R_SUPER"
		}
		t.Run(role, func(t *testing.T) {
			engine := newInternalRouteTestEngine(t)
			if err := engine.Sync(new(model.User), new(model.AuthToken), new(model.SecurityAudit)); err != nil {
				t.Fatal(err)
			}
			cfg := config.GetDefaultServerConfig()
			cfg.DisableLoginCaptcha = true
			application, err := newBaseApp(cfg, engine)
			if err != nil {
				t.Fatal(err)
			}
			application.Logger().SetLevel("error")
			SetAdminRoute(application)
			if err := application.Build(); err != nil {
				t.Fatal(err)
			}
			password, err := util.Password("admin-role-regression-password")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := engine.Insert(&model.User{Username: "role-fixture", Name: "角色测试", Password: password, Status: 1, IsAdmin: admin}); err != nil {
				t.Fatal(err)
			}
			login := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/admin/auth/login", strings.NewReader(`{"username":"role-fixture","password":"admin-role-regression-password"}`))
			req.Header.Set("Content-Type", "application/json")
			application.ServeHTTP(login, req)
			var result struct {
				Code int `json:"code"`
				Data struct {
					Token string `json:"token"`
				} `json:"data"`
			}
			if json.Unmarshal(login.Body.Bytes(), &result) != nil || result.Code != 200 || result.Data.Token == "" {
				t.Fatal("ERR-2398 管理密码登录未成功")
			}
			info := httptest.NewRecorder()
			req = httptest.NewRequest(http.MethodGet, "/admin/userinfo", nil)
			req.Header.Set("Authorization", result.Data.Token)
			application.ServeHTTP(info, req)
			var user struct {
				Code int `json:"code"`
				Data struct {
					Roles []string `json:"roles"`
				} `json:"data"`
			}
			if json.Unmarshal(info.Body.Bytes(), &user) != nil || user.Code != 200 || len(user.Data.Roles) != 1 || user.Data.Roles[0] != role {
				t.Fatalf("ERR-2398 登录后角色错误：HTTP %d，业务码 %d，角色 %v", info.Code, user.Code, user.Data.Roles)
			}
		})
	}
}
