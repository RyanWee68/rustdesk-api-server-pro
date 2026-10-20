package service

import (
	"context"
	"testing"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"
)

const testRelaySessionUUID = "123e4567-e89b-42d3-a456-426614174000"

// TestRelayGrantConsumeBeforeIssue 校验官方客户端先连接中继时等待签发且仍逐端一次性核销。
func TestRelayGrantConsumeBeforeIssue(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	type outcome struct {
		response core.RustdeskAdmissionResponse
		err      error
	}
	result := make(chan outcome, 1)
	go func() {
		response, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.TargetIP})
		result <- outcome{response, err}
	}()
	select {
	case got := <-result:
		t.Fatalf("签发到达前过早结束核销：%+v %v", got.response, got.err)
	case <-time.After(75 * time.Millisecond):
	}
	if got, err := svc.IssueRelayGrant(req); err != nil || !got.Allow {
		t.Fatalf("延迟签发失败：%+v %v", got, err)
	}
	select {
	case got := <-result:
		if got.err != nil || !got.response.Allow {
			t.Fatalf("先到的被控端未能核销：%+v %v", got.response, got.err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("核销等待未按时结束")
	}
	for _, tc := range []struct {
		ip    string
		allow bool
	}{{req.TargetIP, false}, {req.SourceIP, true}, {req.SourceIP, false}} {
		got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: tc.ip})
		if err != nil || got.Allow != tc.allow || (!tc.allow && got.Code != errcode.ERR2315.Code) {
			t.Fatalf("延迟签发改变一次性核销：%+v %v", got, err)
		}
	}
}

// TestRelayGrantWaitCancellation 校验请求取消或更短截止时立即拒绝，不继续等待签发。
func TestRelayGrantWaitCancellation(t *testing.T) {
	for _, cancelled := range []bool{true, false} {
		svc, req := newRelayGrantFixture(t)
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
		if cancelled {
			cancel()
		}
		started := time.Now()
		got, err := svc.ConsumeRelayGrant(ctx, core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.TargetIP})
		cancel()
		if err != nil || got.Allow || got.Code != errcode.ERR2315.Code || time.Since(started) > 500*time.Millisecond {
			t.Fatalf("取消或截止后未及时拒绝：%+v %v", got, err)
		}
		if len(relayGrantWaiters) != 0 {
			t.Fatal("取消或截止后未释放等待名额")
		}
		if got, err := svc.IssueRelayGrant(req); err != nil || !got.Allow {
			t.Fatalf("取消影响后续签发：%+v %v", got, err)
		}
		if got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.TargetIP}); err != nil || !got.Allow {
			t.Fatalf("取消请求占用了核销名额：%+v %v", got, err)
		}
	}
}

// TestRelayGrantConcurrentDelayedConsume 校验延迟签发后同端并发只能核销一次，错误地址不能占位。
func TestRelayGrantConcurrentDelayedConsume(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	svc.db.SetMaxOpenConns(1)
	type outcome struct {
		ip       string
		response core.RustdeskAdmissionResponse
		err      error
	}
	result := make(chan outcome, 9)
	for _, ip := range []string{req.SourceIP, req.SourceIP, req.SourceIP, req.SourceIP, req.TargetIP, req.TargetIP, req.TargetIP, req.TargetIP, "203.0.113.5"} {
		go func(ip string) {
			got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: ip})
			result <- outcome{ip, got, err}
		}(ip)
	}
	select {
	case got := <-result:
		t.Fatalf("签发前提前结束：%+v %v", got.response, got.err)
	case <-time.After(75 * time.Millisecond):
	}
	if got, err := svc.IssueRelayGrant(req); err != nil || !got.Allow {
		t.Fatalf("延迟签发失败：%+v %v", got, err)
	}
	allowed := map[string]int{}
	deadline := time.After(3 * time.Second)
	for i := 0; i < 9; i++ {
		select {
		case got := <-result:
			if got.err != nil || (!got.response.Allow && got.response.Code != errcode.ERR2315.Code) {
				t.Fatalf("并发核销异常：%+v %v", got.response, got.err)
			}
			if got.response.Allow {
				allowed[got.ip]++
			}
		case <-deadline:
			t.Fatal("并发核销未按时结束")
		}
	}
	if len(allowed) != 2 || allowed[req.SourceIP] != 1 || allowed[req.TargetIP] != 1 {
		t.Fatalf("重复核销或错误地址获准：%v", allowed)
	}
}

