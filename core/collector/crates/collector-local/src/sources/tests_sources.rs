use super::tests_cache::{temp_root, window};
use super::{scan_codex, scan_codex_cached, SourceScan};
use collector_runtime::CancellationToken;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

/// CodeBuddy 会话树扫描: assistant 行 usage (input 含 cache_read 需扣减)、
/// providerData.model 模型名、messageId 去重选择完整快照, 非消息行忽略.
#[test]
fn codebuddy_scans_assistant_usage_with_message_id_dedup() {
    let root = temp_root("codebuddy");
    let session_dir = root.join("Users-sivan-demo-project");
    fs::create_dir_all(&session_dir).unwrap();
    let base = 1_785_211_200_000_i64; // 2026-07-28 12:00+08 (窗口今天)
    let line = |role: &str, input: u64, output: u64, cache_read: u64, id: Option<&str>| {
        json!({
            "type": "message",
            "role": role,
            "timestamp": base,
            "message": { "usage": {
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_input_tokens": cache_read,
                "total_tokens": input + output,
            }},
            "providerData": {
                "model": "hy3",
                "messageId": id,
            },
        })
        .to_string()
    };
    let content = [
        // 无 usage 的 assistant 行 (流式部分写入) 应忽略.
        json!({"type": "message", "role": "assistant", "timestamp": base}).to_string(),
        // m1 首次: input 1000(含 cache 200) → 纯输入 800, 总量 1100.
        line("assistant", 1000, 100, 200, Some("m1")),
        // m1 重写: input 1500 → 完整快照总量 1600 (不叠加).
        line("assistant", 1500, 100, 200, Some("m1")),
        // 无 messageId 的直接行: 总量 50.
        line("assistant", 50, 0, 0, None),
        // 非 assistant 行忽略.
        line("user", 999, 0, 0, Some("m2")),
    ]
    .join("\n");
    fs::write(session_dir.join("session-a.jsonl"), content).unwrap();

    let scan = super::scan_codebuddy(&root, &window());
    assert!(scan.diagnostic.is_none(), "扫描不应报错");
    assert!(scan.found, "应识别到会话文件");
    let today = &scan.contribution.by_day["2026-07-28"];
    assert_eq!(today.total, 1600 + 50, "去重后的 m1 加直接行");
    assert_eq!(today.input, 1300 + 50, "纯输入口径 (已扣 cache_read)");
    assert_eq!(today.cache_read, 200, "cache_read 单列");
    assert_eq!(
        scan.contribution.models_today[0].model, "hy3",
        "模型名取自 providerData.model"
    );
    assert_eq!(
        scan.contribution.projects_today[0].name, "Users-sivan-demo-project",
        "项目名取自会话目录"
    );
    fs::remove_dir_all(&root).ok();
}

#[test]
fn codebuddy_reads_raw_usage_from_function_call() {
    let root = temp_root("codebuddy-raw");
    let session_dir = root.join("Users-sivan-demo-project");
    fs::create_dir_all(&session_dir).unwrap();
    let base = 1_785_211_200_000_i64;
    let content = json!({
        "type": "function_call",
        "sessionId": "session-a",
        "timestamp": base,
        "providerData": {
            "requestModelId": "glm-5.2",
            "messageId": "raw-1",
            "rawUsage": {
                "prompt_tokens": 1200,
                "completion_tokens": 50,
                "completion_thinking_tokens": 20,
                "prompt_cache_hit_tokens": 300,
                "prompt_cache_write_tokens": 100
            }
        }
    })
    .to_string();
    fs::write(session_dir.join("session-a.jsonl"), content).unwrap();

    let scan = super::scan_codebuddy(&root, &window());
    assert!(scan.diagnostic.is_none(), "扫描不应报错");
    let today = &scan.contribution.by_day["2026-07-28"];
    assert_eq!(today.input, 800, "raw prompt_tokens 应扣除两类缓存");
    assert_eq!(
        today.output, 50,
        "completion_tokens 已含 thinking, 不再叠加"
    );
    assert_eq!(today.cache_read, 300);
    assert_eq!(today.cache_creation, 100);
    assert_eq!(today.total, 1250);
    assert_eq!(scan.contribution.models_today[0].model, "glm-5.2");
    fs::remove_dir_all(&root).ok();
}

#[test]
fn codebuddy_reads_camel_case_cache_breakdown() {
    let root = temp_root("codebuddy-camel");
    let session_dir = root.join("Users-sivan-demo-project");
    fs::create_dir_all(&session_dir).unwrap();
    let base = 1_785_211_200_000_i64;
    let content = json!({
        "type": "function_call",
        "timestamp": base,
        "providerData": {
            "model": "glm-5.2",
            "rawUsage": {
                "cachedMissTokens": 700,
                "cachedTokens": 200,
                "cachedWriteTokens": 50,
                "completionTokens": 30,
                "reasoningTokens": 10
            }
        }
    })
    .to_string();
    fs::write(session_dir.join("session-a.jsonl"), content).unwrap();

    let scan = super::scan_codebuddy(&root, &window());
    assert!(scan.diagnostic.is_none(), "扫描不应报错");
    let today = &scan.contribution.by_day["2026-07-28"];
    assert_eq!(today.input, 700);
    assert_eq!(today.output, 30, "completionTokens 已含 reasoningTokens");
    assert_eq!(today.cache_read, 200);
    assert_eq!(today.cache_creation, 50);
    assert_eq!(today.total, 980);
    fs::remove_dir_all(&root).ok();
}

#[test]
fn codebuddy_merges_normalized_cache_when_raw_usage_lacks_breakdown() {
    // 本机真实形态: rawUsage 无任何缓存明细, 缓存拆分只在归一化 usage 中;
    // 合并后 input 需同步扣减, 保持 input + output + cache_read == total.
    let root = temp_root("codebuddy-cache-merge");
    let session_dir = root.join("Users-sivan-Desktop");
    fs::create_dir_all(&session_dir).unwrap();
    let base = 1_785_211_200_000_i64;
    let content = json!({
        "type": "message",
        "role": "assistant",
        "timestamp": base,
        "providerData": {
            "model": "glm-5.3-flash",
            "messageId": "raw-2",
            "rawUsage": {
                "prompt_tokens": 24575,
                "completion_tokens": 109,
                "total_tokens": 24684,
                "completion_tokens_details": {"reasoning_tokens": 64}
            }
        },
        "message": {"usage": {
            "input_tokens": 24575,
            "output_tokens": 109,
            "total_tokens": 24684,
            "cache_read_input_tokens": 384
        }}
    })
    .to_string();
    fs::write(session_dir.join("session-a.jsonl"), content).unwrap();

    let scan = super::scan_codebuddy(&root, &window());
    assert!(scan.diagnostic.is_none(), "扫描不应报错");
    let today = &scan.contribution.by_day["2026-07-28"];
    assert_eq!(today.input, 24191, "归一化 cache_read 应从 input 中扣减");
    assert_eq!(today.output, 109);
    assert_eq!(today.cache_read, 384, "rawUsage 缺明细时应回退归一化缓存");
    assert_eq!(today.cache_creation, 0);
    assert_eq!(today.total, 24684);
    fs::remove_dir_all(&root).ok();
}

