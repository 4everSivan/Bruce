//! C196: JSONL 引擎的单文件竞态 —— 文件在列目录与 stat / 读指纹之间被删除或改动时只跳过该文件,
//! 不中止整个来源; 解析失败沿用该路径旧条目的陈旧载荷 (与 dsh / Codex 同口径)。

use super::jsonl_adapters::scan_claude_cached_with_hook;
use super::scan_claude_cached;
use super::tests_cache::{temp_root, window};
use collector_runtime::CancellationToken;
use serde_json::json;
use std::fs;
use std::path::Path;

fn claude_line(id: &str, minute: u32, input: u64) -> String {
    json!({
        "type": "assistant",
        "timestamp": format!("2026-07-28T03:{minute:02}:00Z"),
        "message": {"id": id, "model": "claude-sonnet",
            "usage": {"input_tokens": input, "output_tokens": 0}}
    })
    .to_string()
        + "\n"
}

fn today_total(scan: &super::SourceScan) -> u64 {
    scan.contribution
        .by_day
        .get("2026-07-28")
        .map_or(0, |bucket| bucket.total)
}

/// 会话清理竞态: 列目录后、stat 前文件被删除 —— 旧实现整源以 Io 失败结束 (本轮按
/// LOCAL_SOURCE_IO_DEGRADED 整体跳过); 现在只跳过该文件, 其余文件完整, 下一轮按差集回收。
#[test]
fn file_deleted_between_listing_and_stat_skips_only_that_file() {
    let root = temp_root("c196-deleted");
    let cache_root = root.join("cache");
    let projects = root.join("projects");
    fs::create_dir_all(projects.join("demo")).unwrap();
    for (name, input) in [("a", 100), ("b", 20), ("c", 3)] {
        fs::write(
            projects.join(format!("demo/{name}.jsonl")),
            claude_line(name, 0, input),
        )
        .unwrap();
    }
    let warm =
        scan_claude_cached(&projects, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert_eq!(today_total(&warm), 123);

    let mut hook = |path: &Path| {
        if path.file_name().is_some_and(|name| name == "b.jsonl") {
            fs::remove_file(path).unwrap();
        }
    };
    let raced = scan_claude_cached_with_hook(&projects, &window(), &cache_root, &mut hook)
        .expect("单文件消失不得让整个来源失败");
    assert_eq!(today_total(&raced), 103, "其余文件完整计入");
    assert!(raced.found);
    assert_eq!(raced.stats.io_errors, 1);
    assert!(
        raced.notice.is_none(),
        "C201: 列目录后被删除是正常竞态, 不算读取失败"
    );

    let next =
        scan_claude_cached(&projects, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert_eq!(
        next.stats.cache_deletions, 1,
        "真被删除的文件下一轮按差集回收"
    );
    assert_eq!(today_total(&next), 103);
    fs::remove_dir_all(root).ok();
}

/// 已缓存的会话追加后变为不可读: 旧实现读追加指纹失败即整源 Io 失败; 现在按「不可追加」
/// 走整文件重解析, 解析失败沿用旧条目载荷 (只计 io_errors, 不计命中), 恢复后按追加计入。
#[cfg(unix)]
#[test]
fn unreadable_changed_file_keeps_stale_payload_and_other_files() {
    use std::os::unix::fs::PermissionsExt;
    let root = temp_root("c196-stale");
    let cache_root = root.join("cache");
    let projects = root.join("projects");
    fs::create_dir_all(projects.join("demo")).unwrap();
    let live = projects.join("demo/live.jsonl");
    fs::write(&live, claude_line("live-1", 0, 100)).unwrap();
    fs::write(
        projects.join("demo/other.jsonl"),
        claude_line("other", 1, 7),
    )
    .unwrap();
    let scan = || {
        scan_claude_cached(&projects, &window(), &cache_root, &CancellationToken::new()).unwrap()
    };
    let warm = scan();
    assert_eq!(today_total(&warm), 107);

    let mut content = fs::read_to_string(&live).unwrap();
    content.push_str(&claude_line("live-2", 2, 50));
    fs::write(&live, content).unwrap();
    fs::set_permissions(&live, fs::Permissions::from_mode(0o000)).unwrap();
    if fs::File::open(&live).is_ok() {
        // 以 root 运行时权限不生效, 跳过。
        fs::set_permissions(&live, fs::Permissions::from_mode(0o644)).unwrap();
        fs::remove_dir_all(root).ok();
        return;
    }
    let stale = scan();
    assert_eq!(today_total(&stale), 107, "沿用旧载荷, 本轮数字不下降");
    assert_eq!(stale.stats.io_errors, 1);
    assert_eq!(stale.stats.cache_hits, 1, "只有另一个文件命中");
    // C201: 与 Codex (C197) 同口径附信息级说明; 失败不缓存, 下一轮重试。
    assert_eq!(
        stale.notice.as_deref(),
        Some("会话文件读取失败 1 个, 本轮沿用上次结果或暂未计入, 下次刷新重试")
    );
    assert!(stale.diagnostic.is_none());

    fs::set_permissions(&live, fs::Permissions::from_mode(0o644)).unwrap();
    let recovered = scan();
    assert_eq!(today_total(&recovered), 157);
    assert_eq!(
        recovered.stats.cache_appends, 1,
        "旧条目仍在, 恢复后按追加计入"
    );
    assert!(recovered.notice.is_none(), "恢复后说明消失");
    fs::remove_dir_all(root).ok();
}
