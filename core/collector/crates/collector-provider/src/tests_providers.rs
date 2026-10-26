use super::tests_parsers::{provider_request, response, FixtureHttp};
use crate::providers::{claude_token, grok_token, is_claude_token_expired, opencode_credential};
use crate::{
    catalog_entries, codex_service_id, parse_cline_usage_limits, parse_jev_models, reset_epoch,
    service_template, CancellationToken, ClaudeProvider, ClineProvider, CodexProvider,
    DeepSeekProvider, HttpResponse, JevProvider, KimiProvider, OpenCodeGoProvider, ProviderError,
    ProviderRequest, QuotaProvider, VolcEngineProvider, JEV_MODELS_URL,
};
use collector_runtime::RuntimeLimits;
use serde_json::{json, Value};
use std::time::Duration;

#[test]
fn fixture_http_client_checks_request_headers_and_retry_count() {
    let http = FixtureHttp::new(vec![
        response("not seroval"),
        response("$R[0]={rollingUsage:{status:\"ok\",usagePercent:10,resetInSec:5}}"),
    ]);
    let request = provider_request(
        "opencode-go",
        json!({"auth": "fixture-cookie", "workspaceId": "wrk_fixture"}),
    );
    let result = OpenCodeGoProvider
        .query(&request, &http, &CancellationToken::new())
        .unwrap()
        .unwrap();
    assert_eq!(result["windows"][0]["usedPercent"], 10.0);
    let requests = http.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].timeout, Duration::from_secs(8));
    assert_eq!(requests[0].headers["Cookie"], "auth=fixture-cookie");
    assert!(!requests[0].url.contains("fixture-cookie"));
}

#[test]
fn fixture_provider_clients_never_put_credential_in_diagnostic() {
    let secret = "fixture-provider-secret";
    let http = FixtureHttp::new(vec![response("[]")]);
    let request = provider_request("kimi", json!({"api_key": secret}));
    let error = KimiProvider
        .query(&request, &http, &CancellationToken::new())
        .unwrap_err();
    assert!(!error.diagnostic.message.contains(secret));

    let bad_status = FixtureHttp::new(vec![Ok(HttpResponse {
        status: 401,
        body: Vec::new(),
    })]);
    let error = DeepSeekProvider
        .query(
            &provider_request("deepseek", json!({"api_key": secret})),
            &bad_status,
            &CancellationToken::new(),
        )
        .unwrap_err();
    assert_eq!(error.diagnostic.code, "PROVIDER_AUTH_REJECTED");
    assert!(!error.diagnostic.message.contains(secret));
}

#[test]
fn provider_request_uses_bounded_body_and_volc_signature_path() {
    let http = FixtureHttp::new(vec![response(
        r#"{"QuotaUsage":[{"Level":"session","Percent":12.0,"ResetTimestamp":-1}]}"#,
    )]);
    let result = VolcEngineProvider
        .query(
            &provider_request(
                "volcengine",
                json!({"accessKeyId":"fixture-ak","secretAccessKey":"fixture-sk"}),
            ),
            &http,
            &CancellationToken::new(),
        )
        .unwrap()
        .unwrap();
    assert_eq!(result["windows"][0]["usedPercent"], 12.0);
    let request = &http.requests()[0];
    assert!(request.headers.contains_key("Authorization"));
    assert!(!request.headers["Authorization"].contains("fixture-sk"));
}

#[test]
fn jev_parser_handles_valid_models_response() {
    let payload = json!({
        "models": [
            {
                "name": "jev-latest",
                "description": "The most recent stable release.",
                "release_date": "2025-01-01"
            },
            {
                "name": "jev-preview",
                "description": "The most recent preview release.",
                "release_date": "2025-01-01"
            }
        ]
    });
    let result = parse_jev_models(&payload).unwrap().unwrap();
    assert_eq!(result["kind"], "balance");
    assert_eq!(result["plan"], "System One");
    assert!(result["extra"].is_null());
    assert_eq!(result["windows"].as_array().unwrap().len(), 0);
}

#[test]
fn jev_parser_handles_empty_models_response() {
    let payload = json!({ "models": [] });
    let result = parse_jev_models(&payload).unwrap().unwrap();
    assert_eq!(result["kind"], "balance");
    assert!(result["extra"].is_null());
    assert_eq!(result["windows"].as_array().unwrap().len(), 0);
}

