package service

import (
	"strings"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"
	"rustdesk-api-server-pro/util"

	"xorm.io/xorm"
)

const (
	DeviceApprovalPending  = "pending"
	DeviceApprovalApproved = "approved"
	DeviceApprovalRejected = "rejected"
	DeviceApprovalDisabled = "disabled"
)

// RustdeskAdmissionService 封装受控 RustDesk 服务端调用 API 的准入规则。
type RustdeskAdmissionService struct {
	db  *xorm.Engine
	cfg *config.ServerConfig
}

// NewRustdeskAdmissionService 创建 RustDesk 准入服务。
func NewRustdeskAdmissionService(db *xorm.Engine, cfg *config.ServerConfig) *RustdeskAdmissionService {
	return &RustdeskAdmissionService{db: db, cfg: cfg}
}

// Register 登记设备并返回当前审批状态对应的准入结果。
func (s *RustdeskAdmissionService) Register(req core.RustdeskRegisterRequest) (core.RustdeskAdmissionResponse, error) {
	rustdeskID := normalizeRustdeskID(req.RustdeskID, req.ID)
	if rustdeskID == "" {
		return deny(errcode.ERR2302), nil
	}

	now := time.Now()
	var device model.Device
	has, err := s.db.Where("rustdesk_id = ?", rustdeskID).Get(&device)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !has {
		device = model.Device{
			RustdeskId:     rustdeskID,
			Uuid:           req.UUID,
			Fingerprint:    req.Fingerprint,
			Hostname:       req.Hostname,
			Username:       req.Username,
			Os:             req.OS,
			Version:        req.ClientVersion,
			ClientVersion:  req.ClientVersion,
			ApprovalStatus: DeviceApprovalPending,
			AllowRelay:     true,
			LastSourceIP:   req.SourceIP,
			LastSeenAt:     now,
		}
		if _, err := s.db.Insert(&device); err != nil {
			return core.RustdeskAdmissionResponse{}, err
		}
		return deny(errcode.ERR2305), nil
	}

	if !matchesDeviceIdentity(device, req.UUID, req.Fingerprint) {
		return deny(errcode.ERR2313), nil
	}
	update := model.Device{
		Uuid:          firstNonEmpty(req.UUID, device.Uuid),
		Fingerprint:   firstNonEmpty(req.Fingerprint, device.Fingerprint),
		Hostname:      firstNonEmpty(req.Hostname, device.Hostname),
		Username:      firstNonEmpty(req.Username, device.Username),
		Os:            firstNonEmpty(req.OS, device.Os),
		Version:       firstNonEmpty(req.ClientVersion, device.Version),
		ClientVersion: firstNonEmpty(req.ClientVersion, device.ClientVersion),
		LastSourceIP:  firstNonEmpty(req.SourceIP, device.LastSourceIP),
		LastSeenAt:    now,
	}
	// 重复注册只能更新设备信息，已有审批状态必须保留。
	update.ApprovalStatus = firstNonEmpty(device.ApprovalStatus, DeviceApprovalPending)
	if _, err := s.db.Where("id = ?", device.Id).
		Cols("uuid", "fingerprint", "hostname", "username", "os", "version", "client_version", "last_source_ip", "last_seen_at", "approval_status").
		Update(&update); err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	device.Uuid = update.Uuid
	device.Fingerprint = update.Fingerprint
	device.Hostname = update.Hostname
	device.Username = update.Username
	device.Os = update.Os
	device.Version = update.Version
	device.ClientVersion = update.ClientVersion
	device.LastSourceIP = update.LastSourceIP
	device.LastSeenAt = update.LastSeenAt
	if update.ApprovalStatus != "" {
		device.ApprovalStatus = update.ApprovalStatus
	}
	return s.evaluateDevice(device, nil, false), nil
}

// Authorize 校验设备登录态、审批状态和用户状态。
func (s *RustdeskAdmissionService) Authorize(req core.RustdeskAdmissionRequest) (core.RustdeskAdmissionResponse, error) {
	return s.authorize(req, false)
}

// authorize 在所有准入策略通过后才更新绑定和在线状态。
func (s *RustdeskAdmissionService) authorize(req core.RustdeskAdmissionRequest, relayOnly bool) (core.RustdeskAdmissionResponse, error) {
	rustdeskID := normalizeRustdeskID(req.RustdeskID, req.ID)
	if rustdeskID == "" {
		return deny(errcode.ERR2302), nil
	}

	device, has, err := s.getDevice(rustdeskID)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !has {
		return deny(errcode.ERR2304), nil
	}
	if !matchesDeviceIdentity(device, req.UUID, req.Fingerprint) {
		return deny(errcode.ERR2313), nil
	}

	token, user, ok, err := s.resolveActiveClientToken(req.AccessToken, rustdeskID, firstNonEmpty(device.Uuid, req.UUID))
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !ok {
		return deny(errcode.ERR2303), nil
	}
	if device.UserId > 0 && device.UserId != user.Id {
		return deny(errcode.ERR2314), nil
	}
	resp := s.evaluateDevice(device, token, relayOnly)
	if !resp.Allow {
		return resp, nil
	}
	if err := s.touchDevice(device, user.Id, req.UUID, req.Fingerprint, req.SourceIP, req.ClientVersion, nil); err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	return resp, nil
}

