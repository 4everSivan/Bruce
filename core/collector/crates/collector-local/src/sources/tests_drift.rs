//! C193: usage 口径漂移哨兵 —— 来源字段改名或嵌套变化时不再静默记 0, 而是经信息级说明暴露;
//! 正常数据不输出说明, 命中缓存的轮次说明不消失。

use super::tests_cache::{temp_root, window};
use super::{
    scan_claude_cached, scan_codex_cached, scan_dsh_cached, scan_opencode_cached, scan_zcode_cached,
};
use crate::jsonl_cache::{UsageProbe, DATABASE_DRIFT_STREAK, FILE_DRIFT_STREAK};
use collector_runtime::CancellationToken;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

const FILE_NOTICE: &str =
    "疑似来源 usage 字段口径变化: 1 个会话文件末尾连续 5 条以上用量记录均未取到用量";

fn write_lines(path: &Path, lines: &[Value]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let content: String = lines.iter().map(|line| format!("{line}\n")).collect();
    fs::write(path, content).unwrap();
}

fn append_lines(path: &Path, lines: &[Value]) {
    let mut content = fs::read_to_string(path).unwrap();
    for line in lines {
        content.push_str(&format!("{line}\n"));
    }
    fs::write(path, content).unwrap();
}

fn claude_line(index: usize, usage_key: &str) -> Value {
    let mut message = json!({"id": format!("msg-{usage_key}-{index}"), "model": "claude-sonnet"});
    message[usage_key] = json!({"input_tokens": 100, "output_tokens": 10});
    json!({
        "type": "assistant",
        "timestamp": format!("2026-07-28T03:{:02}:00Z", index),
        "message": message
    })
}

#[test]
fn usage_probe_tracks_trailing_zero_streak_across_appends() {
    let mut probe = UsageProbe::default();
    for usable in [true, false, false] {
        probe.observe(usable);
    }
    assert_eq!(
        probe,
        UsageProbe {
            candidates: 3,
            zero_streak: 2,
            truncated_usage: 0
        }
    );
    let mut all_zero = UsageProbe::default();
    for _ in 0..3 {
        all_zero.observe(false);
    }
    assert_eq!(
        probe.then(all_zero).zero_streak,
        5,
        "追加段全零时末尾连续数接续"
    );
    let mut recovered = UsageProbe::default();
    recovered.observe(false);
    recovered.observe(true);
    assert_eq!(probe.then(recovered).zero_streak, 0, "追加段取到用量即清零");
    assert!(probe.then(all_zero).drifted(FILE_DRIFT_STREAK));
    assert!(!probe.drifted(FILE_DRIFT_STREAK));
}

/// Claude usage 键改名 (message.usage → message.token_usage): 旧实现静默记 0、无任何说明;
/// 现在输出信息级说明 (diagnostic 仍为空, agent 不会被置 error), 热轮命中缓存说明仍在。
#[test]
fn claude_usage_key_rename_raises_notice_and_survives_cache_hits() {
    let root = temp_root("c193-claude-drift");
    let cache_root = root.join("cache");
    let projects = root.join("projects");
    let renamed: Vec<Value> = (0..FILE_DRIFT_STREAK as usize)
        .map(|index| claude_line(index, "token_usage"))
        .collect();
    write_lines(&projects.join("demo/drifted.jsonl"), &renamed);
    let normal: Vec<Value> = (0..8).map(|index| claude_line(index, "usage")).collect();
    write_lines(&projects.join("demo/normal.jsonl"), &normal);

    let scan = || {
        scan_claude_cached(&projects, &window(), &cache_root, &CancellationToken::new()).unwrap()
    };
    let cold = scan();
    assert_eq!(
        cold.notice.as_deref(),
        Some(FILE_NOTICE),
        "只有改名的那个文件触发"
    );
    assert!(cold.diagnostic.is_none(), "哨兵是说明, 不是故障");
    let warm = scan();
    assert_eq!(warm.stats.cache_hits, 2);
    assert_eq!(
        warm.notice.as_deref(),
        Some(FILE_NOTICE),
        "命中缓存的轮次说明不消失"
    );

    // 正常会话追加到改名格式: 追加段接续末尾连续数, 跨过阈值即说明。
    fs::remove_file(projects.join("demo/drifted.jsonl")).unwrap();
    let after_remove = scan();
    assert!(after_remove.notice.is_none(), "正常数据不输出说明");
    let tail: Vec<Value> = (20..20 + FILE_DRIFT_STREAK as usize)
        .map(|index| claude_line(index, "token_usage"))
        .collect();
    append_lines(&projects.join("demo/normal.jsonl"), &tail);
    let appended = scan();
    assert_eq!(appended.stats.cache_appends, 1, "走追加路径");
    assert_eq!(appended.notice.as_deref(), Some(FILE_NOTICE));
    fs::remove_dir_all(root).ok();
}

