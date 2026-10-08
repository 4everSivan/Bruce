//! DeepSeek balance-delta ledger. Decimal arithmetic avoids cumulative floating point drift.
//! No API key, token, account name or complete artifact is persisted here.
use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs,
    hash::{Hash, Hasher},
    path::Path,
};

#[derive(Clone, Debug)]
struct Amount {
    units: i128,
    scale: u32,
}
impl Amount {
    fn parse(raw: &str) -> Option<Self> {
        let (mantissa, exponent) = raw
            .split_once(['e', 'E'])
            .map(|(a, b)| Some((a, b.parse::<i32>().ok()?)))
            .unwrap_or(Some((raw, 0)))?;
        let (whole, fraction) = mantissa.split_once('.').unwrap_or((mantissa, ""));
        let digits = format!("{whole}{fraction}");
        let mut units = digits.parse::<i128>().ok()?;
        let scale = fraction.len() as i32 - exponent;
        let mut scale = if scale < 0 {
            units = units.checked_mul(10i128.checked_pow((-scale).try_into().ok()?)?)?;
            0
        } else {
            u32::try_from(scale).ok()?
        };
        if scale > 28 {
            return None;
        }
        while scale > 0 && units % 10 == 0 {
            units /= 10;
            scale -= 1;
        }
        Some(Self { units, scale })
    }
    fn arithmetic(&self, other: &Self, subtract: bool) -> Option<Self> {
        let scale = self.scale.max(other.scale);
        let a = self
            .units
            .checked_mul(10i128.checked_pow(scale - self.scale)?)?;
        let b = other
            .units
            .checked_mul(10i128.checked_pow(scale - other.scale)?)?;
        Some(Self {
            units: if subtract {
                a.checked_sub(b)?
            } else {
                a.checked_add(b)?
            },
            scale,
        })
    }
    fn text(&self) -> String {
        let negative = self.units < 0;
        let mut digits = self.units.unsigned_abs().to_string();
        if self.scale > 0 {
            while digits.len() <= self.scale as usize {
                digits.insert(0, '0');
            }
            digits.insert(digits.len() - self.scale as usize, '.');
        }
        if negative {
            digits.insert(0, '-');
        }
        digits
    }
    fn number(&self) -> f64 {
        self.text().parse().unwrap_or(0.0)
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Point {
    observed_at: String,
    cumulative_consumption: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Ledger {
    schema_version: u32,
    tracking_id: String,
    month_key: String,
    currency: String,
    coverage_start: String,
    last_observed_at: String,
    balance: String,
    consumption: String,
    points: Vec<Point>,
    credit_note: Option<String>,
}
impl Ledger {
    fn valid(&self, tracking: &str) -> bool {
        self.schema_version == 1
            && self.tracking_id == tracking
            && DateTime::parse_from_rfc3339(&self.last_observed_at).is_ok()
            && Amount::parse(&self.balance).is_some_and(|a| a.units >= 0)
            && Amount::parse(&self.consumption).is_some_and(|a| a.units >= 0)
            && !self.points.is_empty()
            && self.points.len() <= 100_000
            && self.points.iter().all(|p| {
                DateTime::parse_from_rfc3339(&p.observed_at).is_ok()
                    && Amount::parse(&p.cumulative_consumption).is_some_and(|a| a.units >= 0)
            })
    }
    fn view(&self) -> Value {
        let trend = self.points.len() >= 2;
        let start = DateTime::parse_from_rfc3339(&self.coverage_start)
            .map(|t| t.with_timezone(&Local).format("%y/%m/%d").to_string())
            .unwrap_or_else(|_| self.coverage_start.clone());
        let money = |raw: &str| {
            bruce_win_viewmodel::format::balance_text(
                Amount::parse(raw).map(|a| a.number()).unwrap_or(0.0),
                Some(&self.currency),
            )
        };
        json!({"state":if trend {"trend"} else {"baseline"},"estimatedConsumptionText":if trend {money(&self.consumption)} else {String::new()},"currentBalanceText":money(&self.balance),"coverageText":format!("自 {start} 起{}",if trend {"累计推算"} else {"首次记录"}),"trendPoints":if trend {self.points.iter().map(|p|json!({"observedAt":p.observed_at,"cumulativeConsumption":Amount::parse(&p.cumulative_consumption).unwrap().number()})).collect::<Vec<_>>()} else {vec![]},"creditNote":self.credit_note})
    }
}
fn ledger_path(root: &Path, id: &str) -> std::path::PathBuf {
    if id == "deepseek" {
        return root.join("usage-ledger/deepseek-monthly.json");
    }
    // The filename reveals no account identifier, and never uses input as a path component.
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    id.hash(&mut hash);
    root.join("usage-ledger")
        .join(format!("deepseek-{:016x}.json", hash.finish()))
}
fn observe(
    root: &Path,
    id: &str,
    at: &str,
    balance: &Value,
    currency: &str,
    fresh: bool,
) -> Result<Option<Value>, String> {
    let path = ledger_path(root, id);
    let tracking = if fresh {
        crate::credentials::deepseek_tracking_id(root)?
    } else {
        let Ok(id) = fs::read_to_string(root.join("deepseek-tracking-id")) else {
            return Ok(None);
        };
        id
    };
    let previous = fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice::<Ledger>(&b).ok())
        .filter(|s| s.valid(&tracking));
    if !fresh {
        return Ok(previous.map(|s| s.view()));
    }
    let Ok(date) = DateTime::parse_from_rfc3339(at) else {
        return Ok(previous.map(|s| s.view()));
    };
    let Some(amount) = Amount::parse(&balance.to_string()).filter(|a| a.units >= 0) else {
        return Ok(previous.map(|s| s.view()));
    };
    let month = date.with_timezone(&Local).format("%Y-%m").to_string();
    if let Some(old) = &previous {
        if DateTime::parse_from_rfc3339(&old.last_observed_at).is_ok_and(|last| date <= last) {
            return Ok(Some(old.view()));
        }
    }
    let mut next = match previous.filter(|s| s.month_key == month && s.currency == currency) {
        Some(s) => s,
        None => Ledger {
            schema_version: 1,
            tracking_id: tracking,
            month_key: month,
            currency: currency.into(),
            coverage_start: at.into(),
            last_observed_at: at.into(),
            balance: amount.text(),
            consumption: "0".into(),
            points: vec![Point {
                observed_at: at.into(),
                cumulative_consumption: "0".into(),
            }],
            credit_note: None,
        },
    };
    if next.last_observed_at != at {
        let delta = Amount::parse(&next.balance)
            .and_then(|last| last.arithmetic(&amount, true))
            .ok_or("LEDGER_AMOUNT_INVALID")?;
        if delta.units != 0 {
            if delta.units > 0 {
                next.consumption = Amount::parse(&next.consumption)
                    .and_then(|sum| sum.arithmetic(&delta, false))
                    .ok_or("LEDGER_AMOUNT_INVALID")?
                    .text();
                next.credit_note = None;
            } else {
                next.credit_note = Some("入账未计入消费".into());
            }
            next.points.push(Point {
                observed_at: at.into(),
                cumulative_consumption: next.consumption.clone(),
            });
        }
        next.last_observed_at = at.into();
        next.balance = amount.text();
    }
    let bytes = serde_json::to_vec(&next).map_err(|_| "LEDGER_ENCODE_FAILED")?;
    // Preserve the prior complete ledger; backups are not used to invent missing observations.
    if let Ok(old) = fs::read(&path) {
        crate::credentials::atomic_private_write(&path.with_extension("json.backup"), &old)?;
    }
    crate::credentials::atomic_private_write(&path, &bytes)?;
    let checked: Ledger =
        serde_json::from_slice(&fs::read(&path).map_err(|_| "LEDGER_READ_FAILED")?)
            .map_err(|_| "LEDGER_READ_FAILED")?;
    if !checked.valid(&next.tracking_id) {
        return Err("LEDGER_READ_FAILED".into());
    }
    Ok(Some(next.view()))
}

pub fn decorate_panel(root: &Path, artifact: &Value, panel: &mut Value) -> Result<(), String> {
    decorate(root, artifact, panel, true)
}
pub fn decorate_cached_panel(
    root: &Path,
    artifact: &Value,
    panel: &mut Value,
) -> Result<(), String> {
    decorate(root, artifact, panel, false)
}
fn decorate(root: &Path, artifact: &Value, panel: &mut Value, record: bool) -> Result<(), String> {
    let Some(at) = artifact.get("generatedAt").and_then(Value::as_str) else {
        return Ok(());
    };
    let Some(services) = artifact.get("services").and_then(Value::as_array) else {
        return Ok(());
    };
    for service in services {
        let Some(id) = service
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| *id == "deepseek" || id.starts_with("deepseek_"))
        else {
            continue;
        };
        if service["kind"] != "balance" {
            continue;
        }
        let Some(balance) = service
            .get("balance")
            .filter(|v| v.as_f64().is_some_and(|n| n.is_finite() && n >= 0.0))
        else {
            continue;
        };
        let Some(currency) = service
            .get("currency")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        else {
            continue;
        };
        let fresh = record
            && service["status"] == "ok"
            && service.get("freshness").is_none_or(|v| v == "fresh");
        let Some(monthly) = observe(root, id, at, balance, currency, fresh)? else {
            continue;
        };
        if let Some(sections) = panel
            .pointer_mut("/subscription/sections")
            .and_then(Value::as_array_mut)
        {
            for section in sections {
                if section["id"] == id {
                    section["deepSeekMonthlyUsage"] = monthly.clone();
                }
                if let Some(accounts) = section.get_mut("accounts").and_then(Value::as_array_mut) {
                    for account in accounts {
                        if account["id"] == id {
                            account["deepSeekMonthlyUsage"] = monthly.clone();
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn root() -> std::path::PathBuf {
        std::env::temp_dir().join(format!("c009-ledger-{}", uuid::Uuid::new_v4()))
    }
    fn sample(at: &str, balance: f64) -> Value {
        json!({"generatedAt":at,"services":[{"id":"deepseek","status":"ok","kind":"balance","balance":balance,"currency":"CNY"}]})
    }
    fn panel() -> Value {
        json!({"subscription":{"sections":[{"id":"deepseek","deepSeekMonthlyUsage":null}]}})
    }
    #[test]
    fn baseline_consumption_credit_duplicate_and_month_boundary() {
        let root = root();
        let mut p = panel();
        decorate_panel(&root, &sample("2026-10-01T12:00:00+08:00", 100.3), &mut p).unwrap();
        assert_eq!(
            p["subscription"]["sections"][0]["deepSeekMonthlyUsage"]["state"],
            "baseline"
        );
        decorate_panel(&root, &sample("2026-10-02T12:00:00+08:00", 100.1), &mut p).unwrap();
        let m = &p["subscription"]["sections"][0]["deepSeekMonthlyUsage"];
        assert_eq!(m["estimatedConsumptionText"], "¥ 0.20");
        assert_eq!(m["trendPoints"].as_array().unwrap().len(), 2);
        decorate_panel(&root, &sample("2026-10-03T12:00:00+08:00", 110.1), &mut p).unwrap();
        decorate_panel(&root, &sample("2026-10-03T12:00:00+08:00", 110.1), &mut p).unwrap();
        let m = &p["subscription"]["sections"][0]["deepSeekMonthlyUsage"];
        assert_eq!(m["estimatedConsumptionText"], "¥ 0.20");
        assert_eq!(m["creditNote"], "入账未计入消费");
        assert_eq!(m["trendPoints"].as_array().unwrap().len(), 3);
        decorate_panel(&root, &sample("2026-11-01T12:00:00+08:00", 90.0), &mut p).unwrap();
        assert_eq!(
            p["subscription"]["sections"][0]["deepSeekMonthlyUsage"]["state"],
            "baseline"
        );
    }
    #[test]
    fn invalid_or_stale_observations_do_not_create_ledger() {
        let root = root();
        let mut p = panel();
        let mut a = sample("2026-10-01T00:00:00Z", 100.0);
        a["services"][0]["freshness"] = json!("stale");
        decorate_panel(&root, &a, &mut p).unwrap();
        assert!(!root.join("usage-ledger/deepseek-monthly.json").exists());
    }
}

#[cfg(test)]
mod boundary_tests {
    use super::*;
    fn root() -> std::path::PathBuf {
        std::env::temp_dir().join(format!("c009-ledger-boundary-{}", uuid::Uuid::new_v4()))
    }
    fn artifact(at: &str, balance: f64, currency: &str) -> Value {
        json!({"generatedAt":at,"services":[{"id":"deepseek","status":"ok","kind":"balance","balance":balance,"currency":currency}]})
    }
    fn panel() -> Value {
        json!({"subscription":{"sections":[{"id":"deepseek"}]}})
    }
    #[test]
    fn cached_dashboard_read_never_creates_a_ledger_or_tracking_id() {
        let root = root();
        let mut p = panel();
        decorate_cached_panel(
            &root,
            &artifact("2026-10-08T12:00:00Z", 10.0, "CNY"),
            &mut p,
        )
        .unwrap();
        assert!(!root.exists());
    }
    #[test]
    fn credential_change_and_currency_change_rebaseline_without_backfill() {
        let root = root();
        let mut p = panel();
        decorate_panel(
            &root,
            &artifact("2026-10-01T12:00:00Z", 10.0, "CNY"),
            &mut p,
        )
        .unwrap();
        decorate_panel(&root, &artifact("2026-10-02T12:00:00Z", 9.0, "CNY"), &mut p).unwrap();
        assert_eq!(
            p.pointer("/subscription/sections/0/deepSeekMonthlyUsage/state")
                .unwrap(),
            "trend"
        );
        crate::credentials::save_credential_account(
            &root,
            "deepseekQuotaAccounts",
            "a",
            &json!({"api_key":"new-fixture"}),
        )
        .unwrap();
        decorate_panel(&root, &artifact("2026-10-03T12:00:00Z", 1.0, "CNY"), &mut p).unwrap();
        assert_eq!(
            p.pointer("/subscription/sections/0/deepSeekMonthlyUsage/state")
                .unwrap(),
            "baseline"
        );
        decorate_panel(&root, &artifact("2026-10-04T12:00:00Z", 0.5, "USD"), &mut p).unwrap();
        assert_eq!(
            p.pointer("/subscription/sections/0/deepSeekMonthlyUsage/state")
                .unwrap(),
            "baseline"
        );
    }
    #[test]
    fn decimal_delta_keeps_small_repeated_consumption_exact() {
        let mut sum = Amount::parse("0").unwrap();
        let part = Amount::parse("0.0001").unwrap();
        for _ in 0..10000 {
            sum = sum.arithmetic(&part, false).unwrap();
        }
        assert_eq!(sum.number(), 1.0);
        assert_eq!(Amount::parse("1e-7").unwrap().number(), 0.0000001);
    }
}
