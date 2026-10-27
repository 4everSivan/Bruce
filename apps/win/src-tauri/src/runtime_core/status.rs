//! 顶部四色状态灯判定 (C100); C128 由 runtime_core.rs 拆出。

use serde_json::Value;

// MARK: - 顶部四色状态灯判定 (C100)

/// 状态灯四色, 严重度 `Neutral < Ok < Warn < Error`。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum StatusTone {
    Neutral,
    Ok,
    Warn,
    Error,
}

impl StatusTone {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Neutral => "neutral",
            Self::Ok => "ok",
            Self::Warn => "warn",
            Self::Error => "error",
        }
    }

    /// 托盘图标角标色, 与看板 HUD 状态灯同值 (styles.css `--ok` / `--warn` / `--danger` / 中性灰)。
    pub fn tray_rgba(self) -> [u8; 4] {
        match self {
            Self::Neutral => [0x8A, 0x8A, 0x8A, 0xFF],
            Self::Ok => [0x4A, 0x9E, 0x5C, 0xFF],
            Self::Warn => [0xD4, 0xA8, 0x43, 0xFF],
            Self::Error => [0xE5, 0x53, 0x4B, 0xFF],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashboardStatus {
    pub tone: StatusTone,
    pub is_refreshing: bool,
    pub reason: String,
}

/// 状态码 -> 中文态名 (与 mac `DashboardStatusToneResolver.statusLabel` / `app.js` `statusLabel` 同表)。
fn status_label(state: &str) -> &str {
    match state {
        "ok" | "fresh" => "正常",
        "ready" => "可刷新",
        "refreshing" | "loading" => "刷新中",
        "partial" => "部分失败",
        "failed" => "刷新失败",
        "error" => "失败",
        "stale" => "数据过期",
        "unavailable" => "不可用",
        "idle" => "等待刷新",
        "empty" => "暂无数据",
        "notConfigured" => "未配置",
        "authRequired" => "需要授权",
        other => other,
    }
}

fn collection_tone(module_state: &str, has_data: bool) -> StatusTone {
    match module_state {
        "failed" | "error" | "unavailable" => StatusTone::Error,
        "partial" | "stale" | "authRequired" => StatusTone::Warn,
        "fresh" | "ready" | "ok" => StatusTone::Ok,
        "idle" | "refreshing" | "loading" if has_data => StatusTone::Ok,
        _ => StatusTone::Neutral,
    }
}

fn section_tone(status: &str) -> StatusTone {
    match status {
        "error" | "failed" | "unavailable" => StatusTone::Error,
        "partial" | "stale" | "authRequired" => StatusTone::Warn,
        "ok" | "fresh" | "ready" => StatusTone::Ok,
        _ => StatusTone::Neutral,
    }
}

/// `runtime.error` 机器码 -> 中文释义 (与 `app.js` `RUNTIME_ERROR_TEXT` 同表, 由测试锁定);
/// 未登记的码返回 `None`, 不外露到原因文案。
pub fn runtime_error_text(code: &str) -> Option<&'static str> {
    Some(match code {
        "COLLECTION_PARTIAL" => "部分来源未能采集",
        "COLLECTION_FAILED" => "本次采集失败",
        "SNAPSHOT_RESTORED" => "显示上次保存的数据",
        "SNAPSHOT_WRITE_FAILED" => "本地快照写入失败",
        "SNAPSHOT_INVALID" | "SNAPSHOT_READ_FAILED" => "本地快照无法读取",
        "ARTIFACT_MISSING" => "采集结果缺失",
        "ARTIFACT_INVALID" => "采集结果格式无效",
        crate::reachability::NETWORK_UNAVAILABLE => "网络不可用",
        _ => return None,
    })
}

/// 顶部状态灯单一判定 (与 mac `DashboardStatusToneResolver.resolve` / `app.js`
/// `resolveDashboardStatus` 逐字对齐, 三端共用 `tests/fixtures/status-tone-parity` 对拍):
/// 聚合采集与订阅健康度取最严重态; `detail` 只描述采集侧, 订阅侧更严重时原因点名服务。
pub fn resolve_dashboard_status(
    module_state: &str,
    subscriptions: &[(&str, &str)],
    has_data: bool,
    detail: Option<&str>,
) -> DashboardStatus {
    let is_refreshing = matches!(module_state, "refreshing" | "loading");
    let mod_tone = collection_tone(module_state, has_data);

    let mut sub_tone = StatusTone::Neutral;
    let mut worst_sub_status = "empty";
    for (status, _) in subscriptions {
        let candidate = section_tone(status);
        if candidate > sub_tone {
            sub_tone = candidate;
            worst_sub_status = status;
        }
    }

    let tone = mod_tone.max(sub_tone);
    let detail = detail.map(str::trim).unwrap_or_default();
    let reason = if is_refreshing {
        "正在刷新…".to_owned()
    } else if tone == StatusTone::Ok {
        "运行正常".to_owned()
    } else if sub_tone > mod_tone {
        let label = status_label(worst_sub_status);
        let mut names: Vec<&str> = Vec::new();
        for (status, name) in subscriptions {
            let name = name.trim();
            if section_tone(status) == sub_tone && !name.is_empty() && !names.contains(&name) {
                names.push(name);
            }
        }
        if names.is_empty() {
            label.to_owned()
        } else {
            format!("{label} · {}", names.join("、"))
        }
    } else {
        let effective = if module_state == "idle" && !has_data {
            "empty"
        } else {
            module_state
        };
        let label = status_label(effective);
        if !detail.is_empty() && detail != label {
            format!("{label} · {detail}")
        } else {
            label.to_owned()
        }
    };

    DashboardStatus {
        tone,
        is_refreshing,
        reason,
    }
}

/// 从已发布的看板 JSON 计算状态灯 (与 `app.js` `renderStatus` 取数口径一致), 供托盘角标与提示使用。
pub fn dashboard_status_from_panel(panel: &Value) -> DashboardStatus {
    let present = |key: &str| panel.get(key).is_some_and(|value| !value.is_null());
    let has_data = present("usage") || present("subscription") || present("hourly");
    let phase = panel
        .pointer("/runtime/phase")
        .and_then(Value::as_str)
        .filter(|phase| !phase.is_empty())
        .unwrap_or(if has_data { "fresh" } else { "empty" });
    let subscriptions: Vec<(&str, &str)> = panel
        .pointer("/subscription/sections")
        .and_then(Value::as_array)
        .map(|sections| {
            sections
                .iter()
                .filter_map(|section| {
                    let status = section
                        .get("status")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())?;
                    let name = section.get("name").and_then(Value::as_str).unwrap_or("");
                    Some((status, name))
                })
                .collect()
        })
        .unwrap_or_default();
    let detail = panel
        .pointer("/runtime/error")
        .and_then(Value::as_str)
        .and_then(runtime_error_text);
    resolve_dashboard_status(phase, &subscriptions, has_data, detail)
}
