package app

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"mime"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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
	setDownloadRoutes(application, dir, map[string]publicDownload{
		"/downloads/rustdesk.jtzxsoft.com.cert.cer": {fileName: "rustdesk.jtzxsoft.com.cert.cer"},
		"/downloads/rustdesk-1.4.9-x86_64.exe":      {fileName: "rustdesk-1.4.9-x86_64.exe"},
	})
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

// TestPublicDownloadsRequireChecksums 验证公开分发文件均固定预期摘要。
func TestPublicDownloadsRequireChecksums(t *testing.T) {
	for routePath, download := range publicDownloads {
		if len(download.sha256) != sha256.Size*2 {
			t.Fatalf("download %s checksum length=%d", routePath, len(download.sha256))
		}
		if _, err := hex.DecodeString(download.sha256); err != nil {
			t.Fatalf("download %s checksum is invalid: %v", routePath, err)
		}
	}
}

// TestPublicDownloadMetadataMatchesConsumers 验证下载页和验收脚本与服务端使用相同摘要。
func TestPublicDownloadMetadataMatchesConsumers(t *testing.T) {
	files := []string{
		filepath.Join("..", "..", "soybean-admin", "src", "views", "about", "downloads", "index.vue"),
		filepath.Join("..", "..", "scripts", "deploy", "controlled-security-check.sh"),
	}
	for _, fileName := range files {
		content, err := os.ReadFile(fileName)
		if err != nil {
			t.Fatal(err)
		}
		contents := strings.ToUpper(strings.ReplaceAll(string(content), ":", ""))
		for routePath, download := range publicDownloads {
			if !strings.Contains(contents, strings.ToUpper(download.fileName)) {
				t.Fatalf("%s is missing file %s", fileName, routePath)
			}
			if !strings.Contains(contents, strings.ToUpper(download.sha256)) {
				t.Fatalf("%s checksum differs for %s", fileName, routePath)
			}
		}
	}
}

// TestDownloadFiles 验证新旧客户端和证书互不串文件、附件命名和分段续传。
func TestDownloadFiles(t *testing.T) {
	dir := t.TempDir()
	files := map[string]string{
		"rustdesk.jtzxsoft.com.cert.cer": "certificate-content",
		"rustdesk-1.4.9-x86_64.exe":      "installer-content",
		"rustdesk-1.5.0-x86_64.exe":      "new-installer-content",
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	application := iris.New()
	testDownloads := make(map[string]publicDownload, len(files))
	for name := range files {
		testDownloads["/downloads/"+name] = publicDownload{fileName: name}
	}
	setDownloadRoutes(application, dir, testDownloads)
	if err := application.Build(); err != nil {
		t.Fatal(err)
	}
	for name, content := range files {
		t.Run(name, func(t *testing.T) {
			response := httptest.NewRecorder()
			application.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/downloads/"+name, nil))
			if response.Code != http.StatusOK || response.Body.String() != content {
				t.Fatalf("download status=%d body=%q", response.Code, response.Body.String())
			}
			_, parameters, err := mime.ParseMediaType(response.Header().Get("Content-Disposition"))
			if err != nil || parameters["filename"] != name {
				t.Fatalf("unexpected attachment header=%q err=%v", response.Header().Get("Content-Disposition"), err)
			}
			request := httptest.NewRequest(http.MethodGet, "/downloads/"+name, nil)
			request.Header.Set("Range", "bytes=0-3")
			response = httptest.NewRecorder()
			application.ServeHTTP(response, request)
			if response.Code != http.StatusPartialContent || response.Body.String() != content[:4] {
				t.Fatalf("range status=%d body=%q", response.Code, response.Body.String())
			}
		})
	}
}

// TestDownloadRejectsChecksumMismatch 验证固定安装包被替换后不会继续公开下载。
func TestDownloadRejectsChecksumMismatch(t *testing.T) {
	dir := t.TempDir()
	fileName := "rustdesk-1.4.9-x86_64.exe"
	content := []byte("expected-installer")
	expected := fmt.Sprintf("%X", sha256.Sum256(content))
	if err := os.WriteFile(filepath.Join(dir, fileName), []byte("replaced-installer"), 0600); err != nil {
		t.Fatal(err)
	}

	application := iris.New()
	setDownloadRoutes(application, dir, map[string]publicDownload{
		"/downloads/" + fileName: {fileName: fileName, sha256: expected},
	})
	if err := application.Build(); err != nil {
		t.Fatal(err)
	}

	response := httptest.NewRecorder()
	application.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/downloads/"+fileName, nil))
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("checksum mismatch status=%d body=%q", response.Code, response.Body.String())
	}
	var body struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Code != errcode.ERRB009.Code {
		t.Fatalf("code=%q want=%q", body.Code, errcode.ERRB009.Code)
	}

	if err := os.WriteFile(filepath.Join(dir, fileName), content, 0600); err != nil {
		t.Fatal(err)
	}
	response = httptest.NewRecorder()
	application.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/downloads/"+fileName, nil))
	if response.Code != http.StatusOK || response.Body.String() != string(content) {
		t.Fatalf("verified download status=%d body=%q", response.Code, response.Body.String())
	}
}

// TestDownloadRejectsDirectories 验证白名单文件名对应目录时仍不能下载。
func TestDownloadRejectsDirectories(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "rustdesk-1.4.9-x86_64.exe"), 0700); err != nil {
		t.Fatal(err)
	}
	application := iris.New()
	SetDownloadRoutes(application, dir)
	if err := application.Build(); err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	application.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/downloads/rustdesk-1.4.9-x86_64.exe", nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("directory status=%d", response.Code)
	}
}

// TestDownloadRejectsSymlinks 验证固定下载名不能通过符号链接公开目录外文件。
func TestDownloadRejectsSymlinks(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(t.TempDir(), "private.key")
	if err := os.WriteFile(target, []byte("private-material"), 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "rustdesk.jtzxsoft.com.cert.cer")
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("当前系统不能创建符号链接：%v", err)
	}

	application := iris.New()
	SetDownloadRoutes(application, dir)
	if err := application.Build(); err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	application.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/downloads/rustdesk.jtzxsoft.com.cert.cer", nil))
	if response.Code != http.StatusNotFound || response.Body.String() == "private-material" {
		t.Fatalf("symlink status=%d body=%q", response.Code, response.Body.String())
	}
}
