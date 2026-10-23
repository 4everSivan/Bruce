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

#[test]
fn conflicting_rollout_copies_are_not_added_twice() {
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

    assert_eq!(today_total(&result), 23);
    assert_eq!(result.stats.files_scanned, 1);
    assert_eq!(result.stats.duplicate_files_skipped, 1);
    assert_eq!(result.stats.duplicate_session_groups, 1);
    assert_eq!(result.stats.conflict_session_groups, 1);
    assert!(result.diagnostic.is_some());
    fs::remove_dir_all(first).unwrap();
    fs::remove_dir_all(second).unwrap();
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
    assert_eq!(warm.stats.cache_hits, 1, "未变化应命中缓存");
    assert_eq!(warm.stats.bytes_read, 0, "命中缓存时 bytes_read 保持 0");
    assert!(
        warm.found,
        "unchanged cached Codex files still count as found"
    );

    // 追加新文件: 文件集身份变化, 重新扫描并合并新增量.
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
