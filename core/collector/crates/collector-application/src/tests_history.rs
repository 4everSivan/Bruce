//! 台账 (T26): 来源移除后的历史保留与口径修正。

use crate::{collect_agent_usage_with_dependencies, LOCAL_HISTORY_STORE_UNAVAILABLE};
use serde_json::json;

use crate::tests_support::*;

fn write_claude_history(home: &std::path::Path) {
    let claude = home.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let lines = [
        json!({
            "type": "assistant",
            "timestamp": "2026-07-28T03:00:00Z",
            "message": {
                "id": "t26-history-today",
                "model": "claude-sonnet",
                "usage": {"input_tokens": 100, "output_tokens": 10}
            }
        })
        .to_string(),
        json!({
            "type": "assistant",
            "timestamp": "2026-07-27T03:00:00Z",
            "message": {
                "id": "t26-history-yesterday",
                "model": "claude-sonnet",
                "usage": {"input_tokens": 200, "output_tokens": 20}
            }
        })
        .to_string(),
    ]
    .join("\n")
        + "\n";
    std::fs::write(claude.join("session.jsonl"), lines).unwrap();
}

/// T26: 来源被删除后, 该 agent 的历史用量必须从台账继续输出, 且状态区分于 ok。
#[test]
fn history_survives_source_removal() {
    let home = history_test_home("source-removal");
    let history_db = home.join("usage-history.sqlite");
    write_claude_history(&home);
    let request = history_request(&home, &history_db);

    let first = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    let first_agent = claude_agent(&first.artifact);
    assert_eq!(first_agent["status"], "ok");
    let first_total = daily_total(first_agent);
    assert_eq!(first_total, 330, "两次调用应完整计入: {first_total}");
    assert!(!first
        .diagnostics
        .iter()
        .any(|diagnostic| diagnostic.code == LOCAL_HISTORY_STORE_UNAVAILABLE));

    // 清理来源 (卸载/删除会话目录)
    std::fs::remove_dir_all(home.join("claude")).unwrap();
    let second = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    let second_agent = claude_agent(&second.artifact);
    assert_eq!(
        second_agent["status"], "history",
        "来源消失后应显示历史状态而非 not_found"
    );
    assert!(
        second_agent["note"]
            .as_str()
            .unwrap_or_default()
            .contains("历史用量"),
        "note 应说明来源未发现但展示历史: {}",
        second_agent["note"]
    );
    assert_eq!(
        daily_total(second_agent),
        first_total,
        "来源删除不得减少台账历史"
    );
    assert_eq!(second_agent["today"]["total"], 110, "今日历史仍应保留");

    std::fs::remove_dir_all(&home).ok();
}

/// T26: 台账不可用时只降级为「仅扫描贡献」, artifact 与诊断码均可解释。
#[test]
fn history_store_unavailable_falls_back_to_scan() {
    let home = history_test_home("store-unavailable");
    write_claude_history(&home);
    let blocked_path = home.join("history-as-directory");
    std::fs::create_dir_all(&blocked_path).unwrap();
    let request = history_request(&home, &blocked_path);

    let output = collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    assert!(
        output
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == LOCAL_HISTORY_STORE_UNAVAILABLE),
        "台账不可用必须输出信息级诊断"
    );
    let agent = claude_agent(&output.artifact);
    assert_eq!(agent["status"], "ok", "台账故障不得影响扫描结果");
    assert_eq!(daily_total(agent), 330, "回退路径仍应输出扫描贡献");

    std::fs::remove_dir_all(&home).ok();
}

