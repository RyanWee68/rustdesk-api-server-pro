package service

import (
	"fmt"
	"rustdesk-api-server-pro/app/form/api"
	"rustdesk-api-server-pro/app/model"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/db"
	"rustdesk-api-server-pro/internal/errcode"
	"rustdesk-api-server-pro/util"
	"strconv"
	"strings"
	"time"

	"github.com/kataras/iris/v12"
	"github.com/pquerna/otp/totp"
)

type UserService struct {
	config *config.ServerConfig
}

var userService *UserService

func NewUserService() *UserService {
	// 单例模式
	if userService != nil {
		return userService
	}

	config := config.GetServerConfig()
	return &UserService{
		config: config,
	}
}

// 常规登录，使用账号和密码
func (service *UserService) Login(loginForm api.LoginForm) iris.Map {
	var user model.User
	get, err := db.DbEngine.Where("username = ?", loginForm.Username).Get(&user)
	if err != nil {
		return iris.Map{
			"error": errcode.Errorf(errcode.ERRB010.Code, errcode.ERRB010.Message+": "+err.Error()).Error(),
		}
	}

	if !get {
		return iris.Map{
			"error": errcode.New(errcode.ERR1004.Code, errcode.ERR1004.Message).Error(),
		}
	}

	if !util.PasswordVerify(loginForm.Password, user.Password) {
		return iris.Map{
			"error": errcode.New(errcode.ERR1004.Code, errcode.ERR1004.Message).Error(),
		}
	}

	if user.Status <= 0 {
		return iris.Map{
			"error": errcode.New(errcode.ERR1012.Code, errcode.ERR1012.Message).Error(),
		}
	}

	// 如果是email_check，则发送验证邮件
	if user.LoginVerify == model.LOGIN_EMAIL_CHECK {
		if user.Email == "" {
			return iris.Map{
				"error": errcode.New(errcode.ERR1005.Code, errcode.ERR1005.Message).Error(),
			}
		}

		// 发送邮件
		uuid := util.GetUUID()
		s := NewMailService()

		// 查询登录验证的邮件模板
		tpl, err := s.GetMailTemplateByType(model.MAIL_TPL_TYPE_LOGIN_VERIFY)
		if err != nil {
			return iris.Map{
				"error": errcode.Errorf(errcode.ERRB010.Code, errcode.ERRB010.Message+": "+err.Error()).Error(),
			}
		}

		code := util.RandomString(6)
		code = strings.ToUpper(code)

		expired := 10

		// 发送邮件
		err = s.Send(user.Id, tpl.Id, user.Email, uuid, map[string]string{
			"{$username}": user.Name,
			"{$code}":     code,
			"{$expired}":  strconv.Itoa(expired),
		})

		if err != nil {
			return iris.Map{
				"error": errcode.Errorf(errcode.ERR8007.Code, errcode.ERR8007.Message+": "+err.Error()).Error(),
			}
		}

		_, err = db.DbEngine.Insert(&model.VerifyCode{
			UserId:     user.Id,
			Type:       model.VC_TYPE_MAIL,
			Uuid:       uuid,
			Code:       code,
			RustdeskId: loginForm.RustdeskId,
			Expired:    time.Now().Add(time.Duration(expired) * time.Minute),
			Status:     model.VC_STATUS_UNUSED,
		})
		if err != nil {
			return iris.Map{"error": errcode.New(errcode.ERRB010.Code, errcode.ERRB010.Message).Error()}
		}

		return iris.Map{
			"type":     model.LOGIN_EMAIL_CHECK,
			"tfa_type": model.LOGIN_EMAIL_CHECK,
			"secret":   uuid,
		}
	}

	// 2fa 验证
	if user.LoginVerify == model.LOGIN_TFA_CHECK {
		uuid := util.GetUUID()
		_, err = db.DbEngine.Insert(&model.VerifyCode{
			UserId:     user.Id,
			Type:       model.VC_TYPE_2FA,
			Uuid:       uuid,
			RustdeskId: loginForm.RustdeskId,
			Expired:    time.Now().Add(10 * time.Minute),
			Status:     model.VC_STATUS_UNUSED,
		})
		if err != nil {
			return iris.Map{"error": errcode.New(errcode.ERRB010.Code, errcode.ERRB010.Message).Error()}
		}
		return iris.Map{
			"type":     model.LOGIN_EMAIL_CHECK,
			"tfa_type": model.LOGIN_TFA_CHECK,
			"secret":   uuid,
		}
	}

	// 这里可以根据表单里面的type决定是登录还是什么
	// type 取值范围：account mobile sms_code email_code tfa_code
	// account 就是直接登录

	token, err := service.GetLoginToken(loginForm, user.Id, 0)
	if err != nil {
		return iris.Map{"error": err.Error()}
	}
	return iris.Map{
		"access_token": token,
		"type":         model.LOGIN_ACCESS_TOKEN,
		"user": iris.Map{
			"name":         user.Name,
			"display_name": user.Name,
			"email":        user.Email,
			"note":         user.Note,
			"status":       user.Status,
			"is_admin":     false,
		},
	}

}

