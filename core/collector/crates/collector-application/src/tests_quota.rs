//! 额度通道: 出口校验、账号编排、retryOnly 与凭据轮换输出。

use crate::collect_agent_usage_with_dependencies;
use collector_domain::BridgeRequest;
use collector_provider::{codex_service_id, HttpClient, HttpRequest, HttpResponse, ProviderError};
use collector_runtime::CancellationToken;
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::tests_support::*;

struct EgressFixtureHttp {
    loc: &'static str,
    direct: AtomicUsize,
    proxy: AtomicUsize,
    probes: AtomicUsize,
}

impl HttpClient for EgressFixtureHttp {
    fn send(&self, _: HttpRequest, _: &CancellationToken) -> Result<HttpResponse, ProviderError> {
        self.direct.fetch_add(1, Ordering::SeqCst);
        Ok(HttpResponse {
            status: 200,
            body: b"{}".to_vec(),
        })
    }

    fn send_via_loopback_proxy(
        &self,
        port: u16,
        request: HttpRequest,
        _: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        assert_eq!(port, 12345);
        if request.url.contains("cdn-cgi/trace") {
            self.probes.fetch_add(1, Ordering::SeqCst);
            if self.loc == "FAIL" {
                return Err(ProviderError::new(
                    "TEST_TIMEOUT",
                    "request",
                    "timeout",
                    true,
                ));
            }
            return Ok(HttpResponse {
                status: 200,
                body: format!("ip=192.0.2.1\nloc={}\n", self.loc).into_bytes(),
            });
        }
        self.proxy.fetch_add(1, Ordering::SeqCst);
        Ok(HttpResponse {
            status: 200,
            body: br#"{"is_available":true,"balance_infos":[]}"#.to_vec(),
        })
    }
}

#[test]
fn protected_quota_uses_proxy_and_blocks_mismatched_trace() {
    for (loc, expected_queries) in [("CN", 0), ("US", 0), ("FAIL", 0), ("JP", 1)] {
        let mut request = request(&["externalQuotas"]);
        request.context.insert(
            "egressRules".into(),
            json!({"deepseek":{"country":"JP","port":12345}}),
        );
        request.credentials.insert(
            "deepseekQuotaAccounts".into(),
            json!({
                "account": {"display_name":"fixture", "api_key":"fixture"}
            }),
        );
        let http = EgressFixtureHttp {
            loc,
            direct: AtomicUsize::new(0),
            proxy: AtomicUsize::new(0),
            probes: AtomicUsize::new(0),
        };
        let window = super::CollectionWindow::from_context(&request.context).unwrap();
        let context =
            super::RunContext::new(&request, window, &http, super::RuntimeLimits::default())
                .unwrap();
        let result = super::collect_quota_usage(&context);
        assert_eq!(http.direct.load(Ordering::SeqCst), 0);
        assert_eq!(http.probes.load(Ordering::SeqCst), 1);
        assert_eq!(http.proxy.load(Ordering::SeqCst), expected_queries);
        let state = &result.services[0]["egress"];
        assert_eq!(
            state["status"],
            if expected_queries == 0 {
                "blocked"
            } else {
                "allowed"
            }
        );
        if expected_queries == 0 {
            assert_eq!(result.services[0]["failureKind"], "network");
            let code = match loc {
                "CN" => "EGRESS_CN_DIRECT",
                "US" => "EGRESS_COUNTRY_MISMATCH",
                _ => "EGRESS_PROBE_TIMEOUT",
            };
            assert!(result.diagnostics.iter().any(|item| item.code == code));
            assert!(result.credential_challenges.is_empty());
        }
        assert!(!result.services[0].to_string().contains("192.0.2.1"));
    }
}

#[test]
fn unmanaged_quota_stays_on_original_transport() {
    let mut request = request(&["externalQuotas"]);
    request.context.insert("egressRules".into(), json!({}));
    request.credentials.insert(
        "deepseekQuotaAccounts".into(),
        json!({
            "account": {"display_name":"fixture", "api_key":"fixture"}
        }),
    );
    let http = EgressFixtureHttp {
        loc: "CN",
        direct: AtomicUsize::new(0),
        proxy: AtomicUsize::new(0),
        probes: AtomicUsize::new(0),
    };
    let window = super::CollectionWindow::from_context(&request.context).unwrap();
    let context =
        super::RunContext::new(&request, window, &http, super::RuntimeLimits::default()).unwrap();
    let result = super::collect_quota_usage(&context);
    assert_eq!(http.direct.load(Ordering::SeqCst), 1);
    assert_eq!(http.probes.load(Ordering::SeqCst), 0);
    assert_eq!(http.proxy.load(Ordering::SeqCst), 0);
    assert!(result.services[0].get("egress").is_none());
}

