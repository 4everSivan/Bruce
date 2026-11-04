//! C194: Grok 时间戳 —— 跨日追加后已有观测留在原日期, 只有新追加的观测落在新日期;
//! 来源带消息级时间时优先使用。

use super::scan_grok_cached;
use super::tests_cache::{temp_root, window};
use collector_runtime::CancellationToken;
use serde_json::json;
use std::fs;
use std::path::Path;
use std::time::{Duration, UNIX_EPOCH};

/// 2026-07-26 / 07-27 当地 (Asia/Shanghai) 中午的 epoch 秒。
const JULY_26_NOON: u64 = 1_785_038_400;
const JULY_27_NOON: u64 = JULY_26_NOON + 86_400;

fn set_mtime(path: &Path, epoch_seconds: u64) {
    fs::File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(UNIX_EPOCH + Duration::from_secs(epoch_seconds))
        .unwrap();
}

fn message(kind: &str, chars: usize) -> String {
    json!({"type": kind, "content": "x".repeat(chars)}).to_string() + "\n"
}

fn day_total(scan: &super::SourceScan, day: &str) -> u64 {
    scan.contribution
        .by_day
        .get(day)
        .map_or(0, |bucket| bucket.total)
}

/// 旧实现追加时把已有观测整体重打为新 mtime: 07-26 的 300 漂到 07-27 (合计 340 全在 07-27),
/// 叠加台账按日取大即 07-26=300、07-27=340 的永久重复。现在 07-26 留 300、07-27 只有 40。
#[test]
fn grok_append_keeps_earlier_observations_on_their_original_day() {
    let root = temp_root("c194-grok-append");
    let cache_root = root.join("cache");
    let sessions = root.join("sessions");
    let session = sessions.join("project/session/conversation.jsonl");
    fs::create_dir_all(session.parent().unwrap()).unwrap();
    fs::write(&session, message("user", 800) + &message("assistant", 400)).unwrap();
    set_mtime(&session, JULY_26_NOON);
    let scan = || {
        scan_grok_cached(
            std::slice::from_ref(&sessions),
            &window(),
            &cache_root,
            &CancellationToken::new(),
        )
        .unwrap()
    };
    let first = scan();
    assert_eq!(day_total(&first, "2026-07-26"), 300);

    let mut content = fs::read_to_string(&session).unwrap();
    content.push_str(&message("assistant", 160));
    fs::write(&session, content).unwrap();
    set_mtime(&session, JULY_27_NOON);
    let appended = scan();
    assert_eq!(appended.stats.cache_appends, 1, "走追加路径");
    assert_eq!(
        day_total(&appended, "2026-07-26"),
        300,
        "已有观测留在原日期"
    );
    assert_eq!(
        day_total(&appended, "2026-07-27"),
        40,
        "只有新追加的观测在新日期"
    );
    fs::remove_dir_all(root).ok();
}

/// 来源带消息级时间 (ISO 或秒 / 毫秒数值) 时按消息时间归日, 与文件 mtime 无关。
#[test]
fn grok_prefers_message_timestamps_over_file_mtime() {
    let root = temp_root("c194-grok-message-time");
    let cache_root = root.join("cache");
    let sessions = root.join("sessions");
    let session = sessions.join("project/session/conversation.jsonl");
    fs::create_dir_all(session.parent().unwrap()).unwrap();
    let lines = [
        json!({"type": "user", "timestamp": "2026-07-26T03:00:00Z", "content": "x".repeat(40)}),
        json!({"type": "assistant", "created_at": JULY_27_NOON, "content": "x".repeat(80)}),
        json!({"type": "assistant", "createdAt": (JULY_27_NOON + 3_600) * 1000, "content": "x".repeat(8)}),
    ];
    let content: String = lines.iter().map(|line| format!("{line}\n")).collect();
    fs::write(&session, content).unwrap();
    set_mtime(&session, JULY_27_NOON + 86_400);
    let scan = scan_grok_cached(
        std::slice::from_ref(&sessions),
        &window(),
        &cache_root,
        &CancellationToken::new(),
    )
    .unwrap();
    assert_eq!(day_total(&scan, "2026-07-26"), 10);
    assert_eq!(day_total(&scan, "2026-07-27"), 20 + 2);
    assert_eq!(day_total(&scan, "2026-07-28"), 0, "不按 mtime 归日");
    let reference = super::scan_grok(std::slice::from_ref(&sessions), &window());
    assert_eq!(scan.contribution, reference.contribution, "与参照实现一致");
    fs::remove_dir_all(root).ok();
}
