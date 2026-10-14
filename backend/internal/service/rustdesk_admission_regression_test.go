package service

import (
	"reflect"
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"
	"xorm.io/xorm"
)

// readAdmissionDevice 读取数据库中的实际状态，避免只验证内存响应。
func readAdmissionDevice(t *testing.T, db *xorm.Engine) model.Device {
	t.Helper()
	var device model.Device
	found, err := db.Where("rustdesk_id = ?", "rd-1").Get(&device)
	if err != nil || !found {
		t.Fatalf("ERR-2398 读取测试设备失败：found=%v err=%v", found, err)
	}
	return device
}

// TestAdmissionRepeatRegisterPreservesApproval 覆盖重复注册后的持久化审批状态。
func TestAdmissionRepeatRegisterPreservesApproval(t *testing.T) {
	for _, state := range []string{DeviceApprovalApproved, DeviceApprovalPending, DeviceApprovalRejected, DeviceApprovalDisabled, ""} {
		t.Run("state="+state, func(t *testing.T) {
			db := newAdmissionTestEngine(t)
			insertAdmissionDevice(t, db, "rd-1", state, true, false, 1)
			svc := NewRustdeskAdmissionService(db, admissionTestConfig())
			for i := 0; i < 2; i++ {
				resp, err := svc.Register(core.RustdeskRegisterRequest{RustdeskID: "rd-1", UUID: "uuid-1", Hostname: "updated-host"})
				if err != nil {
					t.Fatal(err)
				}
				if resp.Allow != (state == DeviceApprovalApproved) {
					t.Fatalf("ERR-2398 错误的注册结果：%+v", resp)
				}
				stored := readAdmissionDevice(t, db)
				want := state
				if want == "" {
					want = DeviceApprovalPending
				}
				if stored.ApprovalStatus != want || stored.Hostname != "updated-host" {
					t.Fatalf("ERR-2398 注册破坏审批状态：%+v", stored)
				}
			}
		})
	}
}

// TestAdmissionIdentityConflictDoesNotMutate 覆盖四个接口的冲突身份拒绝与无副作用。
func TestAdmissionIdentityConflictDoesNotMutate(t *testing.T) {
	for _, action := range []string{"register-uuid", "register-fingerprint", "auth-uuid", "auth-fingerprint", "heartbeat", "relay"} {
		t.Run(action, func(t *testing.T) {
			db := newAdmissionTestEngine(t)
			insertAdmissionDevice(t, db, "rd-1", DeviceApprovalApproved, true, false, 1)
			if _, err := db.Where("rustdesk_id = ?", "rd-1").Cols("fingerprint").Update(&model.Device{Fingerprint: "fp-original"}); err != nil {
				t.Fatal(err)
			}
			token := insertAdmissionToken(t, db, 1, "rd-1", "uuid-1")
			before := readAdmissionDevice(t, db)
			svc := NewRustdeskAdmissionService(db, admissionTestConfig())
			var resp core.RustdeskAdmissionResponse
			var err error
			switch action {
			case "register-uuid":
				resp, err = svc.Register(core.RustdeskRegisterRequest{RustdeskID: "rd-1", UUID: "other-uuid"})
			case "register-fingerprint":
				resp, err = svc.Register(core.RustdeskRegisterRequest{RustdeskID: "rd-1", UUID: "uuid-1", Fingerprint: "other-fp"})
			case "auth-uuid":
				resp, err = svc.Authorize(core.RustdeskAdmissionRequest{RustdeskID: "rd-1", UUID: "other-uuid", AccessToken: token})
			case "auth-fingerprint":
				resp, err = svc.Authorize(core.RustdeskAdmissionRequest{RustdeskID: "rd-1", UUID: "uuid-1", Fingerprint: "other-fp", AccessToken: token})
			case "heartbeat":
				resp, err = svc.Heartbeat(core.RustdeskHeartbeatRequest{RustdeskID: "rd-1", UUID: "other-uuid", ConnCount: 10})
			case "relay":
				resp, err = svc.CheckRelay(core.RustdeskRelayCheckRequest{RustdeskID: "rd-1", UUID: "other-uuid", AccessToken: token})
			}
			if err != nil || resp.Allow || resp.Code != errcode.ERR2313.Code {
				t.Fatalf("ERR-2398 身份冲突未拒绝：%+v err=%v", resp, err)
			}
			if after := readAdmissionDevice(t, db); !reflect.DeepEqual(before, after) {
				t.Fatalf("ERR-2398 拒绝后仍修改了设备")
			}
		})
	}
}

