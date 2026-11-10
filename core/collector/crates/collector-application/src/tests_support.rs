//! collector-application 测试共享夹具 (C230: 自 lib.rs 内联测试模块拆出)。

use collector_domain::BridgeRequest;
use collector_provider::{HttpClient, HttpRequest, HttpResponse, ProviderError};
use collector_runtime::CancellationToken;
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};

pub(crate) fn request(capabilities: &[&str]) -> BridgeRequest {
    serde_json::from_value(json!({
        "schemaVersion": 1,
        "runId": "12345678-1234-4234-9234-123456789abc",
        "module": "agent-usage",
        "timeouts": {
            "externalRequestSeconds": 10,
            "moduleSeconds": 90
        },
        "context": {"capabilities": capabilities},
        "credentials": {}
    }))
    .expect("fixture request should deserialize")
}

pub(crate) struct FixtureHttp {
    pub(crate) calls: AtomicUsize,
    pub(crate) body: Vec<u8>,
}

impl HttpClient for FixtureHttp {
    fn send(
        &self,
        _request: HttpRequest,
        cancellation: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        cancellation.check().map_err(ProviderError::from_runtime)?;
        self.calls.fetch_add(1, Ordering::AcqRel);
        Ok(HttpResponse {
            status: 200,
            body: self.body.clone(),
        })
    }
}

pub(crate) fn history_test_home(name: &str) -> std::path::PathBuf {
    let home = std::env::temp_dir().join(format!("bruce-t26-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    home
}

pub(crate) fn history_request(
    home: &std::path::Path,
    history_db: &std::path::Path,
) -> BridgeRequest {
    let paths = json!({
        "claude_projects": home.join("claude").to_string_lossy(),
        "kimi_cli_sessions": home.join("kimi-cli").to_string_lossy(),
        "daimon_kimi_sessions": home.join("kimi-work").to_string_lossy(),
        "codex_sessions": home.join("codex").to_string_lossy(),
        "orca_home": home.join("orca").to_string_lossy(),
        "grok_home": home.join("grok").to_string_lossy(),
        "pi_sessions": home.join("pi").to_string_lossy(),
        "opencode_db": home.join("opencode.db").to_string_lossy(),
        "zcode_db": home.join("zcode.db").to_string_lossy(),
        "codebuddy_projects": home.join("codebuddy").to_string_lossy(),
        "dsh_sessions": home.join("dsh").to_string_lossy(),
        "history_db": history_db.to_string_lossy(),
    });
    let mut request = request(&["localSessions"]);
    for (key, value) in [
        ("home", json!(home.to_string_lossy())),
        ("now", json!("2026-07-28T12:00:00+08:00")),
        ("timezone", json!("Asia/Shanghai")),
        ("days", json!(7)),
        ("paths", paths),
    ] {
        request.context.insert(key.to_owned(), value);
    }
    request
}

pub(crate) fn claude_agent(artifact: &serde_json::Value) -> &serde_json::Value {
    artifact["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|agent| agent["id"] == "claude-code")
        .unwrap()
}

pub(crate) fn daily_total(agent: &serde_json::Value) -> u64 {
    agent["daily"]
        .as_array()
        .unwrap()
        .iter()
        .map(|day| day["total"].as_u64().unwrap_or(0))
        .sum()
}

pub(crate) fn empty_http() -> FixtureHttp {
    FixtureHttp {
        calls: AtomicUsize::new(0),
        body: b"{}".to_vec(),
    }
}

pub(crate) fn agent<'a>(artifact: &'a serde_json::Value, id: &str) -> &'a serde_json::Value {
    artifact["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|agent| agent["id"] == id)
        .unwrap()
}