fn codex_count(input: u64, cached: u64, write: u64, output: u64, key: &str) -> Value {
    let mut info = json!({});
    info[key] = json!({
        "input_tokens": input,
        "cached_input_tokens": cached,
        "cache_write_input_tokens": write,
        "output_tokens": output
    });
    json!({
        "timestamp": "2026-07-28T04:00:00Z",
        "type": "event_msg",
        "payload": {"type": "token_count", "info": info}
    })
}

/// Codex 0.164+ 的 cache_write_input_tokens 包含在 input_tokens 内 (Codex 解析用例口径):
/// 单列为 cache_creation 并从 input 扣除, 总量不变。
#[test]
fn codex_cache_write_tokens_count_as_cache_creation() {
    let root = temp_root("c193-codex-cache-write");
    let cache_root = root.join("cache");
    let mut line = codex_count(100, 40, 60, 10, "last_token_usage");
    line["timestamp"] = json!("2026-07-28T04:00:00Z");
    write_lines(&root.join("sessions/2026/07/28/rollout-a.jsonl"), &[line]);
    let scan = scan_codex_cached(&[root.join("sessions")], &window(), &cache_root);
    let bucket = &scan.contribution.by_day["2026-07-28"];
    assert_eq!(
        (
            bucket.input,
            bucket.cache_read,
            bucket.cache_creation,
            bucket.output
        ),
        (0, 40, 60, 10)
    );
    assert_eq!(bucket.total, 110, "与 Codex total_tokens 一致");
    assert!(scan.notice.is_none());
    fs::remove_dir_all(root).ok();
}

/// Codex token_count 的 last_token_usage / total_token_usage 改名 → 说明; 热轮仍在。
#[test]
fn codex_usage_field_rename_raises_notice() {
    let root = temp_root("c193-codex-drift");
    let cache_root = root.join("cache");
    let lines: Vec<Value> = (0..FILE_DRIFT_STREAK as u64)
        .map(|index| {
            let mut line = codex_count(100 + index, 0, 0, 10, "last_usage_v2");
            line["timestamp"] = json!(format!("2026-07-28T04:{index:02}:00Z"));
            line
        })
        .collect();
    write_lines(
        &root.join("sessions/2026/07/28/rollout-drift.jsonl"),
        &lines,
    );
    let roots = [root.join("sessions")];
    let cold = scan_codex_cached(&roots, &window(), &cache_root);
    assert_eq!(cold.notice.as_deref(), Some(FILE_NOTICE));
    let warm = scan_codex_cached(&roots, &window(), &cache_root);
    assert_eq!(warm.stats.cache_hits, 1);
    assert_eq!(warm.notice.as_deref(), Some(FILE_NOTICE));
    fs::remove_dir_all(root).ok();
}

/// dsh 助手消息的 usage 键改名: 旧实现被预筛直接滤掉 (不含 "usage"), 现在计入哨兵。
#[test]
fn dsh_usage_key_rename_raises_notice() {
    let root = temp_root("c193-dsh-drift");
    let cache_root = root.join("cache");
    let mut lines = vec![json!({"type": "session", "version": 4, "id": "s", "cwd": "/w/demo"})];
    for index in 0..FILE_DRIFT_STREAK as i64 {
        lines.push(json!({
            "type": "assistant/message",
            "time": 1_785_211_200_000_i64 - 60_000 + index,
            "data": {"message": {"id": format!("m-{index}")}, "tokenStats": {"inputTokens": 9}}
        }));
    }
    write_lines(&root.join("ws/session-a/session.v4.jsonl"), &lines);
    let scan = scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert_eq!(scan.notice.as_deref(), Some(FILE_NOTICE));
    assert!(scan.diagnostic.is_none());
    fs::remove_dir_all(root).ok();
}