// TestAdmissionDeniedRequestsDoNotMutate 覆盖策略拒绝之前不得写入绑定、指纹和在线状态。
func TestAdmissionDeniedRequestsDoNotMutate(t *testing.T) {
	for _, action := range []string{"pending", "disabled-user", "owner", "device-relay", "user-relay", "heartbeat-disabled", "token-uuid"} {
		t.Run(action, func(t *testing.T) {
			db := newAdmissionTestEngine(t)
			state, owner, relay := DeviceApprovalApproved, 0, true
			code := errcode.ERR2305.Code
			tokenUser, tokenUUID := 1, "uuid-1"
			switch action {
			case "pending":
				state = DeviceApprovalPending
			case "disabled-user":
				code = errcode.ERR2308.Code
				if _, err := db.Where("id = ?", 1).Cols("status").Update(&model.User{Status: 0}); err != nil {
					t.Fatal(err)
				}
			case "owner":
				owner, tokenUser, code = 1, 2, errcode.ERR2314.Code
				if _, err := db.Insert(&model.User{Id: 2, Username: "bob", Status: 1, AllowRemoteAccess: true, AllowRelay: true}); err != nil {
					t.Fatal(err)
				}
			case "device-relay":
				relay, code = false, errcode.ERR2309.Code
			case "user-relay":
				code = errcode.ERR2309.Code
				if _, err := db.Where("id = ?", 1).Cols("allow_relay").Update(&model.User{AllowRelay: false}); err != nil {
					t.Fatal(err)
				}
			case "heartbeat-disabled":
				state, code = DeviceApprovalDisabled, errcode.ERR2307.Code
			case "token-uuid":
				tokenUUID, code = "other-uuid", errcode.ERR2303.Code
			}
			insertAdmissionDevice(t, db, "rd-1", state, relay, false, owner)
			token := insertAdmissionToken(t, db, tokenUser, "rd-1", tokenUUID)
			svc := NewRustdeskAdmissionService(db, admissionTestConfig())
			before := readAdmissionDevice(t, db)
			for attempt := 0; attempt < 2; attempt++ {
				var resp core.RustdeskAdmissionResponse
				var err error
				switch action {
				case "device-relay", "user-relay":
					resp, err = svc.CheckRelay(core.RustdeskRelayCheckRequest{RustdeskID: "rd-1", AccessToken: token, SourceIP: "192.0.2.3"})
				case "heartbeat-disabled":
					resp, err = svc.Heartbeat(core.RustdeskHeartbeatRequest{RustdeskID: "rd-1", UUID: "uuid-1", ConnCount: 4, SourceIP: "192.0.2.3"})
				default:
					resp, err = svc.Authorize(core.RustdeskAdmissionRequest{RustdeskID: "rd-1", AccessToken: token, Fingerprint: "new-fp", SourceIP: "192.0.2.3"})
				}
				if err != nil || resp.Allow || resp.Code != code {
					t.Fatalf("ERR-2398 拒绝结果错误：%+v err=%v want=%s", resp, err, code)
				}
				if after := readAdmissionDevice(t, db); !reflect.DeepEqual(before, after) {
					t.Fatalf("ERR-2398 拒绝请求产生副作用")
				}
			}
		})
	}
}

