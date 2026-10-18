package db

import (
	"testing"
	"time"

	"xorm.io/xorm"
)

// TestFormatTime 验证数据库时区转换、跨日和缺少时区时保持原时间语义。
func TestFormatTime(t *testing.T) {
	value := time.Date(2026, 10, 18, 0, 30, 0, 0, time.UTC)
	for _, item := range []struct {
		zone *time.Location
		want string
	}{
		{time.UTC, "2026-10-18 00:30:00"},
		{time.FixedZone("东八区", 8*60*60), "2026-10-18 08:30:00"},
		{time.FixedZone("西四区", -4*60*60), "2026-10-17 20:30:00"},
		{nil, "2026-10-18 00:30:00"},
	} {
		if got := FormatTime(&xorm.Engine{DatabaseTZ: item.zone}, value); got != item.want {
			t.Fatalf("ERR-2398 数据库时间格式错误：%s", got)
		}
	}
}
