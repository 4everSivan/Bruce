use super::codex::{codex_tree_signature_with_probe, CodexFileCandidate};
use super::{
    scan_claude, scan_claude_cached, scan_codebuddy, scan_codebuddy_cached, scan_grok,
    scan_grok_cached, scan_jsonl_tree_with_line_probe, scan_kimi_tree, scan_kimi_tree_cached,
    scan_kimi_tree_with_cancellation, scan_opencode, scan_opencode_cached, scan_pi, scan_pi_cached,
    scan_zcode, scan_zcode_cached,
};
use collector_domain::CollectionWindow;
use collector_runtime::{CancellationToken, RuntimeError};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) fn window() -> CollectionWindow {
    let context: Map<String, Value> = serde_json::from_value(json!({
        "now": "2026-07-28T12:00:00+08:00",
        "timezone": "Asia/Shanghai",
        "days": 3
    }))
    .unwrap();
    CollectionWindow::from_context(&context).unwrap()
}

pub(super) fn temp_root(label: &str) -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "bruce-codex-dedup-{label}-{}-{suffix}",
        std::process::id()
    ));
    fs::create_dir_all(&root).unwrap();
    root
}

#[test]
fn cancellation_returns_typed_runtime_error_before_first_directory() {
    let root = temp_root("cancel-before-directory");
    let sessions = root.join("nested");
    fs::create_dir_all(&sessions).unwrap();
    fs::write(
        sessions.join("session.jsonl"),
        "{\"type\":\"usage.record\",\"time\":1785211200000,\"usage\":{\"inputOther\":1}}\n"
            .repeat(4_096),
    )
    .unwrap();
    let cancellation = CancellationToken::new();
    cancellation.cancel();

    let result = scan_kimi_tree_with_cancellation(&root, &window(), &cancellation);

    assert!(matches!(
        result,
        Err(super::SourceScanError::Runtime(RuntimeError::Cancelled))
    ));
    fs::remove_dir_all(root).ok();
}

#[test]
fn cancellation_discards_mid_file_partial_result() {
    let root = temp_root("cancel-mid-file");
    let session = root.join("session.jsonl");
    fs::write(
        &session,
        "{\"type\":\"usage.record\",\"time\":1785211200000,\"usage\":{\"inputOther\":1}}\n"
            .repeat(4_096),
    )
    .unwrap();
    let cancellation = CancellationToken::new();
    let mut probes = 0;

    let result = scan_jsonl_tree_with_line_probe(
        &root,
        window().cutoff_ts,
        &cancellation,
        |_, _, line, stats| {
            let _ = super::parse_json_line(line, stats);
        },
        || {
            probes += 1;
            cancellation.cancel();
        },
    );

    assert_eq!(
        probes, 1,
        "cancellation probe should run after the first parsed line"
    );
    assert!(matches!(
        result,
        Err(super::SourceScanError::Runtime(RuntimeError::Cancelled))
    ));
    fs::remove_dir_all(root).ok();
}

#[test]
fn codex_signature_cancellation_stops_before_all_candidates_are_hashed() {
    let groups = (0..4_096)
        .map(|index| {
            (
                format!("rollout:{index}"),
                vec![CodexFileCandidate {
                    path: PathBuf::from(format!("/fixture/{index}.jsonl")),
                    modified: index as f64,
                    size: index,
                    digest: None,
                    device: 0,
                    inode: 0,
                }],
            )
        })
        .collect::<BTreeMap<_, _>>();
    let cancellation = CancellationToken::new();
    let mut probes = 0;

    let result = codex_tree_signature_with_probe(&groups, &cancellation, || {
        probes += 1;
        cancellation.cancel();
    });

    assert_eq!(probes, 1);
    assert!(matches!(
        result,
        Err(super::SourceScanError::Runtime(RuntimeError::Cancelled))
    ));
}

#[test]
fn grok_later_root_io_error_preserves_earlier_root_contribution() {
    let root = temp_root("grok-per-root-io");
    let valid = root.join("valid/project/session");
    fs::create_dir_all(&valid).unwrap();
    fs::write(
        valid.join("conversation.jsonl"),
        "{\"type\":\"assistant\",\"content\":\"abcdefgh\"}\n",
    )
    .unwrap();
    let unreadable = root.join("not-a-directory");
    fs::write(&unreadable, "fixture").unwrap();

    let grok_window = CollectionWindow::from_context(
        // 不固定 now: 该用例依赖文件 mtime (真实当前时间) 作为记录时间,
        // 固定过去时间会让记录落到窗口之外而恒失败 (时间炸弹).
        &serde_json::from_value(json!({
            "timezone": "Asia/Shanghai",
            "days": 14
        }))
        .unwrap(),
    )
    .unwrap();
    let scan = scan_grok(&[valid, unreadable], &grok_window);

    assert!(scan.found, "earlier readable root must remain published");
    assert_eq!(scan.stats.io_errors, 1, "later root error must be counted");
    assert_eq!(
        scan.contribution
            .by_day
            .get(&grok_window.today)
            .map(|bucket| bucket.total),
        Some(2)
    );
    fs::remove_dir_all(root).ok();
}

