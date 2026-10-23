use crate::signing::{
    extract_stepfun_app_id, extract_stepfun_device_id, is_stepfun_global, is_stepfun_token_expired,
};
use crate::{
    bounded_http_body, codex_service_id, parse_claude_usage, parse_codex_usage,
    parse_deepseek_balance, parse_grok_usage, parse_kimi_usage, parse_opencode_go_body,
    parse_stepfun_usage, parse_volcengine_usage, parse_zhipu_usage, resolve_service_catalog,
    service_template, AccountDescriptor, CancellationToken, CatalogInput, CodexProvider,
    HttpClient, HttpRequest, HttpResponse, ProviderError, ProviderRequest, QuotaProvider,
    StepFunProvider, UreqHttpClient, ZhipuProvider, STEPFUN_GLOBAL_REFRESH_TOKEN_URL,
    STEPFUN_GLOBAL_STEP_PLAN_RATE_LIMIT_URL, STEPFUN_REFRESH_TOKEN_URL,
    STEPFUN_STEP_PLAN_RATE_LIMIT_URL,
};
use collector_runtime::RuntimeLimits;
use serde_json::{json, Value};
use sha2::Digest;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;
use std::time::Duration;

pub(super) struct FixtureHttp {
    responses: Mutex<std::collections::VecDeque<Result<HttpResponse, ProviderError>>>,
    requests: Mutex<Vec<HttpRequest>>,
}

impl FixtureHttp {
    pub(super) fn new(responses: Vec<Result<HttpResponse, ProviderError>>) -> Self {
        Self {
            responses: Mutex::new(responses.into()),
            requests: Mutex::new(Vec::new()),
        }
    }

    pub(super) fn requests(&self) -> Vec<HttpRequest> {
        self.requests.lock().unwrap().clone()
    }
}

impl HttpClient for FixtureHttp {
    fn send(
        &self,
        request: HttpRequest,
        cancellation: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        cancellation.check().map_err(ProviderError::from_runtime)?;
        self.requests.lock().unwrap().push(request);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| {
                Err(ProviderError::new(
                    "FIXTURE_EXHAUSTED",
                    "test",
                    "fixture response 不足",
                    false,
                ))
            })
    }
}

pub(super) fn provider_request(_app: &str, credential: Value) -> ProviderRequest {
    ProviderRequest {
        account_id: None,
        captured_at: "2026-08-21T00:00:00Z".to_owned(),
        timeout: Duration::from_secs(8),
        max_response_body_bytes: RuntimeLimits::default().response_body_bytes,
        credential: Some(credential),
    }
}

pub(super) fn response(body: &str) -> Result<HttpResponse, ProviderError> {
    Ok(HttpResponse {
        status: 200,
        body: body.as_bytes().to_vec(),
    })
}

#[test]
fn catalog_is_stable_and_rejects_duplicate_accounts() {
    let mut input = CatalogInput::default();
    input.accounts.insert(
        "kimi".to_owned(),
        vec![
            AccountDescriptor {
                account_id: "z-account".to_owned(),
                display_name: None,
            },
            AccountDescriptor {
                account_id: "a-account".to_owned(),
                display_name: Some("Kimi · A".to_owned()),
            },
        ],
    );
    input.enabled_official.insert("claude".to_owned());
    let services = resolve_service_catalog(&input).unwrap();
    assert_eq!(services[0].id, "kimi_coding_a-account");
    assert_eq!(services[1].id, "kimi_coding_z-account");
    assert_eq!(services[2].id, "claude");
    let mut duplicate = input;
    duplicate
        .accounts
        .get_mut("kimi")
        .unwrap()
        .push(AccountDescriptor {
            account_id: "a-account".to_owned(),
            display_name: None,
        });
    assert!(resolve_service_catalog(&duplicate).is_err());
}

#[test]
fn response_body_and_service_template_are_bounded() {
    assert_eq!(
        bounded_http_body(
            HttpResponse {
                status: 200,
                body: br#"{"ok":true}"#.to_vec(),
            },
            128,
        )
        .unwrap(),
        br#"{"ok":true}"#.to_vec()
    );
    assert!(bounded_http_body(
        HttpResponse {
            status: 200,
            body: vec![b'x'; 129],
        },
        128,
    )
    .is_err());
    let rate_limit = bounded_http_body(
        HttpResponse {
            status: 429,
            body: br#"{"error":"rate limited"}"#.to_vec(),
        },
        128,
    )
    .unwrap_err();
    assert_eq!(rate_limit.diagnostic.code, "PROVIDER_RATE_LIMIT");
    assert!(rate_limit.diagnostic.message.contains("HTTP 429"));
    let server_error = bounded_http_body(
        HttpResponse {
            status: 502,
            body: b"<html>bad gateway</html>".to_vec(),
        },
        128,
    )
    .unwrap_err();
    assert_eq!(server_error.diagnostic.code, "PROVIDER_SERVER_ERROR");
    assert!(server_error.diagnostic.message.contains("HTTP 502"));
    let client_error = bounded_http_body(
        HttpResponse {
            status: 404,
            body: b"not found".to_vec(),
        },
        128,
    )
    .unwrap_err();
    assert_eq!(client_error.diagnostic.code, "PROVIDER_HTTP_STATUS");
    assert!(client_error.diagnostic.message.contains("HTTP 404"));
    let parsed: Value = serde_json::from_slice(
        &bounded_http_body(
            HttpResponse {
                status: 200,
                body: br#"{"windows":[]}"#.to_vec(),
            },
            128,
        )
        .unwrap(),
    )
    .unwrap();
    assert!(parsed.is_object());
    let service = super::ServiceDescriptor {
        id: "kimi_coding_a".to_owned(),
        name: "Kimi · A".to_owned(),
        app: "kimi".to_owned(),
        is_current: false,
    };
    let value = service_template(&service, "2026-08-21T00:00:00+00:00");
    assert_eq!(value["status"], "ok");
}

