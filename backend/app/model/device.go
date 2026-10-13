package model

import "time"

type Device struct {
	Id              int       `xorm:"'id' int notnull pk autoincr"`
	UserId          int       `xorm:"'user_id' int index"`
	Cpu             string    `xorm:"'cpu' varchar(255)"`
	Fingerprint     string    `xorm:"'fingerprint' varchar(255)"`
	Hostname        string    `xorm:"'hostname' varchar(255)"`
	RustdeskId      string    `xorm:"'rustdesk_id' varchar(255)"`
	Memory          string    `xorm:"'memory' varchar(50)"`
	Os              string    `xorm:"'os' varchar(255)"`
	Username        string    `xorm:"'username' varchar(255)"`
	Uuid            string    `xorm:"'uuid' varchar(255)"`
	Version         string    `xorm:"'version' varchar(255)"`
	Disabled        bool      `xorm:"'disabled' tinyint"`
	DisabledReason  string    `xorm:"'disabled_reason' varchar(255)"`
	ApprovalStatus  string    `xorm:"'approval_status' varchar(20) index"`
	AllowRelay      bool      `xorm:"'allow_relay' tinyint"`
	AuthorizedUntil time.Time `xorm:"'authorized_until' datetime"`
	LastSeenAt      time.Time `xorm:"'last_seen_at' datetime"`
	LastSourceIP    string    `xorm:"'last_source_ip' varchar(64)"`
	ClientVersion   string    `xorm:"'client_version' varchar(64)"`
	IsOnline        bool      `xorm:"'is_online' tinyint"`
	Conns           int       `xorm:"'conns' int"`
	CreatedAt       time.Time `xorm:"'created_at' datetime created"`
	UpdatedAt       time.Time `xorm:"'updated_at' datetime updated"`
}

func (m *Device) TableName() string {
	return "device"
}