// TestAdmissionEffectiveRelayPolicy 覆盖设备和用户策略的交集，以及首次合法绑定。
func TestAdmissionEffectiveRelayPolicy(t *testing.T) {
	db := newAdmissionTestEngine(t)
	insertAdmissionDevice(t, db, "rd-1", DeviceApprovalApproved, true, false, 0)
	if _, err := db.Where("id = ?", 1).Cols("allow_relay").Update(&model.User{AllowRelay: false}); err != nil {
		t.Fatal(err)
	}
	token := insertAdmissionToken(t, db, 1, "rd-1", "uuid-1")
	svc := NewRustdeskAdmissionService(db, admissionTestConfig())
	resp, err := svc.Authorize(core.RustdeskAdmissionRequest{RustdeskID: "rd-1", UUID: "uuid-1", AccessToken: token})
	if err != nil || !resp.Allow || resp.Policy == nil || resp.Policy.AllowRelay || resp.UserID != 1 {
		t.Fatalf("ERR-2398 中继策略错误：%+v err=%v", resp, err)
	}
	stored := readAdmissionDevice(t, db)
	if stored.UserId != 1 || !stored.IsOnline {
		t.Fatal("ERR-2398 合法鉴权未绑定设备或更新在线状态")
	}
	heartbeat, err := svc.Heartbeat(core.RustdeskHeartbeatRequest{RustdeskID: "rd-1", UUID: "uuid-1"})
	if err != nil || !heartbeat.Allow || heartbeat.Policy == nil || heartbeat.Policy.AllowRelay {
		t.Fatalf("ERR-2398 心跳策略错误：%+v err=%v", heartbeat, err)
	}
}

// TestAdmissionHeartbeatClearsConnections 覆盖非零转零的心跳计数及鉴权不重置计数。
func TestAdmissionHeartbeatClearsConnections(t *testing.T) {
	db := newAdmissionTestEngine(t)
	insertAdmissionDevice(t, db, "rd-1", DeviceApprovalApproved, true, false, 1)
	token := insertAdmissionToken(t, db, 1, "rd-1", "uuid-1")
	svc := NewRustdeskAdmissionService(db, admissionTestConfig())
	for _, count := range []int{3, 0} {
		resp, err := svc.Heartbeat(core.RustdeskHeartbeatRequest{RustdeskID: "rd-1", UUID: "uuid-1", ConnCount: count})
		if err != nil || !resp.Allow {
			t.Fatalf("ERR-2398 心跳失败：%+v err=%v", resp, err)
		}
		if stored := readAdmissionDevice(t, db); stored.Conns != count || !stored.IsOnline || stored.LastSeenAt.IsZero() {
			t.Fatalf("ERR-2398 心跳未保存：%+v", stored)
		}
		resp, err = svc.Authorize(core.RustdeskAdmissionRequest{RustdeskID: "rd-1", UUID: "uuid-1", AccessToken: token})
		if err != nil || !resp.Allow || readAdmissionDevice(t, db).Conns != count {
			t.Fatal("ERR-2398 鉴权错误修改连接计数")
		}
	}
}

// TestAdmissionExpiryBoundary 保证返回的过期时间不晚于用户、设备、token 任意一方。
func TestAdmissionExpiryBoundary(t *testing.T) {
	db := newAdmissionTestEngine(t)
	insertAdmissionDevice(t, db, "rd-1", DeviceApprovalApproved, true, false, 1)
	token := insertAdmissionToken(t, db, 1, "rd-1", "uuid-1")
	deadline := time.Now().Add(time.Minute).Truncate(time.Second)
	if _, err := db.Where("id = ?", 1).Cols("authorized_until").Update(&model.User{AuthorizedUntil: deadline}); err != nil {
		t.Fatal(err)
	}
	resp, err := NewRustdeskAdmissionService(db, admissionTestConfig()).Authorize(core.RustdeskAdmissionRequest{RustdeskID: "rd-1", UUID: "uuid-1", AccessToken: token})
	if err != nil || !resp.Allow || resp.Policy == nil || resp.Policy.ExpireAt != deadline.Unix() {
		t.Fatalf("ERR-2398 授权期限错误：%+v err=%v", resp, err)
	}
}