// Heartbeat 更新设备在线状态并返回当前准入状态。
func (s *RustdeskAdmissionService) Heartbeat(req core.RustdeskHeartbeatRequest) (core.RustdeskAdmissionResponse, error) {
	rustdeskID := normalizeRustdeskID(req.RustdeskID, req.ID)
	if rustdeskID == "" {
		return deny(errcode.ERR2302), nil
	}
	device, has, err := s.getDevice(rustdeskID)
	if err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	if !has {
		return deny(errcode.ERR2304), nil
	}
	if !matchesDeviceIdentity(device, req.UUID, "") {
		return deny(errcode.ERR2313), nil
	}
	resp := s.evaluateDevice(device, nil, false)
	if !resp.Allow {
		return resp, nil
	}
	// 零连接数也是有效心跳，必须清除上一次的非零计数。
	if err := s.touchDevice(device, device.UserId, req.UUID, "", req.SourceIP, req.ClientVersion, &req.ConnCount); err != nil {
		return core.RustdeskAdmissionResponse{}, err
	}
	return resp, nil
}

// CheckRelay 校验设备是否允许使用中继服务。
func (s *RustdeskAdmissionService) CheckRelay(req core.RustdeskRelayCheckRequest) (core.RustdeskAdmissionResponse, error) {
	return s.authorize(core.RustdeskAdmissionRequest{
		RustdeskID:  req.RustdeskID,
		ID:          req.ID,
		UUID:        req.UUID,
		AccessToken: req.AccessToken,
		SourceIP:    req.SourceIP,
	}, true)
}

func (s *RustdeskAdmissionService) getDevice(rustdeskID string) (model.Device, bool, error) {
	var device model.Device
	has, err := s.db.Where("rustdesk_id = ?", rustdeskID).Get(&device)
	return device, has, err
}

func (s *RustdeskAdmissionService) resolveActiveClientToken(accessToken, rustdeskID, uuid string) (*model.AuthToken, *model.User, bool, error) {
	token := strings.TrimSpace(accessToken)
	if token == "" {
		return nil, nil, false, nil
	}

	var authToken model.AuthToken
	now := time.Now()
	tokenHash := util.Sha256Hex(token)
	query := s.db.Where("token_hash = ? and rustdesk_id = ? and status = 1 and is_admin = 0", tokenHash, rustdeskID)
	if strings.TrimSpace(uuid) != "" {
		query = query.And("uuid = ?", uuid)
	}
	has, err := query.Get(&authToken)
	if err != nil {
		return nil, nil, false, err
	}
	if !has {
		query = s.db.Where("token = ? and rustdesk_id = ? and status = 1 and is_admin = 0", token, rustdeskID)
		if strings.TrimSpace(uuid) != "" {
			query = query.And("uuid = ?", uuid)
		}
		has, err = query.Get(&authToken)
		if err != nil || !has {
			return nil, nil, false, err
		}
	}
	if !authToken.Expired.After(now) {
		return nil, nil, false, nil
	}

	var user model.User
	has, err = s.db.Where("id = ?", authToken.UserId).Get(&user)
	if err != nil || !has {
		return nil, nil, false, err
	}
	return &authToken, &user, true, nil
}

// touchDevice 更新已放行设备，未提供连接计数时保留原计数。
func (s *RustdeskAdmissionService) touchDevice(device model.Device, userID int, uuid, fingerprint, sourceIP, clientVersion string, connCount *int) error {
	update := model.Device{
		UserId:        userID,
		Uuid:          firstNonEmpty(uuid, device.Uuid),
		Fingerprint:   firstNonEmpty(fingerprint, device.Fingerprint),
		LastSourceIP:  firstNonEmpty(sourceIP, device.LastSourceIP),
		ClientVersion: firstNonEmpty(clientVersion, device.ClientVersion),
		Version:       firstNonEmpty(clientVersion, device.Version),
		LastSeenAt:    time.Now(),
		IsOnline:      true,
	}
	cols := []string{"user_id", "uuid", "fingerprint", "last_source_ip", "client_version", "version", "last_seen_at", "is_online"}
	if connCount != nil {
		update.Conns = *connCount
		cols = append(cols, "conns")
	}
	_, err := s.db.Where("id = ?", device.Id).Cols(cols...).Update(&update)
	return err
}

