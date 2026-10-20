package app

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/internal/errcode"

	_ "modernc.org/sqlite"
	"xorm.io/xorm"
)

// TestRustdeskInternalRouteRequiresSecret 验证 RustDesk 内部接口必须携带内部密钥。
func TestRustdeskInternalRouteRequiresSecret(t *testing.T) {
	engine := newInternalRouteTestEngine(t)
	application, err := newBaseApp(&config.ServerConfig{
		DebugMode: false,
		HttpConfig: &config.HttpConfig{
			Port: ":0",
		},
		RustdeskServer: &config.RustdeskServerConfig{
			InternalSecret:   "0123456789abcdef0123456789abcdef",
			AuthCacheSeconds: 30,
		},
	}, engine)
	if err != nil {
		t.Fatal(err)
	}
	SetInternalRoute(application)
	if err = application.Build(); err != nil {
		t.Fatal(err)
	}

	payload := map[string]string{"rustdesk_id": "rd-1", "uuid": "uuid-1"}

	response := performInternalRouteJSON(application, payload, "")
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("missing secret status=%d", response.Code)
	}
	assertInternalRouteCode(t, response, errcode.ERR2301.Code)

	response = performInternalRouteJSON(application, payload, "wrong-secret")
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("wrong secret status=%d", response.Code)
	}
	assertInternalRouteCode(t, response, errcode.ERR2301.Code)

	response = performInternalRouteJSON(application, payload, "0123456789abcdef0123456789abcdef")
	if response.Code != http.StatusOK {
		t.Fatalf("valid secret status=%d body=%s", response.Code, response.Body.String())
	}
	assertInternalRouteCode(t, response, errcode.ERR2305.Code)

	response = performInternalRouteBearerJSON(application, payload, "0123456789abcdef0123456789abcdef")
	if response.Code != http.StatusOK {
		t.Fatalf("valid bearer secret status=%d body=%s", response.Code, response.Body.String())
	}
	assertInternalRouteCode(t, response, errcode.ERR2305.Code)

	auditCount, err := engine.Where("resource_type = ? and resource_id = ?", "rustdesk_admission", "rd-1").Count(new(model.OperationAudit))
	if err != nil {
		t.Fatal(err)
	}
	if auditCount != 2 {
		t.Fatalf("admission audit count=%d want 2", auditCount)
	}
}

func newInternalRouteTestEngine(t *testing.T) *xorm.Engine {
	t.Helper()
	// 固定单连接，无须共享命名缓存，避免重复运行复用残留测试数据。
	engine, err := xorm.NewEngine("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	engine.SetMaxOpenConns(1)
	engine.SetMaxIdleConns(1)
	t.Cleanup(func() { _ = engine.Close() })
	if err = engine.Sync(new(model.Device), new(model.ContainerLog), new(model.OperationAudit)); err != nil {
		t.Fatal(err)
	}
	return engine
}

func performInternalRouteJSON(application http.Handler, payload interface{}, secret string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(payload)
	request := httptest.NewRequest(http.MethodPost, "/internal/rustdesk/device/register", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	if secret != "" {
		request.Header.Set("X-Internal-Secret", secret)
	}
	response := httptest.NewRecorder()
	application.ServeHTTP(response, request)
	return response
}

func performInternalRouteBearerJSON(application http.Handler, payload interface{}, secret string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(payload)
	request := httptest.NewRequest(http.MethodPost, "/internal/rustdesk/device/register", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+secret)
	response := httptest.NewRecorder()
	application.ServeHTTP(response, request)
	return response
}

func assertInternalRouteCode(t *testing.T, response *httptest.ResponseRecorder, want string) {
	t.Helper()
	var body struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body %q: %v", response.Body.String(), err)
	}
	if body.Code != want {
		t.Fatalf("code=%q want=%q body=%s", body.Code, want, response.Body.String())
	}
}