#[test]
fn catalog_input_uses_ordered_maps_without_hash_iteration() {
    let input = CatalogInput {
        accounts: BTreeMap::new(),
        enabled_official: BTreeSet::new(),
    };
    assert!(resolve_service_catalog(&input).unwrap().is_empty());
}

#[test]
fn provider_registry_resolves_only_supported_stable_app_ids() {
    for app in [
        "opencode-go",
        "kimi",
        "deepseek",
        "zhipu",
        "volcengine",
        "claude",
        "grok",
        "codex",
        "stepfun",
    ] {
        assert_eq!(super::provider_for_app(app).unwrap().app(), app);
    }
    assert_eq!(super::provider_for_app("codex").unwrap().app(), "codex");
    let _ = UreqHttpClient::default();
}

#[test]
fn stepfun_parser_handles_credit_rate_limit_and_windows() {
    let payload = json!({
        "code": 0,
        "message": "success",
        "plan_name": "Plus",
        "plan_credit_rate_limit": {
            "subscription_credit_left_rate": 0.9641,
            "topup_credit_left_rate": 0.8,
            "credit_buckets": [
                {
                    "total_credit": 1600000000_i64,
                    "left_credit": 1542560000_i64,
                    "reset_time": 1789900000_i64
                }
            ]
        },
        "five_hour_usage_left_rate": 0.99,
        "five_hour_usage_reset_time": 1789900000_i64,
        "weekly_usage_left_rate": 0.95,
        "weekly_usage_reset_time": 1789900000_i64
    });
    let result = parse_stepfun_usage(&payload).unwrap().unwrap();
    assert_eq!(result["kind"], "windows");
    assert_eq!(result["plan"], "Plus");
    let windows = result["windows"].as_array().unwrap();
    assert_eq!(windows.len(), 4);
    assert_eq!(windows[0]["label"], "Credits");
    assert!((windows[0]["usedPercent"].as_f64().unwrap() - 3.59).abs() < 0.01);
    assert_eq!(windows[0]["resetsAt"], 1789900000);
    assert_eq!(windows[1]["label"], "加油包 Credits");
    assert!((windows[1]["usedPercent"].as_f64().unwrap() - 20.0).abs() < 0.01);
    assert_eq!(windows[2]["label"], "5小时窗口");
    assert_eq!(windows[3]["label"], "每周窗口");
}

#[test]
fn stepfun_parser_handles_remote_rejected_error() {
    let payload = json!({
        "code": 401,
        "message": "invalid token"
    });
    let error = parse_stepfun_usage(&payload).unwrap_err();
    assert_eq!(error.diagnostic.code, "PROVIDER_REMOTE_REJECTED");
    let _ = StepFunProvider;
}

#[test]
fn stepfun_parser_handles_real_plan_family_credit_response() {
    let payload = json!({
        "status": 1,
        "desc": "",
        "five_hour_usage_left_rate": 0,
        "five_hour_usage_reset_time": "0",
        "weekly_usage_left_rate": 0,
        "weekly_usage_reset_time": "0",
        "plan_family": 2,
        "plan_credit_rate_limit": {
            "subscription_credit_left_rate": 0.96789026,
            "subscription_credit_reset_time": "1792485144",
            "topup_credit_left_rate": 0,
            "credit_buckets": [
                {
                    "type": 1,
                    "credit_total": "1600000000",
                    "credit_residual": "1548624323",
                    "expire_at": "1795059029",
                    "next_reset_at": "1792485144"
                }
            ]
        }
    });
    let result = parse_stepfun_usage(&payload).unwrap().unwrap();
    assert_eq!(result["kind"], "windows");
    let windows = result["windows"].as_array().unwrap();
    assert_eq!(windows.len(), 1);
    assert_eq!(windows[0]["label"], "Credits");
    assert!((windows[0]["usedPercent"].as_f64().unwrap() - 3.21).abs() < 0.05);
    assert_eq!(windows[0]["resetsAt"], 1792485144);
}