/// C194: Grok 07-26 写入 300、07-27 追加 40 —— 旧实现追加时把已有观测重打为新 mtime,
/// 叠加台账按日取大得 07-26=300、07-27=340 (7 日合计 640, 月行 340); 现在日 / 月一致为 340。
#[test]
fn grok_cross_day_append_is_not_double_counted_by_the_ledger() {
    let home = history_test_home("grok-cross-day");
    let history_db = home.join("usage-history.sqlite");
    let session = home.join("grok/sessions/project/session/conversation.jsonl");
    std::fs::create_dir_all(session.parent().unwrap()).unwrap();
    let line = |kind: &str, chars: usize| {
        json!({"type": kind, "content": "x".repeat(chars)}).to_string() + "\n"
    };
    let set_mtime = |epoch_seconds: u64| {
        std::fs::File::options()
            .write(true)
            .open(&session)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(epoch_seconds))
            .unwrap();
    };
    let run = |now: &str| {
        let mut request = history_request(&home, &history_db);
        request.context.insert("now".to_owned(), json!(now));
        collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap()
    };
    std::fs::write(&session, line("user", 800) + &line("assistant", 400)).unwrap();
    set_mtime(1_785_038_400); // 2026-07-26 12:00 +08
    run("2026-07-26T18:00:00+08:00");
    let mut content = std::fs::read_to_string(&session).unwrap();
    content.push_str(&line("assistant", 160));
    std::fs::write(&session, content).unwrap();
    set_mtime(1_785_124_800); // 2026-07-27 12:00 +08
    let output = run("2026-07-27T18:00:00+08:00");

    let grok = agent(&output.artifact, "grok");
    let daily: std::collections::BTreeMap<&str, u64> = grok["daily"]
        .as_array()
        .unwrap()
        .iter()
        .map(|day| {
            (
                day["date"].as_str().unwrap(),
                day["total"].as_u64().unwrap_or(0),
            )
        })
        .collect();
    assert_eq!(daily.get("2026-07-26"), Some(&300));
    assert_eq!(daily.get("2026-07-27"), Some(&40));
    assert_eq!(daily_total(grok), 340, "7 日合计等于真实值");
    let month: u64 = grok["modelMonths"]["2026-07"]
        .as_object()
        .unwrap()
        .values()
        .map(|value| value.as_u64().unwrap_or(0))
        .sum();
    assert_eq!(month, 340, "日与月一致");
    std::fs::remove_dir_all(&home).ok();
}

/// C199: 旧口径 (C194 前) 已把 Grok 跨日追加写成 07-26=300、07-27=340 (7 日合计 640);
/// Grok 声明派生口径版本 2 后的首个来源可见轮按扫描窗口修正为 340, 之后恢复单调。
#[test]
fn grok_inflated_history_is_corrected_once_after_version_bump() {
    let home = history_test_home("grok-correction");
    let history_db = home.join("usage-history.sqlite");
    let session = home.join("grok/sessions/project/session/conversation.jsonl");
    std::fs::create_dir_all(session.parent().unwrap()).unwrap();
    let line = |kind: &str, chars: usize| {
        json!({"type": kind, "content": "x".repeat(chars)}).to_string() + "\n"
    };
    std::fs::write(
        &session,
        line("user", 800) + &line("assistant", 400) + &line("assistant", 160),
    )
    .unwrap();
    std::fs::File::options()
        .write(true)
        .open(&session)
        .unwrap()
        .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_785_124_800))
        .unwrap(); // 2026-07-27 12:00 +08
    {
        // 按旧实现逐轮写入 (基线口径版本 1): 07-26 一轮 300, 07-27 追加后整体漂到 07-27 记 340。
        let mut store = collector_history::HistoryStore::open(&history_db).unwrap();
        for (now, today, millis, input) in [
            (
                "2026-07-26T18:00:00+08:00",
                "2026-07-26",
                1_785_038_400_000_i64,
                300,
            ),
            (
                "2026-07-27T18:00:00+08:00",
                "2026-07-27",
                1_785_124_800_000,
                340,
            ),
        ] {
            let window_context: serde_json::Map<String, serde_json::Value> =
                serde_json::from_value(json!({
                    "now": now,
                    "timezone": "Asia/Shanghai",
                    "days": 7
                }))
                .unwrap();
            let window = collector_domain::CollectionWindow::from_context(&window_context).unwrap();
            let mut builder = collector_domain::UsageContributionBuilder::new(window);
            builder.record(collector_domain::UsageSample {
                timestamp_millis: millis,
                model: Some("grok"),
                project: None,
                input,
                output: 0,
                cache_read: 0,
                cache_creation: 0,
                cache_creation_1h: 0,
            });
            store
                .merge("grok", &builder.contribution(), true, today, now)
                .unwrap();
        }
    }
    let mut request = history_request(&home, &history_db);
    request
        .context
        .insert("now".to_owned(), json!("2026-07-27T18:00:00+08:00"));
    let run = || collect_agent_usage_with_dependencies(&request, &empty_http()).unwrap();
    let corrected = run();
    let grok = agent(&corrected.artifact, "grok");
    assert_eq!(daily_total(grok), 340, "已落库的重复值被修正: 640 → 340");
    let month: u64 = grok["modelMonths"]["2026-07"]
        .as_object()
        .unwrap()
        .values()
        .map(|value| value.as_u64().unwrap_or(0))
        .sum();
    assert_eq!(month, 340, "日与月一致");
    // 修正只发生一次: 之后恢复单调 (来源被删除也不抹历史)。
    std::fs::remove_dir_all(home.join("grok")).unwrap();
    let after = run();
    let grok = agent(&after.artifact, "grok");
    assert_eq!(grok["status"], "history");
    assert_eq!(daily_total(grok), 340);
    std::fs::remove_dir_all(&home).ok();
}
