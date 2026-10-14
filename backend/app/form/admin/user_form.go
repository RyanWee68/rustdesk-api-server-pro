package admin

import "time"

type UserForm struct {
	Id                  int    `json:"id"`
	Username            string `json:"username"`
	Password            string `json:"password"`
	Name                string `json:"name"`
	Email               string `json:"email"`
	LoginVerify         string `json:"login_verify"` // email_check tfa_check access_token
	TwoFactorAuthSecret string `json:"tfa_secret"`   // 2fa key
	TwoFactorAuthCode   string `json:"tfa_code"`     // 2fa code
	Note                string `json:"note"`
	LicensedDevices     int    `json:"licensed_devices"`
	AllowRemoteAccess   *bool  `json:"allow_remote_access"`
	AllowRelay          *bool  `json:"allow_relay"`
	AuthorizedUntil     string `json:"authorized_until"`
	Status              int    `json:"status"`
	IsAdmin             bool   `json:"is_admin"`
}

func (f UserForm) AuthorizedUntilTime() (time.Time, error) {
	if f.AuthorizedUntil == "" {
		return time.Time{}, nil
	}
	return time.ParseInLocation("2006-01-02 15:04:05", f.AuthorizedUntil, time.Local)
}
