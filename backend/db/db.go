package db

import (
	"rustdesk-api-server-pro/config"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
	_ "modernc.org/sqlite"
	"xorm.io/xorm"
)

var DbEngine *xorm.Engine

// FormatTime 将 SQL 时间参数格式化为入库时区，避免 SQLite 驱动使用进程时区延长凭据有效期。
func FormatTime(engine *xorm.Engine, value time.Time) string {
	if engine.DatabaseTZ != nil {
		value = value.In(engine.DatabaseTZ)
	}
	return value.Format(config.TimeFormat)
}

func NewEngine(cfg *config.DbConfig) (*xorm.Engine, error) {
	dsn := cfg.Dsn
	if cfg.Driver == "sqlite" && !strings.Contains(dsn, "_pragma") {
		sep := "?"
		if strings.Contains(dsn, "?") {
			sep = "&"
		}
		dsn = dsn + sep + "_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)"
	}
	engine, err := xorm.NewEngine(cfg.Driver, dsn)
	if err != nil {
		return nil, err
	}
	location, _ := time.LoadLocation(cfg.TimeZone)
	engine.TZLocation = location
	engine.DatabaseTZ = location
	engine.ShowSQL(cfg.ShowSql)
	if cfg.Driver == "sqlite" {
		engine.SetMaxIdleConns(1)
		engine.SetMaxOpenConns(1)
	} else {
		engine.SetMaxIdleConns(100)
		engine.SetMaxOpenConns(100)
	}
	DbEngine = engine
	return engine, nil
}
