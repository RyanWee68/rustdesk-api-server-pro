package rustdeskinternal

import (
	"crypto/subtle"
	"encoding/json"
	"strings"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"
	v2service "rustdesk-api-server-pro/internal/service"

	"github.com/kataras/iris/v12"
	"github.com/kataras/iris/v12/mvc"
	"xorm.io/xorm"
)

type RustdeskController struct {
	Ctx iris.Context
	Db  *xorm.Engine
	Cfg *config.ServerConfig
}

func (c *RustdeskController) BeforeActivation(b mvc.BeforeActivation) {
	b.Handle("POST", "/auth", "PostAuth")
	b.Handle("POST", "/device/register", "PostDeviceRegister")
	b.Handle("POST", "/device/heartbeat", "PostDeviceHeartbeat")
	b.Handle("POST", "/relay/check", "PostRelayCheck")
	b.Handle("POST", "/connection/check", "PostConnectionCheck")
	b.Handle("POST", "/relay/grant/issue", "PostRelayGrantIssue")
	b.Handle("POST", "/relay/grant/consume", "PostRelayGrantConsume")
}

// PostRelayGrantIssue 由 hbbs 在中继请求获准后登记短时会话。
func (c *RustdeskController) PostRelayGrantIssue() mvc.Result {
	if result, ok := c.requireInternalSecret(); !ok {
		return result
	}
	var req core.RustdeskRelayGrantIssueRequest
	if err := c.Ctx.ReadJSON(&req); err != nil {
		return c.internalError(err)
	}
	resp, err := c.service().IssueRelayGrant(req)
	return c.resultWithAudit("rustdesk_internal_relay_grant_issue", strings.TrimSpace(req.TargetID), iris.Map{
		"target_id": strings.TrimSpace(req.TargetID), "source_ip": req.SourceIP,
		"target_ip": req.TargetIP, "has_token": strings.TrimSpace(req.AccessToken) != "",
	}, resp, err)
}

// PostRelayGrantConsume 由 hbbr 根据实际连接 IP 核销会话的一端。
func (c *RustdeskController) PostRelayGrantConsume() mvc.Result {
	if result, ok := c.requireInternalSecret(); !ok {
		return result
	}
	var req core.RustdeskRelayGrantConsumeRequest
	if err := c.Ctx.ReadJSON(&req); err != nil {
		return c.internalError(err)
	}
	resp, err := c.service().ConsumeRelayGrant(c.Ctx.Request().Context(), req)
	return c.resultWithAudit("rustdesk_internal_relay_grant_consume", resp.DeviceID, iris.Map{
		"peer_ip": req.PeerIP, "has_session_uuid": strings.TrimSpace(req.SessionUUID) != "",
	}, resp, err)
}

// PostConnectionCheck 校验控制端 token 与被控端策略，审计不记录凭据。
func (c *RustdeskController) PostConnectionCheck() mvc.Result {
	if result, ok := c.requireInternalSecret(); !ok {
		return result
	}
	var req core.RustdeskConnectionRequest
	if err := c.Ctx.ReadJSON(&req); err != nil {
		return c.internalError(err)
	}
	req.SourceIP = c.sourceIP(req.SourceIP)
	resp, err := c.service().CheckConnection(req)
	return c.resultWithAudit("rustdesk_internal_connection_check", strings.TrimSpace(req.TargetID), iris.Map{
		"target_id": strings.TrimSpace(req.TargetID),
		"has_token": strings.TrimSpace(req.AccessToken) != "",
		"source_ip": req.SourceIP,
		"relay":     req.Relay,
	}, resp, err)
}

func (c *RustdeskController) PostAuth() mvc.Result {
	if result, ok := c.requireInternalSecret(); !ok {
		return result
	}
	var req core.RustdeskAdmissionRequest
	if err := c.Ctx.ReadJSON(&req); err != nil {
		return c.internalError(err)
	}
	req.SourceIP = c.sourceIP(req.SourceIP)
	resp, err := c.service().Authorize(req)
	return c.resultWithAudit("rustdesk_internal_auth", rustdeskAdmissionAuditResource(req.RustdeskID, req.ID), sanitizeAdmissionRequest(req), resp, err)
}

