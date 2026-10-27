// C126: 以下导入只服务于不走缓存的参照实现 scan_codebuddy (仅对拍用例使用)
#[cfg(test)]
use super::jsonl_adapters::digest_source_key;
#[cfg(test)]
use super::{
    finish, parse_json_line, project_from_parent, record, scan_jsonl_tree, timestamp_number,
    SourceScan, SourceScanError,
};
#[cfg(test)]
use collector_domain::{CollectionWindow, UsageContributionBuilder};
#[cfg(test)]
use collector_runtime::CancellationToken;
use serde_json::Value;
#[cfg(test)]
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, Clone, Default)]
pub(super) struct CodeBuddyUsage {
    pub(super) input: u64,
    pub(super) output: u64,
    pub(super) cache_read: u64,
    pub(super) cache_creation: u64,
    pub(super) timestamp_millis: i64,
    pub(super) model: Option<String>,
    pub(super) project: Option<String>,
}

impl CodeBuddyUsage {
    pub(super) fn total(&self) -> u64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_creation)
    }
}

fn codebuddy_provider_data(value: &Value) -> Option<&Value> {
    value
        .get("providerData")
        .or_else(|| value.get("provider_data"))
}

fn codebuddy_number(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_i64().and_then(|value| u64::try_from(value).ok()))
        .or_else(|| {
            value
                .as_f64()
                .filter(|value| value.is_finite() && *value >= 0.0)
                .map(|value| value as u64)
        })
}

fn codebuddy_first_number(value: &Value, names: &[&str]) -> Option<u64> {
    names
        .iter()
        .find_map(|name| value.get(*name).and_then(codebuddy_number))
}

/// 返回字段列表中首个大于 0 的值; 全部缺失或为 0 时返回 None.
///
/// 不返回 `Some(0)` 兜底: 那会阻断调用方 `.or_else` 的嵌套回退
/// (扁平字段存在但为 0 时, 嵌套对象里的正值缓存明细会被丢弃).
fn codebuddy_first_positive_number(value: &Value, names: &[&str]) -> Option<u64> {
    names
        .iter()
        .filter_map(|name| value.get(*name).and_then(codebuddy_number))
        .find(|number| *number > 0)
}

fn codebuddy_nested_number(
    value: &Value,
    object_names: &[&str],
    field_names: &[&str],
) -> Option<u64> {
    object_names.iter().find_map(|object_name| {
        value
            .get(*object_name)
            .filter(|candidate| candidate.is_object())
            .and_then(|candidate| codebuddy_first_number(candidate, field_names))
    })
}

fn codebuddy_nested_positive_number(
    value: &Value,
    object_names: &[&str],
    field_names: &[&str],
) -> Option<u64> {
    object_names.iter().find_map(|object_name| {
        value
            .get(*object_name)
            .filter(|candidate| candidate.is_object())
            .and_then(|candidate| codebuddy_first_positive_number(candidate, field_names))
    })
}

/// `codebuddy_usage_fields` 的解析结果.
struct CodeBuddyUsageFields {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
    /// input 是否尚未做过缓存扣减 (cache_miss 缺失时 input 仍为缓存含值口径).
    input_cache_inclusive: bool,
}

