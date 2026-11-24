//! Grok Bot 订阅周用量 (T39, design/02 规则 18).
//!
//! 只读 Grok Bot 客户端自身缓存的周用量读数 (`sand-client-persistence` 分片), 不发起
//! 任何网络请求, 不读取加密会话 `sand-secrets.json` 与钥匙串。账号定位、文件读取与
//! 解析只在这里实现一份: Collector 经 [`GrokBotProvider`] 查询, Windows 壳在连接时
//! 直接调用 [`read_active_account`] / [`grok_bot_account_key`]。

use crate::{
    clamp_percent, invalid_credential, service_result, window, CancellationToken, HttpClient,
    ProviderError, ProviderRequest, QuotaProvider,
};
use chrono::{SecondsFormat, TimeZone, Utc};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};

/// Grok Bot 客户端数据目录名 (Electron `userData` 的 productName)。
pub const GROK_BOT_APP_DIR: &str = "Grok Bot";
/// 分片目录。
pub const GROK_BOT_SLICE_DIR: &str = "sand-client-persistence";
/// 已核对的周用量缓存格式版本; 其余版本视为格式漂移。
pub const GROK_BOT_USAGE_SCHEMA_VERSION: u64 = 3;
/// 单个分片文件的读取上限。
pub const GROK_BOT_MAX_SLICE_BYTES: u64 = 64 * 1024;
/// 客户端读数超过该时长未刷新即标陈旧。
pub const GROK_BOT_FRESH_READING_SECS: i64 = 30 * 60;
/// 账号标识长度上限 (与目录表账号 ID 上限同口径)。
pub const GROK_BOT_MAX_ACCOUNT_BYTES: usize = 256;

const ACCOUNT_SLOT_SLICE: &str = "sand.client.slice.client-meta.account-slot";
const WEEK_MINUTES: u64 = 7 * 24 * 60;
const PLAN_MAX_CHARS: usize = 40;

/// 平台默认的 Grok Bot 数据目录。
pub fn grok_bot_data_dir(home: &Path) -> PathBuf {
    platform_data_root(home).join(GROK_BOT_APP_DIR)
}

#[cfg(target_os = "macos")]
fn platform_data_root(home: &Path) -> PathBuf {
    home.join("Library").join("Application Support")
}

#[cfg(windows)]
fn platform_data_root(home: &Path) -> PathBuf {
    env_dir("APPDATA").unwrap_or_else(|| home.join("AppData").join("Roaming"))
}

#[cfg(not(any(target_os = "macos", windows)))]
fn platform_data_root(home: &Path) -> PathBuf {
    env_dir("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config"))
}

#[cfg(not(target_os = "macos"))]
fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// 账号键: `sha256(account)` 十六进制前 16 位。服务 ID 为 `grokbot_<账号键>`,
/// 原始账号标识不进入 artifact。
pub fn grok_bot_account_key(account: &str) -> String {
    let digest = Sha256::digest(account.as_bytes());
    format!("{digest:x}")[..16].to_owned()
}

/// 账号标识是否可接受: 非空、不超长、无控制字符。
pub fn is_valid_grok_bot_account(account: &str) -> bool {
    !account.is_empty()
        && account.len() <= GROK_BOT_MAX_ACCOUNT_BYTES
        && !account.chars().any(char::is_control)
}

/// 分片文件名: 分片键的 RFC 4648 base32 (小写、无填充) + `.blob`。
pub fn slice_file_name(slice_key: &str) -> String {
    const ALPHABET: &[u8; 32] = b"abcdefghijklmnopqrstuvwxyz234567";
    let mut name = String::with_capacity(slice_key.len() * 8 / 5 + 6);
    let mut buffer: u32 = 0;
    let mut bits = 0u32;
    for byte in slice_key.bytes() {
        buffer = (buffer << 8) | u32::from(byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            name.push(ALPHABET[((buffer >> bits) & 0x1f) as usize] as char);
        }
    }
    if bits > 0 {
        name.push(ALPHABET[((buffer << (5 - bits)) & 0x1f) as usize] as char);
    }
    name.push_str(".blob");
    name
}

