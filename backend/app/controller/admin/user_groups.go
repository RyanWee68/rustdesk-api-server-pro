package admin

import (
	"strings"

	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/internal/core"
	"rustdesk-api-server-pro/internal/errcode"
	"rustdesk-api-server-pro/util"

	"github.com/kataras/iris/v12"
	"github.com/kataras/iris/v12/mvc"
)

type UserGroupsController struct {
	basicController
}

func (c *UserGroupsController) BeforeActivation(b mvc.BeforeActivation) {
	b.Handle("GET", "/user-groups/list", "HandleList")
	b.Handle("POST", "/user-groups/save", "HandleSave")
	b.Handle("DELETE", "/user-groups/delete", "HandleDelete")
	b.Handle("GET", "/user-groups/members", "HandleMembers")
	b.Handle("POST", "/user-groups/members", "HandleSaveMembers")
}

func (c *UserGroupsController) HandleList() mvc.Result {
	currentPage := c.Ctx.URLParamIntDefault("current", 1)
	pageSize := c.Ctx.URLParamIntDefault("size", 10)
	name := strings.TrimSpace(c.Ctx.URLParamDefault("name", ""))

	query := c.Db.Table(&model.UserGroup{})
	if name != "" {
		query = query.Where("name LIKE ?", "%"+name+"%")
	}
	total, err := query.Count(&model.UserGroup{})
	if err != nil {
		return c.dbError(err)
	}

	var groups []model.UserGroup
	listQuery := c.Db.Table(&model.UserGroup{}).Desc("id")
	if name != "" {
		listQuery = listQuery.Where("name LIKE ?", "%"+name+"%")
	}
	if err = listQuery.Limit(pageSize, (currentPage-1)*pageSize).Find(&groups); err != nil {
		return c.dbError(err)
	}

	records := make([]iris.Map, 0, len(groups))
	for _, group := range groups {
		memberCount, _ := c.Db.Where("group_guid = ?", group.Guid).Count(new(model.UserGroupMember))
		records = append(records, iris.Map{
			"id":           group.Id,
			"guid":         group.Guid,
			"name":         group.Name,
			"owner_id":     group.OwnerId,
			"member_count": memberCount,
			"created_at":   group.CreatedAt.Format(config.TimeFormat),
			"updated_at":   group.UpdatedAt.Format(config.TimeFormat),
		})
	}
	return c.Success(iris.Map{"total": total, "records": records, "current": currentPage, "size": pageSize}, "ok")
}

func (c *UserGroupsController) HandleSave() mvc.Result {
	type saveParams struct {
		Guid string `json:"guid"`
		Name string `json:"name"`
	}
	var params saveParams
	if err := c.Ctx.ReadJSON(&params); err != nil {
		return c.dbError(err)
	}
	params.Name = strings.TrimSpace(params.Name)
	if params.Name == "" {
		return c.Error(nil, errcode.New(errcode.ERR6004.Code, errcode.ERR6004.Message).Error())
	}

	if strings.TrimSpace(params.Guid) == "" {
		admin := c.GetUser()
		group := model.UserGroup{Guid: util.GetUUID(), Name: params.Name}
		if admin != nil {
			group.OwnerId = admin.Id
		}
		if _, err := c.Db.Insert(&group); err != nil {
			return c.dbError(err)
		}
		c.recordUserGroupOperationAudit("admin_user_group_add", group.Guid, nil, sanitizeUserGroupForAudit(&group), "success", "")
		return c.Success(iris.Map{"guid": group.Guid, "name": group.Name}, "UserGroupSaveSuccess")
	}

	var before model.UserGroup
	has, err := c.Db.Where("guid = ?", params.Guid).Get(&before)
	if err != nil {
		return c.dbError(err)
	}
	if !has {
		return c.Error(nil, errcode.New(errcode.ERR6002.Code, errcode.ERR6002.Message).Error())
	}
	if _, err = c.Db.Where("guid = ?", params.Guid).Cols("name").Update(&model.UserGroup{Name: params.Name}); err != nil {
		return c.dbError(err)
	}
	var after model.UserGroup
	_, _ = c.Db.Where("guid = ?", params.Guid).Get(&after)
	c.recordUserGroupOperationAudit("admin_user_group_edit", params.Guid, sanitizeUserGroupForAudit(&before), sanitizeUserGroupForAudit(&after), "success", "")
	return c.Success(nil, "UserGroupSaveSuccess")
}