/// Return pure input, output, cache-read and cache-write counts.
///
/// CodeBuddy's `message.usage` is normalized and its `input_tokens` includes
/// cache reads. `providerData.rawUsage` follows the provider naming and may
/// expose cache hit/miss/write counts directly. Prefer raw usage whenever it
/// is available because it preserves the provider's split instead of making
/// assumptions about a normalized total.
///
/// Reasoning/thinking tokens are NOT added on top of completion output:
/// provider `completion_tokens` already includes them (verified against local
/// rollouts where `total_tokens == prompt_tokens + completion_tokens` while
/// `completion_thinking_tokens` > 0), so an additive fold would double count.
fn codebuddy_usage_fields(value: &Value, raw: bool) -> Option<CodeBuddyUsageFields> {
    let cache_read = codebuddy_first_positive_number(
        value,
        &[
            "cache_read_input_tokens",
            "cacheReadInputTokens",
            "cache_read_tokens",
            "cacheReadTokens",
            "prompt_cache_hit_tokens",
            "promptCacheHitTokens",
            "prompt_cache_hit",
            "cached_tokens",
            "cachedTokens",
        ],
    )
    .or_else(|| {
        codebuddy_nested_positive_number(
            value,
            &["prompt_tokens_details", "promptTokensDetails"],
            &[
                "cached_tokens",
                "cachedTokens",
                "cache_read_tokens",
                "cacheReadTokens",
            ],
        )
    })
    .unwrap_or(0);
    let cache_creation = codebuddy_first_positive_number(
        value,
        &[
            "cache_creation_input_tokens",
            "cacheCreationInputTokens",
            "cache_creation_tokens",
            "cacheCreationTokens",
            "prompt_cache_write_tokens",
            "promptCacheWriteTokens",
            "prompt_cache_write",
            "cache_write_tokens",
            "cacheWriteTokens",
            "cached_write_tokens",
            "cachedWriteTokens",
        ],
    )
    .or_else(|| {
        codebuddy_nested_positive_number(
            value,
            &["prompt_tokens_details", "promptTokensDetails"],
            &[
                "cache_write_tokens",
                "cacheWriteTokens",
                "cached_write_tokens",
                "cachedWriteTokens",
            ],
        )
    })
    .unwrap_or(0);
    let reported_input = codebuddy_first_number(
        value,
        &[
            "input_tokens",
            "inputTokens",
            "prompt_tokens",
            "promptTokens",
        ],
    );
    let cache_miss = codebuddy_first_number(
        value,
        &[
            "prompt_cache_miss_tokens",
            "promptCacheMissTokens",
            "cached_miss_tokens",
            "cachedMissTokens",
            "cache_miss_tokens",
            "cacheMissTokens",
        ],
    )
    .or_else(|| {
        codebuddy_nested_number(
            value,
            &["prompt_tokens_details", "promptTokensDetails"],
            &[
                "cache_miss_tokens",
                "cacheMissTokens",
                "cached_miss_tokens",
                "cachedMissTokens",
                "uncached_tokens",
                "uncachedTokens",
            ],
        )
    });
    let output = codebuddy_first_number(
        value,
        &[
            "output_tokens",
            "outputTokens",
            "completion_tokens",
            "completionTokens",
        ],
    );

    if reported_input.is_none()
        && cache_miss.is_none()
        && output.is_none()
        && cache_read == 0
        && cache_creation == 0
    {
        return None;
    }

    let input = cache_miss.unwrap_or_else(|| {
        let reported = reported_input.unwrap_or(0);
        if raw {
            reported
                .saturating_sub(cache_read)
                .saturating_sub(cache_creation)
        } else {
            // message.usage.input_tokens is cache-inclusive. The normalized
            // CodeBuddy shape does not report cache writes separately, so a
            // cache-read subtraction preserves the established project
            // contract for that shape.
            reported.saturating_sub(cache_read)
        }
    });
    // completion/reasoning 明细不再叠加: completion_tokens 已含 reasoning,
    // 叠加会对 thinking 部分双计数 (见函数注释与本机数据验证).
    Some(CodeBuddyUsageFields {
        input,
        output: output.unwrap_or(0),
        cache_read,
        cache_creation,
        input_cache_inclusive: cache_miss.is_none(),
    })
}

pub(super) fn codebuddy_usage(value: &Value) -> Option<(u64, u64, u64, u64)> {
    let provider = codebuddy_provider_data(value);
    let message = value.get("message");
    let candidates = [
        (
            provider.and_then(|provider| {
                provider
                    .get("rawUsage")
                    .or_else(|| provider.get("raw_usage"))
            }),
            true,
        ),
        (provider.and_then(|provider| provider.get("usage")), false),
        (message.and_then(|message| message.get("usage")), false),
        (value.get("usage"), false),
    ];
    let mut parsed = candidates.into_iter().filter_map(|(candidate, raw)| {
        candidate
            .filter(|candidate| candidate.is_object())
            .and_then(|candidate| codebuddy_usage_fields(candidate, raw))
    });
    let mut primary = parsed.next()?;
    // 首选候选缺缓存明细时 (rawUsage 常缺 prompt_tokens_details), 用后续
    // 归一化候选补齐缓存拆分; 此时 primary 的 input 仍是缓存含值口径, 需同步
    // 扣减, 保证 input + cache_read + cache_creation 与总量守恒.
    if primary.cache_read == 0 && primary.cache_creation == 0 {
        for extra in parsed {
            if extra.cache_read == 0 && extra.cache_creation == 0 {
                continue;
            }
            if primary.input_cache_inclusive {
                primary.input = primary
                    .input
                    .saturating_sub(extra.cache_read)
                    .saturating_sub(extra.cache_creation);
            }
            primary.cache_read = extra.cache_read;
            primary.cache_creation = extra.cache_creation;
            break;
        }
    }
    Some((
        primary.input,
        primary.output,
        primary.cache_read,
        primary.cache_creation,
    ))
}

fn codebuddy_string(value: Option<&Value>, names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| {
        value
            .and_then(|value| value.get(*name))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    })
}