#[test]
fn codebuddy_nested_cache_detail_survives_flat_zero_field() {
    // 扁平 cached_tokens 为 0 不应阻断嵌套 prompt_tokens_details 的正值回退:
    // 旧行为返回 Some(0) 中断 or_else 链, 缓存明细被丢弃、input 全额计入.
    let root = temp_root("codebuddy-zero-trap");
    let session_dir = root.join("Users-sivan-demo-project");
    fs::create_dir_all(&session_dir).unwrap();
    let base = 1_785_211_200_000_i64;
    let content = json!({
        "type": "function_call",
        "timestamp": base,
        "providerData": {
            "model": "glm-5.2",
            "messageId": "raw-3",
            "rawUsage": {
                "prompt_tokens": 1000,
                "completion_tokens": 20,
                "cached_tokens": 0,
                "prompt_tokens_details": {"cached_tokens": 300}
            }
        }
    })
    .to_string();
    fs::write(session_dir.join("session-a.jsonl"), content).unwrap();

    let scan = super::scan_codebuddy(&root, &window());
    assert!(scan.diagnostic.is_none(), "扫描不应报错");
    let today = &scan.contribution.by_day["2026-07-28"];
    assert_eq!(today.input, 700);
    assert_eq!(today.output, 20);
    assert_eq!(today.cache_read, 300, "嵌套正值缓存应命中, 不被扁平 0 阻断");
    assert_eq!(today.cache_creation, 0);
    assert_eq!(today.total, 1020);
    fs::remove_dir_all(&root).ok();
}

#[test]
fn codebuddy_dedup_uses_complete_snapshot_and_session_scope() {
    let root = temp_root("codebuddy-snapshot");
    let project_a = root.join("project-a");
    let project_b = root.join("project-b");
    fs::create_dir_all(&project_a).unwrap();
    fs::create_dir_all(&project_b).unwrap();
    let base = 1_785_211_200_000_i64;
    let line = |session: &str, input: u64, output: u64, id: &str| {
        json!({
            "type": "message",
            "role": "assistant",
            "sessionId": session,
            "timestamp": base,
            "message": { "usage": {
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_input_tokens": 0
            }},
            "providerData": {
                "model": "hy3",
                "messageId": id,
            },
        })
        .to_string()
    };
    // The first complete snapshot has the larger total. A field-wise max
    // would incorrectly combine these two rewrites into 250 tokens.
    let first = line("session-a", 100, 100, "same-id");
    let rewrite = line("session-a", 150, 1, "same-id");
    fs::write(
        project_a.join("session-a.jsonl"),
        [first, rewrite].join("\n"),
    )
    .unwrap();
    // The same provider message id in another session must remain a
    // separate contribution.
    fs::write(
        project_b.join("session-b.jsonl"),
        line("session-b", 10, 5, "same-id"),
    )
    .unwrap();

    let scan = super::scan_codebuddy(&root, &window());
    assert!(scan.diagnostic.is_none(), "扫描不应报错");
    let today = &scan.contribution.by_day["2026-07-28"];
    assert_eq!(today.input, 110);
    assert_eq!(today.output, 105);
    assert_eq!(today.total, 215, "应选择完整快照并按会话隔离去重");
    fs::remove_dir_all(&root).ok();
}

fn write_token_file(
    root: &Path,
    name: &str,
    last_input: u64,
    last_output: u64,
    total_input: u64,
    padding: &str,
) {
    let path = root.join("2026").join("07").join("28").join(name);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let line = json!({
        "timestamp": "2026-07-28T04:00:00Z",
        "payload": {
            "type": "token_count",
            "info": {
                "last_token_usage": {
                    "input_tokens": last_input,
                    "cached_input_tokens": 0,
                    "output_tokens": last_output
                },
                "total_token_usage": {
                    "input_tokens": total_input,
                    "output_tokens": total_input
                }
            }
        },
        "padding": padding
    });
    let mut bytes = serde_json::to_vec(&line).unwrap();
    bytes.push(b'\n');
    fs::write(path, bytes).unwrap();
}

fn write_codex_lines(root: &Path, name: &str, lines: &[Value]) {
    let path = root.join("2026").join("07").join("28").join(name);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let content = lines
        .iter()
        .map(|line| serde_json::to_string(line).unwrap())
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(path, format!("{content}\n")).unwrap();
}

fn codex_turn_context(timestamp: &str, model: &str) -> Value {
    json!({
        "timestamp": timestamp,
        "type": "turn_context",
        "payload": { "model": model }
    })
}

fn codex_token_count(timestamp: &str, input: u64, cache_read: u64, output: u64) -> Value {
    json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "last_token_usage": {
                    "input_tokens": input,
                    "cached_input_tokens": cache_read,
                    "output_tokens": output
                }
            }
        }
    })
}

#[allow(clippy::too_many_arguments)]
fn codex_token_snapshot(
    timestamp: &str,
    total_input: u64,
    total_cache_read: u64,
    total_output: u64,
    last_input: u64,
    last_cache_read: u64,
    last_output: u64,
    limit_id: &str,
) -> Value {
    json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": {
                    "input_tokens": total_input,
                    "cached_input_tokens": total_cache_read,
                    "output_tokens": total_output
                },
                "last_token_usage": {
                    "input_tokens": last_input,
                    "cached_input_tokens": last_cache_read,
                    "output_tokens": last_output
                }
            },
            "rate_limits": { "limit_id": limit_id }
        }
    })
}

fn codex_total_snapshot(
    timestamp: &str,
    total_input: u64,
    total_cache_read: u64,
    total_output: u64,
    limit_id: &str,
) -> Value {
    json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": {
                    "input_tokens": total_input,
                    "cached_input_tokens": total_cache_read,
                    "output_tokens": total_output
                },
                "last_token_usage": {}
            },
            "rate_limits": { "limit_id": limit_id }
        }
    })
}

fn today_total(result: &SourceScan) -> u64 {
    result
        .contribution
        .by_day
        .get("2026-07-28")
        .map(|bucket| bucket.total)
        .unwrap_or(0)
}