#[test]
fn stepfun_device_id_extractor_handles_jwt_payload() {
    // Base64Url-encoded payload: {"app_id":10300,"device_id":"test-device-uuid-1234"}
    let dummy_jwt = "eyJhbGciOiJIUzI1NiJ9.eyJhcHBfaWQiOjEwMzAwLCJkZXZpY2VfaWQiOiJ0ZXN0LWRldmljZS11dWlkLTEyMzQifQ.signature";
    assert_eq!(
        extract_stepfun_device_id(dummy_jwt).as_deref(),
        Some("test-device-uuid-1234")
    );
    let multi_part = format!("header.part1.sig...{dummy_jwt}");
    assert_eq!(
        extract_stepfun_device_id(&multi_part).as_deref(),
        Some("test-device-uuid-1234")
    );
}

#[test]
fn stepfun_token_expiry_detector_handles_jwt_exp() {
    let expired_jwt = "header.eyJleHAiOiAxNzAwMDAwMDAwfQ.sig...header.payload2.sig";
    let fresh_jwt = "header.eyJleHAiOiAyMTAwMDAwMDAwfQ.sig...header.payload2.sig";
    let now_epoch = 1780000000;
    assert!(is_stepfun_token_expired(expired_jwt, now_epoch));
    assert!(!is_stepfun_token_expired(fresh_jwt, now_epoch));
    assert!(!is_stepfun_token_expired("not-a-jwt", now_epoch));
}

#[test]
fn stepfun_provider_refreshes_token_on_401_and_retries() {
    let old_token =
        "header.part1.sig...header.eyJhcHBfaWQiOjEwMzAwLCJkZXZpY2VfaWQiOiJkZXYtMSJ9.sig";
    let refresh_resp = json!({
        "accessToken": {"raw": "header.new_part1.sig"},
        "refreshToken": {"raw": "header.new_part2.sig"}
    });
    let quota_resp = json!({
        "status": 1,
        "desc": "",
        "plan_credit_rate_limit": {
            "subscription_credit_left_rate": 0.85,
            "subscription_credit_reset_time": "1792485144",
            "credit_buckets": []
        }
    });
    let http = FixtureHttp::new(vec![
        // 1. Initial query returns 401
        Ok(HttpResponse {
            status: 401,
            body: b"unauthenticated".to_vec(),
        }),
        // 2. Refresh request returns 200 with new tokens
        Ok(HttpResponse {
            status: 200,
            body: serde_json::to_vec(&refresh_resp).unwrap(),
        }),
        // 3. Retry query returns 200 with quota
        Ok(HttpResponse {
            status: 200,
            body: serde_json::to_vec(&quota_resp).unwrap(),
        }),
    ]);
    let request = ProviderRequest {
        account_id: Some("test-acc".to_owned()),
        captured_at: "2026-09-21T00:00:00Z".to_owned(),
        timeout: Duration::from_secs(5),
        max_response_body_bytes: 65536,
        credential: Some(json!({ "token": old_token })),
    };
    let cancel = CancellationToken::default();
    let result = StepFunProvider
        .query(&request, &http, &cancel)
        .unwrap()
        .unwrap();
    assert_eq!(result["kind"], "windows");
    assert_eq!(
        result["credential_update"]["access_token"],
        "header.new_part1.sig...header.new_part2.sig"
    );
    let requests = http.requests();
    assert_eq!(requests.len(), 3);
    assert_eq!(requests[0].url, STEPFUN_STEP_PLAN_RATE_LIMIT_URL);
    assert_eq!(requests[1].url, STEPFUN_REFRESH_TOKEN_URL);
    assert_eq!(requests[2].url, STEPFUN_STEP_PLAN_RATE_LIMIT_URL);
}