// GetLoginToken 在同一事务核销挑战、撤销旧会话和保存新令牌；密码登录的挑战 ID 为 0。
func (service *UserService) GetLoginToken(loginForm api.LoginForm, userId, challengeID int) (string, error) {
	signStr := fmt.Sprintf("%s_%s_%d_%s", loginForm.RustdeskId, loginForm.Uuid, userId, time.Now().String())
	token := util.HmacSha256(signStr, service.config.SignKey)
	expired := 90 * 24 * time.Hour // 保持原有 90 天会话期限。

	authToken := &model.AuthToken{
		UserId:     userId,
		RustdeskId: loginForm.RustdeskId,
		Uuid:       loginForm.Uuid,
		DeviceOs:   loginForm.DeviceInfo.OS,
		DeviceType: loginForm.DeviceInfo.Type,
		DeviceName: loginForm.DeviceInfo.Name,
		TokenHash:  util.Sha256Hex(token),
		Expired:    time.Now().Add(expired),
		IsAdmin:    false,
		Status:     1,
	}

	session := db.DbEngine.NewSession()
	defer session.Close()
	if err := session.Begin(); err != nil {
		return "", errcode.New(errcode.ERRB010.Code, errcode.ERRB010.Message)
	}
	defer session.Rollback()
	active, err := session.ID(userId).Where("status > 0").Exist(new(model.User))
	if err != nil {
		return "", errcode.New(errcode.ERRB010.Code, errcode.ERRB010.Message)
	}
	if !active {
		return "", errcode.New(errcode.ERR1012.Code, errcode.ERR1012.Message)
	}
	if challengeID != 0 {
		changed, err := session.ID(challengeID).
			Where("user_id = ? and rustdesk_id = ? and uuid = ? and status = ? and expired > ?", userId, loginForm.RustdeskId, loginForm.Secret, model.VC_STATUS_UNUSED, db.FormatTime(db.DbEngine, time.Now())).
			Cols("status").Update(&model.VerifyCode{Status: model.VC_STATUS_USED})
		if err != nil {
			return "", errcode.New(errcode.ERRB010.Code, errcode.ERRB010.Message)
		}
		if changed != 1 {
			return "", errcode.New(errcode.ERR1006.Code, errcode.ERR1006.Message)
		}
	}
	if _, err := session.Where("user_id = ? and rustdesk_id = ? and status = 1 and is_admin = 0", userId, loginForm.RustdeskId).
		Cols("status").Update(&model.AuthToken{Status: 0}); err != nil {
		return "", errcode.New(errcode.ERRB010.Code, errcode.ERRB010.Message)
	}
	if _, err := session.Insert(authToken); err != nil {
		return "", errcode.New(errcode.ERRB010.Code, errcode.ERRB010.Message)
	}
	if err := session.Commit(); err != nil {
		return "", errcode.New(errcode.ERRB010.Code, errcode.ERRB010.Message)
	}
	return token, nil
}