#[test]
fn duplicate_rollout_copies_are_counted_once() {
    let first = temp_root("duplicate-first");
    let second = temp_root("duplicate-second");
    write_token_file(&first, "rollout-duplicate.jsonl", 10, 2, 100, "same");
    write_token_file(&second, "rollout-duplicate.jsonl", 10, 2, 100, "same");

    let result = scan_codex(&[first.clone(), second.clone()], &window());

    assert_eq!(today_total(&result), 12);
    assert_eq!(result.stats.files_scanned, 1);
    assert_eq!(result.stats.usage_records, 1);
    assert_eq!(result.stats.duplicate_files_skipped, 1);
    assert_eq!(result.stats.duplicate_session_groups, 1);
    assert_eq!(result.stats.conflict_session_groups, 0);
    assert!(result.diagnostic.is_none());
    fs::remove_dir_all(first).unwrap();
    fs::remove_dir_all(second).unwrap();
}

#[test]
fn distinct_rollout_sessions_are_both_counted() {
    let first = temp_root("distinct-first");
    let second = temp_root("distinct-second");
    write_token_file(&first, "rollout-first.jsonl", 10, 2, 100, "first");
    write_token_file(&second, "rollout-second.jsonl", 20, 3, 200, "second");

    let result = scan_codex(&[first.clone(), second.clone()], &window());

    assert_eq!(today_total(&result), 35);
    assert_eq!(result.stats.files_scanned, 2);
    assert_eq!(result.stats.usage_records, 2);
    assert_eq!(result.stats.duplicate_files_skipped, 0);
    assert_eq!(result.stats.duplicate_session_groups, 0);
    fs::remove_dir_all(first).unwrap();
    fs::remove_dir_all(second).unwrap();
}

/// C190: 同名副本在同一时间戳各有一次用量不同的响应 —— 按单次响应模型是两次响应,
/// 取并集; 组记为分叉并输出说明。(C190 前整份择一、只计 23。)
#[test]
fn diverged_rollout_copies_with_distinct_responses_are_unioned() {
    let first = temp_root("conflict-first");
    let second = temp_root("conflict-second");
    write_token_file(&first, "rollout-conflict.jsonl", 10, 2, 100, "short");
    write_token_file(
        &second,
        "rollout-conflict.jsonl",
        20,
        3,
        200,
        "longer-content-that-wins",
    );

    let result = scan_codex(&[first.clone(), second.clone()], &window());

    assert_eq!(today_total(&result), 12 + 23);
    assert_eq!(result.stats.files_scanned, 2);
    assert_eq!(result.stats.duplicate_files_skipped, 0);
    assert_eq!(result.stats.duplicate_session_groups, 1);
    assert_eq!(result.stats.conflict_session_groups, 1);
    // C198: 副本取舍是说明而非故障。
    assert!(result.notice.is_some());
    assert!(result.diagnostic.is_none());
    fs::remove_dir_all(first).unwrap();
    fs::remove_dir_all(second).unwrap();
}

/// C190 夹具: 一次响应 = 单次响应记录 (可选, Codex 0.164+) + token_count。
fn codex_response(
    timestamp: &str,
    response_id: Option<&str>,
    input: u64,
    output: u64,
) -> Vec<Value> {
    let usage = json!({"input_tokens": input, "cached_input_tokens": 0, "output_tokens": output});
    let mut lines = Vec::new();
    if let Some(response_id) = response_id {
        lines.push(json!({
            "timestamp": timestamp,
            "type": "token_usage_record",
            "payload": {"response_id": response_id, "usage": usage}
        }));
    }
    lines.push(json!({
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {"type": "token_count", "info": {"last_token_usage": usage}}
    }));
    lines
}

/// C190 夹具: CLI 根与 Orca 根各一份同名 rollout。shared 为两份共有的前缀响应。
fn write_codex_copies(
    cli: &Path,
    orca: &Path,
    shared: &[Vec<Value>],
    cli_only: &[Vec<Value>],
    orca_only: &[Vec<Value>],
) {
    let name = "rollout-2026-07-28T10-00-00-same.jsonl";
    let lines = |own: &[Vec<Value>]| -> Vec<Value> {
        shared.iter().chain(own).flatten().cloned().collect()
    };
    write_codex_lines(cli, name, &lines(cli_only));
    write_codex_lines(orca, name, &lines(orca_only));
}

/// (标签, CLI 独有响应, Orca 独有响应, 期望今日合计, 期望分叉组数)
type CopyCase<'a> = (&'a str, &'a [Vec<Value>], &'a [Vec<Value>], u64, u64);

/// C190: 同名副本按单次响应取并集 —— 前缀副本等于长副本、不算冲突; 分叉副本为并集
/// 12,760 (旧实现整份择一得 12,430, 「两份都计」得 13,090); 新旧两种 rollout 格式一致;
/// 带缓存与不带缓存结果相同, 热轮全部命中。
#[test]
fn codex_copies_merge_by_response_without_double_counting() {
    for with_records in [true, false] {
        let id = |value: &'static str| with_records.then_some(value);
        let shared = vec![codex_response(
            "2026-07-28T02:00:00Z",
            id("resp_shared"),
            300,
            30,
        )];
        let cli_only = vec![codex_response(
            "2026-07-28T02:05:00Z",
            id("resp_cli"),
            300,
            30,
        )];
        let orca_only = vec![codex_response(
            "2026-07-28T02:06:00Z",
            id("resp_orca"),
            12_000,
            100,
        )];
        let cases: [CopyCase; 2] = [
            ("prefix", &cli_only, &[], 660, 0),
            ("diverged", &cli_only, &orca_only, 12_760, 1),
        ];
        for (label, cli_part, orca_part, expected, conflicts) in cases {
            let label = format!("{label}/records={with_records}");
            let cli = temp_root(&format!("c190-cli-{label}").replace('/', "-"));
            let orca = temp_root(&format!("c190-orca-{label}").replace('/', "-"));
            let cache_dir = temp_root(&format!("c190-cache-{label}").replace('/', "-"));
            write_codex_copies(&cli, &orca, &shared, cli_part, orca_part);
            let roots = [cli.clone(), orca.clone()];

            let reference = scan_codex(&roots, &window());
            assert_eq!(today_total(&reference), expected, "{label}");
            assert_eq!(
                reference.stats.conflict_session_groups, conflicts,
                "{label}"
            );
            assert_eq!(reference.notice.is_some(), conflicts > 0, "{label}");
            assert_eq!(reference.stats.files_scanned, 2, "{label}: 两份都解析");

            let cold = scan_codex_cached(&roots, &window(), &cache_dir);
            assert_eq!(cold.contribution, reference.contribution, "{label}");
            assert_eq!(cold.stats.conflict_session_groups, conflicts, "{label}");
            let warm = scan_codex_cached(&roots, &window(), &cache_dir);
            assert_eq!(warm.contribution, reference.contribution, "{label}");
            assert_eq!(
                (warm.stats.cache_hits, warm.stats.cache_rebuilds),
                (2, 0),
                "{label}: 两份副本各自按文件缓存命中"
            );
            assert_eq!(warm.notice, cold.notice, "{label}: 命中缓存的轮次说明不变");
            for root in [cli, orca, cache_dir] {
                fs::remove_dir_all(root).ok();
            }
        }
    }
}

