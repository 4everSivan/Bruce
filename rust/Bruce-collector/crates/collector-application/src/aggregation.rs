use collector_aggregate::UsageAccumulator;
use collector_domain::{CollectionWindow, Diagnostic, SourceDeltaChange, UsageContribution};
use collector_runtime::{BoundedQueue, CancellationToken, RuntimeError};
use std::collections::BTreeMap;
use std::sync::Arc;

#[derive(Debug)]
pub(crate) struct AggregationResult {
    pub accumulator: UsageAccumulator,
    pub diagnostics: Vec<Diagnostic>,
}

/// Consume source-level replacements from a bounded queue.
///
/// The source map makes remove-old/add-new and repeated source identities
/// idempotent. Contributions are folded in sorted source-id order after the
/// stream closes, so queue capacity and producer scheduling cannot affect the
/// final artifact ordering or totals. Only derived contributions are retained;
/// raw session lines never cross this boundary.
pub(crate) fn consume_source_changes(
    queue: Arc<BoundedQueue<SourceDeltaChange>>,
    window: CollectionWindow,
    cancellation: CancellationToken,
) -> AggregationResult {
    let mut sources = BTreeMap::<String, UsageContribution>::new();
    let mut diagnostics = Vec::new();

    loop {
        match queue.pop(&cancellation) {
            Ok(Some(change)) => {
                if change.removed.is_some() {
                    sources.remove(&change.source_id);
                }
                if let Some(added) = change.added {
                    sources.insert(change.source_id, added);
                }
            }
            Ok(None) => break,
            Err(error) => {
                diagnostics.push(queue_diagnostic(error));
                break;
            }
        }
    }

    let mut accumulator = UsageAccumulator::new(window);
    for contribution in sources.values() {
        if !accumulator.merge_delta(contribution) {
            diagnostics.push(Diagnostic::new(
                "LOCAL_CONTRIBUTION_INVALID",
                "local",
                "aggregate",
                "本地 usage contribution 格式无效",
                false,
            ));
        }
    }
    AggregationResult {
        accumulator,
        diagnostics,
    }
}

fn queue_diagnostic(error: RuntimeError) -> Diagnostic {
    let (code, operation, retryable, message) = match error {
        RuntimeError::Cancelled => (
            "LOCAL_AGGREGATION_CANCELLED",
            "cancel",
            true,
            "本地聚合因取消请求提前停止, 已保留已消费结果",
        ),
        RuntimeError::DeadlineExceeded => (
            "LOCAL_AGGREGATION_DEADLINE",
            "deadline",
            true,
            "本地聚合达到时间预算, 已保留已消费结果",
        ),
        RuntimeError::Closed => (
            "LOCAL_AGGREGATION_QUEUE_CLOSED",
            "consume",
            true,
            "本地聚合队列提前关闭, 已保留已消费结果",
        ),
        RuntimeError::InvalidLimits => (
            "RUNTIME_INVALID_LIMITS",
            "setup",
            false,
            "本地聚合运行时限制无效",
        ),
    };
    Diagnostic::new(code, "local", operation, message, retryable)
}

#[cfg(test)]
mod tests {
    use super::consume_source_changes;
    use collector_domain::{
        CollectionWindow, ModelDelta, SourceDeltaChange, TokenBucket, UsageContribution,
    };
    use collector_runtime::{BoundedQueue, CancellationToken};
    use serde_json::{json, Map, Value};
    use std::collections::BTreeMap;
    use std::sync::Arc;

    fn window() -> CollectionWindow {
        let context: Map<String, Value> = serde_json::from_value(json!({
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "days": 3
        }))
        .unwrap();
        CollectionWindow::from_context(&context).unwrap()
    }

    fn contribution(window: &CollectionWindow, model: &str, total: u64) -> UsageContribution {
        let bucket = TokenBucket {
            input: total,
            output: 0,
            cache_read: 0,
            cache_creation: 0,
            total,
        };
        let mut by_day = BTreeMap::new();
        by_day.insert(window.today.clone(), bucket.clone());
        let mut hours = vec![0; 24];
        hours[0] = total;
        UsageContribution {
            by_day,
            models_today: vec![ModelDelta {
                model: model.to_owned(),
                bucket,
            }],
            projects_today: Vec::new(),
            hours,
        }
    }

    fn run_stream(capacity: usize, changes: Vec<SourceDeltaChange>) -> serde_json::Value {
        let queue = Arc::new(BoundedQueue::new(capacity).unwrap());
        let producer_queue = Arc::clone(&queue);
        let token = CancellationToken::new();
        std::thread::scope(|scope| {
            let consumer_queue = Arc::clone(&queue);
            let consumer_token = token.clone();
            let consumer = scope
                .spawn(move || consume_source_changes(consumer_queue, window(), consumer_token));
            for change in changes {
                producer_queue.push(change, &token).unwrap();
            }
            producer_queue.close();
            let result = consumer.join().unwrap();
            assert!(result.diagnostics.is_empty());
            serde_json::to_value(result.accumulator.finalize("kimi", "Kimi", None)).unwrap()
        })
    }

    #[test]
    fn remove_replace_and_readd_are_idempotent() {
        let window = window();
        let source_a_old = contribution(&window, "model-a", 10);
        let source_a_new = contribution(&window, "model-a", 7);
        let source_a_final = contribution(&window, "model-a", 5);
        let source_b = contribution(&window, "model-b", 3);
        let artifact = run_stream(
            1,
            vec![
                SourceDeltaChange::replace("a", None, Some(source_a_old.clone())),
                SourceDeltaChange::replace("b", None, Some(source_b)),
                SourceDeltaChange::replace("a", Some(source_a_old), Some(source_a_new)),
                SourceDeltaChange::replace("b", Some(contribution(&window, "model-b", 3)), None),
                SourceDeltaChange::replace("a", Some(contribution(&window, "model-a", 7)), None),
                SourceDeltaChange::replace("a", None, Some(source_a_final)),
            ],
        );
        assert_eq!(artifact["today"]["total"], 5);
        assert_eq!(artifact["todayModels"][0]["total"], 5);
    }

    #[test]
    fn changing_queue_capacity_keeps_artifact_identical() {
        let window = window();
        let changes = vec![
            SourceDeltaChange::replace("z", None, Some(contribution(&window, "model-z", 4))),
            SourceDeltaChange::replace("a", None, Some(contribution(&window, "model-a", 6))),
        ];
        assert_eq!(run_stream(1, changes.clone()), run_stream(8, changes));
    }
}