#[test]
fn stepfun_app_id_and_site_detector_identifies_domestic_and_global_tokens() {
    // domestic: app_id 10300
    let domestic_jwt =
        "header.part1.sig...header.eyJhcHBfaWQiOjEwMzAwLCJkZXZpY2VfaWQiOiJkZXYtMSJ9.sig";
    assert_eq!(extract_stepfun_app_id(domestic_jwt), Some(10300));
    let req_domestic = ProviderRequest {
        account_id: Some("test".to_owned()),
        captured_at: "2026-09-21T00:00:00Z".to_owned(),
        timeout: Duration::from_secs(5),
        max_response_body_bytes: 65536,
        credential: Some(json!({ "token": domestic_jwt })),
    };
    assert!(!is_stepfun_global(domestic_jwt, &req_domestic));

    // global: app_id 20700
    let global_jwt =
        "header.part1.sig...header.eyJhcHBfaWQiOjIwNzAwLCJkZXZpY2VfaWQiOiJkZXYtMiJ9.sig";
    assert_eq!(extract_stepfun_app_id(global_jwt), Some(20700));
    let req_global = ProviderRequest {
        account_id: Some("test".to_owned()),
        captured_at: "2026-09-21T00:00:00Z".to_owned(),
        timeout: Duration::from_secs(5),
        max_response_body_bytes: 65536,
        credential: Some(json!({ "token": global_jwt })),
    };
    assert!(is_stepfun_global(global_jwt, &req_global));

    // override via credential.site = "global"
    let req_override = ProviderRequest {
        account_id: Some("test".to_owned()),
        captured_at: "2026-09-21T00:00:00Z".to_owned(),
        timeout: Duration::from_secs(5),
        max_response_body_bytes: 65536,
        credential: Some(json!({ "token": domestic_jwt, "site": "global" })),
    };
    assert!(is_stepfun_global(domestic_jwt, &req_override));

    // C093 / 设计规则 28: 显式选择优先于令牌推导, 反向亦然 (国内站选择覆盖国际站令牌)。
    let req_override_domestic = ProviderRequest {
        account_id: Some("test".to_owned()),
        captured_at: "2026-09-21T00:00:00Z".to_owned(),
        timeout: Duration::from_secs(5),
        max_response_body_bytes: 65536,
        credential: Some(json!({ "token": global_jwt, "site": "domestic" })),
    };
    assert!(!is_stepfun_global(global_jwt, &req_override_domestic));

    // 未写入 site (C093 起前端不再写默认站点) 时, 国际站令牌必须判为国际站 ——
    // 这正是「国际站令牌被默认国内站查错站点」的回归锁。
    let req_token_only = ProviderRequest {
        account_id: Some("test".to_owned()),
        captured_at: "2026-09-21T00:00:00Z".to_owned(),
        timeout: Duration::from_secs(5),
        max_response_body_bytes: 65536,
        credential: Some(json!({ "token": global_jwt })),
    };
    assert!(is_stepfun_global(global_jwt, &req_token_only));
}

#[test]
fn stepfun_provider_routes_to_global_endpoints_when_global_token() {
    let global_token =
        "header.part1.sig...header.eyJhcHBfaWQiOjIwNzAwLCJkZXZpY2VfaWQiOiJkZXYtZ2xvYmFsIn0.sig";
    let refresh_resp = json!({
        "accessToken": {"raw": "header.new_global1.sig"},
        "refreshToken": {"raw": "header.new_global2.sig"}
    });
    let quota_resp = json!({
        "status": 1,
        "desc": "",
        "plan_credit_rate_limit": {
            "subscription_credit_left_rate": 0.9,
            "subscription_credit_reset_time": "1792485144",
            "credit_buckets": []
        }
    });
    let http = FixtureHttp::new(vec![
        Ok(HttpResponse {
            status: 401,
            body: b"unauthenticated".to_vec(),
        }),
        Ok(HttpResponse {
            status: 200,
            body: serde_json::to_vec(&refresh_resp).unwrap(),
        }),
        Ok(HttpResponse {
            status: 200,
            body: serde_json::to_vec(&quota_resp).unwrap(),
        }),
    ]);
    let request = ProviderRequest {
        account_id: Some("test-global-acc".to_owned()),
        captured_at: "2026-09-21T00:00:00Z".to_owned(),
        timeout: Duration::from_secs(5),
        max_response_body_bytes: 65536,
        credential: Some(json!({ "token": global_token })),
    };
    let cancel = CancellationToken::default();
    let result = StepFunProvider
        .query(&request, &http, &cancel)
        .unwrap()
        .unwrap();
    assert_eq!(result["kind"], "windows");
    assert_eq!(
        result["credential_update"]["access_token"],
        "header.new_global1.sig...header.new_global2.sig"
    );
    let requests = http.requests();
    assert_eq!(requests.len(), 3);
    assert_eq!(requests[0].url, STEPFUN_GLOBAL_STEP_PLAN_RATE_LIMIT_URL);
    assert_eq!(requests[0].headers["Oasis-appID"], "20700");
    assert_eq!(requests[1].url, STEPFUN_GLOBAL_REFRESH_TOKEN_URL);
    assert_eq!(requests[1].headers["Oasis-appID"], "20700");
    assert_eq!(requests[1].headers["Origin"], "https://platform.stepfun.ai");
    assert_eq!(requests[2].url, STEPFUN_GLOBAL_STEP_PLAN_RATE_LIMIT_URL);
    assert_eq!(requests[0].headers["Oasis-Webid"], "dev-global");
}

