//! Windows 系统托盘动态配额环与状态心跳图标渲染器 (方案 1)
//!
//! 纯内存纯数学像素着色 (32x32 RGBA):
//! - 底轨圆环 (Track)
//! - 动态配额圆弧 (Progress Arc, 从 12 点钟顺时针覆盖)
//! - 中心心跳状态点 (Center Dot, 翠绿/琥珀/科技红/离线灰)
//! - 支持根据聚合快照/视图模型提取配额速览数据 (QuotaSummary)

use crate::runtime_core::StatusTone;
use serde::Serialize;
use serde_json::Value;

/// 托盘配额环与悬停预览卡共用的速览数据 (C115: 两处同源, 预览卡经 `panel.preview` 读取)。
///
/// 只读取 `PanelViewModel` 真实序列化的字段: `usage.costText` / `usage.totalTokensText`、
/// `hourly.rows[].todayTotal` (与 HUD「N AGENTS ACTIVE」同口径)、`subscription.sections[]`
/// 及其 `accounts[]` 的 `windows[].usedPercent` / `resetText`。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSummary {
    /// 有效窗口中剩余比例的最小值 (0–100, 与 mac 菜单栏配额环同口径: 跳过 error / failed
    /// 的服务与账号); 没有任何有效窗口时为 None, 托盘只画底轨, 不伪装成 100%。
    pub remaining_pct: Option<f64>,
    pub top_provider: Option<String>,
    pub top_window_label: Option<String>,
    /// 最紧迫窗口的重置文案; 无数据为 None。
    pub reset_text: Option<String>,
    /// 今日费用文案; 定价缺失时为 None。
    pub cost_text: Option<String>,
    pub tokens_text: Option<String>,
    pub active_agents: usize,
    /// 状态灯色调 (`StatusTone::as_str`), 与 HUD 状态灯同一判定表 (C100)。
    pub status_tone: &'static str,
    #[serde(skip)]
    pub tone: StatusTone,
    pub status_reason: String,
}

fn text(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn is_failed(status: Option<&Value>) -> bool {
    matches!(
        status
            .and_then(Value::as_str)
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("error" | "failed")
    )
}

/// 从面板视图模型提取配额速览数据。
pub fn extract_quota_summary(panel: &Value) -> QuotaSummary {
    let status = crate::runtime_core::dashboard_status_from_panel(panel);
    let usage = panel.get("usage");
    let active_agents = panel
        .pointer("/hourly/rows")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter(|row| row.get("todayTotal").and_then(Value::as_i64).unwrap_or(0) > 0)
                .count()
        })
        .unwrap_or(0);

    // (已用比例, 服务名, 窗口, 重置文案): 取已用比例最高 (剩余最少) 的有效窗口
    let mut tightest: Option<(f64, String, Option<String>, Option<String>)> = None;
    let mut consider = |provider: &str, windows: Option<&Value>| {
        for window in windows.and_then(Value::as_array).into_iter().flatten() {
            let Some(used) = window
                .get("usedPercent")
                .and_then(Value::as_f64)
                .filter(|used| used.is_finite())
            else {
                continue;
            };
            if tightest.as_ref().is_none_or(|(best, ..)| used > *best) {
                tightest = Some((
                    used,
                    provider.to_owned(),
                    text(window.get("label")),
                    text(window.get("resetText")),
                ));
            }
        }
    };
    for section in panel
        .pointer("/subscription/sections")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if is_failed(section.get("status")) {
            continue;
        }
        let name = section
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("订阅服务");
        consider(name, section.get("windows"));
        for account in section
            .get("accounts")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if !is_failed(account.get("status")) {
                consider(name, account.get("windows"));
            }
        }
    }

    let (remaining_pct, top_provider, top_window_label, reset_text) = match tightest {
        Some((used, provider, label, reset)) => (
            Some((100.0 - used).clamp(0.0, 100.0)),
            Some(provider),
            label,
            reset,
        ),
        None => (None, None, None, None),
    };
    QuotaSummary {
        remaining_pct,
        top_provider,
        top_window_label,
        reset_text,
        cost_text: text(usage.and_then(|usage| usage.get("costText"))),
        tokens_text: text(usage.and_then(|usage| usage.get("totalTokensText"))),
        active_agents,
        status_tone: status.tone.as_str(),
        tone: status.tone,
        status_reason: status.reason,
    }
}

/// 托盘提示文案: 缺失项省略, 不显示伪造的默认值。
pub fn tray_tooltip(summary: &QuotaSummary) -> String {
    let mut parts = vec![format!("Bruce · {}", summary.status_reason)];
    if let Some(remaining) = summary.remaining_pct {
        parts.push(format!("额度剩余 {remaining:.0}%"));
    }
    if let Some(cost) = &summary.cost_text {
        parts.push(format!("今日 {cost}"));
    }
    parts.join(" · ")
}

