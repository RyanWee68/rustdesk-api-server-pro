package service

import (
	"reflect"
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"
)

// TestConnectionSeparatesSourceAndTarget 验证控制端凭据不可误当成被控端凭据。
func TestConnectionSeparatesSourceAndTarget(t *testing.T) {
	db := newAdmissionTestEngine(t)
	insertAdmissionDevice(t, db, "rd-1", DeviceApprovalApproved, true, false, 1)
	insertAdmissionDevice(t, db, "rd-target", DeviceApprovalApproved, true, false, 1)
	token := insertAdmissionToken(t, db, 1, "rd-1", "uuid-1")
	svc := NewRustdeskAdmissionService(db, admissionTestConfig())
	before := readAdmissionDevice(t, db)
	resp, err := svc.CheckConnection(core.RustdeskConnectionRequest{TargetID: "rd-target", AccessToken: token, Relay: true})
	if err != nil || !resp.Allow || resp.DeviceID != "rd-target" || resp.SourceDeviceID != "rd-1" || resp.UserID != 1 || resp.Policy == nil || !resp.Policy.AllowRelay {
		t.Fatalf("ERR-2398 控制端/被控端校验失败：%+v err=%v", resp, err)
	}
	if !reflect.DeepEqual(before, readAdmissionDevice(t, db)) {
		t.Fatal("ERR-2398 连接校验不应修改设备")
	}
	legacy, err := svc.Authorize(core.RustdeskAdmissionRequest{RustdeskID: "rd-target", AccessToken: token})
	if err != nil || legacy.Allow || legacy.Code != errcode.ERR2303.Code {
		t.Fatal("ERR-2398 原设备鉴权语义发生变化")
	}
}

// TestConnectionDenialMatrix 覆盖任意一方审批、用户、token 与中继策略拒绝。
func TestConnectionDenialMatrix(t *testing.T) {
	for _, scenario := range []string{"empty-target", "bad-token", "expired-token", "revoked-token", "admin-token", "source-pending", "target-pending", "target-missing", "source-relay", "target-relay", "target-user-disabled", "source-owner", "source-uuid", "source-uuid-empty"} {
		t.Run(scenario, func(t *testing.T) {
			db := newAdmissionTestEngine(t)
			if _, err := db.Insert(&model.User{Id: 2, Username: "target-owner", Status: 1, AllowRemoteAccess: true, AllowRelay: true}); err != nil {
				t.Fatal(err)
			}
			insertAdmissionDevice(t, db, "rd-1", DeviceApprovalApproved, true, false, 1)
			insertAdmissionDevice(t, db, "rd-target", DeviceApprovalApproved, true, false, 2)
			token := insertAdmissionToken(t, db, 1, "rd-1", "uuid-1")
			req := core.RustdeskConnectionRequest{TargetID: "rd-target", AccessToken: token, Relay: true}
			code := errcode.ERR2303.Code
			var err error
			switch scenario {
			case "empty-target":
				req.TargetID, code = "", errcode.ERR2302.Code
			case "bad-token":
				req.AccessToken = "invalid"
			case "expired-token":
				_, err = db.Where("rustdesk_id = ?", "rd-1").Cols("expired").Update(&model.AuthToken{Expired: time.Now().Add(-time.Hour)})
			case "revoked-token":
				_, err = db.Where("rustdesk_id = ?", "rd-1").Cols("status").Update(&model.AuthToken{Status: 0})
			case "admin-token":
				_, err = db.Where("rustdesk_id = ?", "rd-1").Cols("is_admin").Update(&model.AuthToken{IsAdmin: true})
			case "source-pending", "target-pending":
				id := "rd-1"
				if scenario == "target-pending" {
					id = "rd-target"
				}
				code = errcode.ERR2305.Code
				_, err = db.Where("rustdesk_id = ?", id).Cols("approval_status").Update(&model.Device{ApprovalStatus: DeviceApprovalPending})
			case "target-missing":
				req.TargetID, code = "missing", errcode.ERR2304.Code
			case "source-relay", "target-relay":
				id := "rd-1"
				if scenario == "target-relay" {
					id = "rd-target"
				}
				code = errcode.ERR2309.Code
				_, err = db.Where("rustdesk_id = ?", id).Cols("allow_relay").Update(&model.Device{AllowRelay: false})
			case "target-user-disabled":
				code = errcode.ERR2308.Code
				_, err = db.Where("id = ?", 2).Cols("status").Update(&model.User{Status: 0})
			case "source-owner":
				code = errcode.ERR2314.Code
				_, err = db.Where("rustdesk_id = ?", "rd-1").Cols("user_id").Update(&model.Device{UserId: 2})
			case "source-uuid", "source-uuid-empty":
				code = errcode.ERR2313.Code
				uuid := "conflicting-uuid"
				if scenario == "source-uuid-empty" {
					uuid = ""
				}
				_, err = db.Where("rustdesk_id = ?", "rd-1").Cols("uuid").Update(&model.AuthToken{Uuid: uuid})
			}
			if err != nil {
				t.Fatal(err)
			}
			before := readAdmissionDevice(t, db)
			resp, err := NewRustdeskAdmissionService(db, admissionTestConfig()).CheckConnection(req)
			if err != nil || resp.Allow || resp.Code != code {
				t.Fatalf("ERR-2398 拒绝结果错误：%+v err=%v want=%s", resp, err, code)
			}
			if !reflect.DeepEqual(before, readAdmissionDevice(t, db)) {
				t.Fatal("ERR-2398 拒绝连接不应修改设备")
			}
		})
	}
}

// TestConnectionCombinesPolicy 验证直连允许不代表中继允许，且采用双方最早到期时间。
func TestConnectionCombinesPolicy(t *testing.T) {
	db := newAdmissionTestEngine(t)
	insertAdmissionDevice(t, db, "rd-1", DeviceApprovalApproved, true, false, 1)
	insertAdmissionDevice(t, db, "rd-target", DeviceApprovalApproved, false, false, 1)
	token := insertAdmissionToken(t, db, 1, "rd-1", "uuid-1")
	expiry := time.Now().Add(time.Minute).Truncate(time.Second)
	if _, err := db.Where("rustdesk_id = ?", "rd-target").Cols("authorized_until").Update(&model.Device{AuthorizedUntil: expiry}); err != nil {
		t.Fatal(err)
	}
	resp, err := NewRustdeskAdmissionService(db, admissionTestConfig()).CheckConnection(core.RustdeskConnectionRequest{TargetID: "rd-target", AccessToken: token})
	if err != nil || !resp.Allow || resp.Policy == nil || resp.Policy.AllowRelay || resp.Policy.ExpireAt != expiry.Unix() {
		t.Fatalf("ERR-2398 合并策略错误：%+v err=%v", resp, err)
	}
}