pub(super) fn codebuddy_model(value: &Value) -> Option<String> {
    let provider = codebuddy_provider_data(value);
    codebuddy_string(provider, &["model", "modelId", "model_id"])
        .or_else(|| codebuddy_string(provider, &["requestModelId", "request_model_id"]))
        .or_else(|| codebuddy_string(value.get("message"), &["model", "modelId", "model_id"]))
        .or_else(|| codebuddy_string(Some(value), &["model", "modelId", "model_id"]))
}

pub(super) fn codebuddy_message_id(value: &Value) -> Option<String> {
    let provider = codebuddy_provider_data(value);
    codebuddy_string(
        provider,
        &["messageId", "message_id", "traceId", "trace_id"],
    )
    .or_else(|| codebuddy_string(Some(value), &["messageId", "message_id"]))
    .or_else(|| codebuddy_string(value.get("message"), &["id", "messageId", "message_id"]))
    .or_else(|| codebuddy_string(Some(value), &["id"]))
}

pub(super) fn codebuddy_scope(path: &Path, value: &Value) -> String {
    let project = path
        .parent()
        .map(|parent| parent.to_string_lossy().into_owned())
        .unwrap_or_default();
    let session = codebuddy_string(
        Some(value),
        &[
            "sessionId",
            "session_id",
            "conversationId",
            "conversation_id",
        ],
    )
    .or_else(|| {
        codebuddy_string(
            codebuddy_provider_data(value),
            &[
                "sessionId",
                "session_id",
                "conversationId",
                "conversation_id",
            ],
        )
    });
    match session {
        Some(session) => format!("{project}::{session}"),
        None => path.to_string_lossy().into_owned(),
    }
}

/// Scan CodeBuddy CLI conversation trees (`~/.codebuddy/projects`).
///
/// Layout mirrors Claude Code: `<path-encoded-project>/<session>.jsonl`, one
/// record per line. Normalized assistant messages and provider function-call
/// records are accepted. Usage is read from `providerData.rawUsage` first,
/// then `providerData.usage`, `message.usage`, and top-level `usage`; model
/// names and IDs use the corresponding provider/message fallbacks. Rewrites
/// of one message are selected as complete snapshots by total token count and
/// deduplicated within a project/session scope. System task summaries that
/// expose only `usage.total_tokens` are intentionally ignored because the
/// artifact has no unattributed-token bucket and child records are the
/// decomposable source of truth.
#[cfg(test)]
pub(crate) fn scan_codebuddy(root: &Path, window: &CollectionWindow) -> SourceScan {
    scan_codebuddy_with_cancellation(root, window, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

#[cfg(test)]
pub(crate) fn scan_codebuddy_with_cancellation(
    root: &Path,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    let mut best = BTreeMap::<String, CodeBuddyUsage>::new();
    let mut direct = Vec::<CodeBuddyUsage>::new();
    let stats = scan_jsonl_tree(
        root,
        window.cutoff_ts,
        cancellation,
        |path, _, line, stats| {
            let Some(value) = parse_json_line(line, stats) else {
                return;
            };
            let record_type = value.get("type").and_then(Value::as_str);
            if record_type != Some("message") && record_type != Some("function_call") {
                return;
            }
            if record_type == Some("message")
                && value.get("role").and_then(Value::as_str) != Some("assistant")
            {
                return;
            }
            let Some(timestamp) = timestamp_number(value.get("timestamp")) else {
                return;
            };
            let Some((input, output, cache_read, cache_creation)) = codebuddy_usage(&value) else {
                return;
            };
            let usage = CodeBuddyUsage {
                input,
                output,
                cache_read,
                cache_creation,
                timestamp_millis: timestamp,
                model: codebuddy_model(&value),
                project: project_from_parent(path),
            };
            let id = codebuddy_message_id(&value);
            if let Some(id) = id {
                let key = digest_source_key(
                    "codebuddy-message",
                    &format!("{}::{id}", codebuddy_scope(path, &value)),
                );
                let replace = match best.get(&key) {
                    None => true,
                    Some(previous) => {
                        usage.total() > previous.total()
                            || (usage.total() == previous.total()
                                && usage.timestamp_millis > previous.timestamp_millis)
                    }
                };
                if replace {
                    best.insert(key, usage);
                }
            } else {
                direct.push(usage);
            }
            stats.usage_records = stats.usage_records.saturating_add(1);
        },
    )?;
    let mut builder = UsageContributionBuilder::new(window.clone());
    for usage in best.into_values().chain(direct) {
        record(
            &mut builder,
            usage.timestamp_millis,
            usage.model.as_deref(),
            usage.input,
            usage.output,
            usage.cache_read,
            usage.cache_creation,
            usage.project.as_deref(),
        );
    }
    Ok(finish(
        window,
        builder,
        stats.clone(),
        stats.files_scanned > 0,
    ))
}
