//! Cryptographic signing (HMAC-SHA256 / VolcEngine) and StepFun JWT helpers (C053).

use crate::{
    captured_epoch, parse_stepfun_usage, provider_headers, send_json, HttpClient, ProviderError,
    ProviderRequest, STEPFUN_GLOBAL_REFRESH_TOKEN_URL, STEPFUN_GLOBAL_STEP_PLAN_RATE_LIMIT_URL,
    STEPFUN_REFRESH_TOKEN_URL, STEPFUN_STEP_PLAN_RATE_LIMIT_URL,
};
use chrono::{DateTime, Utc};
use collector_runtime::CancellationToken;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fmt::Write as _;

fn sha256_hex(value: &[u8]) -> String {
    let digest = Sha256::digest(value);
    hex_bytes(&digest)
}

fn hex_bytes(value: &[u8]) -> String {
    let mut output = String::with_capacity(value.len() * 2);
    for byte in value {
        let _ = write!(&mut output, "{byte:02x}");
    }
    output
}

fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut normalized = [0u8; 64];
    if key.len() > 64 {
        normalized[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        normalized[..key.len()].copy_from_slice(key);
    }
    let mut inner_key = [0u8; 64];
    let mut outer_key = [0u8; 64];
    for index in 0..64 {
        inner_key[index] = normalized[index] ^ 0x36;
        outer_key[index] = normalized[index] ^ 0x5c;
    }
    let mut inner = Sha256::new();
    inner.update(inner_key);
    inner.update(message);
    let inner_digest = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(outer_key);
    outer.update(inner_digest);
    outer.finalize().into()
}

fn hmac_hex(key: &[u8], message: &[u8]) -> String {
    hex_bytes(&hmac_sha256(key, message))
}

fn base64_decode_text(value: &str) -> Option<String> {
    let mut output = Vec::new();
    let mut accumulator = 0u32;
    let mut bits = 0u8;
    for byte in value.bytes().filter(|byte| !byte.is_ascii_whitespace()) {
        if byte == b'=' {
            break;
        }
        let digit = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return None,
        };
        accumulator = (accumulator << 6) | u32::from(digit);
        bits += 6;
        while bits >= 8 {
            bits -= 8;
            output.push((accumulator >> bits) as u8);
            if bits > 0 {
                accumulator &= (1 << bits) - 1;
            } else {
                accumulator = 0;
            }
        }
    }
    String::from_utf8(output)
        .ok()
        .filter(|value| !value.is_empty())
}

pub(crate) fn extract_stepfun_device_id(token: &str) -> Option<String> {
    let target_jwt = token.split("...").last().unwrap_or(token);
    let mut parts = target_jwt.split('.');
    let _header = parts.next()?;
    let payload_b64 = parts.next()?;
    let payload_str = base64_decode_text(payload_b64)?;
    let parsed: Value = serde_json::from_str(&payload_str).ok()?;
    parsed
        .get("device_id")
        .and_then(Value::as_str)
        .map(|s| s.to_owned())
}

pub(crate) fn is_stepfun_token_expired(token: &str, now_epoch: i64) -> bool {
    let first_jwt = token.split("...").next().unwrap_or(token);
    let mut parts = first_jwt.split('.');
    let _header = match parts.next() {
        Some(h) => h,
        None => return false,
    };
    let payload_b64 = match parts.next() {
        Some(p) => p,
        None => return false,
    };
    let payload_str = match base64_decode_text(payload_b64) {
        Some(s) => s,
        None => return false,
    };
    let parsed: Value = match serde_json::from_str(&payload_str) {
        Ok(v) => v,
        Err(_) => return false,
    };
    if let Some(exp) = parsed.get("exp").and_then(Value::as_i64) {
        return exp <= now_epoch + 30;
    }
    false
}

pub(crate) fn extract_stepfun_app_id(token: &str) -> Option<u32> {
    let target_jwt = token.split("...").last().unwrap_or(token);
    let mut parts = target_jwt.split('.');
    let _header = parts.next()?;
    let payload_b64 = parts.next()?;
    let payload_str = base64_decode_text(payload_b64)?;
    let parsed: Value = serde_json::from_str(&payload_str).ok()?;
    parsed
        .get("app_id")
        .and_then(Value::as_u64)
        .map(|id| id as u32)
}

