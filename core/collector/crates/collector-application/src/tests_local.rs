//! 本机来源: agent 行合并、缓存热路径、价卡选择与来源说明。

use crate::{
    collect_agent_usage, collect_agent_usage_with_dependencies, finalize_local_agent,
    LocalAgentResult, LOCAL_SOURCE_NOTICE,
};
use serde_json::json;
use std::sync::atomic::AtomicUsize;

use crate::tests_support::*;

/// C046: 用量合并失败必须可见 —— agent 降级为 partial 且 note 说明缺失,
/// 不得继续对外报 ok 而静默丢数据。
#[test]
fn local_agent_merge_failure_is_visible_not_silent() {
    use collector_domain::{CollectionWindow, PricingTable, UsageContribution};

    let context: serde_json::Map<String, serde_json::Value> = serde_json::from_value(json!({
        "now": "2026-07-28T12:00:00+08:00",
        "timezone": "Asia/Shanghai",
        "days": 3
    }))
    .unwrap();
    let window = CollectionWindow::from_context(&context).unwrap();
    let pricing = PricingTable::new(std::collections::HashMap::new());

    // 构造不可合并的 contribution: 某天不在当前窗口 day_list 内
    let mut invalid = UsageContribution {
        by_day: std::collections::BTreeMap::new(),
        models_by_month: std::collections::BTreeMap::new(),
        models_today: Vec::new(),
        projects_today: Vec::new(),
        hours: Vec::new(),
        models_by_day: std::collections::BTreeMap::new(),
        hour_models_today: std::collections::BTreeMap::new(),
    };
    invalid.by_day.insert(
        "1999-01-01".to_owned(),
        collector_domain::TokenBucket {
            input: 1,
            output: 1,
            cache_read: 0,
            cache_creation: 0,
            cache_creation_1h: 0,
            total: 2,
            ..Default::default()
        },
    );

    let source = LocalAgentResult {
        found: true,
        contribution: invalid,
        requests: collector_domain::RequestRows::default(),
        diagnostic: None,
        notice: None,
        history_note: None,
    };
    let agent = finalize_local_agent(
        &window,
        "claude-code",
        "Claude Code",
        &source,
        "本机会话聚合",
        "unavailable",
        "未发现会话记录",
        &pricing,
    );
    assert_eq!(
        agent.status, "partial",
        "合并失败必须降级为 partial, 不得静默报 ok"
    );
    assert!(
        agent.note.contains("合并失败"),
        "note 必须说明数据不完整: {}",
        agent.note
    );
}