#[test]
fn jev_parser_rejects_invalid_payload() {
    let payload = json!({ "error": "not models" });
    assert!(parse_jev_models(&payload).is_err());
}

#[test]
fn jev_provider_query_success_and_auth_failure() {
    let secret = "sk-typesafe-test-key";
    let http = FixtureHttp::new(vec![response(
        r#"{"models":[{"name":"jev-latest","description":"test","release_date":"2025-01-01"}]}"#,
    )]);
    let result = JevProvider
        .query(
            &provider_request("jev", json!({"api_key": secret})),
            &http,
            &CancellationToken::new(),
        )
        .unwrap()
        .unwrap();
    assert_eq!(result["plan"], "System One");
    let request = &http.requests()[0];
    assert_eq!(request.method, "GET");
    assert_eq!(request.url, JEV_MODELS_URL);
    assert_eq!(request.headers["Authorization"], format!("Bearer {secret}"));

    // 401 鉴权拒绝
    let bad_http = FixtureHttp::new(vec![Ok(HttpResponse {
        status: 401,
        body: Vec::new(),
    })]);
    let err = JevProvider
        .query(
            &provider_request("jev", json!({"api_key": secret})),
            &bad_http,
            &CancellationToken::new(),
        )
        .unwrap_err();
    assert_eq!(err.diagnostic.code, "PROVIDER_AUTH_REJECTED");
    assert!(!err.diagnostic.message.contains(secret));

    // 429 限流
    let rate_limited_http = FixtureHttp::new(vec![Ok(HttpResponse {
        status: 429,
        body: Vec::new(),
    })]);
    let err = JevProvider
        .query(
            &provider_request("jev", json!({"api_key": secret})),
            &rate_limited_http,
            &CancellationToken::new(),
        )
        .unwrap_err();
    assert_eq!(err.diagnostic.code, "PROVIDER_RATE_LIMIT");

    // 余额注入测试
    let balance_http = FixtureHttp::new(vec![response(
        r#"{"models":[{"name":"jev-latest","description":"test","release_date":"2025-01-01"}]}"#,
    )]);
    let result = JevProvider
        .query(
            &provider_request("jev", json!({"api_key": secret, "balance": 18.5})),
            &balance_http,
            &CancellationToken::new(),
        )
        .unwrap()
        .unwrap();
    assert_eq!(result["kind"], "balance");
    assert_eq!(result["balance"], 18.5);
    assert_eq!(result["currency"], "USD");
}

fn cline_plan_payload(thresholds: (u64, u64, u64), canceled_at: Option<&str>) -> Value {
    json!({
        "data": {
            "planHistoryId": "iph-fixture",
            "userId": "usr-fixture",
            "plan": {
                "id": "pln-fixture",
                "name": "Cline Pass (Monthly)[Internal]",
                "displayName": "Cline Pass (Monthly)",
                "type": "individual",
                "interval": "Monthly",
                "pricePerSeatCents": 999,
                "entitlements": {
                    "cline_pass": {
                        "enabled": true,
                        "inferenceCapThreshold": {
                            "last5HoursUsageCostUSDPerUser": thresholds.0,
                            "last7daysUsageCostUSDPerUser": thresholds.1,
                            "last30daysUsageCostUSDPerUser": thresholds.2,
                        }
                    }
                }
            },
            "subscriptionId": "sub-fixture",
            "currentPeriodStart": "2026-10-14T11:52:39Z",
            "currentPeriodEnd": "2026-11-14T11:52:39Z",
            "cancelAt": "2026-11-14T11:52:39Z",
            "canceledAt": canceled_at,
        },
        "success": true,
    })
}

fn cline_request(secret: &str) -> ProviderRequest {
    ProviderRequest {
        account_id: None,
        captured_at: "2026-10-14T12:00:00Z".to_owned(),
        timeout: Duration::from_secs(8),
        max_response_body_bytes: RuntimeLimits::default().response_body_bytes,
        credential: Some(json!({ "api_key": secret })),
    }
}