/// 渲染 32x32 动态托盘配额图标 (RGBA 字节流，共 32*32*4 = 4096 字节)
/// `remaining_pct` 为 None (无有效配额窗口) 时只画底轨与状态点。
pub fn render_tray_quota_icon(
    size: u32,
    remaining_pct: Option<f64>,
    tone: StatusTone,
    is_refreshing: bool,
) -> Vec<u8> {
    let width = size as usize;
    let height = size as usize;
    let mut buffer = vec![0u8; width * height * 4];

    let cx = (width as f64 - 1.0) / 2.0;
    let cy = (height as f64 - 1.0) / 2.0;

    let r_ring = cx * 0.74; // 约 11.5
    let w_ring = (cx * 0.20).max(2.2); // 约 3.0
    let r_dot = (cx * 0.22).max(2.5); // 约 3.4

    let stroke_rgba = tone.tray_rgba();
    let track_rgba = [60u8, 66u8, 80u8, 140u8];
    let dot_rgba = if is_refreshing {
        [220u8, 240u8, 255u8, 255u8]
    } else {
        stroke_rgba
    };

    let clamped_pct = remaining_pct.unwrap_or(0.0).clamp(0.0, 100.0);
    let progress_angle = (clamped_pct / 100.0) * std::f64::consts::TAU;

    for y in 0..height {
        for x in 0..width {
            let dx = x as f64 - cx;
            let dy = y as f64 - cy;
            let dist = (dx * dx + dy * dy).sqrt();
            let idx = (y * width + x) * 4;

            // 1. 中心心跳状态点
            if dist <= r_dot + 0.8 {
                let alpha_factor = ((r_dot + 0.8 - dist) / 0.8).clamp(0.0, 1.0);
                let alpha = (dot_rgba[3] as f64 * alpha_factor).round() as u8;
                buffer[idx] = dot_rgba[0];
                buffer[idx + 1] = dot_rgba[1];
                buffer[idx + 2] = dot_rgba[2];
                buffer[idx + 3] = alpha;
                continue;
            }

            // 2. 底轨与动态配额圆环
            let ring_dist = (dist - r_ring).abs();
            let half_w = w_ring / 2.0;
            if ring_dist <= half_w + 0.8 {
                let rad_alpha = ((half_w + 0.8 - ring_dist) / 0.8).clamp(0.0, 1.0);

                // 计算当前像素的角度 (以 12 点钟为起点顺时针 0..2*PI)
                let angle = dy.atan2(dx) + std::f64::consts::FRAC_PI_2;
                let norm_angle = if angle < 0.0 {
                    angle + std::f64::consts::TAU
                } else {
                    angle
                };

                let in_progress = norm_angle <= progress_angle && clamped_pct > 0.0;
                let (r, g, b, base_a) = if in_progress {
                    (
                        stroke_rgba[0],
                        stroke_rgba[1],
                        stroke_rgba[2],
                        stroke_rgba[3],
                    )
                } else {
                    (track_rgba[0], track_rgba[1], track_rgba[2], track_rgba[3])
                };

                let final_a = (base_a as f64 * rad_alpha).round() as u8;
                buffer[idx] = r;
                buffer[idx + 1] = g;
                buffer[idx + 2] = b;
                buffer[idx + 3] = final_a;
            }
        }
    }

    buffer
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实面板形状 (mac 产出 ≡ golden 快照), 而非手写的假字段 (C115)。
    fn golden_panel(name: &str) -> Value {
        let path = format!(
            "{}/../../../tests/fixtures/viewmodel-parity/agent-usage-{name}.panel.json",
            env!("CARGO_MANIFEST_DIR")
        );
        serde_json::from_str(&std::fs::read_to_string(path).expect("golden panel"))
            .expect("golden panel json")
    }

    #[test]
    fn test_render_tray_quota_icon_dimensions() {
        let pixels = render_tray_quota_icon(32, Some(85.0), StatusTone::Ok, false);
        assert_eq!(pixels.len(), 32 * 32 * 4);

        // 中心像素必须不透明并着色
        let center_idx = (16 * 32 + 16) * 4;
        assert!(pixels[center_idx + 3] > 180);
    }

    #[test]
    fn missing_quota_draws_track_without_progress_arc() {
        let none = render_tray_quota_icon(32, None, StatusTone::Ok, false);
        let zero = render_tray_quota_icon(32, Some(0.0), StatusTone::Ok, false);
        let full = render_tray_quota_icon(32, Some(100.0), StatusTone::Ok, false);
        assert_eq!(none, zero, "无配额与 0% 一样只画底轨");
        assert_ne!(none, full, "不得把缺失配额画成满环");
    }

    #[test]
    fn summary_reads_the_real_panel_contract() {
        let panel = golden_panel("valid");
        let summary = extract_quota_summary(&panel);
        // golden valid: 订阅段中已用最高的有效窗口
        let expected_used = panel
            .pointer("/subscription/sections")
            .and_then(Value::as_array)
            .unwrap()
            .iter()
            .filter(|section| !is_failed(section.get("status")))
            .flat_map(|section| {
                let own = section.get("windows").and_then(Value::as_array).cloned();
                let accounts = section
                    .get("accounts")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter(|account| !is_failed(account.get("status")))
                    .filter_map(|account| account.get("windows").and_then(Value::as_array))
                    .flatten()
                    .cloned()
                    .collect::<Vec<_>>();
                own.into_iter().flatten().chain(accounts)
            })
            .filter_map(|window| window.get("usedPercent").and_then(Value::as_f64))
            .fold(f64::MIN, f64::max);
        assert!(expected_used >= 0.0, "golden 必须含订阅窗口");
        assert_eq!(summary.remaining_pct, Some(100.0 - expected_used));
        assert!(summary.top_provider.is_some());
        assert_eq!(
            summary.cost_text.as_deref(),
            panel.pointer("/usage/costText").and_then(Value::as_str)
        );
        assert_eq!(
            summary.tokens_text.as_deref(),
            panel
                .pointer("/usage/totalTokensText")
                .and_then(Value::as_str)
        );
        let active = panel
            .pointer("/hourly/rows")
            .and_then(Value::as_array)
            .map(|rows| {
                rows.iter()
                    .filter(|row| row["todayTotal"].as_i64().unwrap_or(0) > 0)
                    .count()
            })
            .unwrap_or(0);
        assert_eq!(summary.active_agents, active);
        assert!(active > 0, "golden valid 应有活跃 Agent");
        let tooltip = tray_tooltip(&summary);
        assert!(tooltip.contains("额度剩余"), "{tooltip}");
    }

    #[test]
    fn summary_skips_failed_services_and_omits_missing_values() {
        let panel = serde_json::json!({
            "usage": {"costText": null, "totalTokensText": "1.2K"},
            "subscription": {"sections": [
                {"name": "Broken", "status": "error",
                 "windows": [{"label": "5h", "usedPercent": 99.0, "resetText": ""}]},
                {"name": "Codex", "status": "ok", "windows": [], "accounts": [
                    {"status": "failed", "windows": [{"label": "5h", "usedPercent": 95.0}]},
                    {"status": "ok", "windows": [{"label": "周", "usedPercent": 40.0, "resetText": "3 天后"}]}
                ]}
            ]}
        });
        let summary = extract_quota_summary(&panel);
        assert_eq!(summary.remaining_pct, Some(60.0));
        assert_eq!(summary.top_provider.as_deref(), Some("Codex"));
        assert_eq!(summary.reset_text.as_deref(), Some("3 天后"));
        assert_eq!(summary.cost_text, None);
        let tooltip = tray_tooltip(&summary);
        assert!(
            !tooltip.contains("今日"),
            "定价缺失不得显示伪造费用: {tooltip}"
        );

        let empty = extract_quota_summary(&golden_panel("empty"));
        assert_eq!(empty.remaining_pct, None, "无订阅不得伪装为 100%");
        assert!(!tray_tooltip(&empty).contains("额度剩余"));
    }

    /// 预览卡前端测试读取的 `panel.preview` 必须就是本函数对 golden 面板的序列化结果,
    /// 两侧以同一份 fixture 对拍 (C115: 杜绝前后端各自猜字段名)。
    #[test]
    fn preview_fixture_matches_backend_serialization() {
        let path = format!(
            "{}/../../../tests/fixtures/viewmodel-parity/agent-usage-valid.preview.json",
            env!("CARGO_MANIFEST_DIR")
        );
        let actual = serde_json::to_value(extract_quota_summary(&golden_panel("valid"))).unwrap();
        if std::env::var_os("BRUCE_WRITE_PREVIEW_FIXTURE").is_some() {
            std::fs::write(&path, serde_json::to_string_pretty(&actual).unwrap() + "\n").unwrap();
        }
        let expected: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).expect("preview fixture"))
                .unwrap();
        assert_eq!(actual, expected, "后端速览序列化与前端 fixture 不一致");
    }
}
