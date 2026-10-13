package app

import (
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"

	_ "modernc.org/sqlite"
	"xorm.io/xorm"
)

// TestMarkExpiredDevicesOffline 验证官方三十秒边界只下线过期设备。
func TestMarkExpiredDevicesOffline(t *testing.T) {
	engine, err := xorm.NewEngine("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Close()
	if err = engine.Sync(new(model.Device)); err != nil {
		t.Fatal(err)
	}

	now := time.Now().Truncate(time.Second)
	fixtures := []model.Device{
		{RustdeskId: "expired", IsOnline: true, UpdatedAt: now.Add(-31 * time.Second)},
		{RustdeskId: "fresh", IsOnline: true, UpdatedAt: now.Add(-29 * time.Second)},
	}
	if _, err = engine.NoAutoTime().Insert(&fixtures); err != nil {
		t.Fatal(err)
	}
	var before []model.Device
	if err = engine.Asc("rustdesk_id").Find(&before); err != nil {
		t.Fatal(err)
	}
	if len(before) != 2 || !before[0].IsOnline || !before[1].IsOnline {
		t.Fatalf("测试前置在线状态错误: %+v", before)
	}

	cutoff := now.Add(-30 * time.Second)
	if _, err = markExpiredDevicesOffline(engine, cutoff); err != nil {
		t.Fatal(err)
	}

	var devices []model.Device
	if err = engine.Asc("rustdesk_id").Find(&devices); err != nil {
		t.Fatal(err)
	}
	if len(devices) != 2 || devices[0].RustdeskId != "expired" || devices[0].IsOnline {
		t.Fatalf("过期设备未下线: %+v", devices)
	}
	if devices[1].RustdeskId != "fresh" || !devices[1].IsOnline {
		t.Fatalf("新鲜设备被误下线: %+v", devices)
	}
}

// TestMarkExpiredDevicesOfflineDatabaseTimezone 覆盖实际数据库时区和三十秒截止边界。
func TestMarkExpiredDevicesOfflineDatabaseTimezone(t *testing.T) {
	for _, zone := range []string{"UTC", "Asia/Shanghai"} {
		t.Run(zone, func(t *testing.T) {
			engine, err := xorm.NewEngine("sqlite", ":memory:")
			if err != nil {
				t.Fatal(err)
			}
			defer engine.Close()
			location, err := time.LoadLocation(zone)
			if err != nil {
				t.Fatal(err)
			}
			engine.TZLocation, engine.DatabaseTZ = location, location
			if err = engine.Sync(new(model.Device)); err != nil {
				t.Fatal(err)
			}
			now := time.Date(2026, 10, 12, 10, 0, 0, 0, time.UTC)
			devices := []model.Device{
				{RustdeskId: "expired", IsOnline: true, UpdatedAt: now.Add(-31 * time.Second)},
				{RustdeskId: "boundary", IsOnline: true, UpdatedAt: now.Add(-30 * time.Second)},
				{RustdeskId: "fresh", IsOnline: true, UpdatedAt: now.Add(-29 * time.Second)},
			}
			if _, err = engine.NoAutoTime().Insert(&devices); err != nil {
				t.Fatal(err)
			}
			cutoff := now.Add(-30 * time.Second)
			affected, err := markExpiredDevicesOffline(engine, cutoff)
			if err != nil || affected != 2 {
				t.Fatalf("ERR-2398 时区 %s 过期设备数错误: affected=%d err=%v", zone, affected, err)
			}
			var fresh model.Device
			if _, err = engine.Where("rustdesk_id=?", "fresh").Get(&fresh); err != nil || !fresh.IsOnline {
				t.Fatalf("ERR-2398 新鲜设备被误下线: err=%v", err)
			}
		})
	}
}