/// 服务端权威端点 (C039): /users/me/plan + /users/me/plan/usage-limits 恒定 2 次 GET,
/// 百分比与重置时刻由服务端返回、Bruce 直读映射, 不做任何本地窗口建模。
#[test]
fn cline_provider_reads_server_usage_limits() {
    let secret = "sk-cline-fixture-key";
    let usage_limits = json!({
        "data": {
            "limits": [
                {"type": "five_hour", "percentUsed": 2,
                 "resetsAt": "2026-10-16T05:51:46.262166334Z"},
                {"type": "weekly", "percentUsed": 34,
                 "resetsAt": "2026-10-21T12:00:46.265101164Z"},
                {"type": "monthly", "percentUsed": 17,
                 "resetsAt": "2026-11-13T12:00:46.267955904Z"},
            ]
        },
        "success": true,
    });
    let http = FixtureHttp::new(vec![
        response(
            &cline_plan_payload((1_000_000_000, 2_500_000_000, 5_000_000_000), None).to_string(),
        ),
        response(&usage_limits.to_string()),
    ]);
    let result = ClineProvider
        .query(&cline_request(secret), &http, &CancellationToken::new())
        .unwrap()
        .unwrap();
    assert_eq!(result["kind"], "windows");
    assert_eq!(result["plan"], "Cline Pass (Monthly)");
    assert!(result["extra"].is_null());
    let windows = result["windows"].as_array().expect("windows array");
    assert_eq!(windows.len(), 3);
    // 服务端整数百分比原样透传
    assert_eq!(windows[0]["label"], "每 5 小时");
    assert_eq!(windows[0]["windowMinutes"], json!(300));
    assert!((windows[0]["usedPercent"].as_f64().unwrap() - 2.0).abs() < 1e-6);
    assert_eq!(windows[1]["windowMinutes"], json!(10080));
    assert!((windows[1]["usedPercent"].as_f64().unwrap() - 34.0).abs() < 1e-6);
    assert_eq!(windows[2]["windowMinutes"], json!(43200));
    assert!((windows[2]["usedPercent"].as_f64().unwrap() - 17.0).abs() < 1e-6);
    // 纳秒级 resetsAt 截断到秒 (chrono rfc3339 原生解析任意位小数)
    assert_eq!(
        windows[0]["resetsAt"],
        json!(reset_epoch(Some(&json!("2026-10-16T05:51:46.262166334Z"))).unwrap())
    );
    assert_eq!(
        windows[1]["resetsAt"],
        json!(reset_epoch(Some(&json!("2026-10-21T12:00:46.265101164Z"))).unwrap())
    );
    assert_eq!(
        windows[2]["resetsAt"],
        json!(reset_epoch(Some(&json!("2026-11-13T12:00:46.267955904Z"))).unwrap())
    );
    // 请求序列与鉴权头: 恒定 2 次 GET (plan → usage-limits), 不再请求 /users/me 与台账
    let requests = http.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(
        requests[0].url,
        "https://api.cline.bot/api/v1/users/me/plan"
    );
    assert_eq!(
        requests[1].url,
        "https://api.cline.bot/api/v1/users/me/plan/usage-limits"
    );
    for request in requests {
        assert_eq!(request.headers["Authorization"], format!("Bearer {secret}"));
    }
}

#[test]
fn cline_provider_maps_auth_and_rate_limit_without_leaking_key() {
    let secret = "sk-cline-fixture-key";
    let unauthorized = FixtureHttp::new(vec![Ok(HttpResponse {
        status: 401,
        body: Vec::new(),
    })]);
    let err = ClineProvider
        .query(
            &cline_request(secret),
            &unauthorized,
            &CancellationToken::new(),
        )
        .unwrap_err();
    assert_eq!(err.diagnostic.code, "PROVIDER_AUTH_REJECTED");
    assert!(!err.diagnostic.message.contains(secret));

    let rate_limited = FixtureHttp::new(vec![Ok(HttpResponse {
        status: 429,
        body: Vec::new(),
    })]);
    let err = ClineProvider
        .query(
            &cline_request(secret),
            &rate_limited,
            &CancellationToken::new(),
        )
        .unwrap_err();
    assert_eq!(err.diagnostic.code, "PROVIDER_RATE_LIMIT");
}

#[test]
fn cline_provider_returns_empty_without_pass_entitlements() {
    let mut plan = cline_plan_payload((1_000_000_000, 2_500_000_000, 5_000_000_000), None);
    plan["data"]["plan"]["entitlements"]["cline_pass"]["enabled"] = json!(false);
    let http = FixtureHttp::new(vec![response(&plan.to_string())]);
    let result = ClineProvider
        .query(
            &cline_request("sk-cline-fixture-key"),
            &http,
            &CancellationToken::new(),
        )
        .unwrap();
    assert!(result.is_none());
    // 非 ClinePass 账户不得继续查询 usage-limits
    assert_eq!(http.requests().len(), 1);
}