#[test]
fn codex_credits_map_to_structured_balance_and_vanish_at_zero() {
    // 有余额: 结构化 balance + credits 判别键, 不再有余额 extra 文本。
    let parsed = parse_codex_usage(&json!({
        "plan_type": "plus",
        "rate_limit": {},
        "credits": {"has_credits": true, "balance": 2998.116571}
    }))
    .unwrap()
    .unwrap();
    assert_eq!(parsed["balance"], 2998.116571);
    assert_eq!(parsed["currency"], "credits");
    assert!(parsed.get("extra").is_none());

    // 归零: 不产出 balance (下一次刷新条目自动消失)。
    let parsed = parse_codex_usage(&json!({
        "plan_type": "plus",
        "rate_limit": {},
        "credits": {"has_credits": true, "balance": 0.0}
    }))
    .unwrap()
    .unwrap();
    assert!(parsed.get("balance").is_none());
    assert!(parsed.get("extra").is_none());

    // 耗尽 (has_credits=false): 同样不产出。
    let parsed = parse_codex_usage(&json!({
        "plan_type": "plus",
        "rate_limit": {},
        "credits": {"has_credits": false, "balance": 12.0}
    }))
    .unwrap()
    .unwrap();
    assert!(parsed.get("balance").is_none());

    // 不限量: 维持 extra 文本, 无 balance。
    let parsed = parse_codex_usage(&json!({
        "plan_type": "plus",
        "rate_limit": {},
        "credits": {"unlimited": true}
    }))
    .unwrap()
    .unwrap();
    assert_eq!(parsed["extra"], "Credits 不限量");
    assert!(parsed.get("balance").is_none());
}

#[test]
fn codex_parser_and_provider_preserve_account_quota_contract() {
    let parsed = parse_codex_usage(&json!({
        "plan_type": "fixture-plan",
        "rate_limit": {
            "primary_window": {
                "limit_window_seconds": 18000,
                "used_percent": 42,
                "reset_at": "2026-08-21T17:00:00+08:00"
            },
            "secondary_window": {
                "limit_window_seconds": 604800,
                "used_percent": 12.5,
                "reset_at": 1785000000
            }
        },
        "credits": {"unlimited": true}
    }))
    .unwrap()
    .unwrap();
    assert_eq!(parsed["kind"], "windows");
    assert_eq!(parsed["plan"], "fixture-plan");
    assert_eq!(parsed["windows"][0]["label"], "5小时窗口");
    assert_eq!(parsed["windows"][0]["windowMinutes"], 300);
    assert_eq!(parsed["windows"][0]["usedPercent"], 42.0);
    assert_eq!(parsed["extra"], "Credits 不限量");
    assert_eq!(
        codex_service_id("acc-1"),
        "codex_".to_owned() + &sha256_prefix("acc-1")
    );

    let http = FixtureHttp::new(vec![response(
        r#"{"plan_type":"fixture-plan","rate_limit":{"primary_window":{"limit_window_seconds":18000,"used_percent":42,"reset_at":"2026-08-21T17:00:00+08:00"}}}"#,
    )]);
    let mut request = provider_request(
        "codex",
        json!({"display_name": "Codex · user", "access_token": "fixture-token"}),
    );
    request.account_id = Some("acc-1".to_owned());
    let result = CodexProvider
        .query(&request, &http, &CancellationToken::new())
        .unwrap()
        .unwrap();
    assert_eq!(result["windows"][0]["usedPercent"], 42.0);
    let sent = &http.requests()[0];
    assert_eq!(sent.url, super::CODEX_USAGE_URL);
    assert_eq!(sent.headers["Authorization"], "Bearer fixture-token");
    assert_eq!(sent.headers["chatgpt-account-id"], "acc-1");
    assert!(!sent.url.contains("fixture-token"));
}

fn sha256_prefix(value: &str) -> String {
    let digest = sha2::Sha256::digest(value.as_bytes());
    format!("{:x}", digest)[..16].to_owned()
}

#[test]
fn codex_401_is_auth_error_without_secret_in_diagnostic() {
    let secret = "fixture-codex-token";
    let http = FixtureHttp::new(vec![Ok(HttpResponse {
        status: 401,
        body: br#"{"error":"unauthorized"}"#.to_vec(),
    })]);
    let mut request = provider_request("codex", json!({"access_token": secret}));
    request.account_id = Some("acc-1".to_owned());
    let error = CodexProvider
        .query(&request, &http, &CancellationToken::new())
        .unwrap_err();
    assert_eq!(error.diagnostic.code, "PROVIDER_AUTH_REJECTED");
    assert!(error.diagnostic.message.contains("HTTP 401"));
    assert!(!error.diagnostic.message.contains(secret));
}

#[test]
fn zhipu_query_parses_quota_and_uses_monitor_endpoint() {
    let secret = "fixture-zhipu-secret";
    let http = FixtureHttp::new(vec![response(
        r#"{"success":true,"data":{"level":"pro","limits":[{"type":"TOKENS_LIMIT","unit":3,"percentage":18.0,"nextResetTime":1800000000000}]}}"#,
    )]);
    let result = ZhipuProvider
        .query(
            &provider_request(
                "zhipu",
                json!({
                    "api_key": secret,
                    "base_url": "https://open.bigmodel.cn/api/paas/v4"
                }),
            ),
            &http,
            &CancellationToken::new(),
        )
        .unwrap()
        .unwrap();
    assert_eq!(result["plan"], "pro");
    assert_eq!(result["windows"][0]["usedPercent"], 18.0);
    let sent = &http.requests()[0];
    assert_eq!(
        sent.url,
        "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
    );
    assert_eq!(sent.headers["Authorization"], secret);
    assert!(!sent.url.contains(secret));
}

