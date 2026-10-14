package service

import (
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"
	"rustdesk-api-server-pro/util"

	_ "modernc.org/sqlite"
	"xorm.io/xorm"
)

func TestRustdeskAdmissionRegisterCreatesPendingDevice(t *testing.T) {
	engine := newAdmissionTestEngine(t)
	svc := NewRustdeskAdmissionService(engine, admissionTestConfig())

	resp, err := svc.Register(core.RustdeskRegisterRequest{
		RustdeskID:    "rd-1001",
		UUID:          "uuid-1001",
		Fingerprint:   "fp-1001",
		Hostname:      "workstation",
		ClientVersion: "1.4.9",
	})
	if err != nil {
		t.Fatal(err)
	}
	if resp.Allow || resp.Code != errcode.ERR2305.Code {
		t.Fatalf("register response=%+v", resp)
	}
	var device model.Device
	has, err := engine.Where("rustdesk_id = ?", "rd-1001").Get(&device)
	if err != nil || !has {
		t.Fatalf("device not created, has=%v err=%v", has, err)
	}
	if device.ApprovalStatus != DeviceApprovalPending {
		t.Fatalf("approval=%q want pending", device.ApprovalStatus)
	}
}

func TestRustdeskAdmissionRules(t *testing.T) {
	tests := []struct {
		name      string
		setup     func(*testing.T, *xorm.Engine) string
		relay     bool
		wantAllow bool
		wantCode  string
	}{
		{
			name: "unregistered device is denied",
			setup: func(t *testing.T, engine *xorm.Engine) string {
				return insertAdmissionToken(t, engine, 1, "rd-missing", "uuid-1")
			},
			wantCode: errcode.ERR2304.Code,
		},
		{
			name: "pending device is denied",
			setup: func(t *testing.T, engine *xorm.Engine) string {
				insertAdmissionDevice(t, engine, "rd-1", DeviceApprovalPending, true, false, 1)
				return insertAdmissionToken(t, engine, 1, "rd-1", "uuid-1")
			},
			wantCode: errcode.ERR2305.Code,
		},
		{
			name: "approved device is allowed",
			setup: func(t *testing.T, engine *xorm.Engine) string {
				insertAdmissionDevice(t, engine, "rd-1", DeviceApprovalApproved, true, false, 1)
				return insertAdmissionToken(t, engine, 1, "rd-1", "uuid-1")
			},
			wantAllow: true,
		},
		{
			name: "disabled user is denied",
			setup: func(t *testing.T, engine *xorm.Engine) string {
				if _, err := engine.Where("id = ?", 1).Cols("status").Update(&model.User{Status: 0}); err != nil {
					t.Fatal(err)
				}
				insertAdmissionDevice(t, engine, "rd-1", DeviceApprovalApproved, true, false, 1)
				return insertAdmissionToken(t, engine, 1, "rd-1", "uuid-1")
			},
			wantCode: errcode.ERR2308.Code,
		},
		{
			name: "user remote access disabled is denied",
			setup: func(t *testing.T, engine *xorm.Engine) string {
				if _, err := engine.Where("id = ?", 1).Cols("allow_remote_access").Update(&model.User{AllowRemoteAccess: false}); err != nil {
					t.Fatal(err)
				}
				insertAdmissionDevice(t, engine, "rd-1", DeviceApprovalApproved, true, false, 1)
				return insertAdmissionToken(t, engine, 1, "rd-1", "uuid-1")
			},
			wantCode: errcode.ERR2311.Code,
		},
		{
			name: "user authorization expired is denied",
			setup: func(t *testing.T, engine *xorm.Engine) string {
				if _, err := engine.Where("id = ?", 1).Cols("authorized_until").Update(&model.User{AuthorizedUntil: time.Now().Add(-time.Hour)}); err != nil {
					t.Fatal(err)
				}
				insertAdmissionDevice(t, engine, "rd-1", DeviceApprovalApproved, true, false, 1)
				return insertAdmissionToken(t, engine, 1, "rd-1", "uuid-1")
			},
			wantCode: errcode.ERR2312.Code,
		},
		{
			name: "disabled device is denied",
			setup: func(t *testing.T, engine *xorm.Engine) string {
				insertAdmissionDevice(t, engine, "rd-1", DeviceApprovalApproved, true, true, 1)
				return insertAdmissionToken(t, engine, 1, "rd-1", "uuid-1")
			},
			wantCode: errcode.ERR2307.Code,
		},
		{
			name: "relay denied by device policy",
			setup: func(t *testing.T, engine *xorm.Engine) string {
				insertAdmissionDevice(t, engine, "rd-1", DeviceApprovalApproved, false, false, 1)
				return insertAdmissionToken(t, engine, 1, "rd-1", "uuid-1")
			},
			relay:    true,
			wantCode: errcode.ERR2309.Code,
		},
		{
			name: "relay denied by user policy",
			setup: func(t *testing.T, engine *xorm.Engine) string {
				if _, err := engine.Where("id = ?", 1).Cols("allow_relay").Update(&model.User{AllowRelay: false}); err != nil {
					t.Fatal(err)
				}
				insertAdmissionDevice(t, engine, "rd-1", DeviceApprovalApproved, true, false, 1)
				return insertAdmissionToken(t, engine, 1, "rd-1", "uuid-1")
			},
			relay:    true,
			wantCode: errcode.ERR2309.Code,
		},
		{
			name: "invalid token is denied",
			setup: func(t *testing.T, engine *xorm.Engine) string {
				insertAdmissionDevice(t, engine, "rd-1", DeviceApprovalApproved, true, false, 1)
				return "wrong-token"
			},
			wantCode: errcode.ERR2303.Code,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := newAdmissionTestEngine(t)
			token := tt.setup(t, engine)
			svc := NewRustdeskAdmissionService(engine, admissionTestConfig())
			var resp core.RustdeskAdmissionResponse
			var err error
			if tt.relay {
				resp, err = svc.CheckRelay(core.RustdeskRelayCheckRequest{RustdeskID: "rd-1", UUID: "uuid-1", AccessToken: token})
			} else {
				resp, err = svc.Authorize(core.RustdeskAdmissionRequest{RustdeskID: "rd-1", UUID: "uuid-1", AccessToken: token})
			}
			if err != nil {
				t.Fatal(err)
			}
			if resp.Allow != tt.wantAllow {
				t.Fatalf("allow=%v want=%v response=%+v", resp.Allow, tt.wantAllow, resp)
			}
			if !tt.wantAllow && resp.Code != tt.wantCode {
				t.Fatalf("code=%q want=%q response=%+v", resp.Code, tt.wantCode, resp)
			}
		})
	}
}

