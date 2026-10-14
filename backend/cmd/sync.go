package cmd

import (
	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/db"
	"rustdesk-api-server-pro/internal/errcode"
	"rustdesk-api-server-pro/util"

	"github.com/spf13/cobra"
	"xorm.io/xorm"
)

var dbSyncCmd = &cobra.Command{
	Use:   "sync",
	Short: "同步 API 数据库结构和旧令牌",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg := config.GetServerConfig()
		engine, err := db.NewEngine(cfg.Db)
		if err != nil {
			return errcode.Errorf(errcode.ERRB010.Code, "创建数据库引擎失败: %w", err)
		}
		defer engine.Close()
		models := []interface{}{
			new(model.User),
			new(model.Peer),
			new(model.Tags),
			new(model.AuthToken),
			new(model.Audit),
			new(model.AlarmAudit),
			new(model.OperationAudit),
			new(model.SecurityAudit),
			new(model.CompatAPIAudit),
			new(model.FileTransfer),
			new(model.Device),
			new(model.RustdeskRelayGrant),
			new(model.AddressBook),
			new(model.AddressBookTag),
			new(model.AddressBookRule),
			new(model.MailLogs),
			new(model.VerifyCode),
			new(model.SystemSettings),
			new(model.MailTemplate),
			new(model.DeviceGroup),
			new(model.DeviceGroupDevice),
			new(model.UserGroup),
			new(model.UserGroupMember),
			new(model.Strategy),
			new(model.StrategyAssignment),
			new(model.OAuthAccount),
			new(model.OAuthLoginSession),
			new(model.ErrorLog),
			new(model.ContainerLog),
			new(model.WebauthnCredential),
			new(model.WebauthnSession),
		}
		err = engine.Sync(models...)
		if err != nil {
			return errcode.Errorf(errcode.ERRB010.Code, "同步数据库结构失败: %w", err)
		}
		if err = migratePlaintextAuthTokens(engine); err != nil {
			return errcode.Errorf(errcode.ERRB010.Code, "迁移旧登录令牌失败: %w", err)
		}
		cmd.Println("数据库结构及登录令牌同步成功")
		return nil
	},
}

// migratePlaintextAuthTokens 将旧明文令牌转为摘要，失败时阻止服务启动。
func migratePlaintextAuthTokens(engine *xorm.Engine) error {
	legacyTokens := make([]model.AuthToken, 0)
	if err := engine.Where("token != ''").Find(&legacyTokens); err != nil {
		return err
	}
	for _, token := range legacyTokens {
		if token.TokenHash == "" {
			token.TokenHash = util.Sha256Hex(token.Token)
		}
		token.Token = ""
		if _, err := engine.Where("id = ?", token.Id).Cols("token_hash", "token").Update(&token); err != nil {
			return err
		}
	}
	return nil
}

func init() {
	RootCmd.AddCommand(dbSyncCmd)
}
