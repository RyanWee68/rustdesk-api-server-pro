package util

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// TestGenerateSelfSignedCert 验证签发内容、独占创建和已有文件保护。
func TestGenerateSelfSignedCert(t *testing.T) {
	for _, existing := range []string{"certificate", "key", "both", "none"} {
		t.Run(existing, func(t *testing.T) {
			dir := t.TempDir()
			cert, key := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
			for _, item := range []struct{ kind, path string }{{"certificate", cert}, {"key", key}} {
				if existing == item.kind || existing == "both" {
					if err := os.WriteFile(item.path, []byte("existing-material"), 0600); err != nil {
						t.Fatal(err)
					}
				}
			}
			_, _, err := GenerateSelfSignedCert(cert, key, []string{"rustdesk.example.test", "127.0.0.1"})
			if existing == "none" {
				if err != nil {
					t.Fatal(err)
				}
				pair, err := tls.LoadX509KeyPair(cert, key)
				if err != nil {
					t.Fatal(err)
				}
				for _, host := range []string{"rustdesk.example.test", "127.0.0.1"} {
					if err := pair.Leaf.VerifyHostname(host); err != nil {
						t.Fatal(err)
					}
				}
				if time.Until(pair.Leaf.NotAfter) < 9*365*24*time.Hour {
					t.Fatal("原有十年有效期不应缩短")
				}
				if runtime.GOOS != "windows" {
					info, err := os.Stat(key)
					if err != nil || info.Mode().Perm() != 0600 {
						t.Fatalf("私钥权限应为 0600: %v", err)
					}
				}
				return
			}
			if err == nil {
				t.Fatal("已有证书或私钥不应被覆盖")
			}
			for _, item := range []struct{ kind, path string }{{"certificate", cert}, {"key", key}} {
				content, readErr := os.ReadFile(item.path)
				if existing == item.kind || existing == "both" {
					if readErr != nil || string(content) != "existing-material" {
						t.Fatal("已有文件内容改变")
					}
				} else if !os.IsNotExist(readErr) {
					t.Fatal("签发失败后遗留了不完整新文件")
				}
			}
		})
	}
}

// TestConcurrentCertificateCreation 确保并发签发仅一份成功且最终证书与私钥匹配。
func TestConcurrentCertificateCreation(t *testing.T) {
	dir := t.TempDir()
	cert, key := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	results := make(chan error, 8)
	var group sync.WaitGroup
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			_, _, err := GenerateSelfSignedCert(cert, key, nil)
			results <- err
		}()
	}
	group.Wait()
	close(results)
	success := 0
	for err := range results {
		if err == nil {
			success++
		}
	}
	if success != 1 {
		t.Fatalf("应仅有一次签发成功，实际 %d", success)
	}
	if _, err := tls.LoadX509KeyPair(cert, key); err != nil {
		t.Fatal(err)
	}
}

// TestTLSGenerationFailureCleanup 验证证书路径失败时只回收本次新建私钥。
func TestTLSGenerationFailureCleanup(t *testing.T) {
	dir := t.TempDir()
	cert, key := filepath.Join(dir, "existing-directory"), filepath.Join(dir, "key.pem")
	if err := os.Mkdir(cert, 0700); err != nil {
		t.Fatal(err)
	}
	if _, _, err := GenerateSelfSignedCert(cert, key, nil); err == nil {
		t.Fatal("证书目录不应接受为文件")
	}
	if _, err := os.Stat(key); !os.IsNotExist(err) {
		t.Fatal("失败后未清理本次创建的私钥")
	}
	if info, err := os.Stat(cert); err != nil || !info.IsDir() {
		t.Fatal("既有目录被修改")
	}
}

