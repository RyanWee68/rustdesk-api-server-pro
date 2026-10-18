package api

import (
	apiform "rustdesk-api-server-pro/app/form/api"
	"rustdesk-api-server-pro/internal/core"

	"github.com/kataras/iris/v12"
	"github.com/kataras/iris/v12/mvc"
)

type LoginController struct {
	basicController
}

func (c *LoginController) BeforeActivation(b mvc.BeforeActivation) {
	b.Handle("GET", "/login-options", "HandleLoginOptions")
	b.Handle("POST", "/login-options", "HandleLoginOptions")
}

func (c *LoginController) PostLogin() mvc.Result {
	var loginForm apiform.LoginForm
	if err := c.readJSONBody(&loginForm); err != nil {
		c.recordClientLoginAudit("", false, "decode_error: "+err.Error())
		return c.fail(err)
	}

	result := c.loginService().HandleLogin(loginForm)
	success, reason := clientLoginAuditResult(result)
	c.recordClientLoginAudit(loginForm.Username, success, reason)
	return mvc.Response{Object: result}
}

func (c *LoginController) HandleLoginOptions() mvc.Result {
	result := c.compatService().LoginOptions()
	c.recordCompatAPIAudit(false, 200, "ok", "", nil)
	return mvc.Response{
		Object: result.Options,
	}
}

func (c *LoginController) recordClientLoginAudit(username string, success bool, reason string) {
	if reason == "" {
		if success {
			reason = "access_token"
		} else {
			reason = "unknown"
		}
	}
	_ = c.auditService().CreateSecurityAudit(core.SecurityAuditCreateCommand{
		Username:  username,
		Event:     "api_login",
		IP:        c.Ctx.RemoteAddr(),
		UserAgent: c.Ctx.GetHeader("User-Agent"),
		Success:   success,
		Reason:    reason,
	})
}

func clientLoginAuditResult(result any) (bool, string) {
	m, ok := result.(iris.Map)
	if !ok {
		return false, "unexpected_response"
	}
	if errValue, exists := m["error"]; exists {
		return false, stringFromAny(errValue)
	}
	if _, exists := m["access_token"]; exists {
		return true, "access_token"
	}
	if t, exists := m["type"]; exists {
		return false, "pending_" + stringFromAny(t)
	}
	return false, "pending_or_unknown"
}