/// 与 JavaScript `encodeURIComponent` 同口径的百分号编码 (大写十六进制)。
fn encode_uri_component(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        let unreserved = byte.is_ascii_alphanumeric()
            || matches!(
                byte,
                b'-' | b'_' | b'.' | b'!' | b'~' | b'*' | b'\'' | b'(' | b')'
            );
        if unreserved {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

/// 指定账号的周用量分片键。
pub fn usage_cache_slice_key(account: &str) -> String {
    format!(
        "sand.client.slice.account.{}.weekly-usage.cache",
        encode_uri_component(account)
    )
}

fn slice_path(data_dir: &Path, slice_key: &str) -> PathBuf {
    data_dir
        .join(GROK_BOT_SLICE_DIR)
        .join(slice_file_name(slice_key))
}

/// 有界读取分片 JSON。文件不存在返回 `Ok(None)`。
fn read_slice(data_dir: &Path, slice_key: &str) -> Result<Option<Value>, ProviderError> {
    let path = slice_path(data_dir, slice_key);
    let file = match File::open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(read_failed()),
    };
    let mut bytes = Vec::new();
    file.take(GROK_BOT_MAX_SLICE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| read_failed())?;
    if bytes.len() as u64 > GROK_BOT_MAX_SLICE_BYTES {
        return Err(ProviderError::new(
            "PROVIDER_RESPONSE_TOO_LARGE",
            "response",
            "Grok Bot 本机读数超过大小上限",
            false,
        ));
    }
    serde_json::from_slice(&bytes).map(Some).map_err(|_| {
        ProviderError::new(
            "PROVIDER_INVALID_JSON",
            "parse",
            "Grok Bot 本机读数不是有效 JSON",
            false,
        )
    })
}

/// 读取客户端当前登录账号。未登录 (分片缺失或为空) 返回 `Ok(None)`。
pub fn read_active_account(data_dir: &Path) -> Result<Option<String>, ProviderError> {
    let Some(document) = read_slice(data_dir, ACCOUNT_SLOT_SLICE)? else {
        return Ok(None);
    };
    let object = document.as_object().ok_or_else(format_drift)?;
    if object.get("schemaVersion").and_then(Value::as_u64) != Some(1) {
        return Err(format_drift());
    }
    match object.get("value") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(account)) if account.is_empty() => Ok(None),
        Some(Value::String(account)) if is_valid_grok_bot_account(account) => {
            Ok(Some(account.clone()))
        }
        Some(_) => Err(format_drift()),
    }
}

