//! 订阅卡映射 —— 对齐 mac `SubscriptionMapping.swift` +
//! `SubscriptionPresentationPolicy` (S5a 冻结规则)。
//!
//! 输入为 artifact.services 的未类型化 JSON (与 mac AgentServiceItem 字段一致);
//! 所有规则注释与 Swift 端保持同源, 任何行为差异都是对拍缺陷。

use std::collections::BTreeMap;

use chrono::{DateTime, TimeZone, Timelike};
use collector_domain::AgentUsageArtifact;
use serde::Serialize;
use serde_json::Value;

use crate::format::balance_text;
use crate::models::PanelDiagnostic;
use crate::usage::PanelViewModelMapper;

// MARK: - 视图模型 (serde 输出即对拍协议)

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionWindowRow {
    /// 已映射措辞 (每 5 小时 / 每周 / 每月 / 赠送额度 ...)。
    pub label: String,
    /// 已用百分比 0...100。
    pub used_percent: f64,
    pub percent_text: String,
    /// 重置时间文案, 无数据为空串。
    pub reset_text: String,
    /// collector 标记单独占一行的量条 (如赠送额度)。
    pub own_row: bool,
    /// 原始窗口周期 (分钟), 供折叠态排序; 无数据为 null。
    pub window_minutes: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BalanceRow {
    pub label: String,
    pub amount_text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexAccountViewModel {
    pub id: String,
    /// 去掉 "Codex · " 前缀的账号名。
    pub name: String,
    pub plan: Option<String>,
    pub status: String,
    pub note: Option<String>,
    pub windows: Vec<SubscriptionWindowRow>,
    /// 非 ok 状态时显示的上次成功时间文案 ("上次成功 HH:mm")。
    pub last_success_text: Option<String>,
    pub tag: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionProviderSection {
    pub id: String,
    pub name: String,
    pub plan: Option<String>,
    pub status: String,
    pub note: Option<String>,
    pub extra_text: Option<String>,
    pub windows: Vec<SubscriptionWindowRow>,
    pub accounts: Vec<CodexAccountViewModel>,
    pub collapsed_window: Option<SubscriptionWindowRow>,
    pub balance: Option<BalanceRow>,
    pub account_count_text: Option<String>,
    /// DeepSeek 月度统计 (T03 账本未接入前恒为 null, 与 mac nil 行为一致)。
    pub deep_seek_monthly_usage: Option<serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionViewModel {
    /// 余额型 provider 已沉底, 其余保持 artifact 顺序。
    pub sections: Vec<SubscriptionProviderSection>,
    /// 卡片右上角最后更新时间 ("最后更新 HH:mm")。
    pub updated_text: Option<String>,
}

// MARK: - Provider 展示策略 (对齐 SubscriptionPresentationPolicy)

/// SubscriptionProviderID rawValues (BruceOnboardingCore); 分组前缀匹配依赖顺序。
const PROVIDER_IDS: [&str; 9] = [
    "kimi",
    "deepseek",
    "volcengine",
    "zhipu",
    "codex",
    "claude",
    "grok",
    "opencodeGo",
    "stepfun",
];

/// 把 artifact service ID 归一化为 provider rawValue。
/// Kimi 的 service ID 是 "kimi_coding" 而 provider rawValue 是 "kimi";
/// 多账号 service ID 格式 "<provider>_<accountID>"; collector 连字符命名归一。
fn provider_id_for_service(service_id: &str) -> String {
    if service_id == "kimi_coding" {
        return "kimi".to_owned();
    }
    for provider in PROVIDER_IDS {
        let prefix = format!("{provider}_");
        if service_id.starts_with(&prefix) {
            return provider.to_owned();
        }
    }
    if service_id.starts_with("opencode_go_") {
        return "opencodeGo".to_owned();
    }
    service_id.to_owned()
}

/// 订阅展示名: 火山引擎剥离 collector 名称里的 Coding Plan 后缀 (仅显示层)。
fn display_name(service_id: &str, service_name: &str) -> String {
    if service_id != "volcengine" {
        return service_name.to_owned();
    }
    service_name.replace("（Coding Plan）", "")
}

/// 附加文案: 「加量包未启用」对用户无信息量, 不展示。
fn extra_text(extra: Option<&str>) -> Option<String> {
    match extra {
        Some("加量包未启用") | None => None,
        Some(value) => Some(value.to_owned()),
    }
}

/// 未授权占位 (kind nil, 无窗口无余额, partial) 视为未启用, 排除;
/// empty 是查询未取到数据的真实诊断状态, 必须渲染。
fn should_skip_placeholder(
    kind: Option<&str>,
    has_windows: bool,
    has_balance: bool,
    status: &str,
) -> bool {
    kind.is_none() && !has_windows && !has_balance && status == "partial"
}

/// 多账号分组展示名 (冻结表)。
fn group_display_name(provider_id: &str) -> String {
    match provider_id {
        "codex" => "ChatGPT",
        "kimi" => "Kimi",
        "deepseek" => "DeepSeek",
        "volcengine" => "火山引擎",
        "zhipu" => "智谱",
        "claude" => "Claude",
        "grok" => "Grok",
        "opencodeGo" | "opencode-go" => "OpenCode GO",
        "stepfun" => "StepFun",
        other => other,
    }
    .to_owned()
}

/// 通用账号短名: Codex 剥离 "Codex · "; 其他剥离首个 " · " 前缀。
fn account_short_name(display_name: &str, provider_id: &str) -> String {
    if provider_id == "codex" {
        return display_name
            .strip_prefix("Codex · ")
            .unwrap_or(display_name)
            .to_owned();
    }
    match display_name.find(" · ") {
        Some(index) => display_name[index + " · ".len()..].to_owned(),
        None => display_name.to_owned(),
    }
}

/// 账号标记: 仅多账号时 stepfun 国外站加 "国际" 标记。
fn account_tag(
    display_name: &str,
    provider_id: &str,
    total_account_count: usize,
) -> Option<String> {
    if total_account_count <= 1 {
        return None;
    }
    if provider_id == "stepfun"
        && (display_name.contains("国际") || display_name.contains("Global"))
    {
        return Some("国际".to_owned());
    }
    None
}

/// Codex 分组状态: 取账号中最差状态 (ok < partial < error)。
fn group_status(statuses: &[String]) -> String {
    let rank = |status: &str| match status {
        "ok" => 0,
        "partial" => 1,
        "error" => 2,
        _ => 1,
    };
    let worst = statuses
        .iter()
        .map(|status| rank(status))
        .max()
        .unwrap_or(0);
    match worst {
        0 => "ok".to_owned(),
        1 => "partial".to_owned(),
        _ => "error".to_owned(),
    }
}

/// 多账号折叠态窗口摘要: 最短重置周期里 usedPercent 最高者。
fn collapsed_window(accounts: &[CodexAccountViewModel]) -> Option<SubscriptionWindowRow> {
    let mut all: Vec<&SubscriptionWindowRow> = accounts
        .iter()
        .flat_map(|account| account.windows.iter())
        .collect();
    all.sort_by(|lhs, rhs| {
        lhs.window_minutes
            .unwrap_or(i64::MAX)
            .cmp(&rhs.window_minutes.unwrap_or(i64::MAX))
            .then(rhs.used_percent.total_cmp(&lhs.used_percent))
    });
    all.first().map(|row| (*row).clone())
}

// MARK: - 窗口行解析

/// 窗口措辞映射: windowMinutes 优先 (±2% 容差), 其次 collector 规范 label。
pub fn window_label(raw_label: &str, window_minutes: Option<i64>) -> String {
    if let Some(minutes) = window_minutes {
        let approximates = |target: i64| (minutes - target).abs() <= (target / 50).max(2);
        if approximates(300) {
            return "每 5 小时".to_owned();
        }
        if approximates(10080) {
            return "每周".to_owned();
        }
        if approximates(43200) {
            return "每月".to_owned();
        }
    }
    match raw_label {
        "5小时窗口" => "每 5 小时".to_owned(),
        "7天窗口" | "每周窗口" => "每周".to_owned(),
        "每月窗口" => "每月".to_owned(),
        other => other.to_owned(),
    }
}

/// 重置时间文案: 当天显示 "H:mm", 之后显示 "N 天后", 已过期显示 "已到期"。
pub fn reset_text(
    resets_at: Option<DateTime<chrono::FixedOffset>>,
    now: DateTime<chrono::FixedOffset>,
) -> String {
    let Some(resets_at) = resets_at else {
        return String::new();
    };
    if resets_at <= now {
        return "已到期".to_owned();
    }
    let resets_date = resets_at.date_naive();
    let now_date = now.date_naive();
    if resets_date == now_date {
        return format!("{}:{:02}", resets_at.hour(), resets_at.minute());
    }
    let days = (resets_date - now_date).num_days();
    format!("{} 天后", days.max(1))
}

/// freshness=stale 且有 capturedAt 时显示 "上次成功 HH:mm"。
fn last_success_text(
    captured_at: Option<&str>,
    freshness: Option<&str>,
    tz_offset: chrono::FixedOffset,
) -> Option<String> {
    if freshness != Some("stale") {
        return None;
    }
    let captured = DateTime::parse_from_rfc3339(captured_at?).ok()?;
    let local = captured.with_timezone(&tz_offset);
    Some(format!("上次成功 {}", local.format("%H:%M")))
}

// MARK: - 主映射

impl PanelViewModelMapper {
    /// artifact.services -> 订阅卡视图模型 (对齐 mac makeSubscription;
    /// deepSeekMonthlyUsage 账本未接入恒 None, providerOrder 空 → 余额型沉底)。
    pub fn make_subscription(
        &self,
        artifact: &AgentUsageArtifact,
        now: DateTime<chrono::FixedOffset>,
        diagnostics: &mut Vec<PanelDiagnostic>,
    ) -> Option<SubscriptionViewModel> {
        struct ParsedService {
            id: String,
            name: String,
            status: String,
            note: Option<String>,
            plan: Option<String>,
            balance: Option<f64>,
            currency: Option<String>,
            extra: Option<String>,
            captured_at: Option<String>,
            freshness: Option<String>,
            windows: Vec<SubscriptionWindowRow>,
        }

        let mut groups: BTreeMap<String, Vec<ParsedService>> = BTreeMap::new();
        let mut group_display: BTreeMap<String, String> = BTreeMap::new();
        let mut group_order: Vec<String> = Vec::new();

        for service in &artifact.services {
            let get = |key: &str| service.get(key);
            let id = get("id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let name = get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let status = get("status")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let note = get("note")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty());
            let kind = get("kind").and_then(Value::as_str);
            let plan = get("plan").and_then(Value::as_str).map(str::to_owned);
            let balance = get("balance").and_then(Value::as_f64);
            let currency = get("currency").and_then(Value::as_str).map(str::to_owned);
            let extra = get("extra").and_then(Value::as_str);
            let captured_at = get("capturedAt").and_then(Value::as_str);
            let freshness = get("freshness").and_then(Value::as_str);

            let raw_windows = get("windows")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let has_windows = !raw_windows.is_empty();
            let has_balance = balance.is_some();

            if should_skip_placeholder(kind, has_windows, has_balance, &status) {
                diagnostics.push(PanelDiagnostic::ServiceSkipped {
                    service_id: id.clone(),
                    status: status.clone(),
                    note: note.unwrap_or_default().to_owned(),
                });
                continue;
            }
            if status != "ok" {
                diagnostics.push(PanelDiagnostic::ServiceIssue {
                    service_id: id.clone(),
                    status: status.clone(),
                    note: note.unwrap_or_default().to_owned(),
                });
            }

            let mut windows = Vec::new();
            for raw in &raw_windows {
                let Some(object) = raw.as_object() else {
                    diagnostics.push(PanelDiagnostic::WindowDropped {
                        service_id: id.clone(),
                        reason: "窗口条目不是对象".to_owned(),
                    });
                    continue;
                };
                let Some(label) = object.get("label").and_then(Value::as_str) else {
                    diagnostics.push(PanelDiagnostic::WindowDropped {
                        service_id: id.clone(),
                        reason: "缺少 label".to_owned(),
                    });
                    continue;
                };
                let Some(used_percent) = object.get("usedPercent").and_then(Value::as_f64) else {
                    diagnostics.push(PanelDiagnostic::WindowDropped {
                        service_id: id.clone(),
                        reason: format!("缺少 usedPercent: {label}"),
                    });
                    continue;
                };
                let clamped = used_percent.clamp(0.0, 100.0);
                let minutes = object.get("windowMinutes").and_then(Value::as_i64);
                // 对齐 mac parseResetDate: 正数 epoch (秒) 或 ISO 字符串;
                // 非正 epoch (如火山未开始窗口的 -1) 仅重置文案为空, 不得中断整卡。
                let resets_at: Option<DateTime<chrono::FixedOffset>> = match object.get("resetsAt")
                {
                    Some(Value::Number(number)) => number
                        .as_i64()
                        .or_else(|| number.as_f64().map(|value| value as i64))
                        .filter(|seconds| *seconds > 0)
                        .and_then(|seconds| chrono::Utc.timestamp_opt(seconds, 0).single())
                        .map(|value| value.with_timezone(now.offset())),
                    Some(Value::String(text)) => DateTime::parse_from_rfc3339(text).ok(),
                    _ => None,
                };
                windows.push(SubscriptionWindowRow {
                    label: window_label(label, minutes),
                    used_percent: clamped,
                    percent_text: format!("{clamped:.0}%"),
                    reset_text: reset_text(
                        resets_at.map(|value| value.with_timezone(now.offset())),
                        now,
                    ),
                    own_row: object
                        .get("ownRow")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    window_minutes: minutes,
                });
            }

            let provider = provider_id_for_service(&id);
            // 对齐 mac: 仅在该 provider 首次出现时记录分组顺序。
            if !groups.contains_key(&provider) {
                group_display
                    .entry(provider.clone())
                    .or_insert_with(|| display_name(&id, &name));
                group_order.push(provider.clone());
            }
            groups.entry(provider).or_default().push(ParsedService {
                id,
                name,
                status,
                note: note.map(str::to_owned),
                plan,
                balance,
                currency,
                extra: extra.map(str::to_owned),
                captured_at: captured_at.map(str::to_owned),
                freshness: freshness.map(str::to_owned),
                windows,
            });
        }

        let mut sections: Vec<SubscriptionProviderSection> = Vec::new();
        for provider in &group_order {
            let Some(services) = groups.get(provider) else {
                continue;
            };
            if services.len() == 1 {
                // 单账号: 直接作为 section; accounts 携带单条记录但不触发折叠。
                let svc = &services[0];
                let account = CodexAccountViewModel {
                    id: svc.id.clone(),
                    name: account_short_name(&svc.name, provider),
                    plan: svc.plan.clone(),
                    status: svc.status.clone(),
                    note: svc.note.clone(),
                    windows: svc.windows.clone(),
                    last_success_text: last_success_text(
                        svc.captured_at.as_deref(),
                        svc.freshness.as_deref(),
                        *now.offset(),
                    ),
                    tag: None,
                };
                sections.push(SubscriptionProviderSection {
                    id: svc.id.clone(),
                    name: group_display_name(provider),
                    plan: svc.plan.clone(),
                    status: svc.status.clone(),
                    note: svc.note.clone(),
                    extra_text: extra_text(svc.extra.as_deref()),
                    windows: svc.windows.clone(),
                    accounts: vec![account],
                    collapsed_window: None,
                    balance: svc.balance.map(|amount| BalanceRow {
                        label: "账户余额".to_owned(),
                        amount_text: balance_text(amount, svc.currency.as_deref()),
                    }),
                    account_count_text: None,
                    deep_seek_monthly_usage: None,
                });
            } else {
                // 多账号: 分组成 section + accounts + collapsedWindow。
                let accounts: Vec<CodexAccountViewModel> = services
                    .iter()
                    .map(|item| CodexAccountViewModel {
                        id: item.id.clone(),
                        name: account_short_name(&item.name, provider),
                        plan: item.plan.clone(),
                        status: item.status.clone(),
                        note: item.note.clone(),
                        windows: item.windows.clone(),
                        last_success_text: last_success_text(
                            item.captured_at.as_deref(),
                            item.freshness.as_deref(),
                            *now.offset(),
                        ),
                        tag: account_tag(&item.name, provider, services.len()),
                    })
                    .collect();
                let status = group_status(
                    &accounts
                        .iter()
                        .map(|account| account.status.clone())
                        .collect::<Vec<_>>(),
                );
                let collapsed = collapsed_window(&accounts);
                sections.push(SubscriptionProviderSection {
                    id: provider.clone(),
                    name: group_display_name(provider),
                    plan: None,
                    status,
                    note: None,
                    extra_text: None,
                    windows: Vec::new(),
                    accounts,
                    collapsed_window: collapsed,
                    balance: None,
                    account_count_text: Some(format!("{} 个账号", services.len())),
                    deep_seek_monthly_usage: None,
                });
            }
        }

        if sections.is_empty() {
            return None;
        }

        // 无自定义顺序: 余额型沉底, 其余保持 artifact 顺序 (稳定排序)。
        sections.sort_by_key(|section| section.balance.is_some());
        let updated_text = updated_text(&artifact.generated_at, *now.offset());
        Some(SubscriptionViewModel {
            sections,
            updated_text,
        })
    }
}

/// 订阅卡右上角更新时间: "最后更新 HH:mm" (跟随 mapper 时区)。
fn updated_text(generated_at: &str, tz_offset: chrono::FixedOffset) -> Option<String> {
    let generated = DateTime::parse_from_rfc3339(generated_at).ok()?;
    Some(format!(
        "最后更新 {}",
        generated.with_timezone(&tz_offset).format("%H:%M")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn now() -> DateTime<chrono::FixedOffset> {
        chrono::FixedOffset::east_opt(8 * 3600)
            .unwrap()
            .with_ymd_and_hms(2026, 7, 28, 12, 30, 0)
            .unwrap()
    }

    #[test]
    fn window_label_mapping_matches_mac() {
        assert_eq!(window_label("5h", Some(300)), "\u{6bcf} 5 \u{5c0f}\u{65f6}");
        assert_eq!(window_label("5h", None), "5h");
    }

    #[test]
    fn reset_text_semantics_match_mac() {
        let at = |value: &str| DateTime::parse_from_rfc3339(value).unwrap();
        let same_day = at("2026-07-28T15:00:00+08:00");
        let next_day = at("2026-07-29T09:05:00+08:00");
        let past = at("2026-07-28T08:00:00+08:00");
        assert_eq!(
            reset_text(Some(same_day), now()),
            "\u{15}:00".replace('\u{15}', "15")
        );
        assert_eq!(
            reset_text(Some(next_day), now()),
            "1 \u{5929}\u{540e}".to_owned()
        );
        assert_eq!(reset_text(Some(past), now()), "\u{5df2}\u{5230}\u{671f}");
        assert_eq!(reset_text(None, now()), "");
    }

    fn artifact_from(services: serde_json::Value) -> AgentUsageArtifact {
        serde_json::from_value(json!({
            "schemaVersion": 1, "module": "agent-usage",
            "generatedAt": "2026-07-28T12:00:00+08:00",
            "agents": [],
            "services": services,
            "totalCostUsd": null
        }))
        .unwrap()
    }

    #[test]
    fn placeholder_skipped_and_balance_sinks() {
        let artifact = artifact_from(json!([
            {"id": "kimi_coding", "name": "Kimi", "status": "ok", "kind": "windows",
             "windows": [{"label": "5h", "windowMinutes": 300, "usedPercent": 32.0,
                          "resetAt": "2026-07-28T15:00:00+08:00"},
                         {"label": "\u{6bcf}\u{65e5}", "usedPercent": 5.0,
                          "resetsAt": "2026-07-29T09:05:00+08:00"}]},
            {"id": "deepseek", "name": "DeepSeek", "status": "partial", "kind": null,
             "windows": [], "balance": null},
            {"id": "zhipu", "name": "Zhipu", "status": "ok", "kind": "balance",
             "windows": [], "balance": 38.21, "currency": "CNY"}
        ]));
        let mut diagnostics = Vec::new();
        let mapper = PanelViewModelMapper::default();
        let subscription = mapper
            .make_subscription(&artifact, now(), &mut diagnostics)
            .unwrap();
        assert!(diagnostics.iter().any(|item| matches!(
            item,
            PanelDiagnostic::ServiceSkipped { service_id, .. } if service_id == "deepseek"
        )));
        assert_eq!(subscription.sections.len(), 2);
        assert_eq!(subscription.sections[0].id, "kimi_coding");
        assert_eq!(subscription.sections[1].id, "zhipu", "balance sinks last");
        let kimi = &subscription.sections[0];
        assert_eq!(kimi.windows[0].label, "\u{6bcf} 5 \u{5c0f}\u{65f6}");
        assert_eq!(kimi.windows[0].percent_text, "32%");
        // fixture 的窗口用的是旧键拼写 "resetAt" (契约键为 "resetsAt"), 双端一致忽略 → 空文案。
        assert_eq!(
            kimi.windows[0].reset_text, "",
            "row = {:?}",
            kimi.windows[0]
        );
        assert_eq!(
            subscription.sections[1]
                .balance
                .as_ref()
                .unwrap()
                .amount_text,
            "\u{a5} 38.21"
        );
        // 契约键 "resetsAt" 正常解析: 次日 → "1 \u{5929}\u{540e}"。
        assert_eq!(kimi.windows[1].reset_text, "1 \u{5929}\u{540e}");
        assert_eq!(kimi.windows[1].percent_text, "5%");
        assert_eq!(
            subscription.updated_text.as_deref(),
            Some("\u{6700}\u{540e}\u{66f4}\u{65b0} 12:00")
        );
    }

    #[test]
    fn multi_account_groups_and_worst_status() {
        let artifact = artifact_from(json!([
            {"id": "codex_aaa", "name": "Codex \u{b7} Alpha", "status": "ok", "app": "codex",
             "kind": "windows",
             "windows": [{"label": "5h", "windowMinutes": 300, "usedPercent": 10.0}]},
            {"id": "codex_bbb", "name": "Codex \u{b7} Beta", "status": "error", "app": "codex",
             "kind": "windows",
             "windows": [{"label": "5h", "windowMinutes": 300, "usedPercent": 50.0}]}
        ]));
        let mut diagnostics = Vec::new();
        let mapper = PanelViewModelMapper::default();
        let subscription = mapper
            .make_subscription(&artifact, now(), &mut diagnostics)
            .unwrap();
        assert_eq!(subscription.sections.len(), 1);
        let section = &subscription.sections[0];
        assert_eq!(section.id, "codex");
        assert_eq!(section.status, "error", "worst status wins");
        assert_eq!(
            section.account_count_text.as_deref(),
            Some("2 \u{4e2a}\u{8d26}\u{53f7}")
        );
        assert_eq!(section.accounts[0].name, "Alpha", "Codex prefix stripped");
        assert_eq!(
            section.collapsed_window.as_ref().unwrap().used_percent,
            50.0
        );
        assert!(diagnostics.iter().any(|item| matches!(
            item,
            PanelDiagnostic::ServiceIssue { service_id, .. } if service_id == "codex_bbb"
        )));
    }
}
