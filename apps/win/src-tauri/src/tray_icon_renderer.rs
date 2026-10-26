//! Windows 系统托盘动态配额环与状态心跳图标渲染器 (方案 1)
//!
//! 纯内存纯数学像素着色 (32x32 RGBA):
//! - 底轨圆环 (Track)
//! - 动态配额圆弧 (Progress Arc, 从 12 点钟顺时针覆盖)
//! - 中心心跳状态点 (Center Dot, 翠绿/琥珀/科技红/离线灰)
//! - 支持根据聚合快照/视图模型提取配额速览数据 (QuotaSummary)

use crate::runtime_core::StatusTone;

#[derive(Debug, Clone, PartialEq)]
pub struct QuotaSummary {
    pub remaining_pct: f64,
    pub top_provider: String,
    pub top_window_label: String,
    pub resets_in_text: String,
    pub total_cost_text: String,
    pub total_tokens_text: String,
    pub active_agents_count: usize,
    pub status_tone: StatusTone,
    pub status_reason: String,
}

impl Default for QuotaSummary {
    fn default() -> Self {
        Self {
            remaining_pct: 100.0,
            top_provider: "Claude".to_owned(),
            top_window_label: "5h".to_owned(),
            resets_in_text: "--".to_owned(),
            total_cost_text: "$0.00".to_owned(),
            total_tokens_text: "0".to_owned(),
            active_agents_count: 0,
            status_tone: StatusTone::Ok,
            status_reason: "运行正常".to_owned(),
        }
    }
}

/// 从 panel 视图模型中提取配额速览数据
pub fn extract_quota_summary(panel: &serde_json::Value) -> QuotaSummary {
    let mut summary = QuotaSummary::default();

    // 状态灯与原因
    let status = crate::runtime_core::dashboard_status_from_panel(panel);
    summary.status_tone = status.tone;
    summary.status_reason = status.reason;

    // 今日费用与 Token
    if let Some(usage) = panel.get("usage") {
        if let Some(cost) = usage.get("totalCostText").and_then(|v| v.as_str()) {
            summary.total_cost_text = cost.to_owned();
        }
        if let Some(tokens) = usage.get("totalTokensText").and_then(|v| v.as_str()) {
            summary.total_tokens_text = tokens.to_owned();
        }
    }

    // 活跃 Agent 数量
    if let Some(agents) = panel.get("agents").and_then(|v| v.as_array()) {
        summary.active_agents_count = agents
            .iter()
            .filter(|a| a.get("active").and_then(|v| v.as_bool()).unwrap_or(false))
            .count();
    }

    // 订阅配额 (查找最紧迫/利用率最高的一个 window)
    let mut highest_used = -1.0f64;
    if let Some(subs) = panel.get("subscriptions") {
        if let Some(sections) = subs.get("sections").and_then(|v| v.as_array()) {
            for sec in sections {
                let sec_name = sec
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("Provider");
                if let Some(collapsed) = sec.get("collapsedWindow") {
                    if let Some(pct) = collapsed.get("usedPercent").and_then(|v| v.as_f64()) {
                        if pct > highest_used {
                            highest_used = pct;
                            summary.top_provider = sec_name.to_owned();
                            summary.top_window_label = collapsed
                                .get("label")
                                .and_then(|v| v.as_str())
                                .unwrap_or("5h")
                                .to_owned();
                            summary.resets_in_text = collapsed
                                .get("resetsIn")
                                .and_then(|v| v.as_str())
                                .unwrap_or("--")
                                .to_owned();
                        }
                    }
                }
                // 遍历内部所有 windows
                if let Some(windows) = sec.get("windows").and_then(|v| v.as_array()) {
                    for win in windows {
                        if let Some(pct) = win.get("usedPercent").and_then(|v| v.as_f64()) {
                            if pct > highest_used {
                                highest_used = pct;
                                summary.top_provider = sec_name.to_owned();
                                summary.top_window_label = win
                                    .get("label")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("5h")
                                    .to_owned();
                                summary.resets_in_text = win
                                    .get("resetsIn")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("--")
                                    .to_owned();
                            }
                        }
                    }
                }
            }
        }
    }

    if highest_used >= 0.0 {
        summary.remaining_pct = (100.0 - highest_used).clamp(0.0, 100.0);
    } else {
        summary.remaining_pct = 100.0;
    }

    summary
}

/// 渲染 32x32 动态托盘配额图标 (RGBA 字节流，共 32*32*4 = 4096 字节)
pub fn render_tray_quota_icon(
    size: u32,
    remaining_pct: f64,
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

    let clamped_pct = remaining_pct.clamp(0.0, 100.0);
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

    #[test]
    fn test_render_tray_quota_icon_dimensions() {
        let pixels = render_tray_quota_icon(32, 85.0, StatusTone::Ok, false);
        assert_eq!(pixels.len(), 32 * 32 * 4);

        // 中心像素必须不透明并着色
        let center_idx = (16 * 32 + 16) * 4;
        assert!(pixels[center_idx + 3] > 180);
    }

    #[test]
    fn test_extract_quota_summary_parses_sections() {
        let panel = serde_json::json!({
            "status": "ok",
            "usage": {
                "totalCostText": "$1.42",
                "totalTokensText": "384.2k"
            },
            "agents": [
                {"id": "claude", "name": "Claude", "active": true},
                {"id": "codex", "name": "Codex", "active": false}
            ],
            "subscriptions": {
                "sections": [
                    {
                        "id": "claude",
                        "name": "Claude",
                        "windows": [
                            {"label": "5h", "usedPercent": 16.0, "resetsIn": "2h 30m"}
                        ]
                    }
                ]
            }
        });

        let summary = extract_quota_summary(&panel);
        assert_eq!(summary.remaining_pct, 84.0);
        assert_eq!(summary.top_provider, "Claude");
        assert_eq!(summary.top_window_label, "5h");
        assert_eq!(summary.resets_in_text, "2h 30m");
        assert_eq!(summary.total_cost_text, "$1.42");
        assert_eq!(summary.total_tokens_text, "384.2k");
        assert_eq!(summary.active_agents_count, 1);
    }
}