#[test]
fn cline_usage_limits_navigation_and_defense() {
    // 报文含 canceledAt/cancelAt (data 层), 但 C020 起不再产出任何生命周期注记.
    let plan = cline_plan_payload(
        (1_000_000_000, 2_500_000_000, 5_000_000_000),
        Some("2026-10-14T12:02:20Z"),
    );
    // 未知窗口类型跳过; 缺 resetsAt 仅不展示倒计时; 百分比收敛在 0..=100.
    let limits = json!({
        "data": {
            "limits": [
                {"type": "five_hour", "percentUsed": 250, "resetsAt": "2026-10-16T05:51:46Z"},
                {"type": "weekly", "percentUsed": 34},
                {"type": "daily_experimental", "percentUsed": 9,
                 "resetsAt": "2026-10-17T00:00:00Z"}
            ]
        },
        "success": true,
    });
    let result = parse_cline_usage_limits(&plan, &limits).unwrap().unwrap();
    let windows = result["windows"].as_array().expect("windows array");
    assert_eq!(windows.len(), 2);
    assert_eq!(windows[0]["label"], "每 5 小时");
    assert!((windows[0]["usedPercent"].as_f64().unwrap() - 100.0).abs() < 1e-6);
    assert!(windows[1]
        .get("resetsAt")
        .is_some_and(|value| value.is_null()));
    assert!(
        result.get("extra").is_none(),
        "C020: 不得再注入生命周期注记"
    );

    // entitlements 缺失 (典型非 Pass 账户) → 空态
    let missing = json!({
        "data": {
            "planHistoryId": "iph-fixture",
            "plan": {"displayName": "Cline Free"}
        },
        "success": true
    });
    assert!(parse_cline_usage_limits(&missing, &limits)
        .unwrap()
        .is_none());

    // limits 缺失/形状异常 → 显式报错 (fail-visible, 不得静默渲染空窗口)
    assert!(parse_cline_usage_limits(&plan, &json!({"success": true})).is_err());
    assert!(
        parse_cline_usage_limits(&plan, &json!({"data": {"limits": "oops"}, "success": true}))
            .is_err()
    );
}

/// 线上真实报文形态锁定 (2026-10-14 实测 `/users/me/plan`、2026-10-16 实测
/// `/users/me/plan/usage-limits` 响应, 标识已替换为 fixture):
/// 生命周期字段 (`canceledAt`) 位于 `data` 层, `displayName`/`entitlements` 位于
/// `data.plan` 层; usage-limits 为 `data.limits[]` (type/percentUsed/纳秒级 resetsAt).
#[test]
fn cline_live_plan_payload_shape_is_supported() {
    let live_shaped: Value = serde_json::from_str(
        r#"{
              "data": {
                "planHistoryId": "iph-fixture",
                "userId": "usr-fixture",
                "plan": {
                  "id": "pln-fixture",
                  "name": "Cline Pass (Monthly)[Internal]",
                  "displayName": "Cline Pass (Monthly)",
                  "description": "Cline Pass brings agentic coding...",
                  "type": "individual",
                  "interval": "Monthly",
                  "pricePerSeatCents": 999,
                  "priceId": "price-fixture",
                  "maxSeats": 1000000,
                  "features": {
                    "fee_dollars": 0.61,
                    "free_seats": 0,
                    "included": ["Low cost subscription pricing"]
                  },
                  "entitlements": {
                    "cline_pass": {
                      "enabled": true,
                      "inferenceCapThreshold": {
                        "last5HoursUsageCostUSDPerUser": 1000000000,
                        "last7daysUsageCostUSDPerUser": 2500000000,
                        "last30daysUsageCostUSDPerUser": 5000000000
                      }
                    }
                  },
                  "isActive": true,
                  "createdAt": "2026-05-26T09:34:05.877169Z",
                  "updatedAt": "2026-09-21T10:11:10.680596Z"
                },
                "subscriptionId": "sub-fixture",
                "currentPeriodStart": "2026-10-14T11:52:39Z",
                "currentPeriodEnd": "2026-11-14T11:52:39Z",
                "cancelAt": "2026-11-14T11:52:39Z",
                "canceledAt": "2026-10-14T12:02:20Z"
              },
              "success": true
            }"#,
    )
    .expect("live-shaped payload parses");
    let live_limits: Value = serde_json::from_str(
        r#"{
              "data": {
                "limits": [
                  {"type": "five_hour", "percentUsed": 0,
                   "resetsAt": "2026-10-16T05:51:46.262166334Z"},
                  {"type": "weekly", "percentUsed": 34,
                   "resetsAt": "2026-10-21T12:00:46.265101164Z"},
                  {"type": "monthly", "percentUsed": 17,
                   "resetsAt": "2026-11-13T12:00:46.267955904Z"}
                ]
              },
              "success": true
            }"#,
    )
    .expect("live-shaped usage-limits payload parses");
    let result = parse_cline_usage_limits(&live_shaped, &live_limits)
        .unwrap()
        .unwrap();
    assert_eq!(result["plan"], "Cline Pass (Monthly)");
    let windows = result["windows"].as_array().expect("windows array");
    assert_eq!(windows.len(), 3);
    // 服务端整数百分比与纳秒 resetsAt 直读 (2026-10-16 与网页控制台逐字一致)
    assert!((windows[1]["usedPercent"].as_f64().unwrap() - 34.0).abs() < 1e-6);
    assert!((windows[2]["usedPercent"].as_f64().unwrap() - 17.0).abs() < 1e-6);
    assert_eq!(
        windows[0]["resetsAt"],
        json!(reset_epoch(Some(&json!("2026-10-16T05:51:46.262166334Z"))).unwrap())
    );
    // C020: 线上报文含 canceledAt 也不得产出任何注记 (extra 键不出现)
    assert!(result.get("extra").is_none());
}

