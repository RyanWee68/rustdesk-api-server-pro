package admin

import (
	"strconv"
	"time"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/db"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"
	v2service "rustdesk-api-server-pro/internal/service"

	"github.com/kataras/iris/v12"
	"github.com/kataras/iris/v12/mvc"
	"xorm.io/xorm"
)

type DevicesController struct {
	basicController
}

func (c *DevicesController) BeforeActivation(b mvc.BeforeActivation) {
	b.Handle("GET", "/devices/list", "HandleList")
	b.Handle("POST", "/devices/approve", "HandleApprove")
	b.Handle("POST", "/devices/reject", "HandleReject")
	b.Handle("POST", "/devices/disable", "HandleDisable")
	b.Handle("POST", "/devices/enable", "HandleEnable")
	b.Handle("POST", "/devices/relay", "HandleRelay")
}

func (c *DevicesController) HandleList() mvc.Result {
	currentPage := c.Ctx.URLParamIntDefault("current", 1)
	pageSize := c.Ctx.URLParamIntDefault("size", 10)
	hostname := c.Ctx.URLParamDefault("hostname", "")
	username := c.Ctx.URLParamDefault("username", "")
	rustdesk_id := c.Ctx.URLParamDefault("rustdesk_id", "")
	query := func() *xorm.Session {
		q := c.Db.Table(&model.Device{})
		user := c.GetUser()
		if user == nil {
			return q.Where("1 = 0")
		}
		if !user.IsAdmin {
			type idRow struct {
				RustdeskId string `xorm:"'rustdesk_id'"`
			}
			rows := make([]idRow, 0)
			if err := c.Db.Table(&model.AuthToken{}).Where("user_id = ? and status = 1 and expired > ?", user.Id, time.Now().Format(config.TimeFormat)).Cols("rustdesk_id").Find(&rows); err != nil {
				return q.Where("1 = 0")
			}
			ids := make([]string, 0, len(rows))
			for _, row := range rows {
				if row.RustdeskId != "" {
					ids = append(ids, row.RustdeskId)
				}
			}
			if len(ids) == 0 {
				return q.Where("1 = 0")
			}
			q = q.In("rustdesk_id", ids)
		}

		if hostname != "" {
			q.Where("hostname LIKE ?", "%"+hostname+"%")
		}
		if username != "" {
			q.Where("username LIKE ?", "%"+username+"%")
		}
		if rustdesk_id != "" {
			q.Where("rustdesk_id LIKE ?", "%"+rustdesk_id+"%")
		}
		q.Asc("username")
		return q
	}

	pagination := db.NewPagination(currentPage, pageSize)
	deviceList := make([]model.Device, 0)

	err := pagination.Paginate(query, &model.Device{}, &deviceList)
	if err != nil {
		return c.dbError(err)
	}

	loginUsernames, err := findDeviceLoginUsernames(c.Db, deviceList, c.GetUser(), time.Now())
	if err != nil {
		return c.dbError(err)
	}

	list := make([]iris.Map, 0)
	for _, a := range deviceList {
		list = append(list, iris.Map{
			"id":                a.Id,
			"user_id":           a.UserId,
			"rustdesk_id":       a.RustdeskId,
			"hostname":          a.Hostname,
			"username":          a.Username,
			"rustdesk_username": loginUsernames[a.RustdeskId].Username,
			"rustdesk_nickname": loginUsernames[a.RustdeskId].Name,
			"uuid":              a.Uuid,
			"fingerprint":       a.Fingerprint,
			"version":           a.Version,
			"client_version":    a.ClientVersion,
			"os":                a.Os,
			"memory":            a.Memory,
			"disabled":          a.Disabled,
			"disabled_reason":   a.DisabledReason,
			"approval_status":   normalizeDeviceApprovalStatus(a.ApprovalStatus),
			"allow_relay":       a.AllowRelay,
			"authorized_until":  formatDeviceTime(a.AuthorizedUntil),
			"last_seen_at":      formatDeviceTime(a.LastSeenAt),
			"last_source_ip":    a.LastSourceIP,
			"is_online":         a.IsOnline,
			"conns":             a.Conns,
			"created_at":        a.CreatedAt.Format(config.TimeFormat),
		})
	}
	return c.Success(iris.Map{
		"total":   pagination.TotalCount,
		"records": list,
		"current": currentPage,
		"size":    pageSize,
	}, "ok")
}

