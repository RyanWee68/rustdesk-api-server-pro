package model

// RustdeskRelayGrant 记录 hbbs 批准的短时中继会话，供 hbbr 分别核销双方连接。
type RustdeskRelayGrant struct {
	SessionUUID string `xorm:"'session_uuid' varchar(36) pk"`
	SourceID    string `xorm:"'source_id' varchar(255) notnull"`
	TargetID    string `xorm:"'target_id' varchar(255) notnull"`
	SourceIP    string `xorm:"'source_ip' varchar(45) notnull"`
	TargetIP    string `xorm:"'target_ip' varchar(45) notnull"`
	TokenID     int    `xorm:"'token_id' notnull"`
	SourceUsed  bool   `xorm:"'source_used' notnull default 0"`
	TargetUsed  bool   `xorm:"'target_used' notnull default 0"`
	ExpiresAt   int64  `xorm:"'expires_at' bigint notnull index"`
}