/// C049: 目录表是前缀/凭据字段的单一事实源。
/// 断言每条目的三项映射齐备且无重复 —— 任何漏填都会在测试期暴露,
/// 而不是等到某个 provider 静默取不到凭据。
#[test]
fn catalog_entries_are_complete_and_unique() {
    let entries = catalog_entries();
    assert_eq!(entries.len(), 10, "目录表应含 10 家 provider");

    let mut apps = std::collections::BTreeSet::new();
    let mut prefixes = std::collections::BTreeSet::new();
    let mut fields = std::collections::BTreeSet::new();
    for entry in &entries {
        assert!(!entry.app.is_empty(), "app 不得为空: {entry:?}");
        assert!(!entry.prefix.is_empty(), "prefix 不得为空: {entry:?}");
        assert!(
            !entry.credential_field.is_empty(),
            "credential_field 不得为空: {entry:?}"
        );
        assert!(
            entry.prefix.ends_with('_'),
            "prefix 应以下划线结尾 (与账户标识拼接约定一致): {entry:?}"
        );
        assert!(apps.insert(entry.app), "app 重复: {}", entry.app);
        assert!(
            prefixes.insert(entry.prefix),
            "prefix 重复: {}",
            entry.prefix
        );
        assert!(
            fields.insert(entry.credential_field),
            "credential_field 重复: {}",
            entry.credential_field
        );
    }
    // 关键约定抽查: 三处曾手工重复的前缀必须逐字一致
    let kimi = entries.iter().find(|e| e.app == "kimi").expect("kimi 条目");
    assert_eq!(kimi.prefix, "kimi_coding_");
    assert_eq!(kimi.credential_field, "kimiQuotaAccounts");
    let opencode = entries
        .iter()
        .find(|e| e.app == "opencode-go")
        .expect("opencode-go 条目");
    assert_eq!(opencode.prefix, "opencode_go_");
}

#[test]
fn claude_token_expiry_detector_handles_milliseconds_and_buffer() {
    let expired_ms = Some(1_700_000_000_000);
    let fresh_ms = Some(2_100_000_000_000);
    let near_expiry_ms = Some(1_700_000_050_000); // 50s left (< 60s)
    let now_epoch_secs = 1_700_000_000;

    assert!(is_claude_token_expired(expired_ms, now_epoch_secs));
    assert!(!is_claude_token_expired(fresh_ms, now_epoch_secs));
    assert!(is_claude_token_expired(near_expiry_ms, now_epoch_secs));
    assert!(!is_claude_token_expired(None, now_epoch_secs));
}

