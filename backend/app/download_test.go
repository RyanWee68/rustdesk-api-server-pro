package app

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"rustdesk-api-server-pro/internal/errcode"

	"github.com/kataras/iris/v12"
)

// TestDownloadRoutes 验证仅允许下载两个固定文件，且缺失文件返回统一错误码。
func TestDownloadRoutes(t *testing.T) {
	dir := t.TempDir()
	content := []byte("test-certificate")
	if err := os.WriteFile(filepath.Join(dir, "rustdesk.jtzxsoft.com.cert.cer"), content, 0600); err != nil {
		t.Fatal(err)
	}

	application := iris.New()
	SetDownloadRoutes(application, dir)
	if err := application.Build(); err != nil {
		t.Fatal(err)
	}

	response := httptest.NewRecorder()
	application.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/downloads/rustdesk.jtzxsoft.com.cert.cer", nil))
	if response.Code != http.StatusOK || string(response.Body.Bytes()) != string(content) {
		t.Fatalf("certificate status=%d body=%q", response.Code, response.Body.String())
	}
	if response.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal("missing nosniff header")
	}

	response = httptest.NewRecorder()
	application.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/downloads/rustdesk-1.4.9-x86_64.exe", nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("missing installer status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Code != errcode.ERRB007.Code {
		t.Fatalf("code=%q want=%q", body.Code, errcode.ERRB007.Code)
	}

	response = httptest.NewRecorder()
	application.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/downloads/../server.db", nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("unexpected path status=%d", response.Code)
	}
}
