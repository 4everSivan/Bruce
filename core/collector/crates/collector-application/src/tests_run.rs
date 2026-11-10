//! 运行主流程: 阶段接缝、取消栅栏、能力门控与宿主凭据边界。

use crate::{collect_agent_usage, collect_agent_usage_with_dependencies};
use collector_domain::BridgeRequest;
use collector_provider::{HttpClient, HttpRequest, HttpResponse, ProviderError};
use collector_runtime::CancellationToken;
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::tests_support::*;

/// C171: 依次返回固定响应 (Claude 刷新 → usage)。
struct SequenceHttp {
    responses: std::sync::Mutex<std::collections::VecDeque<HttpResponse>>,
}

impl HttpClient for SequenceHttp {
    fn send(
        &self,
        _request: HttpRequest,
        cancellation: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        cancellation.check().map_err(ProviderError::from_runtime)?;
        Ok(self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected extra request"))
    }
}

fn claude_refresh_then_usage_http() -> SequenceHttp {
    let refresh = json!({
        "token_type": "Bearer",
        "access_token": "sk-ant-oat01-fresh_token",
        "refresh_token": "sk-ant-ort01-new_refresh",
        "expires_in": 28800
    });
    let usage = json!({
        "five_hour": { "utilization": 5.0, "resets_at": null },
        "seven_day": { "utilization": 20.0, "resets_at": null }
    });
    SequenceHttp {
        responses: std::sync::Mutex::new(
            [refresh, usage]
                .into_iter()
                .map(|body| HttpResponse {
                    status: 200,
                    body: serde_json::to_vec(&body).unwrap(),
                })
                .collect(),
        ),
    }
}

fn expired_claude_request(capabilities: &[&str]) -> BridgeRequest {
    let mut request = request(capabilities);
    request.credentials.insert(
        "claudeQuotaAccounts".to_owned(),
        json!({
            "acc": {
                "display_name": "Claude",
                "oauth": {"claudeAiOauth": {
                    "accessToken": "sk-ant-oat01-stale_token",
                    "refreshToken": "sk-ant-ort01-refresh_me",
                    "expiresAt": 1_700_000_000_000_i64
                }}
            }
        }),
    );
    request.credentials.insert(
        "providerMeta".to_owned(),
        json!({"claude": {"enabled": true}}),
    );
    request
}

fn assert_carries_rotated_claude_tokens(updates: &[serde_json::Value]) {
    assert_eq!(
        updates.len(),
        1,
        "rotated tokens dropped with the failed run"
    );
    assert_eq!(updates[0]["accountId"], "acc");
    assert_eq!(
        updates[0]["credentials"]["refresh_token"],
        "sk-ant-ort01-new_refresh"
    );
}

/// C229: 组装完成、发布之前取消 —— 经真实阶段接缝驱动, 生产签名不再携带
/// `#[cfg(test)]` 探针参数。
fn collect_cancelled_before_publish(
    request: &BridgeRequest,
    http: &dyn HttpClient,
) -> Result<super::CollectionOutput, super::CollectionFailure> {
    let context = super::prepare_run(request, http)?;
    let assembled = super::assemble(&context, super::gather(&context))?;
    context.cancellation.cancel();
    super::publish(&context, assembled)
}

/// C229: 采集端不读宿主凭据。凭据适配器参数移除后, 以源码扫描守住边界:
/// 本 crate 生产代码不得引用宿主凭据读取入口 (C131: 只读探测函数仅为测试/兼容面)。
#[test]
fn application_sources_never_reference_host_credential_readers() {
    let sources = [
        ("lib.rs", include_str!("lib.rs")),
        ("account.rs", include_str!("account.rs")),
        ("context.rs", include_str!("context.rs")),
        ("egress.rs", include_str!("egress.rs")),
        ("execution.rs", include_str!("execution.rs")),
        ("paths.rs", include_str!("paths.rs")),
    ];
    // 只剔除文件内联的 `mod tests { .. }` 块; lib.rs 顶部的 `#[cfg(test)] mod tests_*;`
    // 声明不能作为截断点 (C230 拆分后测试位于独立文件, 不在扫描范围内)。
    let inline_test_module = ["#[cfg(test)]", "mod tests {"].join("\n");
    for (name, source) in sources {
        let production = source
            .split(inline_test_module.as_str())
            .next()
            .unwrap_or(source);
        assert!(
            production.contains("fn "),
            "{name}: scanned production slice must contain code"
        );
        for forbidden in [
            "CredentialSource",
            "read_claude_token",
            "read_grok_token",
            "read_keychain",
        ] {
            assert!(
                !production.contains(forbidden),
                "{name} production code references host credential reader {forbidden}"
            );
        }
    }
}

#[test]
fn deadline_after_quota_refresh_still_returns_rotated_tokens() {
    let failure = collect_cancelled_before_publish(
        &expired_claude_request(&["externalQuotas"]),
        &claude_refresh_then_usage_http(),
    )
    .unwrap_err();
    assert_eq!(failure.diagnostic.code, "LOCAL_SOURCE_CANCELLED");
    assert_carries_rotated_claude_tokens(&failure.credential_updates);
    let debug = format!("{failure:?}");
    assert!(!debug.contains("sk-ant-ort01-new_refresh"), "{debug}");
}

#[test]
fn local_scan_failure_still_returns_rotated_tokens() {
    // 授权 localSessions 却缺 home: 本机通道失败, 额度通道照常完成并已刷新令牌
    let failure = collect_agent_usage_with_dependencies(
        &expired_claude_request(&["localSessions", "externalQuotas"]),
        &claude_refresh_then_usage_http(),
    )
    .unwrap_err();
    assert_eq!(failure.diagnostic.code, "BRIDGE_INVALID_REQUEST");
    assert_carries_rotated_claude_tokens(&failure.credential_updates);
}

#[test]
fn application_preserves_capability_denied_local_semantics() {
    let output = collect_agent_usage(&request(&[])).unwrap();
    let artifact = output.artifact.as_object().unwrap();
    assert_eq!(artifact["agents"][1]["status"], "unavailable");
    // C124: 未授权云端额度不再输出 partial 占位 service
    assert_eq!(artifact["services"], json!([]));
}

fn local_or_skipped_request(context_extra: serde_json::Value) -> BridgeRequest {
    static LOCAL_SEQ: AtomicUsize = AtomicUsize::new(0);
    let home = std::env::temp_dir().join(format!(
        "bruce-local-or-skipped-{}-{}",
        std::process::id(),
        LOCAL_SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&home).unwrap();
    let mut request = request(&["localSessions", "externalQuotas"]);
    request
        .context
        .insert("home".to_owned(), json!(home.to_string_lossy()));
    request.context.insert(
        "paths".to_owned(),
        json!({"history_db": home.join("usage-history.sqlite").to_string_lossy()}),
    );
    request.credentials.insert(
        "claudeQuotaAccounts".to_owned(),
        json!({
            "acc": {
                "display_name": "Claude",
                "oauth": {"claudeAiOauth": {"accessToken": "tok"}}
            }
        }),
    );
    request.credentials.insert(
        "providerMeta".to_owned(),
        json!({"claude": {"enabled": true}}),
    );
    if let Some(extra) = context_extra.as_object() {
        for (key, value) in extra {
            request.context.insert(key.clone(), value.clone());
        }
    }
    request
}

#[test]
fn local_usage_only_skips_quota_and_denied_placeholders() {
    let request = local_or_skipped_request(json!({"localUsageOnly": true}));
    let http = FixtureHttp {
        calls: AtomicUsize::new(0),
        body: b"{}".to_vec(),
    };
    let output = collect_agent_usage_with_dependencies(&request, &http).unwrap();
    assert_eq!(http.calls.load(Ordering::Acquire), 0, "不得发起额度请求");
    let artifact = output.artifact.as_object().unwrap();
    assert!(
        artifact["services"].as_array().unwrap().is_empty(),
        "不得输出占位 service"
    );
    assert!(
        !output
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "COLLECTOR_PARTIAL_RESULT"),
        "本地专用 run 不得被误报为 partial"
    );
}

#[test]
fn quota_skip_providers_avoids_http_requests() {
    let request = local_or_skipped_request(json!({"quotaSkipProviders": ["claude"]}));
    let http = FixtureHttp {
        calls: AtomicUsize::new(0),
        body: b"{}".to_vec(),
    };
    let output = collect_agent_usage_with_dependencies(&request, &http).unwrap();
    assert_eq!(
        http.calls.load(Ordering::Acquire),
        0,
        "跳过 provider 不得发起请求"
    );
    let artifact = output.artifact.as_object().unwrap();
    assert!(
        artifact["services"].as_array().unwrap().is_empty(),
        "跳过的 provider 不应出现在本轮 services"
    );
}

#[test]
fn application_does_not_fallback_to_host_credentials_for_official_providers() {
    let request: BridgeRequest = serde_json::from_value(json!({
        "schemaVersion": 1,
        "runId": "12345678-1234-4234-9234-123456789abc",
        "module": "agent-usage",
        "timeouts": {
            "externalRequestSeconds": 10,
            "moduleSeconds": 90
        },
        "context": {
            "now": "2026-08-21T08:00:00Z",
            "capabilities": ["externalQuotas"]
        },
        "credentials": {
            "providerMeta": {
                "claude": {"enabled": true},
                "grok": {"enabled": true}
            }
        }
    }))
    .unwrap();
    let http = FixtureHttp {
        calls: AtomicUsize::new(0),
        body: br#"{}"#.to_vec(),
    };
    let output = collect_agent_usage_with_dependencies(&request, &http).unwrap();
    assert_eq!(http.calls.load(Ordering::Acquire), 0);
    assert!(
        output
            .diagnostics
            .iter()
            .filter(|diagnostic| diagnostic.code == "CREDENTIAL_MISSING")
            .count()
            >= 2
    );
}

#[test]
fn cancelled_local_run_returns_existing_diagnostic_without_artifact() {
    let home = std::env::temp_dir().join(format!(
        "bruce-cancelled-local-run-test-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join(".kimi-code/sessions")).unwrap();
    let mut request = request(&["localSessions"]);
    request.context.insert(
        "home".to_owned(),
        serde_json::Value::String(home.to_string_lossy().into_owned()),
    );
    request.timeouts.module_seconds = 0.0;

    let result = collect_agent_usage_with_dependencies(
        &request,
        &FixtureHttp {
            calls: AtomicUsize::new(0),
            body: Vec::new(),
        },
    );

    assert_eq!(
        result.unwrap_err().diagnostic.code,
        "LOCAL_SOURCE_CANCELLED",
        "a cancelled local run must fail before publishing a partial artifact"
    );
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn cancellation_after_last_source_is_fenced_before_artifact_publication() {
    let result = collect_cancelled_before_publish(
        &request(&[]),
        &FixtureHttp {
            calls: AtomicUsize::new(0),
            body: Vec::new(),
        },
    );

    assert_eq!(
        result.unwrap_err().diagnostic.code,
        "LOCAL_SOURCE_CANCELLED",
        "final cancellation must prevent a new artifact from being returned"
    );
}

#[test]
fn external_quota_capability_denied_skips_http_and_credential_sources() {
    let mut request = request(&[]);
    request.credentials.insert(
        "kimiQuotaAccounts".to_owned(),
        json!({"acct-a": {"api_key": "must-not-be-read"}}),
    );
    let http = FixtureHttp {
        calls: AtomicUsize::new(0),
        body: br#"{}"#.to_vec(),
    };
    let output = collect_agent_usage_with_dependencies(&request, &http).unwrap();
    assert_eq!(http.calls.load(Ordering::Acquire), 0);
    assert_eq!(output.artifact["services"], json!([]));
    assert!(output
        .diagnostics
        .iter()
        .all(|diagnostic| diagnostic.code != "COLLECTOR_PARTIAL_RESULT"));
    assert_eq!(output.metrics.http_request_count, 0);
}