/// C190: 去重键 —— 记录与 token_count 用量一致时取 response_id, 否则回退为时间戳;
/// 记录只被下一条用量相同的 token_count 认领一次。
#[test]
fn codex_dedupe_key_prefers_matching_response_record() {
    let root = temp_root("c190-keys");
    let mut lines = codex_response("2026-07-28T02:00:00Z", Some("resp_a"), 10, 1);
    // 用量不同的记录不被认领, 下一条 token_count 回退为时间戳键
    lines.push(json!({
        "timestamp": "2026-07-28T02:01:00Z",
        "type": "token_usage_record",
        "payload": {"response_id": "resp_other", "usage": {"input_tokens": 99, "output_tokens": 9}}
    }));
    lines.extend(codex_response("2026-07-28T02:02:00Z", None, 20, 2));
    write_codex_lines(&root, "rollout-keys.jsonl", &lines);
    let candidate = super::codex::test_candidate(&root.join("2026/07/28/rollout-keys.jsonl"));
    let observations = super::codex::test_parse(&candidate, &window());
    let keys: Vec<_> = observations
        .iter()
        .map(|observation| observation.dedupe_key.clone().unwrap())
        .collect();
    assert_eq!(keys, ["r:resp_a", "t:1785204120000:20:0:2"]);
    fs::remove_dir_all(root).ok();
}

/// 硬链接副本 (Orca 双根形态) 与大文件 (>64KB, 走头尾指纹 seek 路径)
/// 均判为相同副本只计一次, 不再全文件哈希.
#[test]
fn codex_hardlink_and_large_copies_dedup_without_full_hash() {
    let first = temp_root("hardlink-first");
    let second = temp_root("hardlink-second");
    // 大 padding 使文件 >128KB, 覆盖指纹的头块 + seek 尾块路径.
    let big = "x".repeat(200_000);
    write_token_file(&first, "rollout-hard.jsonl", 10, 2, 100, &big);
    let source = first
        .join("2026")
        .join("07")
        .join("28")
        .join("rollout-hard.jsonl");
    let link_dir = second.join("2026").join("07").join("28");
    fs::create_dir_all(&link_dir).unwrap();
    fs::hard_link(&source, link_dir.join("rollout-hard.jsonl")).unwrap();

    let result = scan_codex(&[first.clone(), second.clone()], &window());

    assert_eq!(result.stats.files_scanned, 1, "硬链接副本只计一次");
    assert_eq!(result.stats.duplicate_files_skipped, 1);
    assert_eq!(result.stats.duplicate_session_groups, 1);
    assert_eq!(
        result.stats.conflict_session_groups, 0,
        "同 inode 不得判冲突"
    );
    assert!(result.diagnostic.is_none());
    fs::remove_dir_all(first).unwrap();
    fs::remove_dir_all(second).unwrap();
}

