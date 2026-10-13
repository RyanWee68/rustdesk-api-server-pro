package core

// RustdeskAccessPolicy 描述 RustDesk 服务端可以缓存和执行的准入策略。
type RustdeskAccessPolicy struct {
	AllowRelay bool  `json:"allow_relay"`
	ExpireAt   int64 `json:"expire_at"`
	CacheTTL   int   `json:"cache_ttl"`
}

// RustdeskAdmissionRequest 是 hbbs 发起设备连接准入校验时提交的请求。
type RustdeskAdmissionRequest struct {
	RustdeskID    string `json:"rustdesk_id"`
	ID            string `json:"id"`
	UUID          string `json:"uuid"`
	Fingerprint   string `json:"fingerprint"`
	AccessToken   string `json:"access_token"`
	SourceIP      string `json:"source_ip"`
	ClientVersion string `json:"client_version"`
}

// RustdeskRegisterRequest 是 hbbs 首次发现设备时提交的注册请求。
type RustdeskRegisterRequest struct {
	RustdeskID    string `json:"rustdesk_id"`
	ID            string `json:"id"`
	UUID          string `json:"uuid"`
	Fingerprint   string `json:"fingerprint"`
	Hostname      string `json:"hostname"`
	Username      string `json:"username"`
	OS            string `json:"os"`
	ClientVersion string `json:"client_version"`
	SourceIP      string `json:"source_ip"`
}

// RustdeskHeartbeatRequest 是 hbbs 上报设备在线状态时提交的请求。
type RustdeskHeartbeatRequest struct {
	RustdeskID    string `json:"rustdesk_id"`
	ID            string `json:"id"`
	UUID          string `json:"uuid"`
	SourceIP      string `json:"source_ip"`
	ClientVersion string `json:"client_version"`
	ConnCount     int    `json:"conn_count"`
}

// RustdeskRelayCheckRequest 是 hbbr 或 hbbs 校验中继授权时提交的请求。
type RustdeskRelayCheckRequest struct {
	RustdeskID  string `json:"rustdesk_id"`
	ID          string `json:"id"`
	UUID        string `json:"uuid"`
	AccessToken string `json:"access_token"`
	SourceIP    string `json:"source_ip"`
}

// RustdeskConnectionRequest 将控制端登录凭据与被控端设备 ID 分开。
type RustdeskConnectionRequest struct {
	TargetID    string `json:"target_id"`
	AccessToken string `json:"access_token"`
	SourceIP    string `json:"source_ip"`
	Relay       bool   `json:"relay"`
}

// RustdeskRelayGrantIssueRequest 由 hbbs 提交已校验连接的会话和双方实际公网 IP。
type RustdeskRelayGrantIssueRequest struct {
	TargetID    string `json:"target_id"`
	AccessToken string `json:"access_token"`
	SessionUUID string `json:"session_uuid"`
	SourceIP    string `json:"source_ip"`
	TargetIP    string `json:"target_ip"`
}

// RustdeskRelayGrantConsumeRequest 由 hbbr 用连接实际来源 IP 核销一端会话。
type RustdeskRelayGrantConsumeRequest struct {
	SessionUUID string `json:"session_uuid"`
	PeerIP      string `json:"peer_ip"`
}

// RustdeskAdmissionResponse 是内部准入接口返回给 RustDesk 服务端的稳定结构。
type RustdeskAdmissionResponse struct {
	Allow          bool                  `json:"allow"`
	UserID         int                   `json:"user_id,omitempty"`
	DeviceID       string                `json:"device_id,omitempty"`
	SourceDeviceID string                `json:"source_device_id,omitempty"`
	Code           string                `json:"code,omitempty"`
	Message        string                `json:"message,omitempty"`
	Policy         *RustdeskAccessPolicy `json:"policy,omitempty"`
}