/// OpenCode 助手消息的 tokens 键改名: 旧查询以 LIKE '%tokens%' 在 SQL 层静默滤掉这些行;
/// 现在按 rowid 末尾连续 20 行取不到用量即说明, 增量读取接续计数。
#[test]
fn opencode_tokens_rename_raises_notice_across_incremental_reads() {
    use rusqlite::Connection;
    let root = temp_root("c193-opencode-drift");
    let db_path = root.join("opencode.db");
    let cache_root = root.join("cache");
    let connection = Connection::open(&db_path).unwrap();
    connection
        .execute("CREATE TABLE message (data text not null)", [])
        .unwrap();
    let base = 1_785_211_200_000_i64 - 3_600_000;
    let insert = |offset: i64, tokens_key: &str| {
        let mut message = json!({
            "role": "assistant",
            "time": {"created": base + offset},
            "modelID": "qwen3-coder"
        });
        message[tokens_key] = json!({"input": 7, "output": 2});
        connection
            .execute(
                "INSERT INTO message (data) VALUES (?1)",
                [&message.to_string()],
            )
            .unwrap();
    };
    insert(0, "tokens");
    for offset in 1..10 {
        insert(offset, "usage_v2");
    }
    let scan = || {
        scan_opencode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap()
    };
    let first = scan();
    assert!(first.notice.is_none(), "末尾 9 行未到阈值");
    for offset in 10..(10 + DATABASE_DRIFT_STREAK as i64) {
        insert(offset, "usage_v2");
    }
    let second = scan();
    assert_eq!(second.stats.cache_appends, 1, "走增量读取");
    assert_eq!(
        second.notice.as_deref(),
        Some("疑似来源 usage 字段口径变化: 数据库最近 29 条用量记录均未取到用量")
    );
    let third = scan();
    assert_eq!(third.stats.cache_hits, 1);
    assert_eq!(third.notice, second.notice, "命中缓存的轮次说明不消失");
    drop(connection);
    fs::remove_dir_all(root).ok();
}

/// ZCode 列仍在但取值全零 (列改名由 schema 指纹拦截为故障): 末尾连续 20 行即说明;
/// 零星的零值行 (本机 4 万行中最长连续 5 行) 不触发。
#[test]
fn zcode_trailing_zero_rows_raise_notice_but_scattered_zeros_do_not() {
    use rusqlite::Connection;
    let root = temp_root("c193-zcode-drift");
    let db_path = root.join("zcode.db");
    let cache_root = root.join("cache");
    let connection = Connection::open(&db_path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE session (id text primary key, directory text, task_type text);
             CREATE TABLE model_usage (
                started_at integer not null, model_id text,
                input_tokens integer, output_tokens integer, reasoning_tokens integer,
                cache_creation_input_tokens integer, cache_read_input_tokens integer,
                session_id text
             );",
        )
        .unwrap();
    let base = 1_785_211_200_000_i64 - 3_600_000;
    let insert = |offset: i64, input: i64| {
        connection
            .execute(
                "INSERT INTO model_usage (started_at, model_id, input_tokens, output_tokens) \
                 VALUES (?1, 'glm', ?2, ?2)",
                rusqlite::params![base + offset, input],
            )
            .unwrap();
    };
    for offset in 0..30 {
        insert(offset, if offset % 6 == 2 { 0 } else { 5 });
    }
    let scan =
        || scan_zcode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert!(scan().notice.is_none(), "零星零值行不触发");
    for offset in 30..(30 + DATABASE_DRIFT_STREAK as i64) {
        insert(offset, 0);
    }
    assert_eq!(
        scan().notice.as_deref(),
        Some("疑似来源 usage 字段口径变化: 数据库最近 20 条用量记录均未取到用量")
    );
    drop(connection);
    fs::remove_dir_all(root).ok();
}
