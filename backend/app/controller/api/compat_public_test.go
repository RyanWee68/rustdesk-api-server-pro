package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/db"

	"github.com/kataras/iris/v12"
)

// TestRustdeskOIDCQueryResponse 验证轮询接口直接输出客户端需要解析的认证体。
func TestRustdeskOIDCQueryResponse(t *testing.T) {
	inner := `{"access_token":"token","type":"access_token","user":{"name":"tester","status":1,"info":{}}}`
	response := rustdeskOIDCQueryResponse(inner)
	if response.ContentType != "application/json; charset=utf-8" {
		t.Fatalf("unexpected content type: %s", response.ContentType)
	}

	var result map[string]interface{}
	if err := json.Unmarshal([]byte(response.Text), &result); err != nil {
		t.Fatalf("decode auth response: %v", err)
	}
	if result["type"] != "access_token" {
		t.Fatalf("response must be the direct auth body: %s", response.Text)
	}
	if _, exists := result["body"]; exists {
		t.Fatalf("response must not add a second body wrapper: %s", response.Text)
	}
}

// TestRustdesk150PublicLoginContracts 验证新版登录选项格式，且不信任客户端新增的 apiDomain。
func TestRustdesk150PublicLoginContracts(t *testing.T) {
	engine, err := db.NewEngine(&config.DbConfig{Driver: "sqlite", Dsn: ":memory:", TimeZone: "Asia/Shanghai"})
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Close()
	engine.SetMaxOpenConns(1)
	if err := engine.Sync(new(model.CompatAPIAudit), new(model.OAuthLoginSession)); err != nil {
		t.Fatal(err)
	}
	application := iris.New()
	loginOptions := func(ctx iris.Context) {
		controller := LoginController{basicController: basicController{Ctx: ctx, Db: engine}}
		controller.HandleLoginOptions().Dispatch(ctx)
	}
	application.Get("/api/login-options", loginOptions)
	application.Post("/api/login-options", loginOptions)
	application.Post("/api/oidc/auth", func(ctx iris.Context) {
		controller := CompatPublicController{basicController: basicController{Ctx: ctx, Db: engine}}
		controller.HandleOidcAuth().Dispatch(ctx)
	})
	if err := application.Build(); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{http.MethodGet, http.MethodPost} {
		response := httptest.NewRecorder()
		application.ServeHTTP(response, httptest.NewRequest(method, "/api/login-options", nil))
		var options []string
		if response.Code != http.StatusOK || json.Unmarshal(response.Body.Bytes(), &options) != nil {
			t.Fatalf("ERR-2398 登录选项响应格式不兼容：%d %s", response.Code, response.Body.String())
		}
		if len(options) != 1 || options[0] != "oidc/webauth" {
			t.Fatalf("ERR-2398 默认登录选项错误：%v", options)
		}
	}
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "https://api.example.test/api/oidc/auth", strings.NewReader(
		`{"op":"oidc/webauth","id":"150-test","uuid":"150-uuid","deviceInfo":{"os":"Windows","type":"desktop","name":"test"},"apiDomain":"https://untrusted.example.test"}`))
	request.Header.Set("Content-Type", "application/json")
	application.ServeHTTP(response, request)
	var auth struct {
		Code string `json:"code"`
		URL  string `json:"url"`
	}
	if response.Code != http.StatusOK || json.Unmarshal(response.Body.Bytes(), &auth) != nil || auth.Code == "" ||
		!strings.HasPrefix(auth.URL, "https://api.example.test/#/client-webauth?poll_token=") {
		t.Fatalf("ERR-2398 新版 OIDC 响应错误或使用了不可信入口：%d %s", response.Code, response.Body.String())
	}
}
