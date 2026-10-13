package config

import (
	"bytes"
	"os"
	"reflect"
	"testing"

	"gopkg.in/yaml.v3"
)

// checkLegacyConfiguration 验证旧配置被实际加载且内存序列化不丢失已支持字段，不输出配置值。
func checkLegacyConfiguration(t *testing.T, data []byte) {
	t.Helper()
	expected := GetDefaultServerConfig()
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(expected); err != nil {
		t.Fatal("ERR-2399 旧配置存在格式错误或新版不支持的字段，请在主机本地审阅")
	}
	if expected.Db == nil || expected.Db.Driver == "" || expected.Db.Dsn == "" || expected.HttpConfig == nil || expected.JobsConfig == nil || expected.JobsConfig.DeviceCheckJob == nil {
		t.Fatal("ERR-2399 旧配置缺少必要配置段")
	}
	t.Setenv("PORT", "")
	t.Setenv("ADMIN_PORT", "")
	actual := loadServerConfig()
	if !reflect.DeepEqual(actual, expected) {
		t.Fatal("ERR-2399 实际加载旧配置发生字段丢失或默认值回退")
	}
	encoded, err := yaml.Marshal(actual)
	if err != nil {
		t.Fatal("ERR-2399 旧配置序列化失败")
	}
	var restored ServerConfig
	if err := yaml.Unmarshal(encoded, &restored); err != nil {
		t.Fatal("ERR-2399 旧配置内存往返发生字段丢失")
	}
	roundTrip, err := yaml.Marshal(&restored)
	if err != nil || !bytes.Equal(encoded, roundTrip) {
		t.Fatal("ERR-2399 旧配置内存往返发生字段丢失")
	}
}

// TestLegacyConfigurationDefaults 验证新增准入配置默认收紧，旧 OAuth 与服务配置保持不变。
func TestLegacyConfigurationDefaults(t *testing.T) {
	data := []byte(`signKey: fixture-sign-key-not-for-deployment
db:
  driver: sqlite
  dsn: ./server.db
  showSql: false
httpConfig:
  port: ":12345"
  adminPort: ":12346"
  staticdir: /app/dist
oidc:
  enabled: true
  providerName: legacy
  issuer: https://identity.invalid
  clientId: legacy-client
  clientSecret: fixture-legacy-secret
oauth:
  providers:
    - type: oidc
      name: custom
      enabled: true
      issuer: https://custom.invalid
      clientId: custom-client
      clientSecret: fixture-custom-secret
      scopes: [openid, profile]
smtpConfig:
  host: smtp.invalid
  password: fixture-mail-secret
`)
	file, err := os.CreateTemp("", "rustdesk-legacy-config-*.yaml")
	if err != nil {
		t.Fatal("ERR-2399 无法创建仓库外配置夹具")
	}
	t.Cleanup(func() { os.Remove(file.Name()) })
	if _, err := file.Write(data); err != nil {
		file.Close()
		t.Fatal("ERR-2399 无法写入配置夹具")
	}
	if err := file.Close(); err != nil {
		t.Fatal("ERR-2399 无法关闭配置夹具")
	}
	previous := yamlFile
	yamlFile = file.Name()
	t.Cleanup(func() { yamlFile = previous })
	checkLegacyConfiguration(t, data)
	cfg := loadServerConfig()
	if cfg.AccessPolicy.RegistrationMode != "admin_only" || cfg.AccessPolicy.AllowOAuthAutoCreate || cfg.RustdeskServer.InternalSecret != "" {
		t.Fatal("ERR-2399 旧配置意外放宽新增准入策略")
	}
	providers := cfg.OAuthProviders()
	if len(providers) != 2 || providers[0].ClientSecret != "fixture-legacy-secret" || providers[1].ClientSecret != "fixture-custom-secret" {
		t.Fatal("ERR-2399 旧 OIDC 或自定义 OAuth 配置未保留")
	}
}

// TestPrivateLegacyConfigurationRoundTrip 仅在显式提供主机私有配置路径时只读验证，不写入配置。
func TestPrivateLegacyConfigurationRoundTrip(t *testing.T) {
	path := os.Getenv("CONTROLLED_LEGACY_CONFIG_FILE")
	if path == "" {
		t.Skip("未提供私有旧配置，实机兼容性检查跳过")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("ERR-2399 无法读取私有旧配置")
	}
	previous := yamlFile
	yamlFile = path
	t.Cleanup(func() { yamlFile = previous })
	checkLegacyConfiguration(t, data)
}