/// 解析客户端周用量缓存 (schemaVersion 3)。`now_epoch` 为本轮采集时刻 (epoch 秒)。
pub fn parse_grok_bot_usage_cache(
    document: &Value,
    now_epoch: i64,
) -> Result<Option<Value>, ProviderError> {
    let root = document.as_object().ok_or_else(format_drift)?;
    if root.get("schemaVersion").and_then(Value::as_u64) != Some(GROK_BOT_USAGE_SCHEMA_VERSION) {
        return Err(format_drift());
    }
    let value = root
        .get("value")
        .and_then(Value::as_object)
        .ok_or_else(format_drift)?;
    match value.get("kind").and_then(Value::as_str) {
        Some("present") => {}
        Some(_) => {
            return Ok(Some(empty_state(
                "Grok Bot 暂无用量读数, 请打开 Grok Bot 后重试",
                None,
            )))
        }
        None => return Err(format_drift()),
    }
    let reading = value
        .get("reading")
        .and_then(Value::as_object)
        .ok_or_else(format_drift)?;
    let usage = reading
        .get("usage")
        .and_then(Value::as_object)
        .ok_or_else(format_drift)?;
    let read_at_ms = reading
        .get("readAtMs")
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite() && *value > 0.0)
        .ok_or_else(format_drift)? as i64;
    let captured_at = Utc
        .timestamp_millis_opt(read_at_ms)
        .single()
        .map(|time| time.to_rfc3339_opts(SecondsFormat::Secs, true))
        .ok_or_else(format_drift)?;

    let team = usage.get("isTeamSeat").and_then(Value::as_bool) == Some(true)
        || present_id(usage.get("readForTeamId"))
        || present_id(value.get("selectedTeamId"));
    if team {
        return Ok(Some(empty_state(
            "团队或企业额度由组织管理, 请在 Grok Bot 查看",
            Some(&captured_at),
        )));
    }
    if usage.get("isSandTrial").and_then(Value::as_bool) == Some(true) {
        return Ok(Some(empty_state(
            "试用期用量暂不展示, 请在 Grok Bot 查看",
            Some(&captured_at),
        )));
    }
    let has_included_limit = usage
        .get("hasNonZeroIncludedLimit")
        .and_then(Value::as_bool)
        .ok_or_else(format_drift)?;
    if !has_included_limit {
        return Ok(Some(empty_state(
            "当前套餐不含 Grok Bot 每周用量",
            Some(&captured_at),
        )));
    }
    let percent = usage
        .get("percentUsed")
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite())
        .ok_or_else(format_drift)?;
    let resets_at = match usage.get("nextResetMs") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_f64()
                .filter(|value| value.is_finite() && *value > 0.0)
                .map(|ms| (ms / 1000.0) as i64)
                .ok_or_else(format_drift)?,
        ),
    };
    if resets_at.is_some_and(|reset| reset <= now_epoch) {
        return Ok(Some(empty_state(
            "周额度已重置, 等待 Grok Bot 刷新读数",
            Some(&captured_at),
        )));
    }

    let unified_plan = plan_string(usage.get("unifiedPlanName"));
    let (label, window_key) = if unified_plan.is_some() {
        ("共享每周用量", "weekly_shared")
    } else {
        ("Grok Bot 每周用量", "weekly")
    };
    let plan = unified_plan.or_else(|| plan_string(usage.get("grokPlanLabel")));
    let mut result = service_result(
        "windows",
        plan.map(Value::String),
        vec![window(
            label,
            window_key,
            "block",
            clamp_percent(percent),
            Some(WEEK_MINUTES),
            resets_at,
        )],
    );
    result["capturedAt"] = Value::String(captured_at);
    if now_epoch.saturating_mul(1000) - read_at_ms > GROK_BOT_FRESH_READING_SECS * 1000 {
        result["freshness"] = Value::String("stale".to_owned());
        result["note"] =
            Value::String("读数来自 Grok Bot 上次刷新, 打开 Grok Bot 可更新".to_owned());
    }
    Ok(Some(result))
}

fn present_id(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::String(text)) => !text.trim().is_empty(),
        Some(_) => true,
    }
}

fn plan_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(|text| text.chars().take(PLAN_MAX_CHARS).collect())
}

/// 无法展示数值的空态。`kind` 留空, 让 `finalize_service` 保留本条说明。
fn empty_state(note: &str, captured_at: Option<&str>) -> Value {
    let mut state = json!({
        "status": "empty",
        "kind": null,
        "windows": [],
        "note": note,
    });
    if let Some(captured_at) = captured_at {
        state["capturedAt"] = Value::String(captured_at.to_owned());
    }
    state
}

fn format_drift() -> ProviderError {
    ProviderError::new(
        "PROVIDER_INVALID_PAYLOAD",
        "parse",
        "Grok Bot 本机读数格式已变化",
        false,
    )
}

fn read_failed() -> ProviderError {
    ProviderError::new(
        "CREDENTIAL_READ_FAILED",
        "credential",
        "Grok Bot 本机读数读取失败",
        true,
    )
}