/// StepFun 站点判定 (C093 / 设计规则 28)。优先序为**用户显式选择 > 令牌推导**:
/// 保存了 `site` / `is_global` 时以它为准 (Windows 设置页仅在用户显式选择时才写入),
/// 否则回落到从令牌解析的 `app_id` (国际站 20700)。保存值等于推导结果时两者结论一致,
/// 不构成覆盖 —— 故前端不再写入默认站点后, 国际站令牌不会因默认值被查错站点。
pub(crate) fn is_stepfun_global(token: &str, request: &ProviderRequest) -> bool {
    if let Some(credential) = request.credential.as_ref() {
        if let Some(obj) = credential.as_object() {
            if let Some(site) = obj.get("site").and_then(Value::as_str) {
                if site.eq_ignore_ascii_case("global") || site.contains(".ai") {
                    return true;
                }
                if site.eq_ignore_ascii_case("domestic") || site.contains(".com") {
                    return false;
                }
            }
            if let Some(is_global) = obj.get("is_global").and_then(Value::as_bool) {
                return is_global;
            }
            if let Some(display_name) = obj.get("display_name").and_then(Value::as_str) {
                if display_name.contains("国际") || display_name.contains("Global") {
                    return true;
                }
            }
        }
    }
    if let Some(app_id) = extract_stepfun_app_id(token) {
        return app_id == 20700;
    }
    if let Some(credential) = request.credential.as_ref() {
        if let Some(obj) = credential.as_object() {
            if let Some(orig_token) = obj.get("token").and_then(Value::as_str) {
                if let Some(app_id) = extract_stepfun_app_id(orig_token) {
                    return app_id == 20700;
                }
            }
        } else if let Some(orig_token) = credential.as_str() {
            if let Some(app_id) = extract_stepfun_app_id(orig_token) {
                return app_id == 20700;
            }
        }
    }
    false
}

pub(crate) fn refresh_stepfun_token(
    request: &ProviderRequest,
    token: &str,
    http: &dyn HttpClient,
    cancellation: &CancellationToken,
) -> Result<String, ProviderError> {
    let device_id = extract_stepfun_device_id(token);
    let is_global = is_stepfun_global(token, request);
    let app_id = if is_global { "20700" } else { "10300" };
    let origin = if is_global {
        "https://platform.stepfun.ai"
    } else {
        "https://platform.stepfun.com"
    };
    let referer = if is_global {
        "https://platform.stepfun.ai/"
    } else {
        "https://platform.stepfun.com/"
    };
    let refresh_url = if is_global {
        STEPFUN_GLOBAL_REFRESH_TOKEN_URL
    } else {
        STEPFUN_REFRESH_TOKEN_URL
    };

    let mut headers = vec![
        ("Cookie", format!("Oasis-Token={token}")),
        ("Oasis-Token", token.to_owned()),
        ("Oasis-appID", app_id.to_owned()),
        ("Oasis-Platform", "web".to_owned()),
        ("Oasis-Language", "zh-CN".to_owned()),
        ("Content-Type", "application/json".to_owned()),
        ("Accept", "application/json".to_owned()),
        ("Origin", origin.to_owned()),
        ("Referer", referer.to_owned()),
        (
            "User-Agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36".to_owned(),
        ),
    ];
    if let Some(did) = device_id {
        headers.push(("Oasis-Webid", did));
    }

    let payload = send_json(
        request,
        http,
        cancellation,
        "POST",
        refresh_url.to_owned(),
        provider_headers(&headers),
        Some(b"{}".to_vec()),
        Some("StepFun 凭证刷新失败, 账号可能需要重新登录"),
    )?;

    let object = payload.as_object().ok_or_else(|| {
        ProviderError::new(
            "PROVIDER_REMOTE_REJECTED",
            "refresh",
            "StepFun 刷新响应格式无效",
            false,
        )
    })?;

    let access_raw = object
        .get("accessToken")
        .and_then(Value::as_object)
        .and_then(|t| t.get("raw"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            ProviderError::new(
                "PROVIDER_REMOTE_REJECTED",
                "refresh",
                "StepFun 刷新响应未包含有效 access token",
                false,
            )
        })?;

    let refresh_raw = object
        .get("refreshToken")
        .and_then(Value::as_object)
        .and_then(|t| t.get("raw"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty());

    let new_token = match refresh_raw {
        Some(r) => format!("{access_raw}...{r}"),
        None => {
            let parts: Vec<&str> = token.split("...").collect();
            if parts.len() > 1 {
                format!("{access_raw}...{}", parts[1])
            } else {
                access_raw.to_owned()
            }
        }
    };
    Ok(new_token)
}

pub(crate) fn query_stepfun_rate_limit(
    request: &ProviderRequest,
    token: &str,
    http: &dyn HttpClient,
    cancellation: &CancellationToken,
) -> Result<Option<Value>, ProviderError> {
    let device_id = extract_stepfun_device_id(token);
    let is_global = is_stepfun_global(token, request);
    let app_id = if is_global { "20700" } else { "10300" };
    let origin = if is_global {
        "https://platform.stepfun.ai"
    } else {
        "https://platform.stepfun.com"
    };
    let referer = if is_global {
        "https://platform.stepfun.ai/"
    } else {
        "https://platform.stepfun.com/"
    };
    let rate_limit_url = if is_global {
        STEPFUN_GLOBAL_STEP_PLAN_RATE_LIMIT_URL
    } else {
        STEPFUN_STEP_PLAN_RATE_LIMIT_URL
    };

    let mut headers = vec![
        ("Cookie", format!("Oasis-Token={token}")),
        ("Oasis-Token", token.to_owned()),
        ("Oasis-appID", app_id.to_owned()),
        ("Oasis-Platform", "web".to_owned()),
        ("Oasis-Language", "zh-CN".to_owned()),
        ("Content-Type", "application/json".to_owned()),
        ("Accept", "application/json".to_owned()),
        ("Origin", origin.to_owned()),
        ("Referer", referer.to_owned()),
        (
            "User-Agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36".to_owned(),
        ),
    ];
    if let Some(did) = device_id {
        headers.push(("Oasis-Webid", did));
    }

    let payload = send_json(
        request,
        http,
        cancellation,
        "POST",
        rate_limit_url.to_owned(),
        provider_headers(&headers),
        Some(b"{}".to_vec()),
        Some("StepFun 凭证被拒绝或已过期, 请检查 Oasis-Token"),
    )?;
    parse_stepfun_usage(&payload)
}

pub(crate) fn volc_secret_candidates(raw: &str) -> Vec<String> {
    let mut candidates = vec![raw.to_owned()];
    let mut current = raw.to_owned();
    for _ in 0..2 {
        let Some(decoded) = base64_decode_text(&current) else {
            break;
        };
        if candidates.contains(&decoded) {
            break;
        }
        current = decoded.clone();
        candidates.push(decoded);
    }
    candidates
}

pub(crate) fn volc_credential_field<'a>(credential: &'a Value, key: &str) -> Option<&'a str> {
    let object = credential.as_object()?;
    let nested = object.get("usage_script").and_then(Value::as_object);
    nested
        .and_then(|value| value.get(key))
        .or_else(|| object.get(key))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