#[test]
fn codex_uses_last_token_usage_not_cumulative_total() {
    let root = temp_root("last-usage");
    write_token_file(&root, "rollout-last.jsonl", 4, 2, 400, "single");

    let result = scan_codex(std::slice::from_ref(&root), &window());

    assert_eq!(today_total(&result), 6);
    assert_eq!(result.stats.usage_records, 1);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn codex_attributes_usage_to_the_current_turn_context_model() {
    let root = temp_root("model-attribution");
    write_codex_lines(
        &root,
        "rollout-models.jsonl",
        &[
            codex_turn_context("2026-07-28T04:00:00Z", "gpt-5.4"),
            codex_token_count("2026-07-28T04:00:01Z", 10, 2, 3),
            codex_turn_context("2026-07-28T04:00:02Z", "gpt-5.3-codex"),
            codex_token_count("2026-07-28T04:00:03Z", 20, 5, 4),
        ],
    );

    let result = scan_codex(std::slice::from_ref(&root), &window());
    let model_totals = result
        .contribution
        .models_today
        .iter()
        .map(|entry| (entry.model.clone(), entry.bucket.total))
        .collect::<std::collections::BTreeMap<_, _>>();

    assert_eq!(model_totals.get("gpt-5.4"), Some(&13));
    assert_eq!(model_totals.get("gpt-5.3-codex"), Some(&24));
    assert!(!model_totals.contains_key("codex"));
    let month_totals = result
        .contribution
        .models_by_month
        .get("2026-07")
        .unwrap()
        .iter()
        .map(|(model, bucket)| (model.clone(), bucket.total))
        .collect::<std::collections::BTreeMap<_, _>>();
    assert_eq!(month_totals, model_totals);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn codex_deduplicates_replayed_token_snapshots_across_limit_sources() {
    let root = temp_root("snapshot-dedup");
    write_codex_lines(
        &root,
        "rollout-snapshots.jsonl",
        &[
            codex_turn_context("2026-07-28T04:00:00Z", "gpt-5.4"),
            codex_token_snapshot("2026-07-28T04:00:01Z", 100, 20, 10, 100, 20, 10, "codex"),
            codex_token_snapshot(
                "2026-07-28T04:00:02Z",
                100,
                20,
                10,
                100,
                20,
                10,
                "codex_bengalfox",
            ),
        ],
    );

    let result = scan_codex(std::slice::from_ref(&root), &window());

    assert_eq!(today_total(&result), 110);
    assert_eq!(result.stats.usage_records, 1);
    assert_eq!(result.contribution.models_today[0].bucket.total, 110);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn codex_uses_cumulative_total_when_last_usage_is_missing_across_model_switch() {
    let root = temp_root("cumulative-model-switch");
    write_codex_lines(
        &root,
        "rollout-cumulative.jsonl",
        &[
            codex_turn_context("2026-07-28T04:00:00Z", "model-a"),
            codex_total_snapshot("2026-07-28T04:00:01Z", 100, 20, 10, "codex"),
            codex_turn_context("2026-07-28T04:00:02Z", "model-b"),
            codex_total_snapshot("2026-07-28T04:00:03Z", 150, 30, 15, "codex"),
        ],
    );

    let result = scan_codex(std::slice::from_ref(&root), &window());
    let model_totals = result
        .contribution
        .models_today
        .iter()
        .map(|entry| (entry.model.clone(), entry.bucket.total))
        .collect::<std::collections::BTreeMap<_, _>>();

    assert_eq!(model_totals.get("model-a"), Some(&110));
    assert_eq!(model_totals.get("model-b"), Some(&55));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn codex_uses_unknown_model_when_no_model_context_exists() {
    let root = temp_root("unknown-model");
    write_codex_lines(
        &root,
        "rollout-unknown.jsonl",
        &[codex_token_count("2026-07-28T04:00:00Z", 10, 2, 3)],
    );

    let result = scan_codex(std::slice::from_ref(&root), &window());
    let model_totals = result
        .contribution
        .models_today
        .iter()
        .map(|entry| (entry.model.clone(), entry.bucket.total))
        .collect::<std::collections::BTreeMap<_, _>>();

    assert_eq!(model_totals.get("unknown"), Some(&13));
    assert!(!model_totals.contains_key("codex"));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn codex_cached_scan_skips_unchanged_files_and_increments_on_append() {
    let root = temp_root("cached");
    let cache_dir = temp_root("cached-cache");
    let w = window();
    write_codex_lines(
        &root,
        "rollout-cached.jsonl",
        &[codex_token_count("2026-07-28T04:00:00Z", 10, 2, 3)],
    );
    // 非 rollout jsonl 走 content+指纹分组: 命中缓存时仍会读指纹
    // (不进 bytes_read), 验证该路径聚合正确且不被误判为重复.
    write_codex_lines(
        &root,
        "session-cached.jsonl",
        &[codex_token_count("2026-07-28T04:30:00Z", 4, 1, 1)],
    );

    // 冷: 无缓存, 全量读取.
    let cold = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
    let cold_total = cold
        .contribution
        .by_day
        .get(&w.today)
        .map(|b| b.total)
        .unwrap_or(0);
    // input(10) − cache_read(2) = 8, + output(3) + cache_read(2) = 13.
    // 会话文件: (4−1) + 1 + 1 = 5.
    assert_eq!(cold_total, 18);
    assert_eq!(cold.stats.cache_hits, 0);
    assert!(cold.stats.bytes_read > 0, "冷扫描必须实际读字节");

    // 热: 未变化文件命中缓存, 聚合不变.
    let warm = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
    assert_eq!(
        warm.contribution
            .by_day
            .get(&w.today)
            .map(|b| b.total)
            .unwrap_or(0),
        18
    );
    // C117: 按文件缓存 —— 两个未变化文件各命中一次, 不重新解析。
    assert_eq!(warm.stats.cache_hits, 2, "未变化应命中缓存");
    assert_eq!(warm.stats.cache_rebuilds, 0);
    assert_eq!(warm.stats.bytes_read, 0, "命中缓存时 bytes_read 保持 0");
    assert!(
        warm.found,
        "unchanged cached Codex files still count as found"
    );

    // 追加新文件: 只解析新文件, 其余两个文件继续命中缓存.
    write_codex_lines(
        &root,
        "rollout-cached-2.jsonl",
        &[codex_token_count("2026-07-28T05:00:00Z", 5, 1, 2)],
    );
    let appended = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
    assert_eq!(
        appended
            .contribution
            .by_day
            .get(&w.today)
            .map(|b| b.total)
            .unwrap_or(0),
        25,
        "追加后聚合 = 13 + 5(会话) + (5−1)+2+1 = 25"
    );
    assert_eq!(
        (appended.stats.cache_hits, appended.stats.cache_rebuilds),
        (2, 1),
        "只重解析新增文件"
    );
    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(cache_dir).unwrap();
}

#[test]
fn jsonl_tree_guard_prevents_symlink_cycle_and_excessive_depth() {
    let root = temp_root("cycle-test");
    let sub = root.join("sub");
    fs::create_dir_all(&sub).unwrap();
    fs::write(sub.join("test.jsonl"), "{\"type\":\"test\"}\n").unwrap();

    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;
        let _ = symlink(&sub, sub.join("cycle"));
    }

    let mut count = 0;
    let stats = super::scan_jsonl_tree(&root, 0.0, &CancellationToken::new(), |_, _, _, _| {
        count += 1;
    });

    assert!(
        stats.is_ok(),
        "遍历带有循环软链接的目录不应陷入死循环或报错"
    );
    assert_eq!(count, 1, "文件只应被访问一次，软链接环应被正确跳过");
    fs::remove_dir_all(&root).ok();
}

/// C045: jsonl_cache 适配器 (claude/codebuddy/kimi-work/grok/pi) 的树遍历
/// 必须与其它 walker 一样受深度上限约束, 且环结构下不重复计入文件。
///
/// 说明: symlink 环在 macOS 上会被内核路径长度限制 (ENAMETOOLONG) 提前拦截,
/// 因此「环导致无限递归」并非可稳定观测的失败形态; 本用例锁定的是两个
/// 可证伪行为 —— (1) 超出深度上限的链不再展开 (与 walk_jsonl_tree 一致);
/// (2) 环结构下缓存路径与未缓存路径给出相同聚合。
#[test]
fn jsonl_cache_adapter_survives_symlink_cycle() {
    let root = temp_root("cache-cycle");
    let cache_root = temp_root("cache-cycle-store");
    let sub = root.join("sub");
    fs::create_dir_all(&sub).unwrap();
    let line = json!({
        "type": "assistant",
        "timestamp": "2026-07-28T04:00:00Z",
        "message": {
            "id": "direct-a",
            "model": "claude-sonnet",
            "usage": {
                "input_tokens": 3,
                "output_tokens": 1,
                "cache_read_input_tokens": 4
            }
        }
    })
    .to_string();
    fs::write(sub.join("one.jsonl"), format!("{line}\n")).unwrap();

    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;
        let _ = symlink(&sub, sub.join("cycle"));
        let _ = symlink(&root, sub.join("cycle-root"));
    }

    // 超深链: 在深度上限之下放置文件, 断言其不被计入 (上限语义)
    let mut deep = root.join("deep");
    for level in 0..(super::MAX_DIRECTORY_SCAN_DEPTH + 4) {
        deep = deep.join(format!("l{level}"));
    }
    fs::create_dir_all(&deep).unwrap();
    fs::write(deep.join("unreachable.jsonl"), format!("{line}\n")).unwrap();

    let scan = super::scan_claude_cached(&root, &window(), &cache_root, &CancellationToken::new());
    assert!(
        scan.is_ok(),
        "缓存适配器遍历带环/超深目录必须终止且不报错: {scan:?}"
    );
    let scan = scan.unwrap();
    // 环被跳过后必须与未缓存路径给出一致的日聚合 (环内副本不得重复计入)
    let unscaled = super::scan_claude(&root, &window());
    assert_eq!(
        scan.contribution.by_day, unscaled.contribution.by_day,
        "缓存路径与未缓存路径在环结构下必须给出一致的日聚合"
    );
    let counted = scan
        .contribution
        .by_day
        .values()
        .map(|bucket| bucket.total)
        .sum::<u64>();
    assert_eq!(
        counted,
        3 + 4 + 1,
        "仅 sub/one.jsonl 应被计入 (环内部副本不得重复计入)"
    );
    // 深度上限的可证伪断言: 超深链必须在触达其内容前停止展开。
    // 撤掉深度护栏时该计数会变为 2 (深链中的文件被访问后才因时间窗被跳过),
    // 故本断言能在红态失败 —— 这正是「护栏存在性」的可执行证明。
    assert_eq!(
        scan.stats.files_visited, 1,
        "深度上限之外的文件不得被访问 (实际访问数 {}), 说明遍历未被护栏约束",
        scan.stats.files_visited
    );

    fs::remove_dir_all(&root).ok();
    fs::remove_dir_all(&cache_root).ok();
}

/// C045: codex 文件收集 (整树候选发现) 的 symlink 环防护。
#[test]
fn codex_collection_survives_symlink_cycle() {
    let root = temp_root("codex-cycle");
    let sub = root.join("sessions");
    fs::create_dir_all(&sub).unwrap();
    fs::write(
        sub.join("rollout-2026-01-01T00-00-00.jsonl"),
        "{\"type\":\"event\"}\n",
    )
    .unwrap();

    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;
        let _ = symlink(&sub, sub.join("cycle"));
    }

    let scan = super::scan_codex_with_cancellation(
        std::slice::from_ref(&root),
        &window(),
        &CancellationToken::new(),
    );
    assert!(
        scan.is_ok(),
        "codex 收集遍历带环目录必须终止且不报错: {scan:?}"
    );
    fs::remove_dir_all(&root).ok();
}

/// C107: Claude Code 用量的 1 小时 TTL 缓存写入份额 (`usage.cache_creation.
/// ephemeral_1h_input_tokens`) 必须在缓存 / 未缓存两条路径、缓存命中与追加后都被保留,
/// 同一 message id 的重复写入按最大值去重 (不叠加)。
#[test]
fn claude_keeps_one_hour_cache_write_share_across_cache_paths() {
    let root = temp_root("claude-1h");
    let cache_root = temp_root("claude-1h-cache");
    let project = root.join("-Users-demo-project");
    fs::create_dir_all(&project).unwrap();
    let line = |id: &str, creation: u64, one_hour: u64| {
        json!({
            "type": "assistant",
            "timestamp": "2026-07-28T04:00:00Z",
            "message": {
                "id": id,
                "model": "claude-opus-5-5",
                "usage": {
                    "input_tokens": 10,
                    "output_tokens": 5,
                    "cache_read_input_tokens": 100,
                    "cache_creation_input_tokens": creation,
                    "cache_creation": {
                        "ephemeral_5m_input_tokens": creation - one_hour,
                        "ephemeral_1h_input_tokens": one_hour
                    }
                }
            }
        })
        .to_string()
    };
    let session = project.join("session.jsonl");
    // m1 流式骨架与完整快照 (按最大值去重), m2 全部为 1 小时写入
    fs::write(
        &session,
        format!(
            "{}\n{}\n{}\n",
            line("m1", 40, 30),
            line("m1", 400, 300),
            line("m2", 50, 50)
        ),
    )
    .unwrap();

    let today_bucket = |scan: &SourceScan| {
        scan.contribution
            .models_today
            .iter()
            .find(|model| model.model == "claude-opus-5-5")
            .map(|model| model.bucket.clone())
            .expect("claude-opus-5-5 应计入今日模型")
    };
    let uncached = super::scan_claude(&root, &window());
    let cold = super::scan_claude_cached(&root, &window(), &cache_root, &CancellationToken::new())
        .unwrap();
    let warm = super::scan_claude_cached(&root, &window(), &cache_root, &CancellationToken::new())
        .unwrap();
    for (label, scan) in [("uncached", &uncached), ("cold", &cold), ("warm", &warm)] {
        let bucket = today_bucket(scan);
        assert_eq!(bucket.cache_creation, 450, "{label}: 缓存写入总量");
        assert_eq!(
            bucket.cache_creation_1h, 350,
            "{label}: 1 小时 TTL 写入份额"
        );
    }
    assert_eq!(warm.stats.cache_hits, 1, "第二次扫描应命中缓存");

    // 追加一条后: 增量合并路径同样保留 1 小时份额
    let mut file = fs::OpenOptions::new().append(true).open(&session).unwrap();
    use std::io::Write as _;
    writeln!(file, "{}", line("m3", 20, 0)).unwrap();
    drop(file);
    let appended =
        super::scan_claude_cached(&root, &window(), &cache_root, &CancellationToken::new())
            .unwrap();
    let bucket = today_bucket(&appended);
    assert_eq!(bucket.cache_creation, 470);
    assert_eq!(
        bucket.cache_creation_1h, 350,
        "5 分钟写入不得计入 1 小时份额"
    );

    fs::remove_dir_all(&root).ok();
    fs::remove_dir_all(&cache_root).ok();
}

/// C110: 解析前预筛 —— 不含判定字面量的行 (Claude 的 user / tool_result 等) 不构建 JSON DOM,
/// 计为 ignored; 用量结果与不预筛的参照实现逐日一致。
#[test]
fn claude_prefilter_skips_lines_that_cannot_carry_usage() {
    let root = temp_root("claude-prefilter");
    let cache_root = temp_root("claude-prefilter-cache");
    let project = root.join("-Users-demo-project");
    fs::create_dir_all(&project).unwrap();
    let assistant = json!({
        "type": "assistant",
        "timestamp": "2026-07-28T04:00:00Z",
        "message": {"id": "m1", "model": "claude-opus-5-5",
            "usage": {"input_tokens": 7, "output_tokens": 3, "cache_read_input_tokens": 11}}
    })
    .to_string();
    // 超大非用量行 (含故意损坏的 JSON): 预筛前会被完整解析并计为 malformed
    let tool_output = format!(
        "{{\"type\":\"user\",\"message\":{{\"content\":\"{}\"}} broken",
        "x".repeat(256 * 1024)
    );
    fs::write(
        project.join("session.jsonl"),
        format!("{tool_output}\n{assistant}\n{tool_output}\n"),
    )
    .unwrap();

    let scan = super::scan_claude_cached(&root, &window(), &cache_root, &CancellationToken::new())
        .unwrap();
    assert_eq!(scan.stats.json_lines_parsed, 1, "只解析 assistant 行");
    assert_eq!(scan.stats.malformed_lines, 0, "非用量行不进入 JSON 解析");
    assert_eq!(scan.stats.ignored_lines, 2);
    let reference = super::scan_claude(&root, &window());
    assert_eq!(scan.contribution.by_day, reference.contribution.by_day);
    assert!(super::line_may_match(
        assistant.as_bytes(),
        &[b"\"assistant\""]
    ));
    assert!(!super::line_may_match(
        tool_output.as_bytes(),
        &[b"\"assistant\""]
    ));

    fs::remove_dir_all(&root).ok();
    fs::remove_dir_all(&cache_root).ok();
}

/// C117: Codex 按文件缓存 —— 正在写入的会话文件追加时只重解析该文件; 跨日与改窗口长度
/// 全部命中; 删除文件从缓存移除; 结果始终与不走缓存的 scan_codex 一致。
#[test]
fn codex_file_cache_reparses_only_changed_files_and_survives_rollover() {
    let root = temp_root("codex-file-cache");
    let cache_dir = temp_root("codex-file-cache-dir");
    let window_at = |now: &str, days: u32| {
        let context: serde_json::Map<String, Value> =
            serde_json::from_value(json!({"now": now, "timezone": "Asia/Shanghai", "days": days}))
                .unwrap();
        collector_domain::CollectionWindow::from_context(&context).unwrap()
    };
    write_codex_lines(
        &root,
        "rollout-a.jsonl",
        &[codex_token_count("2026-07-27T04:00:00Z", 10, 2, 3)],
    );
    write_codex_lines(
        &root,
        "rollout-b.jsonl",
        &[codex_token_count("2026-07-28T04:00:00Z", 7, 1, 2)],
    );
    // 钉住一个 f64 秒经 JSON 往返会差 1 ULP 的 mtime (1792990001.6544359 读回为
    // 1792990001.654436): 身份若按 f64 秒比较, 未变化的文件下一轮就会被判为变化
    let pinned = std::time::UNIX_EPOCH + std::time::Duration::new(1_792_990_001, 654_435_761);
    for name in ["rollout-a.jsonl", "rollout-b.jsonl"] {
        fs::File::options()
            .write(true)
            .open(root.join("2026/07/28").join(name))
            .unwrap()
            .set_modified(pinned)
            .unwrap();
    }
    let day = window_at("2026-07-28T12:00:00+08:00", 3);
    let cold = scan_codex_cached(std::slice::from_ref(&root), &day, &cache_dir);
    assert_eq!(cold.stats.cache_rebuilds, 2);
    assert_eq!(
        cold.contribution,
        scan_codex(std::slice::from_ref(&root), &day).contribution
    );

    // 跨日 + 改窗口长度: 全部命中
    for (now, days) in [
        ("2026-07-29T09:00:00+08:00", 3),
        ("2026-07-29T09:00:00+08:00", 182),
    ] {
        let window = window_at(now, days);
        let scan = scan_codex_cached(std::slice::from_ref(&root), &window, &cache_dir);
        assert_eq!(
            (scan.stats.cache_hits, scan.stats.cache_rebuilds),
            (2, 0),
            "{now}/{days}"
        );
        assert_eq!(scan.stats.bytes_read, 0, "命中缓存不读 rollout");
        assert_eq!(
            scan.contribution,
            scan_codex(std::slice::from_ref(&root), &window).contribution,
            "{now}/{days}"
        );
    }

    // 进行中的会话追加一行: 只重解析该文件
    let path = root.join("2026/07/28/rollout-b.jsonl");
    let mut existing = fs::read_to_string(&path).unwrap();
    existing.push_str(
        &serde_json::to_string(&codex_token_count("2026-07-28T05:00:00Z", 12, 3, 4)).unwrap(),
    );
    existing.push('\n');
    fs::write(&path, existing).unwrap();
    let appended = scan_codex_cached(std::slice::from_ref(&root), &day, &cache_dir);
    assert_eq!(
        (appended.stats.cache_hits, appended.stats.cache_rebuilds),
        (1, 1)
    );
    assert_eq!(
        appended.contribution,
        scan_codex(std::slice::from_ref(&root), &day).contribution
    );

    // 删除文件: 缓存移除且不再计入
    fs::remove_file(root.join("2026/07/28/rollout-a.jsonl")).unwrap();
    let removed = scan_codex_cached(std::slice::from_ref(&root), &day, &cache_dir);
    assert_eq!(removed.stats.cache_deletions, 1);
    assert_eq!(
        removed.contribution,
        scan_codex(std::slice::from_ref(&root), &day).contribution
    );

    // 旧整树缓存文件被清理
    fs::write(cache_dir.join("codex-tree-v1.json"), "{}").unwrap();
    scan_codex_cached(std::slice::from_ref(&root), &day, &cache_dir);
    assert!(!cache_dir.join("codex-tree-v1.json").exists());

    fs::remove_dir_all(root).ok();
    fs::remove_dir_all(cache_dir).ok();
}

/// C197: 把 rollout 权限改为 000; 以 root 运行等权限不生效的环境返回 false (调用方跳过)。
#[cfg(unix)]
fn make_unreadable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o000)).unwrap();
    if fs::File::open(path).is_ok() {
        fs::set_permissions(path, fs::Permissions::from_mode(0o644)).unwrap();
        return false;
    }
    true
}

