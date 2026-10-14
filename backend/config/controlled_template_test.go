package config

import (
	"os"
	"path/filepath"
	"testing"

	"gopkg.in/yaml.v3"
)

// TestControlledServerTemplate 确认受控镜像模板可解析且不携带运行密钥。
func TestControlledServerTemplate(t *testing.T) {
	path := filepath.Join("..", "..", "templates", "controlled-server.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var cfg ServerConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		t.Fatal(err)
	}
	if cfg.Db == nil || cfg.Db.Driver != "sqlite" || cfg.Db.Dsn != "./server.db" {
		t.Fatalf("ERR-2399 受控模板数据库配置无效")
	}
	if cfg.HttpConfig == nil || cfg.HttpConfig.Port != ":12345" || cfg.HttpConfig.AdminPort != ":12346" {
		t.Fatalf("ERR-2399 受控模板 HTTP 端口无效")
	}
	if cfg.RustdeskServer == nil || cfg.RustdeskServer.InternalSecret != "" {
		t.Fatalf("ERR-2399 受控模板不得预置内部密钥")
	}
	if cfg.SignKey != "CHANGE_ME_TO_A_RANDOM_32_BYTE_SECRET" {
		t.Fatalf("ERR-2399 受控模板签名密钥占位符无效")
	}
}