type deviceLoginUser struct {
	RustdeskID string `xorm:"rustdesk_id"`
	Username   string `xorm:"username"`
	Name       string `xorm:"name"`
}

// findDeviceLoginUsernames 批量读取设备最近有效的客户端登录账号及昵称，不混用系统登录名。
func findDeviceLoginUsernames(engine *xorm.Engine, devices []model.Device, actor *model.User, now time.Time) (map[string]deviceLoginUser, error) {
	usernames := make(map[string]deviceLoginUser)
	if len(devices) == 0 || actor == nil {
		return usernames, nil
	}
	ids := make([]string, 0, len(devices))
	for _, device := range devices {
		ids = append(ids, device.RustdeskId)
	}
	rows := make([]deviceLoginUser, 0)
	location := engine.DatabaseTZ
	if location == nil {
		location = time.UTC
	}
	q := engine.Table(&model.AuthToken{}).
		Join("INNER", &model.User{}, "auth_token.user_id = user.id").
		In("auth_token.rustdesk_id", ids).
		Where("auth_token.status = 1 AND auth_token.is_admin = 0 AND auth_token.expired > ?", now.In(location).Format(config.TimeFormat)).
		Select("auth_token.rustdesk_id, user.username, user.name").Desc("auth_token.id")
	if !actor.IsAdmin {
		q.And("auth_token.user_id = ?", actor.Id)
	}
	if err := q.Find(&rows); err != nil {
		return nil, err
	}
	for _, row := range rows {
		if _, exists := usernames[row.RustdeskID]; !exists {
			usernames[row.RustdeskID] = row
		}
	}
	return usernames, nil
}

type deviceAdmissionForm struct {
	Id         int    `json:"id"`
	RustdeskId string `json:"rustdesk_id"`
	Reason     string `json:"reason"`
	AllowRelay bool   `json:"allow_relay"`
}

func (c *DevicesController) HandleApprove() mvc.Result {
	form, result, ok := c.readDeviceAdmissionForm()
	if !ok {
		return result
	}
	device, result, ok := c.requireDevice(form)
	if !ok {
		return result
	}
	beforeAudit := sanitizeDeviceForAudit(&device)
	update := model.Device{
		ApprovalStatus: v2service.DeviceApprovalApproved,
		Disabled:       false,
		DisabledReason: "",
		AllowRelay:     true,
	}
	if _, err := c.Db.Where("id = ?", device.Id).Cols("approval_status", "disabled", "disabled_reason", "allow_relay").Update(&update); err != nil {
		c.recordDeviceOperationAudit("admin_device_approve", strconv.Itoa(device.Id), beforeAudit, sanitizeDeviceAdmissionFormForAudit(form), "failure", err.Error())
		return c.dbError(err)
	}
	updated := c.getDeviceForAudit(device.Id)
	c.recordDeviceOperationAudit("admin_device_approve", strconv.Itoa(device.Id), beforeAudit, sanitizeDeviceForAudit(&updated), "success", "")
	return c.Success(nil, "DeviceApproved")
}