pub(crate) fn volc_headers(
    secret: &str,
    access_key: &str,
    captured_at: &str,
    query: &str,
) -> BTreeMap<String, String> {
    let epoch = captured_epoch(captured_at);
    let date = DateTime::<Utc>::from_timestamp(epoch, 0).unwrap_or_else(Utc::now);
    let x_date = date.format("%Y%m%dT%H%M%SZ").to_string();
    let short_date = date.format("%Y%m%d").to_string();
    let payload_hash = sha256_hex(b"");
    let signed_headers = "host;x-date;x-content-sha256;content-type";
    let canonical_headers = format!(
        "host:open.volcengineapi.com\nx-date:{x_date}\nx-content-sha256:{payload_hash}\ncontent-type:application/json; charset=utf-8\n"
    );
    let canonical = format!("GET\n/\n{query}\n{canonical_headers}{signed_headers}\n{payload_hash}");
    let scope = format!("{short_date}/cn-beijing/ark/request");
    let string_to_sign = format!(
        "HMAC-SHA256\n{x_date}\n{scope}\n{}",
        sha256_hex(canonical.as_bytes())
    );
    let date_key = hmac_sha256(secret.as_bytes(), short_date.as_bytes());
    let region_key = hmac_sha256(&date_key, b"cn-beijing");
    let service_key = hmac_sha256(&region_key, b"ark");
    let signing_key = hmac_sha256(&service_key, b"request");
    let signature = hmac_hex(&signing_key, string_to_sign.as_bytes());
    provider_headers(&[
        (
            "Authorization",
            format!(
                "HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"
            ),
        ),
        ("x-date", x_date),
        ("x-content-sha256", payload_hash),
        (
            "content-type",
            "application/json; charset=utf-8".to_owned(),
        ),
    ])
}