#[test]
fn cached_additive_jsonl_sources_match_cold_and_warm_results() {
    let root = temp_root("jsonl-additive-cache");
    let cache_root = root.join("cache");
    let base = 1_785_211_200_000_i64;

    let kimi_root = root.join("kimi");
    fs::create_dir_all(&kimi_root).unwrap();
    fs::write(
        kimi_root.join("session.jsonl"),
        [
            json!({
                "type": "usage.record",
                "time": base,
                "model": "kimi-k2",
                "usage": {"inputOther": 10, "output": 2}
            })
            .to_string(),
            json!({"type": "assistant", "text": "ignored"}).to_string(),
            json!({
                "type": "usage.record",
                "time": base + 3_600_000,
                "model": "kimi-k2",
                "usage": {"inputOther": 3, "inputCacheRead": 4, "output": 1}
            })
            .to_string(),
        ]
        .join("\n"),
    )
    .unwrap();
    let expected_kimi = scan_kimi_tree(&kimi_root, &window());
    let cold_kimi = scan_kimi_tree_cached(
        &kimi_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    let warm_kimi = scan_kimi_tree_cached(
        &kimi_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    assert_eq!(cold_kimi.contribution, expected_kimi.contribution);
    assert_eq!(warm_kimi.contribution, expected_kimi.contribution);
    assert!(warm_kimi.stats.cache_hits > 0);
    assert_eq!(warm_kimi.stats.json_lines_parsed, 0);

    let pi_root = root.join("pi");
    fs::create_dir_all(&pi_root).unwrap();
    fs::write(
        pi_root.join("session.jsonl"),
        [
            json!({
                "type": "message",
                "message": {
                    "role": "assistant",
                    "timestamp": base,
                    "model": "pi-model",
                    "usage": {"input": 7, "output": 5, "reasoning": 2, "cacheRead": 1}
                }
            })
            .to_string(),
            json!({"type": "session", "id": "ignored"}).to_string(),
        ]
        .join("\n"),
    )
    .unwrap();
    let expected_pi = scan_pi(&pi_root, &window());
    let cold_pi =
        scan_pi_cached(&pi_root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let warm_pi =
        scan_pi_cached(&pi_root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert_eq!(cold_pi.contribution, expected_pi.contribution);
    assert_eq!(warm_pi.contribution, expected_pi.contribution);
    assert!(warm_pi.stats.cache_hits > 0);
    assert_eq!(warm_pi.stats.json_lines_parsed, 0);

    let grok_root = root.join("grok/project/session");
    fs::create_dir_all(&grok_root).unwrap();
    fs::write(
        grok_root.join("conversation.jsonl"),
        [
            json!({"type": "user", "content": "abcdefgh"}).to_string(),
            json!({"type": "assistant", "content": [{"text": "abcdefghijkl"}]}).to_string(),
            json!({"type": "system", "content": "ignored"}).to_string(),
        ]
        .join("\n")
            + "\n",
    )
    .unwrap();
    let grok_window = CollectionWindow::from_context(
        // 不固定 now: 该用例依赖文件 mtime (真实当前时间) 作为记录时间,
        // 固定过去时间会让记录落到窗口之外而恒失败 (时间炸弹).
        &serde_json::from_value(json!({
            "timezone": "Asia/Shanghai",
            "days": 14
        }))
        .unwrap(),
    )
    .unwrap();
    let expected_grok = scan_grok(std::slice::from_ref(&grok_root), &grok_window);
    let cold_grok = scan_grok_cached(
        std::slice::from_ref(&grok_root),
        &grok_window,
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    let warm_grok = scan_grok_cached(
        std::slice::from_ref(&grok_root),
        &grok_window,
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    assert_eq!(cold_grok.contribution, expected_grok.contribution);
    assert_eq!(warm_grok.contribution, expected_grok.contribution);
    assert!(warm_grok.stats.cache_hits > 0);
    assert_eq!(warm_grok.stats.json_lines_parsed, 0);
    let mut grok_file = fs::OpenOptions::new()
        .append(true)
        .open(grok_root.join("conversation.jsonl"))
        .unwrap();
    std::io::Write::write_all(
        &mut grok_file,
        json!({"type": "assistant", "content": "abcdefghijklmnop"})
            .to_string()
            .as_bytes(),
    )
    .unwrap();
    drop(grok_file);
    let appended_grok = scan_grok_cached(
        &[root.join("grok/project/session")],
        &grok_window,
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    let expected_appended_grok = scan_grok(&[root.join("grok/project/session")], &grok_window);
    assert_eq!(
        appended_grok.contribution,
        expected_appended_grok.contribution
    );
    assert!(appended_grok.stats.cache_appends > 0);

    fs::remove_dir_all(root).ok();
}

#[test]
fn cached_claude_and_codebuddy_preserve_cross_file_deduplication() {
    let root = temp_root("jsonl-dedupe-cache");
    let cache_root = root.join("cache");
    let base = "2026-07-28T04:00:00Z";

    let claude_root = root.join("claude");
    let claude_a = claude_root.join("project-a");
    let claude_b = claude_root.join("project-b");
    fs::create_dir_all(&claude_a).unwrap();
    fs::create_dir_all(&claude_b).unwrap();
    let claude_line = |id: &str, input: u64, output: u64| {
        json!({
            "type": "assistant",
            "timestamp": base,
            "message": {
                "id": id,
                "model": "claude-sonnet",
                "usage": {
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": 4
                }
            }
        })
        .to_string()
    };
    fs::write(
        claude_a.join("one.jsonl"),
        [
            claude_line("message-1", 10, 2),
            claude_line("direct-a", 3, 1),
        ]
        .join("\n")
            + "\n",
    )
    .unwrap();
    fs::write(claude_b.join("two.jsonl"), claude_line("message-1", 20, 5)).unwrap();
    let expected_claude = scan_claude(&claude_root, &window());
    let cold_claude = scan_claude_cached(
        &claude_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    let warm_claude = scan_claude_cached(
        &claude_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    assert_eq!(cold_claude.contribution, expected_claude.contribution);
    assert_eq!(warm_claude.contribution, expected_claude.contribution);
    assert!(warm_claude.stats.cache_hits >= 2);
    assert_eq!(warm_claude.stats.json_lines_parsed, 0);
    let mut claude_file = fs::OpenOptions::new()
        .append(true)
        .open(claude_a.join("one.jsonl"))
        .unwrap();
    std::io::Write::write_all(&mut claude_file, claude_line("message-1", 30, 6).as_bytes())
        .unwrap();
    drop(claude_file);
    let appended_claude = scan_claude_cached(
        &claude_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    let expected_appended_claude = scan_claude(&claude_root, &window());
    assert_eq!(
        appended_claude.contribution,
        expected_appended_claude.contribution
    );
    assert!(appended_claude.stats.cache_appends > 0);

    let codebuddy_root = root.join("codebuddy");
    let codebuddy_project_a = codebuddy_root.join("project-a");
    let codebuddy_project_b = codebuddy_root.join("project-b");
    fs::create_dir_all(&codebuddy_project_a).unwrap();
    fs::create_dir_all(&codebuddy_project_b).unwrap();
    let codebuddy_line = |session: &str, id: &str, input: u64, output: u64| {
        json!({
            "type": "message",
            "role": "assistant",
            "sessionId": session,
            "timestamp": 1_785_211_200_000_i64,
            "message": {"usage": {
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_input_tokens": 0
            }},
            "providerData": {"model": "codebuddy-model", "messageId": id}
        })
        .to_string()
    };
    fs::write(
        codebuddy_project_a.join("first.jsonl"),
        codebuddy_line("same-session", "same-message", 10, 2),
    )
    .unwrap();
    fs::write(
        codebuddy_project_a.join("second.jsonl"),
        codebuddy_line("same-session", "same-message", 20, 5),
    )
    .unwrap();
    fs::write(
        codebuddy_project_b.join("third.jsonl"),
        codebuddy_line("same-session", "same-message", 7, 1),
    )
    .unwrap();
    let expected_codebuddy = scan_codebuddy(&codebuddy_root, &window());
    let cold_codebuddy = scan_codebuddy_cached(
        &codebuddy_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    let warm_codebuddy = scan_codebuddy_cached(
        &codebuddy_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    assert_eq!(cold_codebuddy.contribution, expected_codebuddy.contribution);
    assert_eq!(warm_codebuddy.contribution, expected_codebuddy.contribution);
    assert!(warm_codebuddy.stats.cache_hits >= 3);
    assert_eq!(warm_codebuddy.stats.json_lines_parsed, 0);

    let mut cache_text = String::new();
    for entry in fs::read_dir(&cache_root).unwrap() {
        let path = entry.unwrap().path();
        if path.is_file() {
            cache_text.push_str(&fs::read_to_string(path).unwrap());
        }
    }
    assert!(
        !cache_text.contains("message-1") && !cache_text.contains("same-message"),
        "cache must store only hashed deduplication keys"
    );
    assert!(!cache_text.contains("refresh_token"));
    assert!(!cache_text.contains("/Users/"));

    fs::remove_dir_all(root).ok();
}

#[test]
fn cached_jsonl_handles_append_rewrite_delete_and_corruption() {
    let root = temp_root("jsonl-state-transitions");
    let source_root = root.join("kimi");
    let cache_root = root.join("cache");
    fs::create_dir_all(&source_root).unwrap();
    let path = source_root.join("session.jsonl");
    let base = 1_785_211_200_000_i64;
    let line = |input: u64| {
        json!({
            "type": "usage.record",
            "time": base,
            "model": "kimi-k2",
            "usage": {"inputOther": input, "output": 1}
        })
        .to_string()
    };
    fs::write(&path, format!("{}\n", line(3))).unwrap();

    let cold = scan_kimi_tree_cached(
        &source_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    assert_eq!(cold.stats.cache_rebuilds, 1);

    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    std::io::Write::write_all(&mut file, format!("{}\n", line(4)).as_bytes()).unwrap();
    drop(file);
    let appended = scan_kimi_tree_cached(
        &source_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    let expected_appended = scan_kimi_tree(&source_root, &window());
    assert_eq!(appended.contribution, expected_appended.contribution);
    assert_eq!(appended.stats.cache_appends, 1);
    assert_eq!(appended.stats.lines_seen, 1);

    fs::write(&path, line(9)).unwrap();
    let rewritten = scan_kimi_tree_cached(
        &source_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    let expected_rewritten = scan_kimi_tree(&source_root, &window());
    assert_eq!(rewritten.contribution, expected_rewritten.contribution);
    assert!(rewritten.stats.cache_invalidations > 0);
    assert_eq!(rewritten.stats.cache_rebuilds, 1);

    let entry_path = fs::read_dir(&cache_root)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("jsonl-"))
        })
        .expect("source cache entry should exist");
    fs::write(&entry_path, b"not-json").unwrap();
    let repaired = scan_kimi_tree_cached(
        &source_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    assert_eq!(repaired.contribution, expected_rewritten.contribution);
    assert_eq!(repaired.stats.cache_corruptions, 1);
    assert_eq!(repaired.stats.cache_rebuilds, 1);

    fs::remove_file(&path).unwrap();
    let deleted = scan_kimi_tree_cached(
        &source_root,
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    assert!(!deleted.found);
    assert!(deleted.contribution.by_day.is_empty());
    assert_eq!(deleted.stats.cache_deletions, 1);
    fs::remove_dir_all(root).ok();
}

#[test]
fn opencode_sqlite_cache_reuses_unchanged_and_reads_append() {
    use rusqlite::Connection;

    let root = temp_root("opencode-cache");
    let db_path = root.join("opencode.db");
    let cache_root = root.join("cache");
    let base = 1_785_211_200_000_i64;
    let message = |created: i64, input: u64| {
        json!({
            "role": "assistant",
            "time": { "created": created },
            "tokens": { "input": input, "output": 2 },
            "modelID": "qwen3-coder",
        })
        .to_string()
    };

    let connection = Connection::open(&db_path).unwrap();
    connection
        .execute("CREATE TABLE message (data text not null)", [])
        .unwrap();
    connection
        .execute(
            "INSERT INTO message (data) VALUES (?1)",
            [&message(base - 3_600_000, 7)],
        )
        .unwrap();
    drop(connection);

    let cold =
        scan_opencode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let warm =
        scan_opencode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert!(cold.found);
    assert_eq!(
        warm.stats.cache_hits, 1,
        "unchanged database should hit cache"
    );
    assert_eq!(
        warm.stats.sqlite_rows_read, 0,
        "warm scan must not read rows"
    );
    assert_eq!(warm.contribution, cold.contribution);

    let connection = Connection::open(&db_path).unwrap();
    connection
        .execute(
            "INSERT INTO message (data) VALUES (?1)",
            [&message(base - 1_800_000, 11)],
        )
        .unwrap();
    drop(connection);

    let appended =
        scan_opencode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let expected = scan_opencode(&db_path, &window());
    assert_eq!(appended.contribution, expected.contribution);
    assert!(
        appended.stats.cache_appends > 0,
        "append-only database change should use cursor cache"
    );
    assert!(appended.stats.sqlite_rows_read <= 1);

    let replacement = root.join("opencode-replacement.db");
    let connection = Connection::open(&replacement).unwrap();
    connection
        .execute("CREATE TABLE message (data text not null)", [])
        .unwrap();
    connection
        .execute(
            "INSERT INTO message (data) VALUES (?1)",
            [&message(base - 900_000, 19)],
        )
        .unwrap();
    drop(connection);
    fs::rename(&replacement, &db_path).unwrap();

    let rewritten =
        scan_opencode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let expected = scan_opencode(&db_path, &window());
    assert_eq!(rewritten.contribution, expected.contribution);
    assert!(
        rewritten.stats.cache_rebuilds > 0,
        "database replacement must fall back to a full rebuild"
    );
    fs::remove_dir_all(root).ok();
}

/// C040 回归: 跨窗口身份错位的缓存条目必须回退全量重建, 严禁以空 base 增量合并
/// (该路径曾把整个历史清空而游标照常前推, 今日用量只剩最后一轮 delta)。
#[test]
fn zcode_sqlite_cache_window_mismatch_rebuilds_instead_of_empty_append() {
    use rusqlite::Connection;

    let root = temp_root("zcode-cache-window-mismatch");
    let db_path = root.join("zcode.db");
    let cache_root = root.join("cache");
    let base = 1_785_211_200_000_i64; // 2026-07-28T12:00+08, 与 window() 锚点一致
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
    let insert = |connection: &Connection, timestamp: i64, input: i64| {
        connection
            .execute(
                "INSERT INTO model_usage (started_at, model_id, input_tokens, output_tokens) \
                     VALUES (?1, 'glm', ?2, 3)",
                rusqlite::params![timestamp, input],
            )
            .unwrap();
    };
    // 一单在 3 天窗口之外 (30 天窗口之内), 一单在 3 天窗口之内。
    insert(&connection, base - 3 * 86_400_000, 5);
    insert(&connection, base - 1_800_000, 7);
    drop(connection);

    // 长窗口 (30 天) 先扫: 写下 window_days=30 的条目, cursor 越过全部行。
    let long_context: Map<String, Value> = serde_json::from_value(json!({
        "now": "2026-07-28T12:00:00+08:00",
        "timezone": "Asia/Shanghai",
        "days": 30
    }))
    .unwrap();
    let long_window = CollectionWindow::from_context(&long_context).unwrap();
    let seeded = scan_zcode_cached(
        &db_path,
        &long_window,
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    assert!(seeded.found);

    // DB 增长 (签名变化) 后换 3 天窗口扫描 (身份错位):
    // 旧行为 = to_domain 越界 → 空 base + 仅增量 → 窗口内旧行丢失;
    // 新行为 = 身份不匹配回退全量重建, 结果与同窗口冷扫逐字段一致。
    let connection = Connection::open(&db_path).unwrap();
    insert(&connection, base - 900_000, 11);
    drop(connection);

    let mismatched =
        scan_zcode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let expected = scan_zcode(&db_path, &window());
    assert_eq!(
        mismatched.contribution, expected.contribution,
        "窗口身份错位必须回退全量重建, 不得以空 base 增量合并"
    );
    assert_eq!(
        mismatched.stats.cache_appends, 0,
        "身份错位时不得走增量追加路径"
    );

    // 反方向同样回退重建: 短窗口 (3 天) 条目的天索引在长窗口 (30 天) day_list 下
    // 恰好全部在界内, 跨窗口合并会"成功"解码但把数据平移到错误的日期 (scramble)。
    let connection = Connection::open(&db_path).unwrap();
    insert(&connection, base - 600_000, 13);
    drop(connection);

    let reverse = scan_zcode_cached(
        &db_path,
        &long_window,
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    let expected_long = scan_zcode(&db_path, &long_window);
    assert_eq!(
        reverse.contribution, expected_long.contribution,
        "反方向窗口错位同样必须回退全量重建, 不得按错误日期合并"
    );
    assert_eq!(
        reverse.stats.cache_appends, 0,
        "反方向身份错位同样不得走增量追加"
    );
    fs::remove_dir_all(root).ok();
}

/// C072: 聚合版本失配的旧格式条目必须回退全量重建, 不得以缺明细的
/// v2 base 增量追加 —— 否则 C070 新增的逐日/逐小时模型明细会在升级
/// 后永久缺失 (月明细为 v2 既有字段而幸存, 形成月/日视图口径分裂)。
#[test]
fn zcode_sqlite_cache_aggregation_version_mismatch_rebuilds_detail() {
    use rusqlite::Connection;

    let root = temp_root("zcode-cache-aggregation-version");
    let db_path = root.join("zcode.db");
    let cache_root = root.join("cache");
    let base = 1_785_211_200_000_i64; // 2026-07-28T12:00+08, 与 window() 锚点一致
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
    let insert = |connection: &Connection, timestamp: i64, input: i64| {
        connection
            .execute(
                "INSERT INTO model_usage (started_at, model_id, input_tokens, output_tokens) \
                     VALUES (?1, 'glm', ?2, 3)",
                rusqlite::params![timestamp, input],
            )
            .unwrap();
    };
    // 一单在前天 (窗口内非今日, 进 models_by_day 明细), 一单在今日。
    insert(&connection, base - 2 * 86_400_000, 5);
    insert(&connection, base - 1_800_000, 7);
    drop(connection);

    // 冷扫写入当前格式条目 (aggregation_version=3 + 全量日明细)。
    let seeded =
        scan_zcode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert!(seeded.found);
    assert_eq!(
        seeded.contribution.models_by_day.len(),
        2,
        "冷扫应产出两个日期的逐日模型明细"
    );

    // 把条目改写成 v2 形状: 剥离 aggregation_version 与逐日/逐小时明细
    // (字段均为 serde 可缺省), 复刻升级当晚生产缓存的真实状态。
    let cache_files: Vec<_> = fs::read_dir(&cache_root)
        .unwrap()
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.starts_with("sqlite-") && name.ends_with(".json"))
                .unwrap_or(false)
        })
        .collect();
    assert_eq!(cache_files.len(), 1, "应恰好存在一个 sqlite 缓存条目");
    let legacy: Value = {
        let mut value: Value =
            serde_json::from_str(&fs::read_to_string(&cache_files[0]).unwrap()).unwrap();
        let object = value.as_object_mut().unwrap();
        object.remove("aggregation_version");
        let contribution = object.get_mut("contribution").unwrap();
        let contribution = contribution.as_object_mut().unwrap();
        contribution.remove("day_models");
        contribution.remove("hour_models");
        value
    };
    fs::write(&cache_files[0], serde_json::to_string(&legacy).unwrap()).unwrap();

    // DB 追加新行 (签名前进, 旧行为会走增量追加)。
    let connection = Connection::open(&db_path).unwrap();
    insert(&connection, base - 900_000, 11);
    drop(connection);

    let upgraded =
        scan_zcode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let expected = scan_zcode(&db_path, &window());
    assert_eq!(
        upgraded.contribution, expected.contribution,
        "聚合版本失配必须回退全量重建, 不得以缺明细的 v2 base 增量合并"
    );
    assert_eq!(
        upgraded.contribution.models_by_day.len(),
        2,
        "重建后前天的逐日模型明细必须恢复"
    );
    assert_eq!(
        upgraded.stats.cache_appends, 0,
        "聚合版本失配时不得走增量追加路径"
    );
    fs::remove_dir_all(root).ok();
}

#[test]
fn zcode_sqlite_cache_reuses_unchanged_and_reads_append() {
    use rusqlite::Connection;

    let root = temp_root("zcode-cache");
    let db_path = root.join("zcode.db");
    let cache_root = root.join("cache");
    let base = 1_785_211_200_000_i64;
    let create_schema = |path: &Path| {
        let connection = Connection::open(path).unwrap();
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
        connection
    };
    let insert = |connection: &Connection, timestamp: i64, input: i64| {
        connection
            .execute(
                "INSERT INTO model_usage (started_at, model_id, input_tokens, output_tokens) \
                     VALUES (?1, 'glm', ?2, 3)",
                rusqlite::params![timestamp, input],
            )
            .unwrap();
    };

    let connection = create_schema(&db_path);
    insert(&connection, base - 3_600_000, 7);
    drop(connection);

    let cold =
        scan_zcode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let warm =
        scan_zcode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert!(cold.found);
    assert_eq!(
        warm.stats.cache_hits, 1,
        "unchanged database should hit cache"
    );
    assert_eq!(
        warm.stats.sqlite_rows_read, 0,
        "warm scan must not read rows"
    );
    assert_eq!(warm.contribution, cold.contribution);

    let connection = Connection::open(&db_path).unwrap();
    insert(&connection, base - 1_800_000, 11);
    drop(connection);

    let appended =
        scan_zcode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let expected = scan_zcode(&db_path, &window());
    assert_eq!(appended.contribution, expected.contribution);
    assert!(
        appended.stats.cache_appends > 0,
        "append-only database change should use cursor cache"
    );
    assert!(appended.stats.sqlite_rows_read <= 1);

    let replacement = root.join("zcode-replacement.db");
    let connection = create_schema(&replacement);
    insert(&connection, base - 900_000, 19);
    drop(connection);
    fs::rename(&replacement, &db_path).unwrap();

    let rewritten =
        scan_zcode_cached(&db_path, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let expected = scan_zcode(&db_path, &window());
    assert_eq!(rewritten.contribution, expected.contribution);
    assert!(
        rewritten.stats.cache_rebuilds > 0,
        "database replacement must fall back to a full rebuild"
    );
    fs::remove_dir_all(root).ok();
}

#[test]
fn sqlite_cache_reports_incompatible_schema_instead_of_empty_success() {
    use rusqlite::Connection;

    let root = temp_root("sqlite-schema");
    let db_path = root.join("opencode.db");
    let connection = Connection::open(&db_path).unwrap();
    connection
        .execute("CREATE TABLE message (payload text not null)", [])
        .unwrap();
    drop(connection);

    let scan = scan_opencode_cached(
        &db_path,
        &window(),
        &root.join("cache"),
        &CancellationToken::new(),
    )
    .unwrap();
    assert!(!scan.found);
    assert!(scan
        .diagnostic
        .as_deref()
        .is_some_and(|message| message.contains("schema")));
    fs::remove_dir_all(root).ok();
}

/// 行数超上限时必须保留最新记录: 10_010 行中最早的 10 行被截掉,
/// 最新 10_000 行全部进入聚合 (7/26 归零, 7/28 完整).
#[test]
fn zcode_row_cap_keeps_newest_rows() {
    use rusqlite::Connection;
    let root = temp_root("zcode-cap");
    let db_path = root.join("db.sqlite");
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
    // 窗口: 2026-07-26 00:00+08 = base - 216_000_000ms; base = 7/28 12:00+08.
    let base = 1_785_211_200_000_i64;
    let old_ts = base - 215_700_000; // 7/26 00:05+08
    let new_ts = base - 3_600_000; // 7/28 11:00+08
    connection.execute("BEGIN", []).unwrap();
    for i in 0..10 {
        connection
            .execute(
                "INSERT INTO model_usage (started_at, model_id, input_tokens, output_tokens) \
                     VALUES (?1, 'glm', 1000, 0)",
                [old_ts + i],
            )
            .unwrap();
    }
    for i in 0..30_000 {
        connection
            .execute(
                "INSERT INTO model_usage (started_at, model_id, input_tokens, output_tokens) \
                     VALUES (?1, 'glm', 10, 0)",
                [new_ts + i],
            )
            .unwrap();
    }
    connection.execute("COMMIT", []).unwrap();
    drop(connection);

    let scan = scan_zcode(&db_path, &window());
    assert!(scan.diagnostic.is_none(), "扫描不应报错");
    assert!(scan.found, "应识别到数据");
    assert_eq!(scan.stats.sqlite_rows_read, 30_000, "应恰好读到上限行数");
    assert!(scan.capped, "C041: 触顶必须携带截断标记");
    let by_day = &scan.contribution.by_day;
    assert_eq!(
        by_day
            .get("2026-07-26")
            .map(|bucket| bucket.total)
            .unwrap_or(0),
        0,
        "被截断的最早 10 行不得计入 7/26"
    );
    assert_eq!(
        by_day
            .get("2026-07-28")
            .map(|bucket| bucket.total)
            .unwrap_or(0),
        30_000 * 10,
        "最新 10_000 行应完整计入 7/28"
    );
    fs::remove_dir_all(&root).ok();
}

/// 行数超上限时按 rowid DESC 保留最新消息: 最早的 10 行被截掉,
/// 最新 10_000 行完整进入聚合.
#[test]
fn opencode_row_cap_keeps_newest_messages() {
    use rusqlite::Connection;
    let root = temp_root("opencode-cap");
    let db_path = root.join("opencode.db");
    let connection = Connection::open(&db_path).unwrap();
    connection
        .execute("CREATE TABLE message (data text not null)", [])
        .unwrap();
    let base = 1_785_211_200_000_i64; // 7/28 12:00+08
    let old_ts = base - 215_700_000; // 7/26 00:05+08
    let new_ts = base - 3_600_000; // 7/28 11:00+08
    let message = |created: i64, input: u64| {
        json!({
            "role": "assistant",
            "time": { "created": created },
            "tokens": { "input": input, "output": 0 },
            "modelID": "qwen3-coder",
        })
        .to_string()
    };
    connection.execute("BEGIN", []).unwrap();
    for i in 0..10 {
        connection
            .execute(
                "INSERT INTO message (data) VALUES (?1)",
                [&message(old_ts + i, 1000)],
            )
            .unwrap();
    }
    for i in 0..30_000 {
        connection
            .execute(
                "INSERT INTO message (data) VALUES (?1)",
                [&message(new_ts + i, 7)],
            )
            .unwrap();
    }
    connection.execute("COMMIT", []).unwrap();
    drop(connection);

    let scan = scan_opencode(&db_path, &window());
    assert!(scan.diagnostic.is_none(), "扫描不应报错");
    assert_eq!(scan.stats.sqlite_rows_read, 30_000, "应恰好读到上限行数");
    assert!(scan.capped, "C041: 触顶必须携带截断标记");
    let by_day = &scan.contribution.by_day;
    assert_eq!(
        by_day
            .get("2026-07-26")
            .map(|bucket| bucket.total)
            .unwrap_or(0),
        0,
        "被截断的最早 10 行不得计入 7/26"
    );
    assert_eq!(
        by_day
            .get("2026-07-28")
            .map(|bucket| bucket.total)
            .unwrap_or(0),
        30_000 * 7,
        "最新 30_000 行应完整计入 7/28"
    );
    fs::remove_dir_all(&root).ok();
}

fn window_at(now: &str, days: u32) -> CollectionWindow {
    let context: Map<String, Value> = serde_json::from_value(json!({
        "now": now,
        "timezone": "Asia/Shanghai",
        "days": days
    }))
    .unwrap();
    CollectionWindow::from_context(&context).unwrap()
}

/// C116: JSONL 缓存条目与窗口无关 —— 跨日 (today 变化) 与改窗口长度都直接命中缓存,
/// 不再整树重新解析; 聚合结果与不走缓存的参照实现逐字段一致。
#[test]
fn jsonl_caches_survive_day_rollover_and_window_length_changes() {
    let root = temp_root("c116-rollover");
    let cache_root = root.join("cache");
    let claude_root = root.join("claude").join("-Users-demo-project");
    let kimi_cli_root = root.join("kimi-cli").join("session");
    fs::create_dir_all(&claude_root).unwrap();
    fs::create_dir_all(&kimi_cli_root).unwrap();
    let day_27 = 1_785_124_800_000_i64; // 2026-07-27 12:00+08
    let day_28 = 1_785_211_200_000_i64; // 2026-07-28 12:00+08
    let claude_line = |id: &str, at: &str, input: u64| {
        json!({"type": "assistant", "timestamp": at, "message": {"id": id, "model": "claude-opus-5-5",
            "usage": {"input_tokens": input, "output_tokens": 2, "cache_read_input_tokens": 5}}})
        .to_string()
    };
    fs::write(
        claude_root.join("session.jsonl"),
        format!(
            "{}\n{}\n",
            claude_line("m1", "2026-07-27T04:00:00Z", 10),
            claude_line("m2", "2026-07-28T04:00:00Z", 20)
        ),
    )
    .unwrap();
    let kimi_line = |at: i64, input: u64| {
        json!({"type": "usage.record", "time": at, "model": "kimi-k2", "usage": {"inputOther": input, "output": 1}})
            .to_string()
    };
    fs::write(
        kimi_cli_root.join("wire.jsonl"),
        format!("{}\n{}\n", kimi_line(day_27, 3), kimi_line(day_28, 4)),
    )
    .unwrap();
    let claude_dir = root.join("claude");
    let kimi_dir = root.join("kimi-cli");
    let token = CancellationToken::new();

    let windows = [
        ("2026-07-28T12:00:00+08:00", 3, true),
        ("2026-07-29T09:00:00+08:00", 3, false),
        ("2026-07-29T09:00:00+08:00", 182, false),
        ("2026-07-30T09:00:00+08:00", 14, false),
    ];
    for (now, days, cold) in windows {
        let window = window_at(now, days);
        let claude = scan_claude_cached(&claude_dir, &window, &cache_root, &token).unwrap();
        let kimi = super::scan_kimi_cli_cached(&kimi_dir, &window, &cache_root, &token).unwrap();
        assert_eq!(
            claude.contribution,
            scan_claude(&claude_dir, &window).contribution,
            "{now}/{days}"
        );
        assert_eq!(
            kimi.contribution,
            scan_kimi_tree(&kimi_dir, &window).contribution,
            "{now}/{days}"
        );
        for (label, stats) in [("claude", &claude.stats), ("kimi-cli", &kimi.stats)] {
            if cold {
                assert_eq!(stats.cache_rebuilds, 1, "{label} 首次冷扫");
            } else {
                assert_eq!(
                    (
                        stats.cache_hits,
                        stats.cache_rebuilds,
                        stats.cache_invalidations
                    ),
                    (1, 0, 0),
                    "{label} 在 {now} / {days} 天窗口必须直接命中缓存"
                );
                assert_eq!(stats.json_lines_parsed, 0, "{label} 命中缓存不得重新解析");
            }
        }
    }
    fs::remove_dir_all(root).ok();
}

/// C116: v1 (按窗口压缩贡献 + today 身份) 条目按版本不匹配失效并重建, 不计为缓存损坏。
#[test]
fn v1_jsonl_cache_entries_are_invalidated_not_counted_as_corrupt() {
    let root = temp_root("c116-v1");
    let cache_root = root.join("cache");
    let project = root.join("claude").join("-Users-demo-project");
    fs::create_dir_all(&project).unwrap();
    fs::write(
        project.join("session.jsonl"),
        json!({"type": "assistant", "timestamp": "2026-07-28T04:00:00Z", "message": {"id": "m1",
            "model": "claude-opus-5-5", "usage": {"input_tokens": 1, "output_tokens": 1}}})
        .to_string()
            + "\n",
    )
    .unwrap();
    let claude_dir = root.join("claude");
    let token = CancellationToken::new();
    scan_claude_cached(&claude_dir, &window(), &cache_root, &token).unwrap();
    // 把条目改写成 v1 形状: schema_version 1 + 窗口身份 + 压缩贡献
    for entry in fs::read_dir(&cache_root).unwrap().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with("jsonl-") {
            continue;
        }
        let mut value: Value = serde_json::from_slice(&fs::read(entry.path()).unwrap()).unwrap();
        let object = value.as_object_mut().unwrap();
        object.insert("schema_version".into(), json!(1));
        object.remove("timezone");
        object.insert(
            "window".into(),
            json!({"days": 3, "timezone": "Asia/Shanghai", "today": "2026-07-28"}),
        );
        object["payload"]
            .as_object_mut()
            .unwrap()
            .insert("contribution".into(), json!({"days": [], "hours": []}));
        fs::write(entry.path(), serde_json::to_vec(&value).unwrap()).unwrap();
    }
    let rescanned = scan_claude_cached(&claude_dir, &window(), &cache_root, &token).unwrap();
    assert_eq!(rescanned.stats.cache_corruptions, 0, "旧版本条目不是损坏");
    assert_eq!(rescanned.stats.cache_invalidations, 1);
    assert_eq!(rescanned.stats.cache_rebuilds, 1);
    assert_eq!(
        rescanned.contribution,
        scan_claude(&claude_dir, &window()).contribution
    );
    fs::remove_dir_all(root).ok();
}