#[cfg(unix)]
fn make_readable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o644)).unwrap();
}

/// C197 回归: rollout 首次扫描时打不开 (EMFILE / 已逐出 / 属主不同) 不得被当成空文件按身份
/// 缓存 —— 文件恢复可读后身份不变, 旧实现会永久命中空条目、该会话永久记 0 且无诊断。
#[cfg(unix)]
#[test]
fn codex_unreadable_rollout_is_not_cached_as_empty() {
    let root = temp_root("codex-unreadable");
    let cache_dir = temp_root("codex-unreadable-cache");
    let w = window();
    write_codex_lines(
        &root,
        "rollout-unreadable.jsonl",
        &[codex_token_count("2026-07-28T04:00:00Z", 10, 2, 3)],
    );
    write_codex_lines(
        &root,
        "rollout-readable.jsonl",
        &[codex_token_count("2026-07-28T05:00:00Z", 20, 0, 5)],
    );
    let expected = scan_codex(std::slice::from_ref(&root), &w);
    let path = root.join("2026/07/28/rollout-unreadable.jsonl");
    if !make_unreadable(&path) {
        fs::remove_dir_all(root).ok();
        fs::remove_dir_all(cache_dir).ok();
        return;
    }

    for round in ["失败轮", "仍不可读的下一轮"] {
        let failed = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
        assert_eq!(today_total(&failed), 25, "{round}: 只计入可读文件");
        assert_eq!(failed.stats.io_errors, 1, "{round}");
        assert_eq!(
            failed.stats.cache_hits + failed.stats.cache_rebuilds,
            1,
            "{round}"
        );
        assert!(
            failed.diagnostic.is_none(),
            "{round}: 读取失败是说明而非故障"
        );
        assert_eq!(
            failed.notice.as_deref(),
            Some("Codex 会话文件读取失败 1 个, 本轮沿用上次结果或暂未计入, 下次刷新重试"),
            "{round}"
        );
        let cache = fs::read_to_string(cache_dir.join("codex-files-v1.json")).unwrap();
        let cache: Value = serde_json::from_str(&cache).unwrap();
        assert_eq!(
            cache["files"].as_object().unwrap().len(),
            1,
            "{round}: 失败文件不得写入缓存条目"
        );
    }

    // 恢复可读 (文件身份不变): 下一轮重解析并计入完整用量, 再下一轮命中缓存。
    make_readable(&path);
    let recovered = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
    assert_eq!(recovered.contribution, expected.contribution);
    assert_eq!(today_total(&recovered), 13 + 25);
    assert_eq!(
        (recovered.stats.cache_hits, recovered.stats.cache_rebuilds),
        (1, 1)
    );
    assert_eq!(recovered.stats.io_errors, 0);
    assert!(recovered.notice.is_none());
    let warm = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
    assert_eq!(warm.contribution, expected.contribution);
    assert_eq!(warm.stats.cache_hits, 2);

    fs::remove_dir_all(root).ok();
    fs::remove_dir_all(cache_dir).ok();
}

