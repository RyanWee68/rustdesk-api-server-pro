package service

import (
	"context"
	"net"
	"strings"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"

	"github.com/google/uuid"
)

const relayGrantLifetime = 30 * time.Second

const relayGrantIssueWait = time.Second

var relayGrantWaiters = make(chan struct{}, 32)

// IssueRelayGrant 在双方准入通过后登记一次短时中继会话。
func (s *RustdeskAdmissionService) IssueRelayGrant(req core.RustdeskRelayGrantIssueRequest) (core.RustdeskAdmissionResponse, error) {
	sessionUUID := strings.TrimSpace(req.SessionUUID)
	sourceIP := canonicalRelayIP(req.SourceIP)
	targetIP := canonicalRelayIP(req.TargetIP)
	if !validRelaySessionUUID(sessionUUID) || sourceIP == "" || targetIP == "" || sourceIP == targetIP {
		return deny(errcode.ERR2315), nil
	}
	resp, err := s.CheckConnection(core.RustdeskConnectionRequest{
		TargetID: req.TargetID, AccessToken: req.AccessToken, SourceIP: sourceIP, Relay: true,
	})
	if err != nil || !resp.Allow {
		return resp, err
	}
	token, ok, err := s.resolveConnectionToken(req.AccessToken)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !ok || token.RustdeskId != resp.SourceDeviceID || token.UserId != resp.UserID {
		return deny(errcode.ERR2303), nil
	}
	expiresAt := time.Now().Add(relayGrantLifetime)
	if resp.Policy != nil && resp.Policy.ExpireAt > 0 {
		policyExpiry := time.Unix(resp.Policy.ExpireAt, 0)
		if policyExpiry.Before(expiresAt) {
			expiresAt = policyExpiry
		}
	}
	if expiresAt.Unix() <= time.Now().Unix() {
		return deny(errcode.ERR2315), nil
	}
	if _, err := s.db.Where("expires_at <= ?", time.Now().Unix()).Delete(&model.RustdeskRelayGrant{}); err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	grant := model.RustdeskRelayGrant{
		SessionUUID: sessionUUID, SourceID: resp.SourceDeviceID, TargetID: resp.DeviceID,
		SourceIP: sourceIP, TargetIP: targetIP, TokenID: token.Id, ExpiresAt: expiresAt.Unix(),
	}
	// 会话 UUID 是主键；重复签发不能重置已核销的状态。
	var existing model.RustdeskRelayGrant
	has, err := s.db.Where("session_uuid = ?", sessionUUID).Get(&existing)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if has {
		return deny(errcode.ERR2315), nil
	}
	if _, err := s.db.Insert(&grant); err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	return resp, nil
}

// ConsumeRelayGrant 核销一端中继连接，并在每次核销时重新检查授权。
func (s *RustdeskAdmissionService) ConsumeRelayGrant(ctx context.Context, req core.RustdeskRelayGrantConsumeRequest) (core.RustdeskAdmissionResponse, error) {
	sessionUUID := strings.TrimSpace(req.SessionUUID)
	peerIP := canonicalRelayIP(req.PeerIP)
	if !validRelaySessionUUID(sessionUUID) || peerIP == "" {
		return deny(errcode.ERR2315), nil
	}
	grant, has, err := s.waitRelayGrant(ctx, sessionUUID)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	now := time.Now()
	if !has || grant.ExpiresAt <= now.Unix() || grant.SourceIP == grant.TargetIP || (peerIP != grant.SourceIP && peerIP != grant.TargetIP) {
		return deny(errcode.ERR2315), nil
	}
	var token model.AuthToken
	has, err = s.db.Where("id = ? and status = 1 and is_admin = 0", grant.TokenID).Get(&token)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !has || !token.Expired.After(now) || token.UserId <= 0 || token.RustdeskId != grant.SourceID {
		return deny(errcode.ERR2303), nil
	}
	source, found, err := s.getDevice(grant.SourceID)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !found || (source.Uuid != "" && source.Uuid != token.Uuid) || (source.UserId > 0 && source.UserId != token.UserId) {
		return deny(errcode.ERR2315), nil
	}
	sourceResp := s.evaluateDevice(source, &token, true)
	if !sourceResp.Allow {
		return sourceResp, nil
	}
	target, found, err := s.getDevice(grant.TargetID)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !found {
		return deny(errcode.ERR2304), nil
	}
	targetResp := s.evaluateDevice(target, nil, true)
	if !targetResp.Allow {
		return targetResp, nil
	}
	useSource := peerIP == grant.SourceIP && !grant.SourceUsed
	useTarget := peerIP == grant.TargetIP && !grant.TargetUsed && !useSource
	if !useSource && !useTarget {
		return deny(errcode.ERR2315), nil
	}
	var affected int64
	if useSource {
		affected, err = s.db.Where("session_uuid = ? and source_used = ? and expires_at > ?", sessionUUID, false, now.Unix()).
			Cols("source_used").Update(&model.RustdeskRelayGrant{SourceUsed: true})
	} else {
		affected, err = s.db.Where("session_uuid = ? and target_used = ? and expires_at > ?", sessionUUID, false, now.Unix()).
			Cols("target_used").Update(&model.RustdeskRelayGrant{TargetUsed: true})
	}
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if affected != 1 {
		return deny(errcode.ERR2315), nil
	}
	targetResp.UserID = token.UserId
	targetResp.SourceDeviceID = source.RustdeskId
	targetResp.Policy.ExpireAt = minNonZeroUnix(sourceResp.Policy.ExpireAt, targetResp.Policy.ExpireAt)
	return targetResp, nil
}

// waitRelayGrant 仅为尚未签发的会话短暂等待，兼容被控端先连 hbbr 的跨连接时序。
func (s *RustdeskAdmissionService) waitRelayGrant(ctx context.Context, sessionUUID string) (model.RustdeskRelayGrant, bool, error) {
	ctx, cancel := context.WithTimeout(ctx, relayGrantIssueWait)
	defer cancel()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	waiting := false
	defer func() {
		if waiting {
			<-relayGrantWaiters
		}
	}()
	for {
		var grant model.RustdeskRelayGrant
		if ctx.Err() != nil {
			return grant, false, nil
		}
		has, err := s.db.Context(ctx).Where("session_uuid = ?", sessionUUID).Get(&grant)
		if ctx.Err() != nil {
			return model.RustdeskRelayGrant{}, false, nil
		}
		if err != nil || has {
			return grant, has, err
		}
		if !waiting {
			select {
			case relayGrantWaiters <- struct{}{}:
				waiting = true
			default:
				return grant, false, nil
			}
		}
		// 等待期间不持有数据库事务；签发完成后仍走完整权限检查及原子核销。
		select {
		case <-ctx.Done():
			return grant, false, nil
		case <-ticker.C:
		}
	}
}

// canonicalRelayIP 将 hbbs/hbbr 观察到的地址统一为纯 IP 文本。
func canonicalRelayIP(raw string) string {
	ip := net.ParseIP(strings.TrimSpace(raw))
	if ip == nil {
		return ""
	}
	return ip.String()
}

// validRelaySessionUUID 只接受客户端会话使用的标准随机 UUID v4。
func validRelaySessionUUID(raw string) bool {
	id, err := uuid.Parse(raw)
	return err == nil && id.Version() == 4 && id.String() == raw
}