#[test]
fn source_metrics_follow_the_stable_local_source_order() {
    let home =
        std::env::temp_dir().join(format!("bruce-source-metrics-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join(".kimi-code/sessions")).unwrap();
    let mut request = request(&["localSessions"]);
    request.context.insert(
        "home".to_owned(),
        serde_json::Value::String(home.to_string_lossy().into_owned()),
    );
    // 隔离 dsh: $DSH_HOME 会让默认路径指向开发者的真实 ~/.dsh, 用例必须显式覆盖。
    // 隔离请求库: Windows 上 resolve_request_log_path 固定用 LOCALAPPDATA,
    // 不注入覆盖会把夹具请求行写进开发机/CI 的真实库 (C250)。
    request.context.insert(
        "paths".to_owned(),
        json!({
            "dsh_sessions": home.join("dsh/sessions"),
            "request_log_db": home.join("request-log.sqlite")
        }),
    );

    let output = collect_agent_usage_with_dependencies(
        &request,
        &FixtureHttp {
            calls: AtomicUsize::new(0),
            body: Vec::new(),
        },
    )
    .unwrap();

    assert_eq!(
        output
            .source_metrics
            .iter()
            .map(|metric| metric.source_id.as_str())
            .collect::<Vec<_>>(),
        vec![
            "kimi-code-cli",
            "kimi-work",
            "claude-code",
            "codex",
            "codebuddy",
            "grok",
            "opencode",
            "pi",
            "zcode",
            "dsh",
            "antigravity",
        ]
    );
    assert!(output.artifact.get("sources").is_none());
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn warm_jsonl_sources_keep_agent_results_and_skip_body_parsing() {
    let home = std::env::temp_dir().join(format!(
        "bruce-warm-jsonl-sources-test-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&home);
    let kimi_work = home.join("kimi-work");
    let claude = home.join("claude/project");
    let codebuddy = home.join("codebuddy/project");
    let grok = home.join("grok/sessions/project/session");
    let pi = home.join("pi");
    let dsh = home.join("dsh/sessions/workspace-dir/session-a");
    for path in [&kimi_work, &claude, &codebuddy, &grok, &pi, &dsh] {
        std::fs::create_dir_all(path).unwrap();
    }
    std::fs::write(
        kimi_work.join("session.jsonl"),
        json!({
            "type": "usage.record",
            "time": 1_788_912_000_000_i64,
            "model": "kimi-k2",
            "usage": {"inputOther": 10, "output": 2}
        })
        .to_string(),
    )
    .unwrap();
    std::fs::write(
        claude.join("session.jsonl"),
        json!({
            "type": "assistant",
            "timestamp": "2026-09-09T04:00:00Z",
            "message": {
                "id": "warm-claude-message",
                "model": "claude-sonnet",
                "usage": {"input_tokens": 11, "output_tokens": 3}
            }
        })
        .to_string(),
    )
    .unwrap();
    std::fs::write(
        codebuddy.join("session.jsonl"),
        json!({
            "type": "message",
            "role": "assistant",
            "timestamp": 1_789_128_000_000_i64,
            "message": {"usage": {"input_tokens": 12, "output_tokens": 4}},
            "providerData": {"model": "codebuddy-model", "messageId": "warm-codebuddy-message"}
        })
        .to_string(),
    )
    .unwrap();
    std::fs::write(
        grok.join("conversation.jsonl"),
        json!({"type": "assistant", "content": "abcdefgh"}).to_string(),
    )
    .unwrap();
    std::fs::write(
        pi.join("session.jsonl"),
        json!({
            "type": "message",
            "message": {
                "role": "assistant",
                "timestamp": 1_789_128_000_000_i64,
                "model": "pi-model",
                "usage": {"input": 13, "output": 5}
            }
        })
        .to_string(),
    )
    .unwrap();
    // C189: dsh 夹具用未压缩 .jsonl (生产环境为 .jsonl.zstd), 同样走按文件签名缓存。
    std::fs::write(
        dsh.join("session.v4.jsonl"),
        [
            json!({"type": "session", "version": 4, "cwd": "/workspace/warm-dsh-project"})
                .to_string(),
            json!({
                "type": "assistant/message",
                "time": 1_788_912_000_000_i64,
                "data": {
                    "message": {"id": "warm-dsh-message", "source": {"model": "deepseek-flash"}},
                    "usage": {"inputTokens": 14, "outputTokens": 6, "cacheReadTokens": 2}
                }
            })
            .to_string(),
        ]
        .join("\n")
            + "\n",
    )
    .unwrap();

    let mut request = request(&["localSessions"]);
    request.context.insert(
        "home".to_owned(),
        serde_json::Value::String(home.to_string_lossy().into_owned()),
    );
    request
        .context
        .insert("now".to_owned(), json!("2026-09-09T12:00:00+08:00"));
    request
        .context
        .insert("timezone".to_owned(), json!("Asia/Shanghai"));
    request.context.insert("days".to_owned(), json!(14));
    request.context.insert(
        "paths".to_owned(),
        json!({
            "kimi_cli_sessions": home.join("kimi-cli").to_string_lossy(),
            "daimon_kimi_sessions": kimi_work,
            "claude_projects": home.join("claude"),
            "codex_sessions": home.join("codex"),
            "orca_home": home.join("orca"),
            "grok_home": home.join("grok"),
            "pi_sessions": pi,
            "opencode_db": home.join("opencode.db"),
            "zcode_db": home.join("zcode.db"),
            "codebuddy_projects": home.join("codebuddy"),
            "dsh_sessions": home.join("dsh/sessions"),
            // C250: Windows 请求库路径不跟随 home, 必须显式注入。
            "request_log_db": home.join("request-log.sqlite")
        }),
    );

    let first = collect_agent_usage_with_dependencies(
        &request,
        &FixtureHttp {
            calls: AtomicUsize::new(0),
            body: Vec::new(),
        },
    )
    .unwrap();
    let second = collect_agent_usage_with_dependencies(
        &request,
        &FixtureHttp {
            calls: AtomicUsize::new(0),
            body: Vec::new(),
        },
    )
    .unwrap();

    assert_eq!(first.artifact["agents"], second.artifact["agents"]);
    assert!(second.scan_stats.cache_hits > 0);
    assert_eq!(second.scan_stats.json_lines_parsed, 0);
    for source_id in ["kimi-work", "claude-code", "codebuddy", "grok", "pi", "dsh"] {
        let metric = second
            .source_metrics
            .iter()
            .find(|metric| metric.source_id == source_id)
            .expect("source metric should be present");
        assert!(metric.stats.cache_hits > 0, "{source_id} should be warm");
        assert_eq!(
            metric.stats.json_lines_parsed, 0,
            "{source_id} should not parse JSONL"
        );
    }
    let dsh_agent = second.artifact["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|agent| agent["id"] == "dsh")
        .unwrap();
    assert_ne!(dsh_agent["status"], "not_found", "dsh 行应产出用量");
    assert_eq!(dsh_agent["today"]["total"], 22, "14 + 6 + 2");
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn codex_warm_cache_preserves_found_status() {
    let home = std::env::temp_dir().join(format!(
        "bruce-codex-warm-cache-test-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&home);
    let codex_root = home.join("codex");
    let rollout = codex_root.join("2026/07/28/rollout-warm.jsonl");
    std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    std::fs::write(
        &rollout,
        br#"{"timestamp":"2026-07-28T04:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}}}
"#,
    )
    .unwrap();

    let empty = home.join("empty");
    let empty_paths = [
        ("kimi_cli_sessions", empty.join("kimi-cli")),
        ("daimon_kimi_sessions", empty.join("kimi-work")),
        ("claude_projects", empty.join("claude")),
        ("orca_codex_sessions", empty.join("orca-sessions")),
        ("orca_home", empty.join("orca-home")),
        ("grok_home", empty.join("grok")),
        ("pi_sessions", empty.join("pi")),
        ("opencode_db", empty.join("opencode.db")),
        ("zcode_db", empty.join("zcode.db")),
        ("codebuddy_projects", empty.join("codebuddy")),
        ("dsh_sessions", empty.join("dsh")),
    ];
    let paths = empty_paths
        .into_iter()
        .map(|(key, path)| {
            (
                key.to_owned(),
                serde_json::Value::String(path.to_string_lossy().into_owned()),
            )
        })
        .chain(std::iter::once((
            "codex_sessions".to_owned(),
            serde_json::Value::String(codex_root.to_string_lossy().into_owned()),
        )))
        // C250: Windows 请求库路径不跟随 home, 必须显式注入。
        .chain(std::iter::once((
            "request_log_db".to_owned(),
            serde_json::Value::String(
                home.join("request-log.sqlite")
                    .to_string_lossy()
                    .into_owned(),
            ),
        )))
        .collect();
    let mut request = request(&["localSessions"]);
    request.context.insert(
        "home".to_owned(),
        serde_json::Value::String(home.to_string_lossy().into_owned()),
    );
    request.context.insert(
        "now".to_owned(),
        serde_json::Value::String("2026-07-28T12:00:00+08:00".to_owned()),
    );
    request
        .context
        .insert("timezone".to_owned(), json!("Asia/Shanghai"));
    request.context.insert("days".to_owned(), json!(3));
    request
        .context
        .insert("paths".to_owned(), serde_json::Value::Object(paths));

    let first = collect_agent_usage_with_dependencies(
        &request,
        &FixtureHttp {
            calls: AtomicUsize::new(0),
            body: Vec::new(),
        },
    )
    .unwrap();
    let second = collect_agent_usage_with_dependencies(
        &request,
        &FixtureHttp {
            calls: AtomicUsize::new(0),
            body: Vec::new(),
        },
    )
    .unwrap();

    let first_codex = first.artifact["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|agent| agent["id"] == "codex")
        .unwrap();
    let second_codex = second.artifact["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|agent| agent["id"] == "codex")
        .unwrap();
    assert_ne!(first_codex["status"], "not_found");
    assert_ne!(second_codex["status"], "not_found");
    let _ = std::fs::remove_dir_all(home);
}

/// C119: Orca 内置 Codex 的会话计入 Codex 行, artifact 不输出 Orca 行。
#[test]
fn orca_sessions_count_toward_codex_and_no_orca_row_is_emitted() {
    let home =
        std::env::temp_dir().join(format!("bruce-orca-into-codex-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let rollout = |root: &std::path::Path, name: &str, input: u64, output: u64| {
        let path = root.join("2026/07/28").join(name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            format!(
                "{}\n",
                json!({"timestamp": "2026-07-28T04:00:00Z", "type": "event_msg",
                    "payload": {"type": "token_count", "info": {"last_token_usage":
                        {"input_tokens": input, "cached_input_tokens": 0, "output_tokens": output}}}})
            ),
        )
        .unwrap();
    };
    let codex_root = home.join("codex");
    let orca_home = home.join("orca");
    let orca_sessions = orca_home.join("codex-runtime-home/home/sessions");
    rollout(&codex_root, "rollout-cli.jsonl", 10, 3);
    rollout(&orca_sessions, "rollout-orca.jsonl", 7, 2);

    let empty = home.join("empty");
    let mut paths = serde_json::Map::new();
    for (key, path) in [
        ("kimi_cli_sessions", empty.join("kimi-cli")),
        ("daimon_kimi_sessions", empty.join("kimi-work")),
        ("claude_projects", empty.join("claude")),
        ("grok_home", empty.join("grok")),
        ("pi_sessions", empty.join("pi")),
        ("opencode_db", empty.join("opencode.db")),
        ("zcode_db", empty.join("zcode.db")),
        ("codebuddy_projects", empty.join("codebuddy")),
        ("dsh_sessions", empty.join("dsh")),
        ("codex_sessions", codex_root),
        ("orca_home", orca_home),
        ("orca_codex_sessions", orca_sessions),
        // C250: Windows 请求库路径不跟随 home, 必须显式注入。
        ("request_log_db", home.join("request-log.sqlite")),
    ] {
        paths.insert(key.to_owned(), json!(path.to_string_lossy()));
    }
    let mut request = request(&["localSessions"]);
    for (key, value) in [
        ("home", json!(home.to_string_lossy())),
        ("now", json!("2026-07-28T12:00:00+08:00")),
        ("timezone", json!("Asia/Shanghai")),
        ("days", json!(3)),
        ("paths", serde_json::Value::Object(paths)),
    ] {
        request.context.insert(key.to_owned(), value);
    }
    let output = collect_agent_usage_with_dependencies(
        &request,
        &FixtureHttp {
            calls: AtomicUsize::new(0),
            body: Vec::new(),
        },
    )
    .unwrap();
    let agents = output.artifact["agents"].as_array().unwrap();
    assert!(
        agents.iter().all(|agent| agent["id"] != "orca"),
        "不再输出 Orca 行"
    );
    let codex = agents.iter().find(|agent| agent["id"] == "codex").unwrap();
    assert_eq!(codex["status"], "ok");
    assert_eq!(
        codex["today"]["total"], 22,
        "Codex CLI 13 + Orca 内置 Codex 9 均计入 Codex 行"
    );
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn application_pricing_table_selection_logic() {
    // Test 1: valid pricingCatalog is accepted and used
    let mut req = request(&[]);
    req.context.insert(
        "pricingCatalog".to_string(),
        json!({
            "schemaVersion": 1,
            "updatedAt": "2026-10-31",
            "models": [
                {
                    "model": "dynamic-model",
                    "displayName": "Dynamic Model",
                    "vendor": "Dynamic",
                    "input": 10.0,
                    "output": 50.0,
                    "note": "dynamic"
                }
            ]
        }),
    );
    let res = collect_agent_usage(&req);
    assert!(res.is_ok());

    // Test 2: invalid pricingCatalog falls back to builtin without failing
    let mut bad_req = request(&[]);
    bad_req.context.insert(
        "pricingCatalog".to_string(),
        json!({
            "schemaVersion": 999,
            "updatedAt": "invalid",
            "models": []
        }),
    );
    let bad_res = collect_agent_usage(&bad_req);
    assert!(bad_res.is_ok());

    // Test 3: older updatedAt falls back to builtin baseline
    let mut stale_req = request(&[]);
    stale_req.context.insert(
        "pricingCatalog".to_string(),
        json!({
            "schemaVersion": 1,
            "updatedAt": "2020-01-01",
            "models": [
                {
                    "model": "stale-model",
                    "displayName": "Stale",
                    "vendor": "Stale",
                    "input": 1.0,
                    "output": 1.0,
                    "note": "stale"
                }
            ]
        }),
    );
    let stale_res = collect_agent_usage(&stale_req);
    assert!(stale_res.is_ok());
}

#[test]
fn finalize_local_agent_with_dynamic_catalog_and_overrides() {
    use collector_domain::{CollectionWindow, PricingTable, UsageContributionBuilder, UsageSample};
    use std::collections::HashMap;

    let context: serde_json::Map<String, serde_json::Value> = serde_json::from_value(json!({
        "now": "2026-07-28T12:00:00+08:00",
        "timezone": "Asia/Shanghai",
        "days": 1
    }))
    .unwrap();
    let window = CollectionWindow::from_context(&context).unwrap();
    let mut builder = UsageContributionBuilder::new(window.clone());
    assert!(builder.record(UsageSample {
        timestamp_millis: 1_785_211_200_000,
        model: Some("dynamic-test-model"),
        project: None,
        input: 1_000_000,
        output: 1_000_000,
        cache_read: 0,
        cache_creation: 0,
        cache_creation_1h: 0,
    }));
    let contribution = builder.contribution();
    let local_result = LocalAgentResult {
        found: true,
        contribution,
        requests: collector_domain::RequestRows::default(),
        diagnostic: None,
        notice: None,
        history_note: None,
    };

    // Construct dynamic catalog: dynamic-test-model @ $2 / $10
    let dynamic_catalog = vec![collector_domain::pricing::CatalogModel {
        model: "dynamic-test-model".to_string(),
        display_name: "Dynamic Test".to_string(),
        vendor: "Dynamic".to_string(),
        input: 2.0,
        output: 10.0,
        cache_read: None,
        cache_write: None,
        note: "Dynamic".to_string(),
        listed: true,
        peak: None,
        long_context: None,
    }];

    let pricing_table = PricingTable::with_catalog(&dynamic_catalog, HashMap::new());
    let agent = finalize_local_agent(
        &window,
        "test_agent",
        "Test Agent",
        &local_result,
        "note",
        "unavailable",
        "missing",
        &pricing_table,
    );

    // 1M in * $2 + 1M out * $10 = $12
    assert_eq!(agent.today_cost_usd, Some(12.0));

    // Now with user override: input $5 -> 1M * $5 + 1M * $10 = $15
    let mut overrides = HashMap::new();
    overrides.insert(
        "dynamic-test-model".to_string(),
        collector_domain::ModelPricingOverride {
            input_price_per_million: Some(5.0),
            ..Default::default()
        },
    );
    let overridden_table = PricingTable::with_catalog(&dynamic_catalog, overrides);
    let overridden_agent = finalize_local_agent(
        &window,
        "test_agent",
        "Test Agent",
        &local_result,
        "note",
        "unavailable",
        "missing",
        &overridden_table,
    );
    assert_eq!(overridden_agent.today_cost_usd, Some(15.0));
}

// MARK: - T26: 用量历史台账

fn has_diagnostic(diagnostics: &[collector_domain::Diagnostic], code: &str, stage: &str) -> bool {
    diagnostics
        .iter()
        .any(|diagnostic| diagnostic.code == code && diagnostic.stage == stage)
}

/// C198: 来源说明 (Codex 会话副本分叉合并, C190) 只输出信息级 LOCAL_SOURCE_NOTICE —— agent 保持 ok、
/// note 附说明、envelope 不升级为 Partial; 同一轮的真实读取故障 (OpenCode 库不可解析)
/// 仍为 error + LOCAL_SOURCE_SCHEMA_INCOMPATIBLE。
#[test]
fn source_notice_stays_informational_while_source_fault_stays_error() {
    let home = history_test_home("source-notice");
    let history_db = home.join("usage-history.sqlite");
    for (copy, input) in [("a", 100_u64), ("b", 1_000)] {
        let dir = home.join("codex").join(copy);
        std::fs::create_dir_all(&dir).unwrap();
        let line = json!({
            "timestamp": "2026-07-28T03:00:00Z",
            "type": "event_msg",
            "payload": {"type": "token_count", "info": {"last_token_usage": {
                "input_tokens": input, "cached_input_tokens": 0, "output_tokens": 5
            }}}
        });
        std::fs::write(dir.join("rollout-c198.jsonl"), format!("{line}\n")).unwrap();
    }
    std::fs::write(home.join("opencode.db"), b"not a sqlite database").unwrap();
    let request = history_request(&home, &history_db);

    let output = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    let codex = agent(&output.artifact, "codex");
    assert_eq!(
        codex["status"], "ok",
        "副本取舍是说明, 不得把 Codex 置 error"
    );
    let note = codex["note"].as_str().unwrap_or_default();
    assert!(
        note.starts_with("额度见下方 Codex 账号") && note.contains("会话副本已分叉"),
        "note 保留来源原说明并附上副本说明: {note}"
    );
    assert!(codex["today"]["total"].as_u64().unwrap_or(0) > 0);
    assert!(
        has_diagnostic(&output.diagnostics, LOCAL_SOURCE_NOTICE, "codex"),
        "副本取舍须以信息级诊断输出"
    );
    let schema_fault = "LOCAL_SOURCE_SCHEMA_INCOMPATIBLE";
    assert!(!has_diagnostic(&output.diagnostics, schema_fault, "codex"));

    let opencode = agent(&output.artifact, "opencode");
    assert_eq!(opencode["status"], "error", "真实读取故障不得被降级");
    assert!(has_diagnostic(
        &output.diagnostics,
        schema_fault,
        "opencode"
    ));
    assert_eq!(
        collector_domain::response_status(true, &output.diagnostics),
        collector_domain::ResponseStatus::Partial,
        "故障仍使 envelope 为 Partial"
    );

    // 只剩说明时 envelope 为 Success。
    std::fs::remove_file(home.join("opencode.db")).unwrap();
    let output = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    assert!(has_diagnostic(
        &output.diagnostics,
        LOCAL_SOURCE_NOTICE,
        "codex"
    ));
    assert_eq!(
        collector_domain::response_status(true, &output.diagnostics),
        collector_domain::ResponseStatus::Success,
        "信息级说明不得触发 Partial: {:?}",
        output.diagnostics
    );

    std::fs::remove_dir_all(&home).ok();
}

/// C193: 来源 usage 键改名 (Claude message.usage → message.token_usage) → 口径哨兵说明经
/// LOCAL_SOURCE_NOTICE 输出, Claude 仍为 ok、envelope 不 Partial。
#[test]
fn usage_drift_sentinel_is_a_notice_not_an_error() {
    let home = history_test_home("usage-drift");
    let history_db = home.join("usage-history.sqlite");
    let claude = home.join("claude").join("demo");
    std::fs::create_dir_all(&claude).unwrap();
    let lines: String = (0..5)
        .map(|index| {
            json!({
                "type": "assistant",
                "timestamp": format!("2026-07-28T03:0{index}:00Z"),
                "message": {
                    "id": format!("drift-{index}"),
                    "model": "claude-sonnet",
                    "token_usage": {"input_tokens": 100, "output_tokens": 10}
                }
            })
            .to_string()
                + "\n"
        })
        .collect();
    std::fs::write(claude.join("session.jsonl"), lines).unwrap();
    let request = history_request(&home, &history_db);
    let output = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    let claude = claude_agent(&output.artifact);
    assert_eq!(claude["status"], "ok", "哨兵说明不得把 agent 置 error");
    assert!(
        claude["note"]
            .as_str()
            .unwrap_or_default()
            .contains("疑似来源 usage 字段口径变化"),
        "{}",
        claude["note"]
    );
    assert!(has_diagnostic(
        &output.diagnostics,
        LOCAL_SOURCE_NOTICE,
        "claude-code"
    ));
    assert_eq!(
        collector_domain::response_status(true, &output.diagnostics),
        collector_domain::ResponseStatus::Success
    );
    std::fs::remove_dir_all(&home).ok();
}

/// C198: 说明附在 note 后且不改变状态; 故障优先, 说明不覆盖故障说明。
#[test]
fn finalize_local_agent_appends_notice_without_changing_status() {
    use collector_domain::{CollectionWindow, PricingTable, UsageContributionBuilder};

    let context: serde_json::Map<String, serde_json::Value> = serde_json::from_value(json!({
        "now": "2026-07-28T12:00:00+08:00",
        "timezone": "Asia/Shanghai",
        "days": 3
    }))
    .unwrap();
    let window = CollectionWindow::from_context(&context).unwrap();
    let pricing = PricingTable::new(std::collections::HashMap::new());
    let finalize = |diagnostic: Option<&str>, history_note: Option<&str>| {
        let source = LocalAgentResult {
            found: history_note.is_none(),
            contribution: UsageContributionBuilder::new(window.clone()).contribution(),
            requests: collector_domain::RequestRows::default(),
            diagnostic: diagnostic.map(str::to_owned),
            notice: Some("缓存已重建".to_owned()),
            history_note: history_note.map(str::to_owned),
        };
        finalize_local_agent(
            &window,
            "codex",
            "Codex",
            &source,
            "本机会话聚合",
            "not_found",
            "未发现会话记录",
            &pricing,
        )
    };

    let ok = finalize(None, None);
    assert_eq!(ok.status, "ok");
    assert_eq!(ok.note, "本机会话聚合 (缓存已重建)");

    let history = finalize(None, Some("显示已保存的历史用量"));
    assert_eq!(history.status, "history");
    assert_eq!(history.note, "显示已保存的历史用量 (缓存已重建)");

    let fault = finalize(Some("本机 codex 数据库schema 不兼容"), None);
    assert_eq!(fault.status, "error");
    assert_eq!(fault.note, "本机 codex 数据库schema 不兼容");
}

/// T26: 从未使用的 agent 不得因占位而写入 0 行或变成 history。
#[test]
fn empty_sources_keep_placeholder_status() {
    let home = history_test_home("empty-sources");
    let history_db = home.join("usage-history.sqlite");
    let request = history_request(&home, &history_db);

    let output = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    let agent = claude_agent(&output.artifact);
    assert_eq!(agent["status"], "not_found");
    assert_eq!(agent["note"], "未发现会话记录");
    assert_eq!(daily_total(agent), 0);

    std::fs::remove_dir_all(&home).ok();
}

/// design/14: Claude 请求行写入独立库, 连续两轮幂等且不影响 artifact。
/// C249: CodeBuddy 经共享 DedupedAggregator 也会产出请求行, 但不在请求日志范围内,
/// 聚合照常计入而请求库不落行。
#[test]
fn request_log_rows_are_idempotent_and_keep_aggregate_parity() {
    use collector_request_log::{RequestLogFilter, RequestLogStore};

    let home = history_test_home("request-log-rows");
    let claude = home.join("claude").join("project");
    std::fs::create_dir_all(&claude).unwrap();
    std::fs::write(
        claude.join("session.jsonl"),
        concat!(
            r#"{"type":"assistant","message":{"id":"msg_request_1","#,
            r#""model":"claude-opus-5-5","stop_reason":"end_turn","#,
            r#""usage":{"input_tokens":10,"output_tokens":2,"#,
            r#""cache_read_input_tokens":3,"cache_creation_input_tokens":4}},"#,
            r#""timestamp":"2026-07-28T03:00:00Z","sessionId":"session-1"}"#,
            "\n"
        ),
    )
    .unwrap();
    let codebuddy = home.join("codebuddy").join("project");
    std::fs::create_dir_all(&codebuddy).unwrap();
    std::fs::write(
        codebuddy.join("session.jsonl"),
        serde_json::json!({
            "type": "message",
            "role": "assistant",
            "timestamp": 1_785_207_600_000_i64,
            "message": {"usage": {"input_tokens": 12, "output_tokens": 4}},
            "providerData": {"model": "codebuddy-model", "messageId": "request-log-scope"}
        })
        .to_string(),
    )
    .unwrap();
    let history_db = home.join("usage-history.sqlite");
    let request = history_request(&home, &history_db);

    let first = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    let second = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    assert_eq!(first.artifact["agents"], second.artifact["agents"]);
    assert_eq!(claude_agent(&first.artifact)["today"]["total"], 19);
    let codebuddy_agent = first.artifact["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|agent| agent["id"] == "codebuddy")
        .unwrap();
    assert_eq!(
        codebuddy_agent["today"]["total"], 16,
        "范围外来源聚合不受影响"
    );

    let store = RequestLogStore::open(&home.join("request-log.sqlite")).unwrap();
    let page = store
        .query(&RequestLogFilter {
            start: 0,
            end: i64::MAX,
            page: 0,
            page_size: 50,
            ..RequestLogFilter::default()
        })
        .unwrap();
    assert_eq!(page.total, 1, "重复运行不得重复插入, 范围外来源不得落库");
    assert_eq!(page.entries[0].agent_id, "claude-code");
    let entry = &page.entries[0];
    assert_eq!(entry.input, 10);
    assert_eq!(entry.output, 2);
    assert_eq!(entry.cache_read, 3);
    assert_eq!(entry.cache_creation, 4);
    assert_eq!(entry.model.as_deref(), Some("claude-opus-5-5"));
    assert!(entry.cost_usd.is_some(), "claude-opus-5-5 应命中内置价卡");

    std::fs::remove_dir_all(&home).ok();
}

/// C249: 本轮无首批来源请求行时仍清理已有请求库的过期明细; 库不存在时不创建。
#[test]
fn request_log_prunes_expired_rows_without_new_entries_and_never_creates_a_store() {
    use collector_request_log::{RequestLogEntry, RequestLogFilter, RequestLogStore};

    let home = history_test_home("request-log-prune");
    let history_db = home.join("usage-history.sqlite");
    let request = history_request(&home, &history_db);
    let store_path = home.join("request-log.sqlite");

    let idle = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    assert!(!store_path.exists(), "无请求行时不得凭空创建请求库");
    assert_eq!(idle.metrics.request_log_rows_written, 0);

    let now = 1_785_211_200_000_i64; // history_request 的 now
    let day = 86_400_000_i64;
    {
        let mut store = RequestLogStore::open(&store_path).unwrap();
        store
            .merge(
                &[
                    RequestLogEntry::exact("claude-code", "expired", now - 40 * day),
                    RequestLogEntry::exact("claude-code", "recent", now - day),
                ],
                0,
            )
            .unwrap();
    }
    let output = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    assert_eq!(output.metrics.request_log_rows_pruned, 1);
    let page = RequestLogStore::open(&store_path)
        .unwrap()
        .query(&RequestLogFilter {
            start: 0,
            end: i64::MAX,
            page_size: 50,
            ..RequestLogFilter::default()
        })
        .unwrap();
    assert_eq!(page.total, 1);
    assert_eq!(page.entries[0].request_key, "recent");

    std::fs::remove_dir_all(&home).ok();
}

/// C249: 范围内来源的截断给出信息级说明并计入指标 (范围外来源不报);
/// pricing_model 记录实际命中的价卡键而非请求模型名。
#[test]
fn request_log_reports_truncation_and_stores_the_matched_price_key() {
    use collector_domain::{
        CollectionWindow, PricingTable, RequestRecord, RequestRows, UsageContributionBuilder,
        LOCAL_SOURCE_NOTICE,
    };
    use collector_request_log::{RequestLogFilter, RequestLogStore};
    use std::collections::BTreeMap;

    let home = history_test_home("request-log-truncation");
    let history_db = home.join("usage-history.sqlite");
    let request = history_request(&home, &history_db);
    let window = CollectionWindow::from_context(&request.context).unwrap();
    let http = empty_http();
    let context = crate::RunContext::new(
        &request,
        window.clone(),
        &http,
        crate::RuntimeLimits::default(),
    )
    .unwrap();
    let agent = |rows: Vec<RequestRecord>, truncated: usize| crate::LocalAgentResult {
        found: true,
        contribution: UsageContributionBuilder::new(window.clone()).contribution(),
        requests: RequestRows { rows, truncated },
        diagnostic: None,
        notice: None,
        history_note: None,
    };
    let row = RequestRecord {
        key: "dated".to_owned(),
        timestamp_millis: 1_785_207_600_000,
        model: Some("claude-opus-5-5-20261001".to_owned()),
        raw_model: Some("claude-opus-5-5-20261001".to_owned()),
        project: None,
        input: 1_000,
        output: 200,
        cache_read: 0,
        cache_creation: 0,
        cache_creation_1h: 0,
        fidelity: "exact".to_owned(),
        latency_ms: None,
        first_token_ms: None,
    };
    let mut agents = BTreeMap::new();
    agents.insert("claude-code".to_owned(), agent(vec![row], 3));
    agents.insert("codebuddy".to_owned(), agent(Vec::new(), 5));

    let mut diagnostics = Vec::new();
    crate::persist_request_logs(
        &context,
        &agents,
        &PricingTable::default(),
        &mut diagnostics,
    );

    assert_eq!(diagnostics.len(), 1, "{diagnostics:?}");
    assert_eq!(diagnostics[0].code, LOCAL_SOURCE_NOTICE);
    assert_eq!(diagnostics[0].stage, "claude-code");
    assert!(
        diagnostics[0].message.contains("较早的 3 条"),
        "{}",
        diagnostics[0].message
    );
    let metrics = context.metrics.snapshot();
    assert_eq!(metrics.request_log_rows_truncated, 3);
    assert_eq!(metrics.request_log_rows_written, 1);

    let entry = RequestLogStore::open(&home.join("request-log.sqlite"))
        .unwrap()
        .query(&RequestLogFilter {
            start: 0,
            end: i64::MAX,
            page_size: 50,
            ..RequestLogFilter::default()
        })
        .unwrap()
        .entries
        .remove(0);
    assert_eq!(entry.pricing_model.as_deref(), Some("claude-opus-5-5"));
    assert!(entry.cost_usd.is_some_and(|cost| cost > 0.0));

    std::fs::remove_dir_all(&home).ok();
}

/// C253: artifact 总额只在「无任何已计价 agent」时为 None；$0 定价仍算已计价。
#[test]
fn artifact_total_cost_keeps_zero_priced_agents() {
    assert_eq!(
        crate::total_cost_of([Some(0.0), None].into_iter()),
        Some(0.0)
    );
    assert_eq!(crate::total_cost_of([None, None].into_iter()), None);
    assert_eq!(
        crate::total_cost_of([Some(1.5), Some(0.0)].into_iter()),
        Some(1.5)
    );
}
