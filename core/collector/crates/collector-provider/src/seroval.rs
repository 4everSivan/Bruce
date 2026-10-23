//! Seroval subset parser and OpenCode GO usage extraction (C053).

use crate::{clamp_percent, invalid_payload, number, service_result, window, ProviderError};
use serde_json::Value;

fn seroval_object(body: &str) -> Option<&str> {
    let marker = "$R[0]={";
    let start = body.find(marker)? + marker.len() - 1;
    let bytes = body.as_bytes();
    let mut depth = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    for (index, byte) in bytes.iter().enumerate().skip(start) {
        let character = *byte as char;
        if in_string {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            continue;
        }
        match character {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return body.get(start..=index);
                }
            }
            _ => {}
        }
    }
    None
}

fn rewrite_seroval_tokens(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut output = String::with_capacity(input.len());
    let mut index = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    while index < bytes.len() {
        let character = bytes[index] as char;
        if in_string {
            output.push(character);
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            index += 1;
            continue;
        }
        if character == '"' {
            in_string = true;
            output.push(character);
            index += 1;
            continue;
        }
        if bytes[index..].starts_with(b"$R[") {
            if let Some(end) = input[index + 3..].find(']') {
                let end = index + 3 + end + 1;
                let mut cursor = end;
                while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
                    cursor += 1;
                }
                if cursor < bytes.len() && bytes[cursor] == b'=' {
                    index = cursor + 1;
                    continue;
                }
                output.push_str("null");
                index = end;
                continue;
            }
        }
        if bytes[index..].starts_with(b"!0") {
            output.push_str("false");
            index += 2;
            continue;
        }
        if bytes[index..].starts_with(b"!1") {
            output.push_str("true");
            index += 2;
            continue;
        }
        if input[index..].starts_with("undefined") {
            output.push_str("null");
            index += "undefined".len();
            continue;
        }
        output.push(character);
        index += 1;
    }
    quote_seroval_keys(&output)
}

fn quote_seroval_keys(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut output = String::with_capacity(input.len() + 32);
    let mut index = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    while index < bytes.len() {
        let character = bytes[index] as char;
        if in_string {
            output.push(character);
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            index += 1;
            continue;
        }
        if character == '"' {
            in_string = true;
            output.push(character);
            index += 1;
            continue;
        }
        if character == '{' || character == ',' {
            output.push(character);
            index += 1;
            while index < bytes.len() && bytes[index].is_ascii_whitespace() {
                output.push(bytes[index] as char);
                index += 1;
            }
            let start = index;
            while index < bytes.len()
                && (bytes[index].is_ascii_alphanumeric() || bytes[index] == b'_')
            {
                index += 1;
            }
            if index > start {
                let mut cursor = index;
                while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
                    cursor += 1;
                }
                if cursor < bytes.len() && bytes[cursor] == b':' {
                    output.push('"');
                    output.push_str(&input[start..index]);
                    output.push('"');
                    output.push_str(&input[index..cursor]);
                    index = cursor;
                    continue;
                }
                output.push_str(&input[start..index]);
            }
            continue;
        }
        output.push(character);
        index += 1;
    }
    output
}

/// Parse the private OpenCode GO seroval response into the stable quota shape.
pub fn parse_opencode_go_body(body: &[u8], now_epoch: i64) -> Result<Option<Value>, ProviderError> {
    let text = std::str::from_utf8(body).map_err(|_| invalid_payload())?;
    let object = seroval_object(text).ok_or_else(invalid_payload)?;
    let normalized = rewrite_seroval_tokens(object);
    let payload: Value = serde_json::from_str(&normalized).map_err(|_| invalid_payload())?;
    parse_opencode_go_usage(&payload, now_epoch)
}

/// Parse normalized OpenCode GO usage. Missing/non-active windows are omitted.
pub fn parse_opencode_go_usage(
    payload: &Value,
    now_epoch: i64,
) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let mut windows = Vec::new();
    for (key, label, minutes) in [
        ("rollingUsage", "每 5 小时", 300u64),
        ("weeklyUsage", "每周", 10080u64),
        ("monthlyUsage", "每月", 43200u64),
    ] {
        let Some(usage) = object.get(key).and_then(Value::as_object) else {
            continue;
        };
        if usage.get("status").and_then(Value::as_str) != Some("ok") {
            continue;
        }
        let percent = number(usage.get("usagePercent")).unwrap_or(0.0);
        let reset = number(usage.get("resetInSec"))
            .filter(|value| value.is_finite())
            .map(|value| now_epoch.saturating_add(value as i64));
        windows.push(window(label, clamp_percent(percent), Some(minutes), reset));
    }
    Ok(Some(service_result("windows", None, windows)))
}