// 使用邮箱验证码登录
func (service *UserService) LoginVerifyByEmailCode(loginForm api.LoginForm) iris.Map {
	var verifyCode model.VerifyCode
	get, err := db.DbEngine.Where("type = 1 and rustdesk_id = ? and uuid = ? and code = ? and status = 1", loginForm.RustdeskId, loginForm.Secret, loginForm.VerificationCode).Desc("id").Get(&verifyCode)
	if err != nil {
		return iris.Map{
			"error": errcode.Errorf(errcode.ERRB010.Code, errcode.ERRB010.Message+": "+err.Error()).Error(),
		}
	}
	if !get {
		return iris.Map{
			"error": errcode.New(errcode.ERR1006.Code, errcode.ERR1006.Message).Error(),
		}
	}
	if !verifyCode.Expired.After(time.Now()) {
		return iris.Map{
			"error": errcode.New(errcode.ERR1006.Code, errcode.ERR1006.Message).Error(),
		}
	}
	if verifyCode.Code != loginForm.VerificationCode {
		return iris.Map{
			"error": errcode.New(errcode.ERR1006.Code, errcode.ERR1006.Message).Error(),
		}
	}

	var user model.User
	get, err = db.DbEngine.Where("id = ?", verifyCode.UserId).Get(&user)
	if err != nil {
		return iris.Map{
			"error": errcode.Errorf(errcode.ERRB010.Code, errcode.ERRB010.Message+": "+err.Error()).Error(),
		}
	}

	if !get {
		return iris.Map{"error": errcode.New(errcode.ERR1004.Code, errcode.ERR1004.Message).Error()}
	}
	if user.Status <= 0 {
		return iris.Map{"error": errcode.New(errcode.ERR1012.Code, errcode.ERR1012.Message).Error()}
	}
	token, err := service.GetLoginToken(loginForm, verifyCode.UserId, verifyCode.Id)
	if err != nil {
		return iris.Map{"error": err.Error()}
	}

	return iris.Map{
		"access_token": token,
		"type":         model.LOGIN_ACCESS_TOKEN,
		"user": iris.Map{
			"name":         user.Name,
			"display_name": user.Name,
			"email":        user.Email,
			"note":         user.Note,
			"status":       user.Status,
			"is_admin":     false,
		},
	}
}

// 使用2FA验证登录
func (service *UserService) LoginVerifyBy2FACode(loginForm api.LoginForm) iris.Map {

	var verifyCode model.VerifyCode
	get, err := db.DbEngine.Where("type = 3 and rustdesk_id = ? and uuid = ? and status = 1", loginForm.RustdeskId, loginForm.Secret).Desc("id").Get(&verifyCode)
	if err != nil {
		return iris.Map{
			"error": errcode.Errorf(errcode.ERRB010.Code, errcode.ERRB010.Message+": "+err.Error()).Error(),
		}
	}
	if !get {
		return iris.Map{
			"error": errcode.New(errcode.ERR1006.Code, errcode.ERR1006.Message).Error(),
		}
	}
	if !verifyCode.Expired.After(time.Now()) {
		return iris.Map{"error": errcode.New(errcode.ERR1006.Code, errcode.ERR1006.Message).Error()}
	}

	var user model.User
	get, err = db.DbEngine.Where("id = ?", verifyCode.UserId).Get(&user)
	if err != nil {
		return iris.Map{
			"error": errcode.Errorf(errcode.ERRB010.Code, errcode.ERRB010.Message+": "+err.Error()).Error(),
		}
	}

	if !get {
		return iris.Map{
			"error": errcode.New(errcode.ERR1004.Code, errcode.ERR1004.Message).Error(),
		}
	}
	if user.Status <= 0 {
		return iris.Map{"error": errcode.New(errcode.ERR1012.Code, errcode.ERR1012.Message).Error()}
	}

	if !totp.Validate(loginForm.TfaCode, user.TwoFactorAuthSecret) {
		return iris.Map{
			"error": errcode.New(errcode.ERR1006.Code, errcode.ERR1006.Message).Error(),
		}
	}

	token, err := service.GetLoginToken(loginForm, user.Id, verifyCode.Id)
	if err != nil {
		return iris.Map{"error": err.Error()}
	}

	return iris.Map{
		"access_token": token,
		"type":         model.LOGIN_ACCESS_TOKEN,
		"user": iris.Map{
			"name":         user.Name,
			"display_name": user.Name,
			"email":        user.Email,
			"note":         user.Note,
			"status":       user.Status,
			"is_admin":     false,
		},
	}
}