func (c *DevicesController) HandleReject() mvc.Result {
	form, result, ok := c.readDeviceAdmissionForm()
	if !ok {
		return result
	}
	device, result, ok := c.requireDevice(form)
	if !ok {
		return result
	}
	beforeAudit := sanitizeDeviceForAudit(&device)
	update := model.Device{
		ApprovalStatus: v2service.DeviceApprovalRejected,
		Disabled:       false,
		DisabledReason: form.Reason,
	}
	if _, err := c.Db.Where("id = ?", device.Id).Cols("approval_status", "disabled", "disabled_reason").Update(&update); err != nil {
		c.recordDeviceOperationAudit("admin_device_reject", strconv.Itoa(device.Id), beforeAudit, sanitizeDeviceAdmissionFormForAudit(form), "failure", err.Error())
		return c.dbError(err)
	}
	updated := c.getDeviceForAudit(device.Id)
	c.recordDeviceOperationAudit("admin_device_reject", strconv.Itoa(device.Id), beforeAudit, sanitizeDeviceForAudit(&updated), "success", "")
	return c.Success(nil, "DeviceRejected")
}

func (c *DevicesController) HandleDisable() mvc.Result {
	form, result, ok := c.readDeviceAdmissionForm()
	if !ok {
		return result
	}
	device, result, ok := c.requireDevice(form)
	if !ok {
		return result
	}
	beforeAudit := sanitizeDeviceForAudit(&device)
	update := model.Device{
		ApprovalStatus: v2service.DeviceApprovalDisabled,
		Disabled:       true,
		DisabledReason: form.Reason,
	}
	if _, err := c.Db.Where("id = ?", device.Id).Cols("approval_status", "disabled", "disabled_reason").Update(&update); err != nil {
		c.recordDeviceOperationAudit("admin_device_disable", strconv.Itoa(device.Id), beforeAudit, sanitizeDeviceAdmissionFormForAudit(form), "failure", err.Error())
		return c.dbError(err)
	}
	updated := c.getDeviceForAudit(device.Id)
	c.recordDeviceOperationAudit("admin_device_disable", strconv.Itoa(device.Id), beforeAudit, sanitizeDeviceForAudit(&updated), "success", "")
	return c.Success(nil, "DeviceDisabled")
}

func (c *DevicesController) HandleEnable() mvc.Result {
	form, result, ok := c.readDeviceAdmissionForm()
	if !ok {
		return result
	}
	device, result, ok := c.requireDevice(form)
	if !ok {
		return result
	}
	beforeAudit := sanitizeDeviceForAudit(&device)
	update := model.Device{
		ApprovalStatus: v2service.DeviceApprovalApproved,
		Disabled:       false,
		DisabledReason: "",
	}
	if _, err := c.Db.Where("id = ?", device.Id).Cols("approval_status", "disabled", "disabled_reason").Update(&update); err != nil {
		c.recordDeviceOperationAudit("admin_device_enable", strconv.Itoa(device.Id), beforeAudit, sanitizeDeviceAdmissionFormForAudit(form), "failure", err.Error())
		return c.dbError(err)
	}
	updated := c.getDeviceForAudit(device.Id)
	c.recordDeviceOperationAudit("admin_device_enable", strconv.Itoa(device.Id), beforeAudit, sanitizeDeviceForAudit(&updated), "success", "")
	return c.Success(nil, "DeviceEnabled")
}

func (c *DevicesController) HandleRelay() mvc.Result {
	form, result, ok := c.readDeviceAdmissionForm()
	if !ok {
		return result
	}
	device, result, ok := c.requireDevice(form)
	if !ok {
		return result
	}
	beforeAudit := sanitizeDeviceForAudit(&device)
	if _, err := c.Db.Where("id = ?", device.Id).Cols("allow_relay").Update(&model.Device{AllowRelay: form.AllowRelay}); err != nil {
		c.recordDeviceOperationAudit("admin_device_relay_update", strconv.Itoa(device.Id), beforeAudit, sanitizeDeviceAdmissionFormForAudit(form), "failure", err.Error())
		return c.dbError(err)
	}
	updated := c.getDeviceForAudit(device.Id)
	c.recordDeviceOperationAudit("admin_device_relay_update", strconv.Itoa(device.Id), beforeAudit, sanitizeDeviceForAudit(&updated), "success", "")
	return c.Success(nil, "DeviceRelayUpdated")
}