fn not_signed_in() -> ProviderError {
    ProviderError::new(
        "CREDENTIAL_MISSING",
        "credential",
        "未检测到 Grok Bot 登录态, 请打开 Grok Bot 并登录",
        false,
    )
}

fn account_mismatch() -> ProviderError {
    ProviderError::new(
        "CREDENTIAL_ACCOUNT_MISMATCH",
        "credential",
        "Grok Bot 当前账号与已连接账号不一致, 请切回该账号或在 Bruce 重新连接",
        false,
    )
}

/// Grok Bot 周用量 Provider: 只读本机文件, 不使用 HTTP 客户端。
#[derive(Debug, Clone, Copy, Default)]
pub struct GrokBotProvider;

impl QuotaProvider for GrokBotProvider {
    fn app(&self) -> &str {
        "grok-bot"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        _http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        cancellation.check().map_err(ProviderError::from_runtime)?;
        let credential = request
            .credential
            .as_ref()
            .and_then(Value::as_object)
            .ok_or_else(invalid_credential)?;
        let account = credential
            .get("account")
            .and_then(Value::as_str)
            .filter(|account| is_valid_grok_bot_account(account))
            .ok_or_else(invalid_credential)?;
        let data_dir = credential
            .get("data_dir")
            .and_then(Value::as_str)
            .filter(|path| !path.is_empty())
            .map(PathBuf::from)
            .ok_or_else(not_signed_in)?;
        let active = read_active_account(&data_dir)?.ok_or_else(not_signed_in)?;
        if active != account {
            return Err(account_mismatch());
        }
        let Some(cache) = read_slice(&data_dir, &usage_cache_slice_key(account))? else {
            return Ok(Some(empty_state(
                "Grok Bot 尚未缓存用量读数, 请打开 Grok Bot 后重试",
                None,
            )));
        };
        parse_grok_bot_usage_cache(&cache, crate::captured_epoch(&request.captured_at))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{finalize_provider_outcome, HttpRequest, HttpResponse};
    use std::fs;
    use std::time::Duration;

    const ACCOUNT: &str = "grok|user_FIXTURE0000000000000000000";
    // 2026-11-24T03:41:47Z: 读数时刻; 重置在其后 6 天。
    const READ_AT_MS: i64 = 1_795_491_707_158;
    const RESET_MS: i64 = 1_796_047_061_228;
    const NOW: i64 = READ_AT_MS / 1000 + 60;

    struct NoHttp;

    impl HttpClient for NoHttp {
        fn send(
            &self,
            _request: HttpRequest,
            _cancellation: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            panic!("Grok Bot 不得发起网络请求");
        }
    }

    fn fixture(name: &str) -> Value {
        assert_eq!(name, "weekly-usage-x-premium.json");
        serde_json::from_str(include_str!(
            "../../../../../tests/fixtures/grok-bot/weekly-usage-x-premium.json"
        ))
        .unwrap()
    }

    fn usage(overrides: Value) -> Value {
        let mut document = fixture("weekly-usage-x-premium.json");
        let usage = document["value"]["reading"]["usage"]
            .as_object_mut()
            .unwrap();
        for (key, value) in overrides.as_object().unwrap() {
            usage.insert(key.clone(), value.clone());
        }
        document
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "bruce-grok-bot-{name}-{}-{}",
            std::process::id(),
            Utc::now().timestamp_nanos_opt().unwrap_or_default()
        ));
        fs::create_dir_all(dir.join(GROK_BOT_SLICE_DIR)).unwrap();
        dir
    }

    fn write_slice(dir: &Path, key: &str, body: &str) {
        fs::write(slice_path(dir, key), body).unwrap();
    }

    fn request(data_dir: Option<&Path>, account: &str) -> ProviderRequest {
        let mut credential = json!({"display_name": "Grok Bot", "account": account});
        if let Some(dir) = data_dir {
            credential["data_dir"] = Value::String(dir.to_string_lossy().into_owned());
        }
        ProviderRequest {
            account_id: Some(grok_bot_account_key(account)),
            captured_at: Utc
                .timestamp_opt(NOW, 0)
                .unwrap()
                .to_rfc3339_opts(SecondsFormat::Secs, true),
            timeout: Duration::from_secs(5),
            max_response_body_bytes: 1024,
            credential: Some(credential),
        }
    }

    fn query(data_dir: &Path, account: &str) -> Result<Option<Value>, ProviderError> {
        GrokBotProvider.query(
            &request(Some(data_dir), account),
            &NoHttp,
            &CancellationToken::new(),
        )
    }

    fn signed_in_dir(name: &str, cache: Option<&Value>) -> PathBuf {
        let dir = temp_dir(name);
        write_slice(
            &dir,
            ACCOUNT_SLOT_SLICE,
            &json!({"schemaVersion": 1, "value": ACCOUNT}).to_string(),
        );
        if let Some(cache) = cache {
            write_slice(&dir, &usage_cache_slice_key(ACCOUNT), &cache.to_string());
        }
        dir
    }

    #[test]
    fn slice_names_match_client_base32_layout() {
        // 实测文件名 (账号段已替换为 fixture 账号前的公共前缀)。
        assert_eq!(
            slice_file_name("sand.client.slice.client-meta.account-slot"),
            "onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob"
        );
        assert_eq!(
            usage_cache_slice_key("grok|user_01"),
            "sand.client.slice.account.grok%7Cuser_01.weekly-usage.cache"
        );
        assert_eq!(slice_file_name("f"), "my.blob");
        assert_eq!(slice_file_name("fo"), "mzxq.blob");
        assert_eq!(slice_file_name("foobar"), "mzxw6ytboi.blob");
        assert_eq!(encode_uri_component("a b/c@d"), "a%20b%2Fc%40d");
    }

    #[test]
    fn account_key_is_stable_sha256_prefix() {
        let key = grok_bot_account_key(ACCOUNT);
        assert_eq!(key.len(), 16);
        assert!(key.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(key, grok_bot_account_key(ACCOUNT));
        assert_ne!(key, grok_bot_account_key("grok|user_OTHER"));
        // 双端对拍锚点: mac `GrokBotAccountIdentity` 必须得到同值。
        assert_eq!(grok_bot_account_key("grok|user_01"), "f827599c055f9a8a");
    }

    #[test]
    fn x_premium_reading_maps_to_shared_weekly_window() {
        let result = parse_grok_bot_usage_cache(&fixture("weekly-usage-x-premium.json"), NOW)
            .unwrap()
            .unwrap();
        assert_eq!(result["kind"], "windows");
        assert_eq!(result["plan"], "Premium");
        assert_eq!(result["capturedAt"], "2026-11-24T03:41:47Z");
        assert!(result.get("freshness").is_none());
        let windows = result["windows"].as_array().unwrap();
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0]["label"], "共享每周用量");
        assert_eq!(windows[0]["windowKey"], "weekly_shared");
        assert_eq!(windows[0]["windowMode"], "block");
        assert_eq!(windows[0]["windowMinutes"], 10080);
        assert_eq!(windows[0]["resetsAt"], RESET_MS / 1000);
        let used = windows[0]["usedPercent"].as_f64().unwrap();
        assert!((used - 31.029_252_437_703_143).abs() < 1e-9);
    }

    #[test]
    fn legacy_reading_keeps_separate_weekly_identity() {
        let document = usage(json!({"unifiedPlanName": null}));
        let result = parse_grok_bot_usage_cache(&document, NOW).unwrap().unwrap();
        assert_eq!(result["plan"], "Grok Bot Plan");
        assert_eq!(result["windows"][0]["label"], "Grok Bot 每周用量");
        assert_eq!(result["windows"][0]["windowKey"], "weekly");
    }

    #[test]
    fn percent_boundaries_are_kept_and_clamped() {
        for (raw, expected) in [(0.0, 0.0), (100.0, 100.0), (130.0, 100.0), (-5.0, 0.0)] {
            let document = usage(json!({"percentUsed": raw}));
            let result = parse_grok_bot_usage_cache(&document, NOW).unwrap().unwrap();
            assert_eq!(result["windows"][0]["usedPercent"], expected, "raw={raw}");
        }
    }

    #[test]
    fn unconfirmed_bases_become_empty_states_without_numbers() {
        let cases = [
            (json!({"hasNonZeroIncludedLimit": false}), "不含"),
            (json!({"isTeamSeat": true}), "组织"),
            (json!({"readForTeamId": "team_1"}), "组织"),
            (json!({"isSandTrial": true}), "试用"),
            (json!({"nextResetMs": READ_AT_MS - 1000}), "已重置"),
        ];
        for (overrides, needle) in cases {
            let document = usage(overrides.clone());
            let result = parse_grok_bot_usage_cache(&document, NOW).unwrap().unwrap();
            assert_eq!(result["status"], "empty", "{overrides}");
            assert!(result["windows"].as_array().unwrap().is_empty());
            assert!(
                result["note"].as_str().unwrap().contains(needle),
                "{overrides}"
            );
            assert_eq!(result["capturedAt"], "2026-11-24T03:41:47Z");
        }
        let mut absent = fixture("weekly-usage-x-premium.json");
        absent["value"] = json!({"kind": "absent", "expiresAtMs": READ_AT_MS});
        let result = parse_grok_bot_usage_cache(&absent, NOW).unwrap().unwrap();
        assert_eq!(result["status"], "empty");
    }

    #[test]
    fn missing_or_drifted_fields_fail_instead_of_showing_zero() {
        let drifted = [
            usage(json!({"percentUsed": null})),
            usage(json!({"percentUsed": "31"})),
            usage(json!({"hasNonZeroIncludedLimit": null})),
            usage(json!({"nextResetMs": "soon"})),
            {
                let mut document = fixture("weekly-usage-x-premium.json");
                document["schemaVersion"] = json!(4);
                document
            },
            {
                let mut document = fixture("weekly-usage-x-premium.json");
                document["value"]["reading"]
                    .as_object_mut()
                    .unwrap()
                    .remove("readAtMs");
                document
            },
            json!([]),
        ];
        for document in drifted {
            let error = parse_grok_bot_usage_cache(&document, NOW).unwrap_err();
            assert_eq!(
                error.diagnostic.code, "PROVIDER_INVALID_PAYLOAD",
                "{document}"
            );
        }
        let without_reset = usage(json!({"nextResetMs": null}));
        let result = parse_grok_bot_usage_cache(&without_reset, NOW)
            .unwrap()
            .unwrap();
        assert_eq!(result["windows"][0]["resetsAt"], Value::Null);
    }

    #[test]
    fn old_reading_is_marked_stale() {
        let now = READ_AT_MS / 1000 + GROK_BOT_FRESH_READING_SECS + 1;
        let result = parse_grok_bot_usage_cache(&fixture("weekly-usage-x-premium.json"), now)
            .unwrap()
            .unwrap();
        assert_eq!(result["freshness"], "stale");
        assert!(result["note"].as_str().unwrap().contains("打开 Grok Bot"));
    }

    #[test]
    fn provider_reads_bound_account_without_network() {
        let dir = signed_in_dir("ok", Some(&fixture("weekly-usage-x-premium.json")));
        let result = query(&dir, ACCOUNT).unwrap().unwrap();
        assert_eq!(result["windows"][0]["windowKey"], "weekly_shared");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn provider_refuses_other_account_and_signed_out_client() {
        let dir = signed_in_dir("mismatch", Some(&fixture("weekly-usage-x-premium.json")));
        let error = query(&dir, "grok|user_OTHER").unwrap_err();
        assert_eq!(error.diagnostic.code, "CREDENTIAL_ACCOUNT_MISMATCH");
        let outcome = finalize_provider_outcome(
            "grok-bot",
            json!({"status": "ok", "windows": []}),
            None,
            Err(error),
        );
        assert_eq!(outcome.service["failureKind"], "accountMismatch");
        assert!(!outcome.service["note"].as_str().unwrap().contains("user_"));

        write_slice(
            &dir,
            ACCOUNT_SLOT_SLICE,
            &json!({"schemaVersion": 1, "value": null}).to_string(),
        );
        assert_eq!(
            query(&dir, ACCOUNT).unwrap_err().diagnostic.code,
            "CREDENTIAL_MISSING"
        );
        fs::remove_dir_all(&dir).unwrap();
        assert_eq!(
            query(&dir, ACCOUNT).unwrap_err().diagnostic.code,
            "CREDENTIAL_MISSING"
        );
        let no_dir = GrokBotProvider
            .query(&request(None, ACCOUNT), &NoHttp, &CancellationToken::new())
            .unwrap_err();
        assert_eq!(no_dir.diagnostic.code, "CREDENTIAL_MISSING");
    }

    #[test]
    fn provider_reports_missing_oversized_and_invalid_slices() {
        let dir = signed_in_dir("missing", None);
        let result = query(&dir, ACCOUNT).unwrap().unwrap();
        assert_eq!(result["status"], "empty");
        assert!(result["note"].as_str().unwrap().contains("尚未缓存"));

        write_slice(&dir, &usage_cache_slice_key(ACCOUNT), "{not json");
        assert_eq!(
            query(&dir, ACCOUNT).unwrap_err().diagnostic.code,
            "PROVIDER_INVALID_JSON"
        );
        let huge = " ".repeat(GROK_BOT_MAX_SLICE_BYTES as usize + 1);
        write_slice(&dir, &usage_cache_slice_key(ACCOUNT), &huge);
        assert_eq!(
            query(&dir, ACCOUNT).unwrap_err().diagnostic.code,
            "PROVIDER_RESPONSE_TOO_LARGE"
        );
        write_slice(
            &dir,
            ACCOUNT_SLOT_SLICE,
            r#"{"schemaVersion":2,"value":"x"}"#,
        );
        assert_eq!(
            query(&dir, ACCOUNT).unwrap_err().diagnostic.code,
            "PROVIDER_INVALID_PAYLOAD"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn provider_rejects_malformed_credentials() {
        let mut bad = request(None, ACCOUNT);
        bad.credential = Some(json!({"account": ""}));
        let error = GrokBotProvider
            .query(&bad, &NoHttp, &CancellationToken::new())
            .unwrap_err();
        assert_eq!(error.diagnostic.code, "PROVIDER_INVALID_CREDENTIAL");
        bad.credential = None;
        assert!(GrokBotProvider
            .query(&bad, &NoHttp, &CancellationToken::new())
            .is_err());
    }

    #[test]
    fn active_account_reader_handles_signed_out_and_drift() {
        let dir = temp_dir("slot");
        assert_eq!(read_active_account(&dir).unwrap(), None);
        write_slice(
            &dir,
            ACCOUNT_SLOT_SLICE,
            r#"{"schemaVersion":1,"value":""}"#,
        );
        assert_eq!(read_active_account(&dir).unwrap(), None);
        write_slice(&dir, ACCOUNT_SLOT_SLICE, r#"{"schemaVersion":1,"value":7}"#);
        assert!(read_active_account(&dir).is_err());
        write_slice(
            &dir,
            ACCOUNT_SLOT_SLICE,
            &json!({"schemaVersion": 1, "value": ACCOUNT}).to_string(),
        );
        assert_eq!(read_active_account(&dir).unwrap().as_deref(), Some(ACCOUNT));
        fs::remove_dir_all(dir).unwrap();
    }
}