func (s *RustdeskAdmissionService) evaluateDevice(device model.Device, token *model.AuthToken, relayOnly bool) core.RustdeskAdmissionResponse {
	if device.Disabled || device.ApprovalStatus == DeviceApprovalDisabled {
		return deny(errcode.ERR2307)
	}
	switch strings.TrimSpace(device.ApprovalStatus) {
	case DeviceApprovalApproved:
	case DeviceApprovalRejected:
		return deny(errcode.ERR2306)
	default:
		return deny(errcode.ERR2305)
	}
	if !device.AuthorizedUntil.IsZero() && device.AuthorizedUntil.Before(time.Now()) {
		return deny(errcode.ERR2310)
	}
	if relayOnly && !device.AllowRelay {
		return deny(errcode.ERR2309)
	}

	userID := device.UserId
	expireAt := int64(0)
	allowRelay := device.AllowRelay
	if userID > 0 {
		var boundUser model.User
		has, err := s.db.Where("id = ?", userID).Get(&boundUser)
		if err != nil || !has {
			return deny(errcode.ERR2308)
		}
		if policyResp, ok := s.evaluateUserPolicy(boundUser, relayOnly, &expireAt); !ok {
			return policyResp
		}
		allowRelay = allowRelay && boundUser.AllowRelay
	}
	if token != nil {
		userID = token.UserId
		expireAt = minNonZeroUnix(expireAt, token.Expired.Unix())
		var user model.User
		has, err := s.db.Where("id = ?", token.UserId).Get(&user)
		if err != nil || !has {
			return deny(errcode.ERR2308)
		}
		if policyResp, ok := s.evaluateUserPolicy(user, relayOnly, &expireAt); !ok {
			return policyResp
		}
		allowRelay = allowRelay && user.AllowRelay
	}
	if !device.AuthorizedUntil.IsZero() {
		expireAt = minNonZeroUnix(expireAt, device.AuthorizedUntil.Unix())
	}

	return core.RustdeskAdmissionResponse{
		Allow:    true,
		UserID:   userID,
		DeviceID: device.RustdeskId,
		Policy: &core.RustdeskAccessPolicy{
			AllowRelay: allowRelay,
			ExpireAt:   expireAt,
			CacheTTL:   s.authCacheSeconds(),
		},
	}
}

func (s *RustdeskAdmissionService) evaluateUserPolicy(user model.User, relayOnly bool, expireAt *int64) (core.RustdeskAdmissionResponse, bool) {
	if user.Status <= 0 {
		return deny(errcode.ERR2308), false
	}
	if !user.AllowRemoteAccess {
		return deny(errcode.ERR2311), false
	}
	if relayOnly && !user.AllowRelay {
		return deny(errcode.ERR2309), false
	}
	if !user.AuthorizedUntil.IsZero() {
		if user.AuthorizedUntil.Before(time.Now()) {
			return deny(errcode.ERR2312), false
		}
		*expireAt = minNonZeroUnix(*expireAt, user.AuthorizedUntil.Unix())
	}
	return core.RustdeskAdmissionResponse{}, true
}

func (s *RustdeskAdmissionService) authCacheSeconds() int {
	if s.cfg != nil && s.cfg.RustdeskServer != nil && s.cfg.RustdeskServer.AuthCacheSeconds > 0 {
		return s.cfg.RustdeskServer.AuthCacheSeconds
	}
	return 60
}

func deny(entry errcode.Entry) core.RustdeskAdmissionResponse {
	return core.RustdeskAdmissionResponse{
		Allow:   false,
		Code:    entry.Code,
		Message: entry.Code + " " + entry.Message,
	}
}

// matchesDeviceIdentity 拒绝使用冲突的设备身份覆盖已登记的身份。
// 未提供的字段保持兼容，不能将此检查当作协议层的设备身份证明。
func matchesDeviceIdentity(device model.Device, uuid, fingerprint string) bool {
	return (uuid == "" || device.Uuid == "" || uuid == device.Uuid) &&
		(fingerprint == "" || device.Fingerprint == "" || fingerprint == device.Fingerprint)
}

func normalizeRustdeskID(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func firstNonEmpty(value, fallback string) string {
	if strings.TrimSpace(value) != "" {
		return value
	}
	return fallback
}

func minNonZeroUnix(current, candidate int64) int64 {
	if candidate == 0 {
		return current
	}
	if current == 0 || candidate < current {
		return candidate
	}
	return current
}