func newAdmissionTestEngine(t *testing.T) *xorm.Engine {
	t.Helper()
	engine, err := xorm.NewEngine("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = engine.Close() })
	if err = engine.Sync(new(model.Device), new(model.User), new(model.AuthToken), new(model.RustdeskRelayGrant)); err != nil {
		t.Fatal(err)
	}
	if _, err = engine.Insert(&model.User{Id: 1, Username: "alice", Status: 1, AllowRemoteAccess: true, AllowRelay: true}); err != nil {
		t.Fatal(err)
	}
	return engine
}

func admissionTestConfig() *config.ServerConfig {
	return &config.ServerConfig{
		RustdeskServer: &config.RustdeskServerConfig{AuthCacheSeconds: 30},
	}
}

func insertAdmissionDevice(t *testing.T, engine *xorm.Engine, rustdeskID, status string, allowRelay, disabled bool, userID int) {
	t.Helper()
	device := model.Device{
		RustdeskId:      rustdeskID,
		Uuid:            "uuid-1",
		UserId:          userID,
		ApprovalStatus:  status,
		AllowRelay:      allowRelay,
		Disabled:        disabled,
		AuthorizedUntil: time.Now().Add(time.Hour),
	}
	if _, err := engine.Insert(&device); err != nil {
		t.Fatal(err)
	}
}

func insertAdmissionToken(t *testing.T, engine *xorm.Engine, userID int, rustdeskID, uuid string) string {
	t.Helper()
	token := "token-" + rustdeskID
	authToken := model.AuthToken{
		UserId:     userID,
		RustdeskId: rustdeskID,
		Uuid:       uuid,
		TokenHash:  util.Sha256Hex(token),
		Expired:    time.Now().Add(time.Hour).Truncate(time.Second),
		Status:     1,
		IsAdmin:    false,
	}
	if _, err := engine.Insert(&authToken); err != nil {
		t.Fatal(err)
	}
	matched, err := engine.Where("token_hash = ? and rustdesk_id = ? and uuid = ?", authToken.TokenHash, rustdeskID, uuid).Count(new(model.AuthToken))
	if err != nil || matched != 1 {
		t.Fatalf("inserted auth token not queryable, matched=%d err=%v", matched, err)
	}
	return token
}