// TestRelayGrantWaitCapacity 校验未知会话等待有界，已有授权不因等待名额耗尽而被拒绝。
func TestRelayGrantWaitCapacity(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	if got, err := svc.IssueRelayGrant(req); err != nil || !got.Allow {
		t.Fatalf("签发失败：%+v %v", got, err)
	}
	for i := 0; i < cap(relayGrantWaiters); i++ {
		relayGrantWaiters <- struct{}{}
	}
	defer func() {
		for i := 0; i < cap(relayGrantWaiters); i++ {
			<-relayGrantWaiters
		}
	}()
	if got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.TargetIP}); err != nil || !got.Allow {
		t.Fatalf("已有授权被等待上限误拒绝：%+v %v", got, err)
	}
	started := time.Now()
	got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: "123e4567-e89b-42d3-a456-426614174001", PeerIP: req.TargetIP})
	if err != nil || got.Allow || got.Code != errcode.ERR2315.Code || time.Since(started) > 500*time.Millisecond {
		t.Fatalf("等待名额耗尽后未及时拒绝：%+v %v", got, err)
	}
}

// TestRelayGrantInvalidConsumeDoesNotWait 校验畸形核销在进入等待和数据库查询之前被拒绝。
func TestRelayGrantInvalidConsumeDoesNotWait(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	if err := svc.db.Close(); err != nil {
		t.Fatal(err)
	}
	for _, consume := range []core.RustdeskRelayGrantConsumeRequest{
		{SessionUUID: "not-uuid", PeerIP: req.TargetIP},
		{SessionUUID: "123e4567-e89b-12d3-a456-426614174000", PeerIP: req.TargetIP},
		{SessionUUID: "123E4567-E89B-42D3-A456-426614174000", PeerIP: req.TargetIP},
		{SessionUUID: req.SessionUUID, PeerIP: "invalid"},
		{SessionUUID: req.SessionUUID, PeerIP: "198.51.100.20:22117"},
	} {
		started := time.Now()
		got, err := svc.ConsumeRelayGrant(context.Background(), consume)
		if err != nil || got.Allow || got.Code != errcode.ERR2315.Code || time.Since(started) > 500*time.Millisecond {
			t.Fatalf("畸形核销未在查询前拒绝：%+v %v", got, err)
		}
		if len(relayGrantWaiters) != 0 {
			t.Fatal("畸形核销占用等待名额")
		}
	}
}

// TestRelayGrantDatabaseFailure 校验查询失败不能被误认为授权尚未到达或占用核销名额。
func TestRelayGrantDatabaseFailure(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	if err := svc.db.Close(); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.TargetIP})
	if err == nil || got.Allow || time.Since(started) > 500*time.Millisecond {
		t.Fatalf("数据库故障未及时返回错误：%+v %v", got, err)
	}
	if len(relayGrantWaiters) != 0 {
		t.Fatal("数据库故障占用等待名额")
	}
}

// TestRelayGrantWaitDatabaseFailure 校验等待期间数据库故障会释放名额并返回错误。
func TestRelayGrantWaitDatabaseFailure(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := svc.ConsumeRelayGrant(ctx, core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.TargetIP})
		result <- err
	}()
	deadline := time.Now().Add(500 * time.Millisecond)
	for len(relayGrantWaiters) == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if len(relayGrantWaiters) == 0 {
		cancel()
		<-result
		t.Fatal("请求未进入等待阶段")
	}
	if err := svc.db.Close(); err != nil {
		cancel()
		<-result
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("等待期间数据库故障未返回错误")
		}
	case <-ctx.Done():
		<-result
		t.Fatal("等待期间数据库故障未及时结束")
	}
	if len(relayGrantWaiters) != 0 {
		t.Fatal("等待期间数据库故障未释放等待名额")
	}
}