#[test]
fn claude_provider_proactively_refreshes_expired_token() {
    let cred = json!({
        "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-stale_token",
            "refreshToken": "sk-ant-ort01-refresh_me",
            "expiresAt": 1_700_000_000_000_i64,
            "scopes": ["user:profile", "user:inference"]
        }
    });
    let refresh_resp = json!({
        "token_type": "Bearer",
        "access_token": "sk-ant-oat01-fresh_token",
        "refresh_token": "sk-ant-ort01-new_refresh",
        "expires_in": 28800,
        "scope": "user:profile user:inference"
    });
    let usage_resp = json!({
        "five_hour": { "utilization": 5.0, "resets_at": null },
        "seven_day": { "utilization": 20.0, "resets_at": null },
        "extra_usage": null,
        "limits": [
            { "kind": "session", "group": "session", "percent": 5, "severity": "normal" },
            { "kind": "weekly_all", "group": "weekly", "percent": 20, "severity": "normal" }
        ]
    });

    let http = FixtureHttp::new(vec![
        // 1. Refresh endpoint responds with new tokens
        Ok(HttpResponse {
            status: 200,
            body: serde_json::to_vec(&refresh_resp).unwrap(),
        }),
        // 2. Usage endpoint responds with fresh quota
        Ok(HttpResponse {
            status: 200,
            body: serde_json::to_vec(&usage_resp).unwrap(),
        }),
    ]);

    let request = ProviderRequest {
        account_id: Some("claude-test".to_owned()),
        captured_at: "2026-10-20T00:00:00Z".to_owned(), // captured epoch > 1700000000
        timeout: Duration::from_secs(5),
        max_response_body_bytes: 65536,
        credential: Some(cred),
    };

    let result = ClaudeProvider
        .query(&request, &http, &CancellationToken::default())
        .unwrap()
        .expect("should return usage value");

    let requests = http.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].method, "POST");
    assert!(requests[0].url.contains("/v1/oauth/token"));
    assert_eq!(requests[1].method, "GET");
    assert!(requests[1].url.contains("/api/oauth/usage"));
    assert_eq!(
        requests[1].headers.get("Authorization"),
        Some(&"Bearer sk-ant-oat01-fresh_token".to_owned())
    );

    let update = result
        .get("credential_update")
        .expect("credential_update attached");
    assert_eq!(
        update["access_token"].as_str(),
        Some("sk-ant-oat01-fresh_token")
    );
    assert_eq!(
        update["refresh_token"].as_str(),
        Some("sk-ant-ort01-new_refresh")
    );
}

#[test]
fn claude_provider_refreshes_token_on_401_and_retries() {
    let cred = json!({
        "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-stale_token",
            "refreshToken": "sk-ant-ort01-refresh_me",
            "expiresAt": 2_100_000_000_000_i64, // looks unexpired
            "scopes": ["user:profile"]
        }
    });
    let refresh_resp = json!({
        "token_type": "Bearer",
        "access_token": "sk-ant-oat01-fresh_token_after_401",
        "refresh_token": "sk-ant-ort01-new_refresh_after_401",
        "expires_in": 28800,
        "scope": "user:profile"
    });
    let usage_resp = json!({
        "five_hour": { "utilization": 12.0, "resets_at": null },
        "seven_day": { "utilization": 30.0, "resets_at": null },
        "extra_usage": null,
        "limits": [
            { "kind": "session", "group": "session", "percent": 12, "severity": "normal" },
            { "kind": "weekly_all", "group": "weekly", "percent": 30, "severity": "normal" }
        ]
    });

    let http = FixtureHttp::new(vec![
        // 1. Initial usage GET returns 401
        Ok(HttpResponse {
            status: 401,
            body: b"{\"error\":\"expired\"}".to_vec(),
        }),
        // 2. Refresh endpoint responds with new tokens
        Ok(HttpResponse {
            status: 200,
            body: serde_json::to_vec(&refresh_resp).unwrap(),
        }),
        // 3. Retry usage GET responds with 200
        Ok(HttpResponse {
            status: 200,
            body: serde_json::to_vec(&usage_resp).unwrap(),
        }),
    ]);

    let request = ProviderRequest {
        account_id: Some("claude-test".to_owned()),
        captured_at: "2026-10-20T00:00:00Z".to_owned(),
        timeout: Duration::from_secs(5),
        max_response_body_bytes: 65536,
        credential: Some(cred),
    };

    let result = ClaudeProvider
        .query(&request, &http, &CancellationToken::default())
        .unwrap()
        .expect("should return usage value");

    let requests = http.requests();
    assert_eq!(requests.len(), 3);
    assert_eq!(requests[0].method, "GET");
    assert_eq!(requests[1].method, "POST");
    assert!(requests[1].url.contains("/v1/oauth/token"));
    assert_eq!(requests[2].method, "GET");
    assert_eq!(
        requests[2].headers.get("Authorization"),
        Some(&"Bearer sk-ant-oat01-fresh_token_after_401".to_owned())
    );

    let update = result
        .get("credential_update")
        .expect("credential_update attached");
    assert_eq!(
        update["access_token"].as_str(),
        Some("sk-ant-oat01-fresh_token_after_401")
    );
    assert_eq!(
        update["refresh_token"].as_str(),
        Some("sk-ant-ort01-new_refresh_after_401")
    );
}