#[test]
fn zhipu_non_json_response_keeps_status_without_response_body() {
    let secret = "fixture-zhipu-secret";
    let http = FixtureHttp::new(vec![Ok(HttpResponse {
        status: 200,
        body: b"<html>gateway response</html>".to_vec(),
    })]);
    let error = ZhipuProvider
        .query(
            &provider_request(
                "zhipu",
                json!({
                    "api_key": secret,
                    "base_url": "https://open.bigmodel.cn/api/paas/v4"
                }),
            ),
            &http,
            &CancellationToken::new(),
        )
        .unwrap_err();
    assert_eq!(error.diagnostic.code, "PROVIDER_INVALID_JSON");
    assert_eq!(
        error.diagnostic.message,
        "Provider 响应不是有效 JSON (HTTP 200)"
    );
    assert!(!error.diagnostic.message.contains(secret));
    assert!(!error.diagnostic.message.contains("gateway response"));
}

#[test]
fn zhipu_http_failures_are_not_reported_as_invalid_json() {
    let credential = json!({
        "api_key": "fixture-zhipu-secret",
        "base_url": "https://api.z.ai/api/paas/v4"
    });
    let rate_limit = FixtureHttp::new(vec![Ok(HttpResponse {
        status: 429,
        body: br#"{"message":"too many requests"}"#.to_vec(),
    })]);
    let error = ZhipuProvider
        .query(
            &provider_request("zhipu", credential.clone()),
            &rate_limit,
            &CancellationToken::new(),
        )
        .unwrap_err();
    assert_eq!(error.diagnostic.code, "PROVIDER_RATE_LIMIT");
    assert!(error.diagnostic.message.contains("HTTP 429"));

    let server_error = FixtureHttp::new(vec![Ok(HttpResponse {
        status: 502,
        body: b"<html>bad gateway</html>".to_vec(),
    })]);
    let error = ZhipuProvider
        .query(
            &provider_request("zhipu", credential),
            &server_error,
            &CancellationToken::new(),
        )
        .unwrap_err();
    assert_eq!(error.diagnostic.code, "PROVIDER_SERVER_ERROR");
    assert!(error.diagnostic.message.contains("HTTP 502"));
}

#[test]
fn zhipu_business_error_json_is_not_misclassified_as_invalid_json() {
    let http = FixtureHttp::new(vec![response(
        r#"{"success":false,"code":1000,"msg":"Authentication Failed"}"#,
    )]);
    let error = ZhipuProvider
        .query(
            &provider_request(
                "zhipu",
                json!({
                    "api_key": "fixture-zhipu-secret",
                    "base_url": "https://api.z.ai/api/paas/v4"
                }),
            ),
            &http,
            &CancellationToken::new(),
        )
        .unwrap_err();
    assert_eq!(error.diagnostic.code, "PROVIDER_REMOTE_REJECTED");
    assert!(!error.diagnostic.message.contains("Authentication Failed"));
}

#[test]
fn provider_parsers_preserve_quota_shapes_and_reset_units() {
    let kimi = parse_kimi_usage(&json!({
            "limits": [{"detail": {"limit": 100, "remaining": 25, "resetTime": "2026-08-21T01:00:00Z"}}],
            "usage": {"limit": 200, "remaining": 100, "resetTime": "2026-08-22T00:00:00Z"}
        }))
        .unwrap()
        .unwrap();
    assert_eq!(kimi["windows"][0]["usedPercent"], 75.0);
    assert_eq!(kimi["windows"][0]["windowMinutes"], 300);
    assert_eq!(kimi["windows"][1]["windowMinutes"], 10080);

    let deepseek = parse_deepseek_balance(&json!({
        "balance_infos": [{"total_balance": "12.5", "currency": "USD"}]
    }))
    .unwrap()
    .unwrap();
    assert_eq!(deepseek["balance"], 12.5);
    assert_eq!(deepseek["currency"], "USD");

    let zhipu = parse_zhipu_usage(&json!({
            "success": true,
            "data": {
                "level": "pro",
                "limits": [
                    {"type": "CREDIT_LIMIT", "unit": 3, "percentage": 18.0, "nextResetTime": 1_800_000_000_000i64},
                    {"type": "TOKENS_LIMIT", "unit": 6, "percentage": 42.0, "nextResetTime": 1_800_100_000i64},
                    {"type": "TIME_LIMIT", "unit": 3, "percentage": 99.0}
                ]
            }
        }))
        .unwrap()
        .unwrap();
    assert_eq!(zhipu["plan"], "pro");
    assert_eq!(zhipu["windows"].as_array().unwrap().len(), 2);
    assert_eq!(zhipu["windows"][0]["resetsAt"], 1_800_000_000);

    let volc = parse_volcengine_usage(&json!({
        "QuotaUsage": [
            {"Level": "session", "Percent": 101.0, "ResetTimestamp": -1},
            {"Level": "weekly", "Percent": 33.0, "ResetTimestamp": 1_800_000_000}
        ]
    }))
    .unwrap()
    .unwrap();
    assert_eq!(volc["windows"][0]["usedPercent"], 100.0);
    assert_eq!(volc["windows"][0]["resetsAt"], Value::Null);
    assert_eq!(volc["windows"][1]["resetsAt"], 1_800_000_000);

    let claude = parse_claude_usage(&json!({
        "five_hour": {"utilization": 7.0, "resets_at": "2026-08-21T02:00:00Z"},
        "extra_usage": {"is_enabled": true, "utilization": 3.0},
        "inactive": {"status": "not_subscribed", "utilization": 99.0}
    }))
    .unwrap()
    .unwrap();
    assert_eq!(claude["windows"].as_array().unwrap().len(), 3);
    assert!(claude["windows"]
        .as_array()
        .unwrap()
        .iter()
        .any(|window| window["ownRow"] == true));
}