// TestRelayGrantWaitExpiryAllowsLaterIssue 校验完整等待超时不预占晚到授权的双端核销。
func TestRelayGrantWaitExpiryAllowsLaterIssue(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	started := time.Now()
	got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.TargetIP})
	if err != nil || got.Allow || got.Code != errcode.ERR2315.Code || time.Since(started) < relayGrantIssueWait {
		t.Fatalf("无授权会话未按等待上限拒绝：%+v %v", got, err)
	}
	if len(relayGrantWaiters) != 0 {
		t.Fatal("等待超时后未释放名额")
	}
	if got, err := svc.IssueRelayGrant(req); err != nil || !got.Allow {
		t.Fatalf("等待超时影响后续签发：%+v %v", got, err)
	}
	for _, ip := range []string{req.SourceIP, req.TargetIP} {
		if got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: ip}); err != nil || !got.Allow {
			t.Fatalf("等待超时占用后续核销：%+v %v", got, err)
		}
	}
}

// TestRelayGrantDelayedGrantRevalidation 校验等待后到达的授权仍需通过当前权限和会话校验。
func TestRelayGrantDelayedGrantRevalidation(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*testing.T, *RustdeskAdmissionService, *model.RustdeskRelayGrant)
		code   string
	}{
		{"expired", func(t *testing.T, svc *RustdeskAdmissionService, grant *model.RustdeskRelayGrant) {
			grant.ExpiresAt = time.Now().Add(-time.Second).Unix()
		}, errcode.ERR2315.Code},
		{"wrong address", func(t *testing.T, svc *RustdeskAdmissionService, grant *model.RustdeskRelayGrant) {
			grant.TargetIP = "203.0.113.5"
		}, errcode.ERR2315.Code},
		{"same address", func(t *testing.T, svc *RustdeskAdmissionService, grant *model.RustdeskRelayGrant) {
			grant.SourceIP = grant.TargetIP
		}, errcode.ERR2315.Code},
		{"token revoked", func(t *testing.T, svc *RustdeskAdmissionService, grant *model.RustdeskRelayGrant) {
			if _, err := svc.db.Where("id = ?", grant.TokenID).Cols("status").Update(&model.AuthToken{Status: 0}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2303.Code},
		{"target disabled", func(t *testing.T, svc *RustdeskAdmissionService, grant *model.RustdeskRelayGrant) {
			if _, err := svc.db.Where("rustdesk_id = ?", grant.TargetID).Cols("disabled").Update(&model.Device{Disabled: true}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2307.Code},
		{"relay disabled", func(t *testing.T, svc *RustdeskAdmissionService, grant *model.RustdeskRelayGrant) {
			if _, err := svc.db.Where("rustdesk_id = ?", grant.TargetID).Cols("allow_relay").Update(&model.Device{AllowRelay: false}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2309.Code},
	} {
		t.Run(tc.name, func(t *testing.T) {
			svc, req := newRelayGrantFixture(t)
			if got, err := svc.IssueRelayGrant(req); err != nil || !got.Allow {
				t.Fatalf("签发失败：%+v %v", got, err)
			}
			var grant model.RustdeskRelayGrant
			if has, err := svc.db.Where("session_uuid = ?", req.SessionUUID).Get(&grant); err != nil || !has {
				t.Fatalf("读取授权失败：%v", err)
			}
			if _, err := svc.db.Where("session_uuid = ?", req.SessionUUID).Delete(&model.RustdeskRelayGrant{}); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			result := make(chan core.RustdeskAdmissionResponse, 1)
			errors := make(chan error, 1)
			go func() {
				got, err := svc.ConsumeRelayGrant(ctx, core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.TargetIP})
				errors <- err
				result <- got
			}()
			select {
			case got := <-result:
				t.Fatalf("授权到达前提前结束：%+v", got)
			case <-time.After(75 * time.Millisecond):
			}
			tc.change(t, svc, &grant)
			if _, err := svc.db.Insert(&grant); err != nil {
				t.Fatal(err)
			}
			select {
			case got := <-result:
				if err := <-errors; err != nil || got.Allow || got.Code != tc.code {
					t.Fatalf("等待后未重新校验：%+v %v", got, err)
				}
			case <-ctx.Done():
				t.Fatal("等待授权未按时结束")
			}
			var stored model.RustdeskRelayGrant
			if has, err := svc.db.Where("session_uuid = ?", req.SessionUUID).Get(&stored); err != nil || !has || stored.SourceUsed || stored.TargetUsed {
				t.Fatalf("拒绝后名额被占用：has=%v err=%v", has, err)
			}
			if len(relayGrantWaiters) != 0 {
				t.Fatal("拒绝后未释放等待名额")
			}
		})
	}
}

// newRelayGrantFixture 创建双方均已审批且控制端持有效 token 的测试环境。
func newRelayGrantFixture(t *testing.T) (*RustdeskAdmissionService, core.RustdeskRelayGrantIssueRequest) {
	t.Helper()
	db := newAdmissionTestEngine(t)
	db.SetMaxOpenConns(1)
	insertAdmissionDevice(t, db, "source", DeviceApprovalApproved, true, false, 1)
	insertAdmissionDevice(t, db, "target", DeviceApprovalApproved, true, false, 1)
	token := insertAdmissionToken(t, db, 1, "source", "uuid-1")
	insertAdmissionToken(t, db, 1, "target", "uuid-1")
	return NewRustdeskAdmissionService(db, admissionTestConfig()), core.RustdeskRelayGrantIssueRequest{
		TargetID: "target", AccessToken: token, SessionUUID: testRelaySessionUUID,
		SourceIP: "192.0.2.10", TargetIP: "198.51.100.20",
	}
}

// TestRelayGrantRequiresIssueAndSingleUse 校验无票据、双方核销、重放和重复签发。
func TestRelayGrantRequiresIssueAndSingleUse(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	consume := func(ip string) core.RustdeskAdmissionResponse {
		t.Helper()
		resp, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: ip})
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	started := time.Now()
	if got := consume(req.SourceIP); got.Allow || got.Code != errcode.ERR2315.Code {
		t.Fatalf("没有 hbbs 授权时仍可中继：%+v", got)
	}
	if elapsed := time.Since(started); elapsed < relayGrantIssueWait || elapsed > relayGrantIssueWait+2*time.Second {
		t.Fatalf("无签发等待越界：%v", elapsed)
	}
	issued, err := svc.IssueRelayGrant(req)
	if err != nil || !issued.Allow || issued.SourceDeviceID != "source" || issued.DeviceID != "target" {
		t.Fatalf("签发失败：%+v %v", issued, err)
	}
	if got := consume("203.0.113.5"); got.Allow || got.Code != errcode.ERR2315.Code {
		t.Fatalf("IP 不匹配仍可中继：%+v", got)
	}
	for _, ip := range []string{req.SourceIP, req.TargetIP} {
		if got := consume(ip); !got.Allow || got.SourceDeviceID != "source" || got.DeviceID != "target" {
			t.Fatalf("合法会话端点被拒绝：%+v", got)
		}
	}
	for _, ip := range []string{req.SourceIP, req.TargetIP} {
		if got := consume(ip); got.Allow || got.Code != errcode.ERR2315.Code {
			t.Fatalf("会话核销后仍可重放：%+v", got)
		}
	}
	if got, err := svc.IssueRelayGrant(req); err != nil || got.Allow || got.Code != errcode.ERR2315.Code {
		t.Fatalf("重复签发重置状态：%+v %v", got, err)
	}
}

// TestRelayGrantRevocationAndExpiry 校验签发后撤销、禁用和超时仍会拒绝。
func TestRelayGrantRevocationAndExpiry(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*testing.T, *RustdeskAdmissionService, core.RustdeskRelayGrantIssueRequest)
		code   string
	}{
		{"token revoked", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("rustdesk_id = ?", "source").Cols("status").Update(&model.AuthToken{Status: 0}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2303.Code},
		{"target disabled", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("rustdesk_id = ?", "target").Cols("disabled").Update(&model.Device{Disabled: true}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2307.Code},
		{"source user disabled", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("id = ?", 1).Cols("status").Update(&model.User{Status: 0}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2308.Code},
		{"source relay disabled", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("rustdesk_id = ?", "source").Cols("allow_relay").Update(&model.Device{AllowRelay: false}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2309.Code},
		{"target relay disabled", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("rustdesk_id = ?", "target").Cols("allow_relay").Update(&model.Device{AllowRelay: false}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2309.Code},
		{"expired", func(t *testing.T, svc *RustdeskAdmissionService, req core.RustdeskRelayGrantIssueRequest) {
			if _, err := svc.db.Where("session_uuid = ?", req.SessionUUID).Cols("expires_at").Update(&model.RustdeskRelayGrant{ExpiresAt: time.Now().Add(-time.Second).Unix()}); err != nil {
				t.Fatal(err)
			}
		}, errcode.ERR2315.Code},
	} {
		t.Run(tc.name, func(t *testing.T) {
			svc, req := newRelayGrantFixture(t)
			if got, err := svc.IssueRelayGrant(req); err != nil || !got.Allow {
				t.Fatalf("签发失败：%+v %v", got, err)
			}
			tc.change(t, svc, req)
			got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.SourceIP})
			if err != nil || got.Allow || got.Code != tc.code {
				t.Fatalf("撤销后仍可核销：%+v %v", got, err)
			}
		})
	}
}

// TestRelayGrantRejectsMismatchedIPWithoutConsuming 校验错误来源地址不会占用合法端点名额。
func TestRelayGrantRejectsMismatchedIPWithoutConsuming(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	if got, err := svc.IssueRelayGrant(req); err != nil || !got.Allow {
		t.Fatalf("签发失败：%+v %v", got, err)
	}
	if got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: "203.0.113.5"}); err != nil || got.Allow || got.Code != errcode.ERR2315.Code {
		t.Fatalf("错误来源地址仍可核销：%+v %v", got, err)
	}
	for _, ip := range []string{req.SourceIP, req.TargetIP} {
		if got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: ip}); err != nil || !got.Allow {
			t.Fatalf("错误地址占用了合法端点名额：%+v %v", got, err)
		}
	}
}