struct StatusFixtureHttp {
    calls: AtomicUsize,
    status: u16,
}

impl HttpClient for StatusFixtureHttp {
    fn send(
        &self,
        _request: HttpRequest,
        cancellation: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        cancellation.check().map_err(ProviderError::from_runtime)?;
        self.calls.fetch_add(1, Ordering::AcqRel);
        Ok(HttpResponse {
            status: self.status,
            body: br#"{"error":"fixture"}"#.to_vec(),
        })
    }
}

#[test]
fn application_executes_injected_quota_account_through_registry() {
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
            "kimiQuotaAccounts": {
                "acct-a": {"display_name": "Kimi A", "api_key": "fixture-key"}
            }
        }
    }))
    .unwrap();
    let http = FixtureHttp {
        calls: AtomicUsize::new(0),
        body: br#"{"limits":[{"detail":{"limit":100,"remaining":25,"resetTime":"2026-08-21T09:00:00Z"}}]}"#.to_vec(),
    };
    let output = collect_agent_usage_with_dependencies(&request, &http).unwrap();
    let services = output.artifact["services"].as_array().unwrap();
    assert_eq!(services.len(), 1);
    assert_eq!(services[0]["id"], "kimi_coding_acct-a");
    assert_eq!(services[0]["status"], "ok");
    assert_eq!(services[0]["windows"][0]["usedPercent"], 75.0);
    assert_eq!(output.metrics.http_request_count, 1);
    assert_eq!(http.calls.load(Ordering::Acquire), 1);
}

#[test]
fn application_executes_ordered_codex_accounts_with_stable_services() {
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
            "capabilities": ["externalQuotas"],
            "codexQuotaAccountOrder": ["acc-z", "acc-a"]
        },
        "credentials": {
            "codexQuotaAccounts": {
                "acc-a": {
                    "display_name": "Codex · A",
                    "access_token": "fixture-a"
                },
                "acc-z": {
                    "display_name": "Codex · Z",
                    "access_token": "fixture-z"
                }
            }
        }
    }))
    .unwrap();
    let http = FixtureHttp {
        calls: AtomicUsize::new(0),
        body: br#"{"plan_type":"fixture","rate_limit":{"primary_window":{"limit_window_seconds":18000,"used_percent":42,"reset_at":"2026-08-21T13:00:00Z"}}}"#.to_vec(),
    };
    let output = collect_agent_usage_with_dependencies(&request, &http).unwrap();
    let services = output.artifact["services"].as_array().unwrap();
    assert_eq!(services.len(), 2);
    assert_eq!(services[0]["id"], codex_service_id("acc-z"));
    assert_eq!(services[1]["id"], codex_service_id("acc-a"));
    assert_eq!(services[0]["name"], "Codex · Z");
    assert_eq!(services[0]["status"], "ok");
    assert_eq!(services[0]["windows"][0]["usedPercent"], 42.0);
    assert!(output.credential_challenges.is_empty());
    assert_eq!(output.metrics.http_request_count, 2);
    assert_eq!(http.calls.load(Ordering::Acquire), 2);
}

#[test]
fn application_emits_codex_challenge_without_credentials_in_output() {
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
            "capabilities": ["externalQuotas"],
            "codexQuotaAccountOrder": ["acc-1"]
        },
        "credentials": {
            "codexQuotaAccounts": {
                "acc-1": {
                    "display_name": "Codex · user",
                    "access_token": "fixture-secret-token"
                }
            }
        }
    }))
    .unwrap();
    let http = StatusFixtureHttp {
        calls: AtomicUsize::new(0),
        status: 401,
    };
    let output = collect_agent_usage_with_dependencies(&request, &http).unwrap();
    let service = &output.artifact["services"][0];
    assert_eq!(service["id"], codex_service_id("acc-1"));
    assert_eq!(service["status"], "error");
    assert_eq!(service["freshness"], "unavailable");
    assert_eq!(service["failureKind"], "auth");
    assert_eq!(
        output.credential_challenges,
        vec![json!({
            "provider": "codex",
            "accountId": "acc-1",
            "reason": "accessRejected"
        })]
    );
    let serialized = serde_json::to_string(&output.artifact).unwrap();
    assert!(!serialized.contains("fixture-secret-token"));
    assert_eq!(http.calls.load(Ordering::Acquire), 1);
}