/// C058: limits[] weekly_scoped 模型专属周限额被解析 (对照 cc-switch 用例)。
fn scoped_limit(model: &str, percent: Value, resets_at: Value, surface: Value) -> Value {
    json!({
        "kind": "weekly_scoped",
        "group": "weekly",
        "percent": percent,
        "resets_at": resets_at,
        "is_active": true,
        "scope": { "model": { "id": null, "display_name": model }, "surface": surface }
    })
}

#[test]
fn claude_usage_renders_scoped_model_weekly_limits() {
    let claude = parse_claude_usage(&json!({
        "five_hour": { "utilization": 12.0, "resets_at": "2026-09-09T15:00:00Z" },
        "seven_day": { "utilization": 25.0, "resets_at": null },
        "seven_day_opus": null,
        "seven_day_sonnet": null,
        "limits": [scoped_limit("Fable", json!(37.5), json!("2026-09-12T00:00:00Z"), Value::Null)]
    }))
    .unwrap()
    .unwrap();
    let windows = claude["windows"].as_array().unwrap();
    assert_eq!(windows.len(), 3);
    let labels: Vec<&str> = windows
        .iter()
        .map(|window| window["label"].as_str().unwrap())
        .collect();
    assert_eq!(labels, ["每 5 小时", "每周", "每周 Fable"]);
    assert_eq!(windows[2]["usedPercent"], 37.5);
    assert_eq!(windows[2]["windowMinutes"], 10080);
    assert_eq!(windows[2]["resetsAt"], 1_789_171_200);
}

#[test]
fn claude_usage_scoped_limits_override_legacy_and_dedupe() {
    // 模型名 trim+小写归一; is_active=false 不过滤; 同名首条优先 (0% 胜过 90%);
    // 覆盖同名旧版顶层窗口 (Fable 80 → 0)。
    let claude = parse_claude_usage(&json!({
        "seven_day_fable": { "utilization": 80.0, "resets_at": "2026-09-11T00:00:00Z" },
        "seven_day_opus": { "utilization": 20.0 },
        "seven_day_sonnet": { "utilization": 30.0 },
        "limits": [
            scoped_limit("Sonnet", json!(5.0), json!("2026-09-12T00:00:00Z"), Value::Null),
            scoped_limit("  fAbLe  ", json!(0.0), Value::Null, Value::Null),
            scoped_limit("Fable", json!(90.0), json!("2026-09-13T00:00:00Z"), Value::Null),
            scoped_limit("Opus", json!(6.0), json!("2026-09-14T00:00:00Z"), Value::Null)
        ]
    }))
    .unwrap()
    .unwrap();
    let windows = claude["windows"].as_array().unwrap();
    let rendered: Vec<(&str, &Value)> = windows
        .iter()
        .map(|window| (window["label"].as_str().unwrap(), &window["usedPercent"]))
        .collect();
    assert_eq!(
        rendered,
        [
            ("每周 Fable", &json!(0.0)),
            ("每周 Opus", &json!(6.0)),
            ("每周 Sonnet", &json!(5.0))
        ]
    );
    assert_eq!(windows[0]["resetsAt"], Value::Null);
}

#[test]
fn claude_usage_skips_invalid_scoped_rows_and_dirty_windows() {
    let mut invalid = vec![Value::Null, json!("invalid")];
    for (pointer, value) in [
        ("/kind", json!("spend")),
        ("/group", json!("daily")),
        ("/percent", Value::Null),
        ("/percent", json!("37")),
        ("/percent", json!(-1)),
        ("/resets_at", json!(123)),
        ("/scope/model/display_name", Value::Null),
        ("/scope/model/display_name", json!("Unknown")),
        ("/scope/surface", json!("claude_code")),
    ] {
        let mut row = scoped_limit(
            "Fable",
            json!(37.0),
            json!("2026-09-12T00:00:00Z"),
            Value::Null,
        );
        *row.pointer_mut(pointer).unwrap() = value;
        invalid.push(row);
    }
    let mut payload = json!({
        "five_hour": { "utilization": 12.0 },
        "seven_day_fable": { "utilization": 8.0 },
        // 脏窗口逐条跳过, 不再让整卡报错 (C058 前为 invalid_payload 错误)。
        "dirty": { "utilization": "not-a-number" },
        "limits": invalid
    });
    let fallback = parse_claude_usage(&payload).unwrap().unwrap();
    let fallback_windows = fallback["windows"].as_array().unwrap();
    assert_eq!(fallback_windows.len(), 2);
    assert_eq!(fallback_windows[1]["usedPercent"], 8.0);
    payload["limits"].as_array_mut().unwrap().push(scoped_limit(
        "Fable",
        json!(37.0),
        json!("2026-09-12T00:00:00Z"),
        Value::Null,
    ));
    let claude = parse_claude_usage(&payload).unwrap().unwrap();
    let windows = claude["windows"].as_array().unwrap();
    assert_eq!(windows.len(), 2);
    assert_eq!(windows[0]["usedPercent"], 12.0);
    assert_eq!(windows[1]["usedPercent"], 37.0);
}

