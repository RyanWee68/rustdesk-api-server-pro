use anyhow::{anyhow, Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::env;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Clone)]
pub struct ControlledAdmissionConfig {
    pub must_login: bool,
    pub api_server: String,
    pub api_internal_secret: String,
    pub api_timeout: Duration,
    pub auth_cache_ttl: Duration,
}

impl ControlledAdmissionConfig {
    pub fn from_env() -> Result<Self> {
        let must_login = matches!(
            env::var("MUST_LOGIN").unwrap_or_default().as_str(),
            "1" | "true" | "TRUE"
        );
        let api_server = env::var("API_SERVER").unwrap_or_default();
        let api_internal_secret = env::var("API_INTERNAL_SECRET").unwrap_or_default();
        let api_timeout = read_seconds("API_TIMEOUT_SECONDS", 3, 1, 30)?;
        let auth_cache_ttl = read_seconds("AUTH_CACHE_SECONDS", 60, 0, 120)?;

        if must_login && api_server.trim().is_empty() {
            return Err(anyhow!("ERR-239B API_SERVER is required when MUST_LOGIN=1"));
        }
        if must_login && api_internal_secret.trim().is_empty() {
            return Err(anyhow!(
                "ERR-239B API_INTERNAL_SECRET is required when MUST_LOGIN=1"
            ));
        }

        Ok(Self {
            must_login,
            api_server: api_server.trim_end_matches('/').to_string(),
            api_internal_secret,
            api_timeout,
            auth_cache_ttl,
        })
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct RegisterRequest {
    pub rustdesk_id: String,
    pub id: String,
    pub uuid: String,
    pub fingerprint: String,
    pub hostname: String,
    pub username: String,
    pub os: String,
    pub client_version: String,
    pub source_ip: String,
}

#[derive(Clone, Serialize)]
pub struct AuthRequest {
    pub rustdesk_id: String,
    pub id: String,
    pub uuid: String,
    pub fingerprint: String,
    pub access_token: String,
    pub source_ip: String,
    pub client_version: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct HeartbeatRequest {
    pub rustdesk_id: String,
    pub id: String,
    pub uuid: String,
    pub source_ip: String,
    pub client_version: String,
    pub conn_count: i32,
}

#[derive(Clone, Serialize)]
pub struct RelayCheckRequest {
    pub rustdesk_id: String,
    pub id: String,
    pub uuid: String,
    pub access_token: String,
    pub source_ip: String,
}

/// 控制端 token 与被控端 ID 必须分别传递，不能使用中继会话 UUID 作为设备 UUID。
#[derive(Clone, Serialize)]
pub struct ConnectionCheckRequest {
    pub target_id: String,
    pub access_token: String,
    pub source_ip: String,
    pub relay: bool,
}

/// hbbs 用真实连接地址为一次中继会话签发双端准入。
#[derive(Clone, Serialize)]
pub struct RelayGrantIssueRequest {
    pub target_id: String,
    pub access_token: String,
    pub session_uuid: String,
    pub source_ip: String,
    pub target_ip: String,
}

/// hbbr 用实际连接地址核销一次会话的一端。
#[derive(Clone, Serialize)]
pub struct RelayGrantConsumeRequest {
    pub session_uuid: String,
    pub peer_ip: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct AdmissionPolicy {
    pub allow_relay: bool,
    pub expire_at: i64,
    pub cache_ttl: i64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct AdmissionResponse {
    pub allow: bool,
    pub user_id: Option<i64>,
    pub device_id: Option<String>,
    pub source_device_id: Option<String>,
    pub code: Option<String>,
    pub message: Option<String>,
    pub policy: Option<AdmissionPolicy>,
}

impl AdmissionResponse {
    pub fn deny_internal(message: impl Into<String>) -> Self {
        Self {
            allow: false,
            user_id: None,
            device_id: None,
            source_device_id: None,
            code: Some("ERR-239B".to_string()),
            message: Some(format!("ERR-239B {}", message.into())),
            policy: None,
        }
    }

    pub fn cache_ttl(&self, fallback: Duration) -> Duration {
        let ttl = self
            .policy
            .as_ref()
            .map(|policy| policy.cache_ttl)
            .unwrap_or_else(|| fallback.as_secs() as i64);
        if ttl <= 0 {
            Duration::from_secs(0)
        } else {
            Duration::from_secs(ttl.min(120) as u64)
        }
    }
}

pub struct ControlledAdmissionClient {
    config: ControlledAdmissionConfig,
    client: Client,
}

impl ControlledAdmissionClient {
    pub fn new(config: ControlledAdmissionConfig) -> Result<Self> {
        let client = Client::builder()
            .timeout(config.api_timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .context("ERR-239B failed to build admission HTTP client")?;
        Ok(Self {
            config,
            client,
        })
    }

    pub async fn register_device(&self, req: &RegisterRequest) -> AdmissionResponse {
        self.post_no_cache("/internal/rustdesk/device/register", req).await
    }

    pub async fn authorize(&self, req: &AuthRequest) -> AdmissionResponse {
        self.post_no_cache("/internal/rustdesk/auth", req)
            .await
    }

    pub async fn heartbeat(&self, req: &HeartbeatRequest) -> AdmissionResponse {
        self.post_no_cache("/internal/rustdesk/device/heartbeat", req)
            .await
    }

    pub async fn check_relay(&self, req: &RelayCheckRequest) -> AdmissionResponse {
        self.post_no_cache("/internal/rustdesk/relay/check", req)
            .await
    }

    /// 新连接必须在线校验，不使用可能属于旧 token 或已撤销授权的缓存。
    pub async fn check_connection(&self, req: &ConnectionCheckRequest) -> AdmissionResponse {
        let response = self.post_no_cache("/internal/rustdesk/connection/check", req).await;
        if response.allow && (
            response.device_id.as_deref() != Some(req.target_id.trim()) ||
            response.source_device_id.as_deref().unwrap_or("").is_empty() ||
            response.user_id.unwrap_or(0) <= 0 ||
            response.policy.as_ref().map(|p| req.relay && !p.allow_relay).unwrap_or(true)
        ) {
            return AdmissionResponse::deny_internal("连接准入响应身份或策略不完整");
        }
        response
    }

    /// hbbs 校验 token、目标和双方 IP 后登记一次短时中继会话。
    pub async fn issue_relay_grant(&self, req: &RelayGrantIssueRequest) -> AdmissionResponse {
        let response = self.post_no_cache("/internal/rustdesk/relay/grant/issue", req).await;
        if response.allow && !valid_relay_response(&response, Some(req.target_id.trim())) {
            return AdmissionResponse::deny_internal("中继签发响应身份或策略不完整");
        }
        response
    }

    /// hbbr 每接纳一个中继端点均在线核销，不能仅靠会话 UUID 配对。
    pub async fn consume_relay_grant(&self, req: &RelayGrantConsumeRequest) -> AdmissionResponse {
        let response = self.post_no_cache("/internal/rustdesk/relay/grant/consume", req).await;
        if response.allow && !valid_relay_response(&response, None) {
            return AdmissionResponse::deny_internal("中继核销响应身份或策略不完整");
        }
        response
    }

    async fn post_no_cache<T: Serialize + ?Sized>(
        &self,
        path: &str,
        body: &T,
    ) -> AdmissionResponse {
        if !self.config.must_login {
            return AdmissionResponse::deny_internal("MUST_LOGIN is disabled");
        }
        let url = format!("{}{}", self.config.api_server, path);
        let result = self
            .client
            .post(url)
            .header("X-Internal-Secret", &self.config.api_internal_secret)
            .json(body)
            .send()
            .await;

        let http_response = match result {
            Ok(response) => response,
            Err(_) => {
                return AdmissionResponse::deny_internal("准入 API 请求失败或超时");
            }
        };

        if !http_response.status().is_success() {
            let status = http_response.status();
            return AdmissionResponse::deny_internal(format!("准入 API HTTP 状态异常：{}", status));
        }

        let response = http_response
            .json::<AdmissionResponse>()
            .await
            .unwrap_or_else(|_| AdmissionResponse::deny_internal("准入 API 响应解析失败"));
        if response.allow {
            let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
            match response.policy.as_ref() {
                Some(policy) if policy.expire_at >= 0 && (policy.expire_at == 0 || policy.expire_at > now) => {}
                _ => return AdmissionResponse::deny_internal("准入响应缺少策略或授权已到期"),
            }
        }
        response
    }
}

/// valid_relay_response 校验内部 API 返回的双端中继身份和有效策略。
fn valid_relay_response(response: &AdmissionResponse, expected_target: Option<&str>) -> bool {
    response.device_id.as_deref().map(|id| !id.is_empty() && expected_target.map_or(true, |expected| id == expected)).unwrap_or(false)
        && response.source_device_id.as_deref().map(|id| !id.is_empty()).unwrap_or(false)
        && response.user_id.unwrap_or(0) > 0
        && response.policy.as_ref().map(|policy| policy.allow_relay).unwrap_or(false)
}

pub fn admission_log_summary(resp: &AdmissionResponse) -> String {
    if resp.allow {
        format!(
            "allow user_id={:?} device_id={:?} relay={}",
            resp.user_id,
            resp.device_id,
            resp.policy
                .as_ref()
                .map(|policy| policy.allow_relay)
                .unwrap_or(false)
        )
    } else {
        format!(
            "deny code={} message={}",
            resp.code.as_deref().unwrap_or(""),
            resp.message.as_deref().unwrap_or("")
        )
    }
}

fn read_seconds(name: &str, default_value: u64, min_value: u64, max_value: u64) -> Result<Duration> {
    let raw = env::var(name).unwrap_or_else(|_| default_value.to_string());
    let parsed = raw
        .parse::<u64>()
        .with_context(|| format!("ERR-239B {} must be an integer", name))?;
    if parsed < min_value || parsed > max_value {
        return Err(anyhow!(
            "ERR-239B {} must be between {} and {}",
            name,
            min_value,
            max_value
        ));
    }
    Ok(Duration::from_secs(parsed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    const ALLOW: &str = r#"{"allow":true,"user_id":1,"device_id":"target","source_device_id":"source","policy":{"allow_relay":true,"expire_at":0,"cache_ttl":60}}"#;

    /// 提供有界的本机 HTTP 应答，捕获实际请求以验证字段映射。
    fn server(responses: Vec<(u16, &'static str)>) -> (String, thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let handle = thread::spawn(move || {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            let mut requests = Vec::new();
            for (status, body) in responses {
                let mut stream = loop {
                    match listener.accept() {
                        Ok((stream, _)) => break stream,
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            assert!(std::time::Instant::now() < deadline, "ERR-239B 等待测试请求超时");
                            thread::sleep(Duration::from_millis(5));
                        }
                        Err(error) => panic!("ERR-239B 接收测试请求失败：{}", error),
                    }
                };
                stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                let mut bytes = Vec::new();
                let mut buf = [0; 4096];
                loop {
                    let count = stream.read(&mut buf).unwrap();
                    assert!(count > 0, "ERR-239B 请求提前结束");
                    bytes.extend_from_slice(&buf[..count]);
                    let text = String::from_utf8_lossy(&bytes);
                    if let Some(end) = text.find("\r\n\r\n") {
                        let length = text[..end].lines().find_map(|line| {
                            let (key, value) = line.split_once(':')?;
                            if key.eq_ignore_ascii_case("content-length") { value.trim().parse::<usize>().ok() } else { None }
                        }).unwrap_or(0);
                        if bytes.len() >= end + 4 + length { break; }
                    }
                }
                requests.push(String::from_utf8(bytes).unwrap());
                write!(stream, "HTTP/1.1 {} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", status, body.len(), body).unwrap();
            }
            requests
        });
        (url, handle)
    }

    /// 创建独立客户端，不修改进程级环境变量。
    fn client(url: String) -> ControlledAdmissionClient {
        ControlledAdmissionClient::new(ControlledAdmissionConfig {
            must_login: true,
            api_server: url,
            api_internal_secret: "test-internal-secret-0123456789abcdef".into(),
            api_timeout: Duration::from_secs(1),
            auth_cache_ttl: Duration::from_secs(60),
        }).unwrap()
    }

    /// 构造控制端与被控端分离的连接请求。
    fn request() -> ConnectionCheckRequest {
        ConnectionCheckRequest { target_id: "target".into(), access_token: "client-token".into(), source_ip: "192.0.2.1".into(), relay: true }
    }

    /// 验证每次连接都访问 API，撤销结果不能被前一次允许缓存覆盖。
    #[tokio::test(flavor = "current_thread")]
    async fn connection_rechecks_api_and_maps_fields() {
        let (url, handle) = server(vec![(200, ALLOW), (200, r#"{"allow":false,"code":"ERR-2303"}"#)]);
        let client = client(url);
        assert!(client.check_connection(&request()).await.allow);
        assert!(!client.check_connection(&request()).await.allow);
        let requests = handle.join().unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests[0].starts_with("POST /internal/rustdesk/connection/check "));
        assert!(requests[0].contains("\"target_id\":\"target\""));
        assert!(requests[0].to_lowercase().contains("x-internal-secret:"));
    }

    /// 非成功 HTTP 状态即使包含 allow=true 也必须拒绝。
    #[tokio::test(flavor = "current_thread")]
    async fn http_errors_never_allow() {
        for status in [302, 401, 500] {
            let (url, handle) = server(vec![(status, ALLOW)]);
            assert!(!client(url).check_connection(&request()).await.allow);
            handle.join().unwrap();
        }
    }

    /// 不完整、过期或身份不匹配的响应不得作为连接凭证。
    #[tokio::test(flavor = "current_thread")]
    async fn invalid_responses_never_allow() {
        for body in [
            "invalid-json",
            r#"{"allow":true}"#,
            r#"{"allow":true,"user_id":1,"device_id":"other","source_device_id":"source","policy":{"allow_relay":true,"expire_at":0,"cache_ttl":60}}"#,
            r#"{"allow":true,"user_id":1,"device_id":"target","policy":{"allow_relay":true,"expire_at":0,"cache_ttl":60}}"#,
            r#"{"allow":true,"user_id":1,"device_id":"target","source_device_id":"source","policy":{"allow_relay":false,"expire_at":0,"cache_ttl":60}}"#,
            r#"{"allow":true,"user_id":1,"device_id":"target","source_device_id":"source","policy":{"allow_relay":true,"expire_at":1,"cache_ttl":60}}"#,
        ] {
            let (url, handle) = server(vec![(200, body)]);
            assert!(!client(url).check_connection(&request()).await.allow);
            handle.join().unwrap();
        }
    }

    /// API 无法连接时拒绝，错误摘要不拼接凭据或完整请求。
    #[tokio::test(flavor = "current_thread")]
    async fn unavailable_api_denies() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let response = client(url).check_connection(&request()).await;
        assert!(!response.allow);
        assert_eq!(response.code.as_deref(), Some("ERR-239B"));
    }

    /// 真实 HTTP 请求应映射到签发和核销端点，服务端拒绝结果保持拒绝。
    #[tokio::test(flavor = "current_thread")]
    async fn relay_grant_issue_and_consume_use_api() {
        let (url, handle) = server(vec![(200, ALLOW), (200, ALLOW), (200, r#"{"allow":false,"code":"ERR-2315"}"#)]);
        let client = client(url);
        let issue = RelayGrantIssueRequest {
            target_id: "target".into(), access_token: "client-token".into(),
            session_uuid: "123e4567-e89b-42d3-a456-426614174000".into(),
            source_ip: "192.0.2.10".into(), target_ip: "198.51.100.20".into(),
        };
        let consume = RelayGrantConsumeRequest { session_uuid: issue.session_uuid.clone(), peer_ip: issue.source_ip.clone() };
        assert!(client.issue_relay_grant(&issue).await.allow);
        assert!(client.consume_relay_grant(&consume).await.allow);
        assert!(!client.consume_relay_grant(&consume).await.allow);
        let requests = handle.join().unwrap();
        assert!(requests[0].starts_with("POST /internal/rustdesk/relay/grant/issue "));
        assert!(requests[0].contains("\"target_ip\":\"198.51.100.20\""));
        assert!(requests[1].starts_with("POST /internal/rustdesk/relay/grant/consume "));
        assert!(requests[1].contains("\"peer_ip\":\"192.0.2.10\""));
    }

    /// 中继签发和核销在 API 不可达时都必须拒绝。
    #[tokio::test(flavor = "current_thread")]
    async fn relay_grants_deny_when_api_unavailable() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let client = client(url);
        let issue = RelayGrantIssueRequest {
            target_id: "target".into(), access_token: "client-token".into(),
            session_uuid: "123e4567-e89b-42d3-a456-426614174000".into(),
            source_ip: "192.0.2.10".into(), target_ip: "198.51.100.20".into(),
        };
        let consume = RelayGrantConsumeRequest { session_uuid: issue.session_uuid.clone(), peer_ip: issue.source_ip.clone() };
        assert!(!client.issue_relay_grant(&issue).await.allow);
        assert!(!client.consume_relay_grant(&consume).await.allow);
    }

    /// API 返回的伪造允许响应不能用于签发或核销中继会话。
    #[tokio::test(flavor = "current_thread")]
    async fn relay_grants_reject_invalid_allow_responses() {
        for body in [
            r#"{"allow":true}"#,
            r#"{"allow":true,"user_id":1,"device_id":"target","source_device_id":"source","policy":{"allow_relay":false,"expire_at":0,"cache_ttl":60}}"#,
            r#"{"allow":true,"user_id":1,"device_id":"target","source_device_id":"source","policy":{"allow_relay":true,"expire_at":1,"cache_ttl":60}}"#,
        ] {
            let (url, handle) = server(vec![(200, body), (200, body)]);
            let client = client(url);
            let issue = RelayGrantIssueRequest {
                target_id: "target".into(), access_token: "client-token".into(),
                session_uuid: "123e4567-e89b-42d3-a456-426614174000".into(),
                source_ip: "192.0.2.10".into(), target_ip: "198.51.100.20".into(),
            };
            let consume = RelayGrantConsumeRequest { session_uuid: issue.session_uuid.clone(), peer_ip: issue.source_ip.clone() };
            assert!(!client.issue_relay_grant(&issue).await.allow);
            assert!(!client.consume_relay_grant(&consume).await.allow);
            handle.join().unwrap();
        }
        let wrong_target = r#"{"allow":true,"user_id":1,"device_id":"other","source_device_id":"source","policy":{"allow_relay":true,"expire_at":0,"cache_ttl":60}}"#;
        let (url, handle) = server(vec![(200, wrong_target)]);
        let issue = RelayGrantIssueRequest {
            target_id: "target".into(), access_token: "client-token".into(),
            session_uuid: "123e4567-e89b-42d3-a456-426614174000".into(),
            source_ip: "192.0.2.10".into(), target_ip: "198.51.100.20".into(),
        };
        assert!(!client(url).issue_relay_grant(&issue).await.allow);
        handle.join().unwrap();
    }
}