func (c *RustdeskController) PostDeviceRegister() mvc.Result {
	if result, ok := c.requireInternalSecret(); !ok {
		return result
	}
	var req core.RustdeskRegisterRequest
	if err := c.Ctx.ReadJSON(&req); err != nil {
		return c.internalError(err)
	}
	req.SourceIP = c.sourceIP(req.SourceIP)
	resp, err := c.service().Register(req)
	return c.resultWithAudit("rustdesk_internal_device_register", rustdeskAdmissionAuditResource(req.RustdeskID, req.ID), sanitizeRegisterRequest(req), resp, err)
}

func (c *RustdeskController) PostDeviceHeartbeat() mvc.Result {
	if result, ok := c.requireInternalSecret(); !ok {
		return result
	}
	var req core.RustdeskHeartbeatRequest
	if err := c.Ctx.ReadJSON(&req); err != nil {
		return c.internalError(err)
	}
	req.SourceIP = c.sourceIP(req.SourceIP)
	resp, err := c.service().Heartbeat(req)
	return c.resultWithAudit("rustdesk_internal_device_heartbeat", rustdeskAdmissionAuditResource(req.RustdeskID, req.ID), sanitizeHeartbeatRequest(req), resp, err)
}

func (c *RustdeskController) PostRelayCheck() mvc.Result {
	if result, ok := c.requireInternalSecret(); !ok {
		return result
	}
	var req core.RustdeskRelayCheckRequest
	if err := c.Ctx.ReadJSON(&req); err != nil {
		return c.internalError(err)
	}
	req.SourceIP = c.sourceIP(req.SourceIP)
	resp, err := c.service().CheckRelay(req)
	return c.resultWithAudit("rustdesk_internal_relay_check", rustdeskAdmissionAuditResource(req.RustdeskID, req.ID), sanitizeRelayCheckRequest(req), resp, err)
}

func (c *RustdeskController) requireInternalSecret() (mvc.Result, bool) {
	expected := ""
	if c.Cfg != nil && c.Cfg.RustdeskServer != nil {
		expected = strings.TrimSpace(c.Cfg.RustdeskServer.InternalSecret)
	}
	actual := strings.TrimSpace(c.Ctx.GetHeader("X-Internal-Secret"))
	if actual == "" {
		actual = strings.TrimPrefix(strings.TrimSpace(c.Ctx.GetHeader("Authorization")), "Bearer ")
	}
	if expected == "" || actual == "" || subtle.ConstantTimeCompare([]byte(expected), []byte(actual)) != 1 {
		c.recordAdmissionAudit("rustdesk_internal_secret_check", "", nil, core.RustdeskAdmissionResponse{
			Allow:   false,
			Code:    errcode.ERR2301.Code,
			Message: errcode.ERR2301.Code + " " + errcode.ERR2301.Message,
		}, nil)
		return mvc.Response{
			Code: iris.StatusUnauthorized,
			Object: core.RustdeskAdmissionResponse{
				Allow:   false,
				Code:    errcode.ERR2301.Code,
				Message: errcode.ERR2301.Code + " " + errcode.ERR2301.Message,
			},
		}, false
	}
	return nil, true
}

func (c *RustdeskController) resultWithAudit(action string, resourceID string, request interface{}, resp core.RustdeskAdmissionResponse, err error) mvc.Result {
	c.recordAdmissionAudit(action, resourceID, request, resp, err)
	if err != nil {
		return c.internalError(err)
	}
	return mvc.Response{Object: resp}
}

func (c *RustdeskController) internalError(err error) mvc.Result {
	ensured := errcode.Ensure(err)
	return mvc.Response{
		Code: iris.StatusInternalServerError,
		Object: core.RustdeskAdmissionResponse{
			Allow:   false,
			Code:    extractErrCode(ensured.Error()),
			Message: ensured.Error(),
		},
	}
}

