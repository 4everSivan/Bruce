//! 对拍调试工具: 读取共享 artifact fixture, 输出 Rust 视图模型的完整 JSON
//! (与 PanelParityHarness 的 mac 侧输出同构, 供人工比对与排障)。
//!
//! 用法: cargo run -p bruce-win-viewmodel --example dump_panel -- <fixture.json>

use std::path::PathBuf;

use bruce_win_viewmodel::usage::PanelViewModelMapper;
use chrono::{FixedOffset, TimeZone};
use collector_domain::AgentUsageArtifact;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("用法: dump_panel <fixture.json>");
        std::process::exit(2);
    };
    let raw = std::fs::read_to_string(PathBuf::from(&path))?;
    let value: serde_json::Value = serde_json::from_str(&raw)?;
    let artifact: AgentUsageArtifact = serde_json::from_value(value["artifact"].clone())?;

    // 与 fixture_parity 测试一致的固定 now (2026-07-28T12:30:00+08:00)。
    let now = FixedOffset::east_opt(8 * 3600)
        .unwrap()
        .with_ymd_and_hms(2026, 7, 28, 12, 30, 0)
        .unwrap();
    let panel = PanelViewModelMapper::default().make(Some(&artifact), now);
    println!("{}", serde_json::to_string_pretty(&panel)?);
    Ok(())
}
