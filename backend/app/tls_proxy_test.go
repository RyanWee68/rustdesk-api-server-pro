package app

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"rustdesk-api-server-pro/config"

	"github.com/kataras/iris/v12"
)

// TestTLSConfigurationDoesNotFallback 验证证书配置缺项不会降为另一路径自动重签。
func TestTLSConfigurationDoesNotFallback(t *testing.T) {
	for _, role := range []string{"certificate", "key"} {
		t.Run(role, func(t *testing.T) {
			dir := t.TempDir()
			cfg := &config.ServerConfig{
				Db:         &config.DbConfig{Dsn: filepath.Join(dir, "server.db")},
				HttpConfig: &config.HttpConfig{TLSPort: "invalid-port"},
			}
			if role == "certificate" {
				cfg.HttpConfig.TLSCertFile = filepath.Join(dir, "specified-cert.pem")
			} else {
				cfg.HttpConfig.TLSKeyFile = filepath.Join(dir, "specified-key.pem")
			}
			var logs bytes.Buffer
			application := iris.New()
			application.Logger().SetOutput(&logs)
			startTLSServer(application, cfg, ":12346")
			entries, err := os.ReadDir(dir)
			if err != nil || len(entries) != 0 {
				t.Fatal("不完整的显式配置创建了替代证书或密钥")
			}
			if !strings.Contains(logs.String(), "ERR-B011") {
				t.Fatal("配置拒绝缺少错误编码")
			}
		})
	}
}

// TestTLSProxyRouteBoundary 验证 HTTPS 客户端 API 分流和内部路径边界。
func TestTLSProxyRouteBoundary(t *testing.T) {
	upstream := func(label string) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("X-Forwarded-Proto") != "https" {
				t.Error("HTTPS 来源头未被覆盖")
			}
			body, _ := io.ReadAll(r.Body)
			w.Header().Set("X-Upstream", label)
			_, _ = w.Write([]byte(r.Method + " " + r.URL.RequestURI() + " " + string(body)))
		}))
	}
	admin := upstream("admin")
	defer admin.Close()
	client := upstream("client")
	defer client.Close()
	adminURL, _ := url.Parse(admin.URL)
	clientURL, _ := url.Parse(client.URL)
	server := httptest.NewTLSServer(newTLSProxy(adminURL, clientURL))
	defer server.Close()
	for _, test := range []struct{ path, target string }{
		{"/api", "client"}, {"/api/login?source=web", "client"},
		{"/api/health", "client"}, {"/lic/web/api", "client"},
		{"/lic/web/api/version", "client"}, {"/", "admin"},
		{"/admin/login", "admin"}, {"/downloads/certificate.cer", "admin"},
		{"/internal/rustdesk/connection/check", "admin"},
		{"/apiary", "admin"}, {"/lic/web/apix", "admin"},
		{"/api/../internal/rustdesk/connection/check", "admin"},
		{"/api/%2e%2e/internal/rustdesk/connection/check", "admin"},
		{"/lic/web/api/../../../internal/rustdesk/connection/check", "admin"},
	} {
		t.Run(test.path, func(t *testing.T) {
			req, _ := http.NewRequest(http.MethodPost, server.URL+test.path, strings.NewReader("fixture"))
			req.Header.Set("X-Forwarded-Proto", "http")
			response, err := server.Client().Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			body, _ := io.ReadAll(response.Body)
			if response.Header.Get("X-Upstream") != test.target || string(body) != "POST "+test.path+" fixture" {
				t.Fatalf("HTTPS 路径分流或请求保留不正确: %s", test.path)
			}
		})
	}
}