// 凭据形状契约 (C081 / 设计规则 21): 两端的 oauth 形状契约由本组用例锁定 ——
// 客户端 (mac / Windows) 落盘的形状必须能被这里的真实解析器读出凭据,
// 且旧扁平形状必须读不出 (否则即为「保存成功但查不出额度」的静默失效)。
// 契约漂移 (解析器改形状) 时本组用例转红。
#[test]
fn oauth_credential_shapes_are_parseable_by_real_parsers() {
    // Claude: claudeAiOauth / claude.ai_oauth 包装 + accessToken。
    for wrapper in ["claudeAiOauth", "claude.ai_oauth"] {
        let credential = json!({ wrapper: { "accessToken": "fixture-claude-token" } });
        assert_eq!(
            claude_token(&credential).unwrap().as_deref(),
            Some("fixture-claude-token"),
            "{wrapper} 包装必须被解析"
        );
    }
    // Grok: 顶层 key 与 https://auth.x.ai:: 作用域条目。
    assert_eq!(
        grok_token(&json!({ "key": "fixture-grok-token" }))
            .unwrap()
            .as_deref(),
        Some("fixture-grok-token")
    );
    assert_eq!(
        grok_token(&json!({"https://auth.x.ai::injected": {"key": "fixture-grok-scoped"}}))
            .unwrap()
            .as_deref(),
        Some("fixture-grok-scoped")
    );
    // OpenCode GO: auth + workspaceId 双必填。
    let opencode = json!({"auth": "Fe26.2**fixture", "workspaceId": "wrk_fixture"});
    assert_eq!(
        opencode_credential(&opencode).unwrap(),
        ("Fe26.2**fixture", "wrk_fixture")
    );
}

#[test]
fn flat_oauth_token_shape_yields_no_credential() {
    // 旧 Windows 通用表单写出的形状: 采集端既不报错也取不到凭据。
    let flat = json!({ "access_token": "fixture-token", "refresh_token": "fixture-refresh" });
    assert_eq!(
        claude_token(&flat).unwrap(),
        None,
        "扁平形状读不出 Claude 凭据"
    );
    assert_eq!(grok_token(&flat).unwrap(), None, "扁平形状读不出 Grok 凭据");
    assert!(
        opencode_credential(&flat).is_err(),
        "扁平形状读不出 OpenCode GO 凭据"
    );
}

#[test]
fn codex_provider_finalize_outcome_standardizes_freshness_failure_kind_and_challenges() {
    let descriptor = super::ServiceDescriptor {
        id: codex_service_id("acc-1"),
        name: "Codex · 1".to_owned(),
        app: "codex".to_owned(),
        is_current: false,
    };
    let template = service_template(&descriptor, "2026-10-23T00:00:00Z");
    let ok_outcome = CodexProvider.finalize_outcome(
        template.clone(),
        Some("acc-1"),
        Ok(Some(json!({
            "kind": "windows",
            "plan": "pro",
            "windows": [{"label": "5h", "usedPercent": 10.0}],
        }))),
    );
    assert_eq!(ok_outcome.service["status"], "ok");
    assert_eq!(ok_outcome.service["freshness"], "fresh");
    assert!(ok_outcome.service["failureKind"].is_null());
    assert!(ok_outcome.credential_challenges.is_empty());

    let auth_err = ProviderError::new("PROVIDER_AUTH_REJECTED", "response", "rejected", false);
    let err_outcome = CodexProvider.finalize_outcome(template, Some("acc-1"), Err(auth_err));
    assert_eq!(err_outcome.service["status"], "error");
    assert_eq!(err_outcome.service["freshness"], "unavailable");
    assert_eq!(err_outcome.service["failureKind"], "auth");
    assert_eq!(
        err_outcome.service["note"],
        "登录态已失效, 请重新登录该账号"
    );
    assert!(err_outcome.service.get("capturedAt").is_none());
    assert_eq!(
        err_outcome.credential_challenges,
        vec![json!({
            "provider": "codex",
            "accountId": "acc-1",
            "reason": "accessRejected"
        })]
    );
}