/// C197: 已缓存的 rollout 追加后打不开 —— 沿用旧条目的陈旧观测 (与 dsh 活写兜底同口径),
/// 本轮数字不下降; 旧条目保留旧身份, 恢复可读后重解析为真实值。
#[cfg(unix)]
#[test]
fn codex_unreadable_changed_rollout_keeps_stale_observations() {
    let root = temp_root("codex-unreadable-stale");
    let cache_dir = temp_root("codex-unreadable-stale-cache");
    let w = window();
    let first = codex_token_count("2026-07-28T04:00:00Z", 10, 2, 3);
    write_codex_lines(&root, "rollout-live.jsonl", std::slice::from_ref(&first));
    let warm = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
    assert_eq!(today_total(&warm), 13);

    let path = root.join("2026/07/28/rollout-live.jsonl");
    write_codex_lines(
        &root,
        "rollout-live.jsonl",
        &[first, codex_token_count("2026-07-28T05:00:00Z", 20, 0, 5)],
    );
    let expected = scan_codex(std::slice::from_ref(&root), &w);
    if !make_unreadable(&path) {
        fs::remove_dir_all(root).ok();
        fs::remove_dir_all(cache_dir).ok();
        return;
    }
    for round in ["失败轮", "仍不可读的下一轮"] {
        let stale = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
        assert_eq!(
            stale.contribution, warm.contribution,
            "{round}: 沿用陈旧观测"
        );
        assert!(stale.found);
        assert_eq!(stale.stats.io_errors, 1, "{round}");
        assert_eq!(stale.stats.cache_hits, 0, "{round}: 陈旧条目不计命中");
        assert_eq!(stale.stats.cache_rebuilds, 0, "{round}: 重建失败不计重建");
        assert_eq!(
            stale.stats.cache_deletions, 0,
            "{round}: 陈旧条目不得被清理"
        );
        assert!(stale.notice.is_some(), "{round}");
    }

    make_readable(&path);
    let recovered = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
    assert_eq!(recovered.contribution, expected.contribution);
    assert_eq!(today_total(&recovered), 13 + 25);
    assert_eq!(recovered.stats.cache_rebuilds, 1);
    assert_eq!(recovered.stats.io_errors, 0);

    fs::remove_dir_all(root).ok();
    fs::remove_dir_all(cache_dir).ok();
}

