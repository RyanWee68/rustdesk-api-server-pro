package cmd

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/db"
	"rustdesk-api-server-pro/util"

	"xorm.io/xorm"
)

// TestDatabaseSyncFailuresReachCommand 验证失败传给命令入口，避免启动脚本误判成功。
func TestDatabaseSyncFailuresReachCommand(t *testing.T) {
	cfg := config.GetServerConfig()
	previousConfig, previousEngine := cfg.Db, db.DbEngine
	t.Cleanup(func() {
		cfg.Db, db.DbEngine = previousConfig, previousEngine
		dbSyncCmd.SetOut(nil)
	})
	for _, tc := range []struct {
		name, driver, dsn, message string
	}{
		{"引擎创建失败", "unsupported-sync-test", "", "创建数据库引擎失败"},
		{"数据库不可写", "sqlite", "file:sync-readonly?mode=memory&_pragma=query_only(1)", "同步数据库结构失败"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg.Db = &config.DbConfig{Driver: tc.driver, Dsn: tc.dsn, TimeZone: "UTC"}
			var output bytes.Buffer
			dbSyncCmd.SetOut(&output)
			err := dbSyncCmd.RunE(dbSyncCmd, nil)
			if err == nil || !strings.HasPrefix(err.Error(), "ERR-B010") || !strings.Contains(err.Error(), tc.message) {
				t.Fatalf("命令未返回预期错误: %v", err)
			}
			if output.Len() != 0 {
				t.Fatal("失败时不应输出成功提示")
			}
		})
	}
	t.Run("令牌迁移失败及重试", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "migration.db")
		engine, err := xorm.NewEngine("sqlite", path)
		if err != nil {
			t.Fatal(err)
		}
		defer engine.Close()
		if err := engine.Sync(new(model.AuthToken)); err != nil {
			t.Fatal(err)
		}
		if _, err := engine.Exec("INSERT INTO auth_token (token,token_hash) VALUES (?, '')", "fixture-token"); err != nil {
			t.Fatal(err)
		}
		if _, err := engine.Exec("INSERT INTO auth_token (token,token_hash) VALUES (?, NULL), (?, ?)", "fixture-null", "fixture-stale", util.Sha256Hex("fixture-current")); err != nil {
			t.Fatal(err)
		}
		if _, err := engine.Exec("CREATE TRIGGER reject_token_update BEFORE UPDATE ON auth_token BEGIN SELECT RAISE(ABORT, 'fixture migration failure'); END"); err != nil {
			t.Fatal(err)
		}
		cfg.Db = &config.DbConfig{Driver: "sqlite", Dsn: path, TimeZone: "UTC"}
		var output bytes.Buffer
		dbSyncCmd.SetOut(&output)
		if err := dbSyncCmd.RunE(dbSyncCmd, nil); err == nil || !strings.Contains(err.Error(), "ERR-B010: 迁移旧登录令牌失败") {
			t.Fatalf("迁移失败未传给命令入口: %v", err)
		}
		if output.Len() != 0 {
			t.Fatal("迁移失败时不应输出成功提示")
		}
		if _, err := engine.Exec("DROP TRIGGER reject_token_update"); err != nil {
			t.Fatal(err)
		}
		if err := dbSyncCmd.RunE(dbSyncCmd, nil); err != nil {
			t.Fatalf("解除故障后重试失败: %v", err)
		}
		var tokens []model.AuthToken
		if err := engine.Asc("id").Find(&tokens); err != nil || len(tokens) != 3 {
			t.Fatal("重试后令牌记录丢失")
		}
		for i, expected := range []string{"fixture-token", "fixture-null", "fixture-current"} {
			if tokens[i].Token != "" || tokens[i].TokenHash != util.Sha256Hex(expected) {
				t.Fatal("旧明文未清除、NULL 摘要未补齐或已有摘要被覆盖")
			}
		}
	})
}