#[test]
fn catalog_entry_for_app_declares_credential_metadata_without_application_hardcoding() {
    let claude = super::catalog_entry_for_app("claude").unwrap();
    assert_eq!(claude.direct_credential_field, Some("claudeOAuth"));
    assert_eq!(claude.missing_credential_source, Some("Swift 注入"));
    assert!(claude.unwraps_oauth_payload);

    let grok = super::catalog_entry_for_app("grok").unwrap();
    assert_eq!(grok.direct_credential_field, Some("grokOAuth"));
    assert_eq!(grok.missing_credential_source, Some("Swift 注入"));
    assert!(grok.unwraps_oauth_payload);

    let kimi = super::catalog_entry_for_app("kimi").unwrap();
    assert_eq!(kimi.direct_credential_field, None);
    assert_eq!(kimi.missing_credential_source, None);
    assert!(!kimi.unwraps_oauth_payload);
}

/// C118: 每个服务都带显式 provider (与应用侧 SubscriptionProviderID 同值) 与 failureKind;
/// 应用不再从 id 前缀或 note 文案推断。
#[test]
fn services_carry_explicit_provider_and_failure_kind() {
    use crate::{finalize_service, ServiceDescriptor};
    let descriptor = |app: &str, id: &str| ServiceDescriptor {
        id: id.to_owned(),
        name: "fixture".to_owned(),
        app: app.to_owned(),
        is_current: false,
    };
    let template = service_template(
        &descriptor("opencode-go", "opencode_go_x"),
        "2026-10-26T00:00:00Z",
    );
    assert_eq!(template["provider"], "opencodeGo");
    assert!(template["failureKind"].is_null());
    // 与 mac / Windows 的 SubscriptionProviderID rawValue 一一对应
    let provider_ids = [
        "kimi",
        "deepseek",
        "volcengine",
        "zhipu",
        "codex",
        "claude",
        "grok",
        "opencodeGo",
        "stepfun",
        "jev",
        "cline",
    ];
    let mut apps = catalog_entries()
        .into_iter()
        .map(|entry| entry.app)
        .collect::<Vec<_>>();
    apps.push("codex");
    for app in apps {
        let service = service_template(&descriptor(app, "fixture_a"), "now");
        let provider = service["provider"].as_str().unwrap_or_default();
        assert!(provider_ids.contains(&provider), "{app} → {provider}");
    }

    let rate_limited = finalize_service(
        service_template(&descriptor("kimi", "kimi_coding_a"), "now"),
        Err(ProviderError::new(
            "PROVIDER_RATE_LIMIT",
            "response",
            "限流",
            true,
        )),
    );
    assert_eq!(rate_limited["status"], "error");
    assert_eq!(rate_limited["failureKind"], "rateLimit");

    let invalid = finalize_service(
        service_template(&descriptor("deepseek", "deepseek_a"), "now"),
        Ok(Some(json!("not an object"))),
    );
    assert_eq!(invalid["failureKind"], "invalidResponse");

    let ok = finalize_service(
        service_template(&descriptor("zhipu", "zhipu_a"), "now"),
        Ok(Some(
            json!({"kind": "windows", "windows": [{"label": "5h", "usedPercent": 1}]}),
        )),
    );
    assert_eq!(ok["status"], "ok");
    assert!(ok["failureKind"].is_null());
    assert_eq!(
        crate::failure_kind_for_code("CREDENTIAL_MISSING"),
        "credential"
    );
    assert_eq!(crate::failure_kind_for_code("PROVIDER_TIMEOUT"), "network");
}