// TestRelayGrantSameIPAndInvalidInput 校验同出口 IP 两端和畸形会话均不得签发。
func TestRelayGrantSameIPAndInvalidInput(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	for _, bad := range []core.RustdeskRelayGrantIssueRequest{
		{TargetID: req.TargetID, AccessToken: req.AccessToken, SessionUUID: "not-uuid", SourceIP: req.SourceIP, TargetIP: req.TargetIP},
		{TargetID: req.TargetID, AccessToken: req.AccessToken, SessionUUID: req.SessionUUID, SourceIP: "invalid", TargetIP: req.TargetIP},
		{TargetID: req.TargetID, AccessToken: req.AccessToken, SessionUUID: req.SessionUUID, SourceIP: req.SourceIP, TargetIP: "::ffff:192.0.2.10"},
	} {
		if got, err := svc.IssueRelayGrant(bad); err != nil || got.Allow || got.Code != errcode.ERR2315.Code {
			t.Fatalf("畸形会话被签发：%+v %v", got, err)
		}
	}
	req.TargetIP = req.SourceIP
	if got, err := svc.IssueRelayGrant(req); err != nil || got.Allow || got.Code != errcode.ERR2315.Code {
		t.Fatalf("同 IP 会话仍被签发：%+v %v", got, err)
	}
	var grant model.RustdeskRelayGrant
	if has, err := svc.db.Where("session_uuid = ?", req.SessionUUID).Get(&grant); err != nil || has {
		t.Fatalf("同 IP 会话仍被持久化：has=%v err=%v", has, err)
	}
}