#[test]
fn quota_retry_only_skips_local_agents_and_returns_only_quota_services() {
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
            "capabilities": ["externalQuotas"],
            "quotaRetryOnly": true,
            "codexQuotaAccountOrder": ["acc-1"]
        },
        "credentials": {
            "codexQuotaAccounts": {
                "acc-1": {
                    "display_name": "Codex · user",
                    "access_token": "fixture-token"
                }
            }
        }
    }))
    .unwrap();
    let http = FixtureHttp {
        calls: AtomicUsize::new(0),
        body: br#"{"plan_type":"fixture","rate_limit":{"primary_window":{"limit_window_seconds":18000,"used_percent":42}}}"#.to_vec(),
    };
    let output = collect_agent_usage_with_dependencies(&request, &http).unwrap();
    assert!(output.artifact["agents"].as_array().unwrap().is_empty());
    assert_eq!(output.artifact["services"].as_array().unwrap().len(), 1);
    assert_eq!(output.artifact["services"][0]["app"], "codex");
    assert_eq!(http.calls.load(Ordering::Acquire), 1);
}

/// C138 / TD-005: quotaRetryOnly 是通用契约 —— 非 codex provider 也能只重试额度,
/// 不再经 codex 专属计划构建入口。
#[test]
fn quota_retry_only_is_provider_agnostic() {
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
            "capabilities": ["externalQuotas"],
            "quotaRetryOnly": true
        },
        "credentials": {
            "kimiQuotaAccounts": {
                "acct-a": {
                    "display_name": "Kimi fixture",
                    "api_key": "fixture-key"
                }
            }
        }
    }))
    .unwrap();
    let http = FixtureHttp {
        calls: AtomicUsize::new(0),
        body: br#"{"limits":[{"detail":{"limit":100,"remaining":60}}]}"#.to_vec(),
    };
    let output = collect_agent_usage_with_dependencies(&request, &http).unwrap();
    assert!(output.artifact["agents"].as_array().unwrap().is_empty());
    assert_eq!(output.artifact["services"].as_array().unwrap().len(), 1);
    assert_eq!(output.artifact["services"][0]["app"], "kimi");
    assert_eq!(http.calls.load(Ordering::Acquire), 1);
}

#[test]
fn application_emits_credential_update_for_stepfun_refresh() {
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
            "stepfunQuotaAccounts": {
                "step-1": {
                    "display_name": "StepFun · user",
                    "token": "header.part1.sig...header.eyJhcHBfaWQiOjEwMzAwLCJkZXZpY2VfaWQiOiJkZXYtMSJ9.sig"
                }
            }
        }
    }))
    .unwrap();

    struct StepFunMockHttp {
        calls: AtomicUsize,
    }
    impl HttpClient for StepFunMockHttp {
        fn send(
            &self,
            _req: HttpRequest,
            _cancellation: &collector_runtime::CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            let call = self.calls.fetch_add(1, Ordering::SeqCst);
            match call {
                0 => Ok(HttpResponse {
                    status: 401,
                    body: b"unauthenticated".to_vec(),
                }),
                1 => Ok(HttpResponse {
                    status: 200,
                    body: serde_json::to_vec(&json!({
                        "accessToken": {"raw": "header.refreshed_access.sig"},
                        "refreshToken": {"raw": "header.refreshed_refresh.sig"}
                    }))
                    .unwrap(),
                }),
                2 => Ok(HttpResponse {
                    status: 200,
                    body: serde_json::to_vec(&json!({
                        "status": 1,
                        "desc": "",
                        "plan_credit_rate_limit": {
                            "subscription_credit_left_rate": 0.9,
                            "subscription_credit_reset_time": "1792485144",
                            "credit_buckets": []
                        }
                    }))
                    .unwrap(),
                }),
                _ => panic!("unexpected call count"),
            }
        }
    }

    let http = StepFunMockHttp {
        calls: AtomicUsize::new(0),
    };
    let output = collect_agent_usage_with_dependencies(&request, &http).unwrap();
    assert_eq!(
        output.credential_updates,
        vec![json!({
            "provider": "stepfun",
            "accountId": "step-1",
            "kind": "oauthTokens",
            "operation": "replace",
            "credentials": {
                "access_token": "header.refreshed_access.sig...header.refreshed_refresh.sig"
            }
        })]
    );
    let service = &output.artifact["services"][0];
    assert_eq!(service["app"], "stepfun");
    assert_eq!(service["status"], "ok");
    assert!(service.get("credential_update").is_none());
    assert_eq!(http.calls.load(Ordering::Acquire), 3);
}