/// C175 回归: Codex 按文件缓存 (自 C117 起即不 fsync) 为空或被截断时判 Corrupt 并全量重建。
#[test]
fn codex_file_cache_left_empty_or_truncated_is_rebuilt() {
    let root = temp_root("codex-power-loss");
    let cache_dir = temp_root("codex-power-loss-cache");
    let w = window();
    write_codex_lines(
        &root,
        "rollout-power-loss.jsonl",
        &[codex_token_count("2026-07-28T04:00:00Z", 10, 2, 3)],
    );
    let expected = scan_codex(std::slice::from_ref(&root), &w);
    let cold = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
    assert_eq!(cold.contribution, expected.contribution);

    let cache_path = cache_dir.join("codex-files-v1.json");
    let intact = fs::read(&cache_path).unwrap();
    for damaged in [&intact[..0], &intact[..intact.len() / 2]] {
        fs::write(&cache_path, damaged).unwrap();
        let repaired = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
        assert_eq!(repaired.contribution, expected.contribution);
        assert_eq!(repaired.stats.cache_corruptions, 1);
        assert_eq!(repaired.stats.cache_hits, 0);
        // C198: 自愈重建只是说明, 用量完整, 不得以故障 diagnostic 输出。
        assert!(repaired.diagnostic.is_none(), "缓存自愈不是故障");
        assert_eq!(
            repaired.notice.as_deref(),
            Some("Codex 缓存文件格式异常, 已整体重建")
        );

        let warm = scan_codex_cached(std::slice::from_ref(&root), &w, &cache_dir);
        assert_eq!(warm.contribution, expected.contribution);
        assert_eq!(warm.stats.cache_hits, 1, "重建后的缓存下一轮应命中");
        assert!(warm.notice.is_none(), "重建完成后说明随之消失");
    }
    super::tests_cache::assert_cache_files_private_without_temporaries(&cache_dir);

    fs::remove_dir_all(root).ok();
    fs::remove_dir_all(cache_dir).ok();
}