func (c *UserGroupsController) HandleDelete() mvc.Result {
	guid := strings.TrimSpace(c.Ctx.URLParamDefault("guid", ""))
	if guid == "" {
		return c.Error(nil, errcode.New(errcode.ERR6002.Code, errcode.ERR6002.Message).Error())
	}

	var before model.UserGroup
	_, _ = c.Db.Where("guid = ?", guid).Get(&before)

	session := c.Db.NewSession()
	defer session.Close()
	if err := session.Begin(); err != nil {
		return c.dbError(err)
	}
	if _, err := session.Where("group_guid = ?", guid).Delete(&model.UserGroupMember{}); err != nil {
		_ = session.Rollback()
		return c.dbError(err)
	}
	if _, err := session.Where("guid = ?", guid).Delete(&model.UserGroup{}); err != nil {
		_ = session.Rollback()
		return c.dbError(err)
	}
	if err := session.Commit(); err != nil {
		return c.dbError(err)
	}
	c.recordUserGroupOperationAudit("admin_user_group_delete", guid, sanitizeUserGroupForAudit(&before), nil, "success", "")
	return c.Success(nil, "UserGroupDeleteSuccess")
}

func (c *UserGroupsController) HandleMembers() mvc.Result {
	guid := strings.TrimSpace(c.Ctx.URLParamDefault("guid", ""))
	if guid == "" {
		return c.Error(nil, errcode.New(errcode.ERR6002.Code, errcode.ERR6002.Message).Error())
	}
	var rows []struct {
		model.User            `xorm:"extends"`
		model.UserGroupMember `xorm:"extends"`
	}
	err := c.Db.Table(&model.UserGroupMember{}).
		Join("INNER", &model.User{}, "user_group_member.user_id = user.id").
		Where("user_group_member.group_guid = ?", guid).
		Asc("user.username").
		Find(&rows)
	if err != nil {
		return c.dbError(err)
	}
	records := make([]iris.Map, 0, len(rows))
	for _, row := range rows {
		records = append(records, iris.Map{
			"id":       row.User.Id,
			"username": row.User.Username,
			"name":     row.User.Name,
			"email":    row.User.Email,
			"status":   row.User.Status,
			"is_admin": row.User.IsAdmin,
		})
	}
	return c.Success(iris.Map{"records": records}, "ok")
}

func (c *UserGroupsController) HandleSaveMembers() mvc.Result {
	type membersParams struct {
		Guid    string `json:"guid"`
		UserIds []int  `json:"userIds"`
	}
	var params membersParams
	if err := c.Ctx.ReadJSON(&params); err != nil {
		return c.dbError(err)
	}
	params.Guid = strings.TrimSpace(params.Guid)
	if params.Guid == "" {
		return c.Error(nil, errcode.New(errcode.ERR6002.Code, errcode.ERR6002.Message).Error())
	}

	session := c.Db.NewSession()
	defer session.Close()
	if err := session.Begin(); err != nil {
		return c.dbError(err)
	}
	if _, err := session.Where("group_guid = ?", params.Guid).Delete(&model.UserGroupMember{}); err != nil {
		_ = session.Rollback()
		return c.dbError(err)
	}
	seen := map[int]struct{}{}
	for _, userID := range params.UserIds {
		if userID <= 0 {
			continue
		}
		if _, ok := seen[userID]; ok {
			continue
		}
		seen[userID] = struct{}{}
		if _, err := session.Insert(&model.UserGroupMember{GroupGuid: params.Guid, UserId: userID}); err != nil {
			_ = session.Rollback()
			return c.dbError(err)
		}
	}
	if err := session.Commit(); err != nil {
		return c.dbError(err)
	}
	c.recordUserGroupOperationAudit("admin_user_group_members_save", params.Guid, nil, iris.Map{"user_ids": params.UserIds}, "success", "")
	return c.Success(nil, "UserGroupMembersSaveSuccess")
}

func (c *UserGroupsController) recordUserGroupOperationAudit(action string, resourceID string, beforeData interface{}, afterData interface{}, result string, errorMessage string) {
	actor := c.GetUser()
	cmd := core.OperationAuditCreateCommand{
		Action:       action,
		ResourceType: "user_group",
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

func sanitizeUserGroupForAudit(group *model.UserGroup) iris.Map {
	if group == nil || group.Guid == "" {
		return nil
	}
	return iris.Map{
		"id":       group.Id,
		"guid":     group.Guid,
		"name":     group.Name,
		"owner_id": group.OwnerId,
	}
}