// TestLoadOrCreateTLSCertificate 验证不完整材料、错误配对、过期与权限失败时保留原文件。
func TestLoadOrCreateTLSCertificate(t *testing.T) {
	for _, scenario := range []string{"new", "existing", "cert-only", "key-only", "mismatch", "invalid", "expired", "future", "directory", "wide-mode"} {
		t.Run(scenario, func(t *testing.T) {
			if scenario == "wide-mode" && runtime.GOOS == "windows" {
				t.Skip("Windows 需要独立验证 ACL，不以 POSIX mode 代替")
			}
			dir := t.TempDir()
			cert, key := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
			if scenario != "new" && scenario != "directory" {
				if _, _, err := GenerateSelfSignedCert(cert, key, nil); err != nil {
					t.Fatal(err)
				}
			}
			switch scenario {
			case "cert-only":
				if err := os.Remove(key); err != nil {
					t.Fatal(err)
				}
			case "key-only":
				if err := os.Remove(cert); err != nil {
					t.Fatal(err)
				}
			case "mismatch":
				otherCert, otherKey := filepath.Join(dir, "other.pem"), filepath.Join(dir, "other-key.pem")
				if _, _, err := GenerateSelfSignedCert(otherCert, otherKey, nil); err != nil {
					t.Fatal(err)
				}
				content, err := os.ReadFile(otherKey)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(key, content, 0600); err != nil {
					t.Fatal(err)
				}
			case "invalid":
				if err := os.WriteFile(cert, []byte("private-fixture-not-a-certificate"), 0600); err != nil {
					t.Fatal(err)
				}
			case "expired", "future":
				privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
				if err != nil {
					t.Fatal(err)
				}
				start, end := time.Now().Add(-2*time.Hour), time.Now().Add(-time.Hour)
				if scenario == "future" {
					start, end = time.Now().Add(time.Hour), time.Now().Add(2*time.Hour)
				}
				template := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: start, NotAfter: end}
				der, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
				if err != nil {
					t.Fatal(err)
				}
				encodedKey, err := x509.MarshalPKCS8PrivateKey(privateKey)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(cert, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(key, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encodedKey}), 0600); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Mkdir(cert, 0700); err != nil {
					t.Fatal(err)
				}
			case "wide-mode":
				if err := os.Chmod(key, 0644); err != nil {
					t.Fatal(err)
				}
			}
			beforeCert, _ := os.ReadFile(cert)
			beforeKey, _ := os.ReadFile(key)
			_, err := LoadOrCreateTLSCertificate(cert, key, nil)
			if scenario == "new" || scenario == "existing" {
				if err != nil {
					t.Fatal(err)
				}
			} else if err == nil || !strings.HasPrefix(err.Error(), "ERR-B011:") || strings.Contains(err.Error(), "private-fixture") {
				t.Fatalf("应返回脱敏的 ERR-B011: %v", err)
			}
			if scenario != "new" {
				afterCert, _ := os.ReadFile(cert)
				afterKey, _ := os.ReadFile(key)
				if !bytes.Equal(beforeCert, afterCert) || !bytes.Equal(beforeKey, afterKey) {
					t.Fatal("已有材料被修改")
				}
			}
		})
	}
}

// TestTLSPathBoundaries 验证路径缺项、同路径与链接拒绝，不创建替代密钥。
func TestTLSPathBoundaries(t *testing.T) {
	dir := t.TempDir()
	for _, paths := range [][2]string{{"", filepath.Join(dir, "key")}, {filepath.Join(dir, "cert"), ""}, {filepath.Join(dir, "same"), filepath.Join(dir, "same")}} {
		if _, err := LoadOrCreateTLSCertificate(paths[0], paths[1], nil); err == nil {
			t.Fatal("无效路径未拒绝")
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 0 {
		t.Fatal("无效路径创建了文件")
	}
	if runtime.GOOS == "windows" {
		t.Skip("链接语义需 Linux 验证")
	}
	target := filepath.Join(dir, "target")
	if err := os.WriteFile(target, []byte("existing-material"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, role := range []string{"cert", "key"} {
		link := filepath.Join(dir, role)
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
		paths := [2]string{filepath.Join(dir, "missing-cert"), filepath.Join(dir, "missing-key")}
		if role == "cert" {
			paths[0] = link
		} else {
			paths[1] = link
		}
		if _, err := LoadOrCreateTLSCertificate(paths[0], paths[1], nil); err == nil {
			t.Fatal("符号链接未拒绝")
		}
	}
	content, err := os.ReadFile(target)
	if err != nil || string(content) != "existing-material" {
		t.Fatal("链接目标被修改")
	}
}