func (c *DevicesController) readDeviceAdmissionForm() (deviceAdmissionForm, mvc.Result, bool) {
	user := c.GetUser()
	if user == nil || !user.IsAdmin {
		return deviceAdmissionForm{}, c.Error(nil, errcode.New(errcode.ERR1007.Code, errcode.ERR1007.Message).Error()), false
	}
	var form deviceAdmissionForm
	if err := c.Ctx.ReadJSON(&form); err != nil {
		return form, c.dbError(err), false
	}
	return form, nil, true
}

func (c *DevicesController) requireDevice(form deviceAdmissionForm) (model.Device, mvc.Result, bool) {
	var device model.Device
	q := c.Db.NewSession()
	defer q.Close()
	if form.Id > 0 {
		q = q.Where("id = ?", form.Id)
	} else if form.RustdeskId != "" {
		q = q.Where("rustdesk_id = ?", form.RustdeskId)
	} else {
		return device, c.Error(nil, errcode.New(errcode.ERR2302.Code, errcode.ERR2302.Message).Error()), false
	}
	has, err := q.Get(&device)
	if err != nil {
		return device, c.dbError(err), false
	}
	if !has {
		return device, c.Error(nil, errcode.New(errcode.ERR2304.Code, errcode.ERR2304.Message).Error()), false
	}
	return device, nil, true
}

func normalizeDeviceApprovalStatus(status string) string {
	if status == "" {
		return v2service.DeviceApprovalPending
	}
	return status
}

func formatDeviceTime(value time.Time) string {
	if value.IsZero() {
		return ""
	}
	return value.Format(config.TimeFormat)
}

func (c *DevicesController) recordDeviceOperationAudit(action string, resourceID string, beforeData interface{}, afterData interface{}, result string, errorMessage string) {
	actor := c.GetUser()
	cmd := core.OperationAuditCreateCommand{
		Action:       action,
		ResourceType: "rustdesk_device",
		ResourceID:   resourceID,
		BeforeData:   auditJSON(beforeData),
		AfterData:    auditJSON(afterData),
		IP:           c.Ctx.RemoteAddr(),
		UserAgent:    c.Ctx.GetHeader("User-Agent"),
		Result:       result,
		ErrorMessage: errorMessage,
	}
	if actor != nil {
		cmd.ActorUserID = actor.Id
		cmd.ActorUsername = actor.Username
	}
	_ = c.auditService().CreateOperationAudit(cmd)
}

func (c *DevicesController) getDeviceForAudit(id int) model.Device {
	var device model.Device
	_, _ = c.Db.Where("id = ?", id).Get(&device)
	return device
}

func sanitizeDeviceForAudit(device *model.Device) iris.Map {
	if device == nil {
		return nil
	}
	return iris.Map{
		"id":               device.Id,
		"user_id":          device.UserId,
		"rustdesk_id":      device.RustdeskId,
		"uuid":             device.Uuid,
		"fingerprint":      device.Fingerprint,
		"hostname":         device.Hostname,
		"username":         device.Username,
		"approval_status":  normalizeDeviceApprovalStatus(device.ApprovalStatus),
		"allow_relay":      device.AllowRelay,
		"disabled":         device.Disabled,
		"disabled_reason":  device.DisabledReason,
		"authorized_until": formatDeviceTime(device.AuthorizedUntil),
		"last_seen_at":     formatDeviceTime(device.LastSeenAt),
		"last_source_ip":   device.LastSourceIP,
		"client_version":   device.ClientVersion,
	}
}

func sanitizeDeviceAdmissionFormForAudit(form deviceAdmissionForm) iris.Map {
	return iris.Map{
		"id":          form.Id,
		"rustdesk_id": form.RustdeskId,
		"reason":      form.Reason,
		"allow_relay": form.AllowRelay,
	}
}
