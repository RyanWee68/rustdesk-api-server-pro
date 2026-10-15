package service

import (
	"strings"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"
	"rustdesk-api-server-pro/util"
)

// CheckConnection 将控制端 token 身份与被控端分别校验，仅作准入判断、不修改设备归属。
// 此接口不是中继票据，hbbr 仍须通过可信授权链路确认连接来自已获准的 hbbs 会话。
func (s *RustdeskAdmissionService) CheckConnection(req core.RustdeskConnectionRequest) (core.RustdeskAdmissionResponse, error) {
	targetID := strings.TrimSpace(req.TargetID)
	if targetID == "" {
		return deny(errcode.ERR2302), nil
	}
	token, ok, err := s.resolveConnectionToken(req.AccessToken)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !ok {
		return deny(errcode.ERR2303), nil
	}

	source, found, err := s.getDevice(token.RustdeskId)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !found {
		return deny(errcode.ERR2304), nil
	}
	if source.Uuid != "" && source.Uuid != token.Uuid {
		return deny(errcode.ERR2313), nil
	}
	if source.UserId > 0 && source.UserId != token.UserId {
		return deny(errcode.ERR2314), nil
	}
	sourceResult := s.evaluateDevice(source, token, req.Relay)
	if !sourceResult.Allow {
		return sourceResult, nil
	}

	target, found, err := s.getDevice(targetID)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !found {
		return deny(errcode.ERR2304), nil
	}
	targetToken, ok, err := s.resolveTargetLoginToken(target)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !ok {
		return deny(errcode.ERR2303), nil
	}
	if target.Uuid != "" && target.Uuid != targetToken.Uuid {
		return deny(errcode.ERR2313), nil
	}
	if target.UserId > 0 && target.UserId != targetToken.UserId {
		return deny(errcode.ERR2314), nil
	}
	targetResult := s.evaluateDevice(target, targetToken, req.Relay)
	if !targetResult.Allow {
		return targetResult, nil
	}

	// 合并双方策略，任何一方不允许中继或更早到期都必须生效。
	targetResult.UserID = token.UserId
	targetResult.SourceDeviceID = source.RustdeskId
	targetResult.Policy.AllowRelay = sourceResult.Policy.AllowRelay && targetResult.Policy.AllowRelay
	targetResult.Policy.ExpireAt = minNonZeroUnix(sourceResult.Policy.ExpireAt, targetResult.Policy.ExpireAt)
	return targetResult, nil
}

// resolveTargetLoginToken 要求被控端至少保有绑定设备的有效客户端登录令牌。
// 这不是设备私钥证明；它只确保退出或撤销登录后不能再建立新连接。
func (s *RustdeskAdmissionService) resolveTargetLoginToken(device model.Device) (*model.AuthToken, bool, error) {
	var tokens []model.AuthToken
	query := s.db.Where("rustdesk_id = ? and status = 1 and is_admin = 0", device.RustdeskId)
	if err := query.Desc("id").Find(&tokens); err != nil {
		return nil, false, err
	}
	now := time.Now()
	for i := range tokens {
		if tokens[i].UserId > 0 && tokens[i].Expired.After(now) {
			return &tokens[i], true, nil
		}
	}
	return nil, false, nil
}

// resolveConnectionToken 由凭据查找控制端，不能用请求的目标 ID 过滤控制端 token。
func (s *RustdeskAdmissionService) resolveConnectionToken(raw string) (*model.AuthToken, bool, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return nil, false, nil
	}
	var token model.AuthToken
	found, err := s.db.Where("token_hash = ? and status = 1 and is_admin = 0", util.Sha256Hex(value)).Get(&token)
	if err != nil {
		return nil, false, err
	}
	if !found {
		found, err = s.db.Where("token = ? and status = 1 and is_admin = 0", value).Get(&token)
	}
	if err != nil || !found {
		return nil, false, err
	}
	if !token.Expired.After(time.Now()) || token.UserId <= 0 || strings.TrimSpace(token.RustdeskId) == "" {
		return nil, false, nil
	}
	return &token, true, nil
}