func (c *RustdeskController) sourceIP(input string) string {
	if strings.TrimSpace(input) != "" {
		return input
	}
	return c.Ctx.RemoteAddr()
}

func (c *RustdeskController) service() *v2service.RustdeskAdmissionService {
	return v2service.NewRustdeskAdmissionService(c.Db, c.Cfg)
}

func (c *RustdeskController) recordAdmissionAudit(action string, resourceID string, request interface{}, resp core.RustdeskAdmissionResponse, err error) {
	if c.Db == nil {
		return
	}
	result := "deny"
	errorMessage := resp.Code
	if err != nil {
		result = "error"
		errorMessage = errcode.Ensure(err).Error()
	} else if resp.Allow {
		result = "allow"
		errorMessage = ""
	}
	_, _ = c.Db.Insert(&model.OperationAudit{
		Action:       action,
		ResourceType: "rustdesk_admission",
		ResourceId:   resourceID,
		BeforeData:   admissionAuditJSON(request),
		AfterData:    admissionAuditJSON(sanitizeAdmissionResponse(resp)),
		IP:           c.Ctx.RemoteAddr(),
		UserAgent:    c.Ctx.GetHeader("User-Agent"),
		Result:       result,
		ErrorMessage: errorMessage,
	})
}

func sanitizeAdmissionRequest(req core.RustdeskAdmissionRequest) iris.Map {
	return iris.Map{
		"rustdesk_id":    rustdeskAdmissionAuditResource(req.RustdeskID, req.ID),
		"uuid":           req.UUID,
		"fingerprint":    req.Fingerprint,
		"source_ip":      req.SourceIP,
		"client_version": req.ClientVersion,
		"has_token":      strings.TrimSpace(req.AccessToken) != "",
	}
}

func sanitizeRegisterRequest(req core.RustdeskRegisterRequest) iris.Map {
	return iris.Map{
		"rustdesk_id":    rustdeskAdmissionAuditResource(req.RustdeskID, req.ID),
		"uuid":           req.UUID,
		"fingerprint":    req.Fingerprint,
		"hostname":       req.Hostname,
		"username":       req.Username,
		"os":             req.OS,
		"source_ip":      req.SourceIP,
		"client_version": req.ClientVersion,
	}
}

func sanitizeHeartbeatRequest(req core.RustdeskHeartbeatRequest) iris.Map {
	return iris.Map{
		"rustdesk_id":    rustdeskAdmissionAuditResource(req.RustdeskID, req.ID),
		"uuid":           req.UUID,
		"source_ip":      req.SourceIP,
		"client_version": req.ClientVersion,
		"conn_count":     req.ConnCount,
	}
}

func sanitizeRelayCheckRequest(req core.RustdeskRelayCheckRequest) iris.Map {
	return iris.Map{
		"rustdesk_id": rustdeskAdmissionAuditResource(req.RustdeskID, req.ID),
		"uuid":        req.UUID,
		"source_ip":   req.SourceIP,
		"has_token":   strings.TrimSpace(req.AccessToken) != "",
	}
}

func sanitizeAdmissionResponse(resp core.RustdeskAdmissionResponse) iris.Map {
	return iris.Map{
		"allow":            resp.Allow,
		"user_id":          resp.UserID,
		"device_id":        resp.DeviceID,
		"source_device_id": resp.SourceDeviceID,
		"code":             resp.Code,
		"policy":           resp.Policy,
	}
}

func rustdeskAdmissionAuditResource(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func admissionAuditJSON(value interface{}) string {
	if value == nil {
		return ""
	}
	data, err := json.Marshal(value)
	if err != nil {
		return ""
	}
	return string(data)
}

func extractErrCode(message string) string {
	message = strings.TrimSpace(message)
	idx := strings.Index(message, ":")
	if idx > 0 {
		return message[:idx]
	}
	if strings.HasPrefix(message, "ERR-") {
		return message
	}
	return ""
}