// TestRelayGrantRejectsLegacySameIP 校验升级前遗留的同 IP 授权不能继续核销。
func TestRelayGrantRejectsLegacySameIP(t *testing.T) {
	svc, req := newRelayGrantFixture(t)
	var token model.AuthToken
	if has, err := svc.db.Where("rustdesk_id = ?", "source").Get(&token); err != nil || !has {
		t.Fatalf("找不到测试令牌：has=%v err=%v", has, err)
	}
	grant := model.RustdeskRelayGrant{
		SessionUUID: req.SessionUUID, SourceID: "source", TargetID: "target",
		SourceIP: req.SourceIP, TargetIP: req.SourceIP, TokenID: token.Id,
		ExpiresAt: time.Now().Add(relayGrantLifetime).Unix(),
	}
	if _, err := svc.db.Insert(&grant); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		got, err := svc.ConsumeRelayGrant(context.Background(), core.RustdeskRelayGrantConsumeRequest{SessionUUID: req.SessionUUID, PeerIP: req.SourceIP})
		if err != nil || got.Allow || got.Code != errcode.ERR2315.Code {
			t.Fatalf("遗留同 IP 会话第 %d 次仍可核销：%+v %v", i+1, got, err)
		}
	}
	var stored model.RustdeskRelayGrant
	if has, err := svc.db.Where("session_uuid = ?", req.SessionUUID).Get(&stored); err != nil || !has || stored.SourceUsed || stored.TargetUsed {
		t.Fatalf("拒绝后遗留会话状态被修改：has=%v grant=%+v err=%v", has, stored, err)
	}
}
