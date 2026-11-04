//! C195: 超过单行上限 (MAX_JSONL_RECORD_BYTES) 的行只有在保留前缀命中来源用量字面量时才算
//! 疑似用量行: 计数随缓存持久化并经信息级说明暴露; 工具结果 / 图片类超长行不产生说明。

use super::tests_cache::{temp_root, window};
use super::{scan_claude_cached, scan_codex_cached, scan_dsh_cached};
use crate::MAX_JSONL_RECORD_BYTES;
use collector_runtime::CancellationToken;
use serde_json::json;
use std::fs;
use std::path::Path;

const NOTICE: &str = "1 条疑似用量记录超过 1 MiB 单行上限, 已跳过未计入";

/// 夹具按来源真实的字段顺序手写 (serde_json 的 json! 会按键名排序, 把超长内容排到判定字段前面)。
fn write_lines(path: &Path, lines: &[String]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let content: String = lines.iter().map(|line| format!("{line}\n")).collect();
    fs::write(path, content).unwrap();
}

fn oversized_text() -> String {
    "x".repeat(MAX_JSONL_RECORD_BYTES + 1024)
}

/// Claude: 超长 assistant 行 (前缀含结构化 "assistant") → 说明且热轮仍在; 超长 user 工具结果
/// 即使文本里写着 "assistant" (JSON 字符串内转义为 \"assistant\") 也不产生说明。
#[test]
fn oversized_claude_assistant_line_is_reported_but_tool_results_are_not() {
    let root = temp_root("c195-claude");
    let cache_root = root.join("cache");
    let projects = root.join("projects");
    // 真实顺序: message 在 type 之前, message 内 role 在 content 之前 (本机实测首个
    // "assistant" 最晚出现在第 170 字节)。
    let assistant = format!(
        r#"{{"parentUuid":"p","message":{{"model":"claude-sonnet","id":"big","type":"message","role":"assistant","content":[{{"type":"text","text":"{}"}}],"usage":{{"input_tokens":100,"output_tokens":10}}}},"type":"assistant","timestamp":"2026-07-28T03:00:00Z"}}"#,
        oversized_text()
    );
    let normal = json!({
        "type": "assistant",
        "timestamp": "2026-07-28T03:01:00Z",
        "message": {"id": "small", "model": "claude-sonnet",
            "usage": {"input_tokens": 7, "output_tokens": 1}}
    })
    .to_string();
    // 工具结果是字符串, 其中的 "assistant" 落盘为 \"assistant\", 不命中结构化字面量。
    let tool_result = json!({
        "type": "user",
        "timestamp": "2026-07-28T03:02:00Z",
        "message": {"role": "user", "content": [{"type": "tool_result",
            "content": format!("{{\"type\":\"assistant\"}} {}", oversized_text())}]}
    })
    .to_string();
    write_lines(
        &projects.join("demo/tools.jsonl"),
        &[tool_result, normal.clone()],
    );
    let scan = || {
        scan_claude_cached(&projects, &window(), &cache_root, &CancellationToken::new()).unwrap()
    };
    let quiet = scan();
    assert_eq!(quiet.stats.truncated_lines, 1);
    assert!(quiet.notice.is_none(), "工具结果类超长行不产生说明");

    write_lines(&projects.join("demo/big.jsonl"), &[assistant, normal]);
    let cold = scan();
    assert_eq!(cold.notice.as_deref(), Some(NOTICE));
    assert!(cold.diagnostic.is_none());
    let warm = scan();
    assert_eq!(warm.stats.cache_hits, 2);
    assert_eq!(warm.stats.truncated_lines, 0, "命中缓存的轮次不重读文件");
    assert_eq!(warm.notice.as_deref(), Some(NOTICE), "计数随缓存持久化");
    fs::remove_dir_all(root).ok();
}

#[test]
fn oversized_dsh_usage_line_is_reported() {
    let root = temp_root("c195-dsh");
    let cache_root = root.join("cache");
    let lines = vec![
        json!({"type": "session", "version": 4, "id": "s", "cwd": "/w/demo"}).to_string(),
        format!(
            r#"{{"type":"assistant/message","time":{},"data":{{"message":{{"id":"big","content":"{}"}},"usage":{{"inputTokens":5,"outputTokens":1}}}}}}"#,
            1_785_211_200_000_i64 - 60_000,
            oversized_text()
        ),
    ];
    write_lines(&root.join("ws/session-a/session.v4.jsonl"), &lines);
    let scan = scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert_eq!(scan.notice.as_deref(), Some(NOTICE));
    fs::remove_dir_all(root).ok();
}

/// Codex: 只认结构化的 "token_count"; 超长的响应内容行 (文本里提到 token_count) 不算。
#[test]
fn oversized_codex_token_count_line_is_reported_but_text_mentions_are_not() {
    let root = temp_root("c195-codex");
    let cache_root = root.join("cache");
    let sessions = root.join("sessions/2026/07/28");
    let mention = format!(
        r#"{{"timestamp":"2026-07-28T04:00:00Z","type":"response_item","payload":{{"type":"message","content":"token_count {}"}}}}"#,
        oversized_text()
    );
    write_lines(&sessions.join("rollout-a.jsonl"), &[mention]);
    let roots = [root.join("sessions")];
    assert!(scan_codex_cached(&roots, &window(), &cache_root)
        .notice
        .is_none());
    let oversized = format!(
        r#"{{"timestamp":"2026-07-28T04:00:01Z","type":"event_msg","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":10,"output_tokens":1}}}},"padding":"{}"}}}}"#,
        oversized_text()
    );
    write_lines(&sessions.join("rollout-b.jsonl"), &[oversized]);
    let cold = scan_codex_cached(&roots, &window(), &cache_root);
    assert_eq!(cold.notice.as_deref(), Some(NOTICE));
    let warm = scan_codex_cached(&roots, &window(), &cache_root);
    assert_eq!(warm.stats.cache_hits, 2);
    assert_eq!(warm.notice.as_deref(), Some(NOTICE));
    fs::remove_dir_all(root).ok();
}