#[test]
fn claude_usage_does_not_invent_windows_from_empty_limits() {
    for limits in [Value::Null, json!([]), json!({})] {
        let claude = parse_claude_usage(&json!({
            "five_hour": { "utilization": 12.0 },
            "limits": limits
        }))
        .unwrap()
        .unwrap();
        let windows = claude["windows"].as_array().unwrap();
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0]["label"], "每 5 小时");
    }
    let only_scoped = parse_claude_usage(&json!({
        "limits": [scoped_limit("Fable", json!(100.0), Value::Null, Value::Null)]
    }))
    .unwrap()
    .unwrap();
    let windows = only_scoped["windows"].as_array().unwrap();
    assert_eq!(windows.len(), 1);
    assert_eq!(windows[0]["label"], "每周 Fable");
    assert_eq!(windows[0]["usedPercent"], 100.0);
}

#[test]
fn zhipu_current_credit_limit_array_response_is_rendered() {
    let zhipu = parse_zhipu_usage(&json!({
        "code": 200,
        "message": "success",
        "data": [
            {
                "type": "CREDIT_LIMIT",
                "unit": 3,
                "number": 5,
                "currentValue": 5,
                "remaining": 0,
                "nextResetTime": 1_800_000_000_000i64
            },
            {
                "type": "CREDIT_LIMIT",
                "unit": 6,
                "number": 1,
                "currentValue": 2,
                "remaining": 8,
                "nextResetTime": 1_800_100_000_000i64
            }
        ]
    }))
    .unwrap()
    .unwrap();

    assert_eq!(zhipu["plan"], Value::Null);
    assert_eq!(zhipu["windows"].as_array().unwrap().len(), 2);
    assert_eq!(zhipu["windows"][0]["label"], "每 5 小时");
    assert_eq!(zhipu["windows"][0]["usedPercent"], 100.0);
    assert_eq!(zhipu["windows"][0]["resetsAt"], 1_800_000_000);
    assert_eq!(zhipu["windows"][1]["label"], "每周");
    assert_eq!(zhipu["windows"][1]["usedPercent"], 20.0);
    assert_eq!(zhipu["windows"][1]["resetsAt"], 1_800_100_000);
}

#[test]
fn opencode_seroval_parser_omits_unsubscribed_windows() {
    let body = br#";((self.$R=self.$R||{})["server-fn:x"]=[],($R=>$R[0]={mine:!0,rollingUsage:{status:"ok",usagePercent:12.5,resetInSec:60},weeklyUsage:{status:"ok",usagePercent:20,resetInSec:3600},monthlyUsage:{status:"not_subscribed",usagePercent:99}})($R["server-fn:x"]))"#;
    let parsed = parse_opencode_go_body(body, 1_800_000_000)
        .unwrap()
        .unwrap();
    assert_eq!(parsed["windows"].as_array().unwrap().len(), 2);
    assert_eq!(parsed["windows"][0]["usedPercent"], 12.5);
    assert_eq!(parsed["windows"][0]["resetsAt"], 1_800_000_060i64);
}

#[test]
fn grok_parser_handles_bounded_grpc_web_heuristic() {
    let reset = 1_800_000_100u64;
    let nested_reset = {
        let mut value = vec![0x08];
        value.extend(encode_varint(reset));
        value
    };
    let mut nested = vec![0x2a, nested_reset.len() as u8];
    nested.extend(nested_reset);
    nested.extend([0x30, 0x01]);
    let mut body = vec![0x0d];
    body.extend(20.0f32.to_le_bytes());
    body.extend([0x0a, nested.len() as u8]);
    body.extend(nested);
    let parsed = parse_grok_usage(&body, 1_800_000_000).unwrap().unwrap();
    assert_eq!(parsed["windows"][0]["usedPercent"], 20.0);
    assert_eq!(parsed["windows"][0]["label"], "每 5 小时");
}

fn encode_varint(mut value: u64) -> Vec<u8> {
    let mut output = Vec::new();
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        output.push(byte);
        if value == 0 {
            return output;
        }
    }
}
