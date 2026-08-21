#![deny(unsafe_code)]

//! Credential read/refresh adapters. App Keychain writes remain in Swift.

use chrono::{DateTime, NaiveDateTime};
use collector_domain::Diagnostic;
use collector_runtime::{AccountSingleFlight, CancellationToken, SingleFlightError};
use serde_json::Value;
use std::collections::BTreeSet;
use std::fmt::{self, Display, Formatter};
use std::path::Path;
use std::process::Command;

pub const CREDENTIAL_ROLE: &str = "credential-adapter";
pub const CREDENTIAL_CHALLENGE_ACCOUNT_ID_MAX: usize = 256;
pub const UPDATE_ACCOUNT_ID_MAX: usize = 256;

const UPDATE_CREDENTIAL_FIELDS: &[&str] = &["access_token", "expiry", "id_token", "refresh_token"];

pub const CLAUDE_KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
pub const ANTIGRAVITY_KEYCHAIN_SERVICE: &str = "gemini";
pub const ANTIGRAVITY_KEYCHAIN_ACCOUNT: &str = "antigravity";
pub const ANTIGRAVITY_KEYCHAIN_PREFIX: &str = "go-keyring-base64:";
pub const DEFAULT_CREDENTIAL_FILE_BYTES: usize = 4 * 1024 * 1024;
pub const CODEX_RETRY_MAX_ATTEMPTS: u8 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CredentialReadError {
    pub diagnostic: Diagnostic,
}

impl Display for CredentialReadError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.diagnostic.message)
    }
}

impl std::error::Error for CredentialReadError {}

/// Read-only boundary used by CLI credential import and provider adapters.
/// The production implementation reads files and Keychain; tests inject a fixture source.
pub trait CredentialSource: Send + Sync {
    fn read_file(&self, path: &Path) -> Result<Option<Vec<u8>>, CredentialReadError>;

    fn read_keychain(&self, service: &str) -> Result<Option<String>, CredentialReadError>;

    fn read_keychain_account(
        &self,
        service: &str,
        _account: &str,
    ) -> Result<Option<String>, CredentialReadError> {
        self.read_keychain(service)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct SystemCredentialSource {
    pub max_file_bytes: usize,
}

impl Default for SystemCredentialSource {
    fn default() -> Self {
        Self {
            max_file_bytes: DEFAULT_CREDENTIAL_FILE_BYTES,
        }
    }
}

impl CredentialSource for SystemCredentialSource {
    fn read_file(&self, path: &Path) -> Result<Option<Vec<u8>>, CredentialReadError> {
        let metadata = match std::fs::metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Ok(None),
        };
        if metadata.len() > self.max_file_bytes as u64 {
            return Err(read_error(
                "CREDENTIAL_FILE_TOO_LARGE",
                "凭证文件超过大小上限",
                false,
            ));
        }
        std::fs::read(path)
            .map(Some)
            .map_err(|_| read_error("CREDENTIAL_FILE_READ_FAILED", "凭证文件读取失败", true))
    }

    fn read_keychain(&self, service: &str) -> Result<Option<String>, CredentialReadError> {
        let output = Command::new("/usr/bin/security")
            .args(["find-generic-password", "-s", service, "-w"])
            .output();
        let Ok(output) = output else {
            return Ok(None);
        };
        if !output.status.success() {
            return Ok(None);
        }
        let value = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        Ok((!value.is_empty()).then_some(value))
    }

    fn read_keychain_account(
        &self,
        service: &str,
        account: &str,
    ) -> Result<Option<String>, CredentialReadError> {
        let output = Command::new("/usr/bin/security")
            .args(["find-generic-password", "-s", service, "-a", account, "-w"])
            .output();
        let Ok(output) = output else {
            return Ok(None);
        };
        if !output.status.success() {
            return Ok(None);
        }
        let value = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        Ok((!value.is_empty()).then_some(value))
    }
}

fn read_error(code: &str, message: &str, retryable: bool) -> CredentialReadError {
    CredentialReadError {
        diagnostic: Diagnostic::new(code, "security", "credentials", message, retryable),
    }
}

fn parse_json_bytes(bytes: &[u8]) -> Option<Value> {
    serde_json::from_slice(bytes).ok()
}

fn parse_json_text(text: &str) -> Option<Value> {
    serde_json::from_str(text).ok()
}

/// Match Python's expiry compatibility: seconds, milliseconds, RFC3339 and
/// timezone-less ISO values are accepted; unknown values are not considered expired.
pub fn is_expired(value: Option<&Value>, now_epoch: i64) -> bool {
    let Some(value) = value else {
        return false;
    };
    let Some(timestamp) = (match value {
        Value::Number(number) => number.as_f64(),
        Value::String(text) => text.trim().parse::<f64>().ok().or_else(|| {
            DateTime::parse_from_rfc3339(text)
                .ok()
                .map(|value| value.timestamp() as f64)
                .or_else(|| {
                    NaiveDateTime::parse_from_str(text, "%Y-%m-%dT%H:%M:%S%.f")
                        .ok()
                        .map(|value| value.and_utc().timestamp() as f64)
                })
        }),
        _ => None,
    }) else {
        return false;
    };
    let timestamp = if timestamp > 1_000_000_000_000.0 {
        timestamp / 1_000.0
    } else {
        timestamp
    };
    timestamp < now_epoch as f64
}

fn expires_at<'a>(object: &'a serde_json::Map<String, Value>, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| object.get(*key))
}

fn injected_json(value: &Value) -> Option<Value> {
    match value {
        Value::String(text) if !text.is_empty() => parse_json_text(text),
        Value::Object(_) => Some(value.clone()),
        _ => None,
    }
}

fn claude_token_from_document(
    document: &Value,
    now_epoch: i64,
) -> Result<Option<String>, CredentialReadError> {
    let Some(object) = document.as_object() else {
        return Ok(None);
    };
    let Some(oauth) = object
        .get("claudeAiOauth")
        .or_else(|| object.get("claude.ai_oauth"))
        .and_then(Value::as_object)
    else {
        return Ok(None);
    };
    let Some(token) = oauth
        .get("accessToken")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };
    if is_expired(expires_at(oauth, &["expiresAt", "expires_at"]), now_epoch) {
        return Err(read_error(
            "CREDENTIAL_EXPIRED",
            "Claude OAuth token 已过期, 请重新登录 Claude CLI",
            false,
        ));
    }
    Ok(Some(token.to_owned()))
}

/// Read Claude CLI credentials: App injection, then Keychain, then file fallback.
/// This function never writes either source and never returns token material in errors.
pub fn read_claude_token(
    source: &dyn CredentialSource,
    home: &Path,
    now_epoch: i64,
    injected: Option<&Value>,
) -> Result<Option<String>, CredentialReadError> {
    if let Some(injected) = injected.and_then(injected_json) {
        return claude_token_from_document(&injected, now_epoch);
    }
    if let Some(raw) = source.read_keychain(CLAUDE_KEYCHAIN_SERVICE)? {
        if let Some(document) = parse_json_text(&raw) {
            if let Some(token) = claude_token_from_document(&document, now_epoch)? {
                return Ok(Some(token));
            }
        }
    }
    let path = home.join(".claude").join(".credentials.json");
    let Some(bytes) = source.read_file(&path)? else {
        return Ok(None);
    };
    let Some(document) = parse_json_bytes(&bytes) else {
        return Ok(None);
    };
    claude_token_from_document(&document, now_epoch)
}

fn grok_entry(object: &serde_json::Map<String, Value>) -> Option<&serde_json::Map<String, Value>> {
    let mut legacy = None;
    for (scope, value) in object {
        let Some(entry) = value.as_object() else {
            continue;
        };
        if entry
            .get("key")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .is_none()
        {
            continue;
        }
        if scope.starts_with("https://auth.x.ai::") {
            return Some(entry);
        }
        if scope == "https://accounts.x.ai/sign-in" || scope.contains("/sign-in") {
            legacy = Some(entry);
        }
    }
    legacy
}

fn grok_token_from_document(
    document: &Value,
    now_epoch: i64,
) -> Result<Option<String>, CredentialReadError> {
    let Some(object) = document.as_object() else {
        return Ok(None);
    };
    let Some(entry) = grok_entry(object) else {
        return Ok(None);
    };
    if is_expired(expires_at(entry, &["expires_at", "expiresAt"]), now_epoch) {
        return Err(read_error(
            "CREDENTIAL_EXPIRED",
            "Grok OAuth token 已过期, 请重新 grok login",
            false,
        ));
    }
    Ok(entry
        .get("key")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned))
}

/// Read Grok CLI credentials with OIDC-first and legacy fallback selection.
pub fn read_grok_token(
    source: &dyn CredentialSource,
    home: &Path,
    now_epoch: i64,
    injected: Option<&Value>,
) -> Result<Option<String>, CredentialReadError> {
    if let Some(injected) = injected.and_then(injected_json) {
        if let Some(token) = grok_token_from_document(&injected, now_epoch)? {
            return Ok(Some(token));
        }
    }
    let path = home.join(".grok").join("auth.json");
    let Some(bytes) = source.read_file(&path)? else {
        return Ok(None);
    };
    let Some(document) = parse_json_bytes(&bytes) else {
        return Ok(None);
    };
    grok_token_from_document(&document, now_epoch)
}

/// Read a bounded JSON file for CLI adapters such as Codex and Antigravity.
pub fn read_json_file(
    source: &dyn CredentialSource,
    path: &Path,
) -> Result<Option<Value>, CredentialReadError> {
    Ok(source
        .read_file(path)?
        .and_then(|bytes| parse_json_bytes(&bytes)))
}

pub fn read_codex_auth_file(
    source: &dyn CredentialSource,
    home: &Path,
) -> Result<Option<Value>, CredentialReadError> {
    read_json_file(source, &home.join(".codex").join("auth.json"))
}

pub fn read_kimi_web_tokens_file(
    source: &dyn CredentialSource,
    home: &Path,
) -> Result<Option<Value>, CredentialReadError> {
    read_json_file(
        source,
        &home
            .join(".config")
            .join("kimi-dashboard")
            .join("kimi-web-tokens.json"),
    )
}

fn decode_base64_text(value: &str) -> Option<Vec<u8>> {
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
            b'+' => 62,
            b'/' => 63,
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
    Some(output)
}

/// Read Antigravity OAuth file first and its go-keyring Keychain value second.
/// The Keychain source is read-only and the base64 wrapper is removed in memory.
pub fn read_antigravity_oauth(
    source: &dyn CredentialSource,
    home: &Path,
) -> Result<Option<Value>, CredentialReadError> {
    let file_path = home
        .join(".gemini")
        .join("antigravity-cli")
        .join("antigravity-oauth-token");
    if let Some(value) = read_json_file(source, &file_path)? {
        return Ok(Some(value));
    }
    let Some(raw) =
        source.read_keychain_account(ANTIGRAVITY_KEYCHAIN_SERVICE, ANTIGRAVITY_KEYCHAIN_ACCOUNT)?
    else {
        return Ok(None);
    };
    let encoded = raw
        .strip_prefix(ANTIGRAVITY_KEYCHAIN_PREFIX)
        .unwrap_or(raw.as_str());
    let decoded = decode_base64_text(encoded)
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .and_then(|text| parse_json_text(&text));
    Ok(decoded)
}

pub struct AccountRefreshCoordinator<K, V, E> {
    inner: AccountSingleFlight<K, V, E>,
}

impl<K, V, E> Default for AccountRefreshCoordinator<K, V, E> {
    fn default() -> Self {
        Self {
            inner: AccountSingleFlight::default(),
        }
    }
}

impl<K, V, E> AccountRefreshCoordinator<K, V, E>
where
    K: Eq + std::hash::Hash + Clone,
    V: Send + Sync + 'static,
    E: Clone + Send + Sync + 'static,
{
    pub fn run<F>(
        &self,
        account_id: K,
        cancellation: &CancellationToken,
        refresh: F,
    ) -> Result<std::sync::Arc<V>, SingleFlightError<E>>
    where
        F: FnOnce() -> Result<V, E>,
    {
        self.inner.run(account_id, cancellation, refresh)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CredentialValidationError {
    pub diagnostic: Diagnostic,
}

impl Display for CredentialValidationError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.diagnostic.message)
    }
}

impl std::error::Error for CredentialValidationError {}

/// Validate and clone Bridge `credentialUpdates` without exposing secret data
/// in diagnostics. Swift remains the only Keychain writer.
pub fn validate_credential_updates(
    updates: &Value,
) -> Result<Vec<Value>, CredentialValidationError> {
    let values = updates.as_array().ok_or_else(|| {
        error(
            "BRIDGE_INVALID_CREDENTIAL_UPDATE",
            "credentialUpdates 必须是数组",
        )
    })?;
    let mut validated = Vec::with_capacity(values.len());
    for update in values {
        let object = update.as_object().ok_or_else(|| {
            error(
                "BRIDGE_INVALID_CREDENTIAL_UPDATE",
                "credentialUpdate 必须是 JSON object",
            )
        })?;
        require_exact_fields(
            object,
            &["provider", "accountId", "kind", "operation", "credentials"],
            "credentialUpdate",
        )?;
        let provider = object
            .get("provider")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                error(
                    "BRIDGE_INVALID_CREDENTIAL_UPDATE",
                    "credentialUpdate provider 不受支持",
                )
            })?;
        if !matches!(provider, "kimi" | "antigravity") {
            return Err(error(
                "BRIDGE_INVALID_CREDENTIAL_UPDATE",
                "credentialUpdate provider 不受支持",
            ));
        }
        let account_id = object
            .get("accountId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                error(
                    "BRIDGE_INVALID_CREDENTIAL_UPDATE",
                    "credentialUpdate 元数据无效",
                )
            })?;
        let kind = object.get("kind").and_then(Value::as_str);
        let operation = object.get("operation").and_then(Value::as_str);
        if account_id.is_empty()
            || account_id.len() > UPDATE_ACCOUNT_ID_MAX
            || kind != Some("oauthTokens")
            || operation != Some("replace")
        {
            return Err(error(
                "BRIDGE_INVALID_CREDENTIAL_UPDATE",
                "credentialUpdate 元数据无效",
            ));
        }
        let credentials = object
            .get("credentials")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                error(
                    "BRIDGE_INVALID_CREDENTIAL_UPDATE",
                    "credentialUpdate 凭证字段无效",
                )
            })?;
        if credentials.is_empty()
            || credentials.keys().any(|key| {
                !UPDATE_CREDENTIAL_FIELDS
                    .iter()
                    .any(|allowed| *allowed == key)
            })
            || credentials.values().any(|value| !value.is_string())
        {
            return Err(error(
                "BRIDGE_INVALID_CREDENTIAL_UPDATE",
                "credentialUpdate 凭证字段无效",
            ));
        }
        validated.push(update.clone());
    }
    Ok(validated)
}

/// Validate and clone Bridge `credentialChallenges` using the frozen v1
/// allowlist. Challenge values never contain token material.
pub fn validate_credential_challenges(
    challenges: &Value,
) -> Result<Vec<Value>, CredentialValidationError> {
    let values = challenges.as_array().ok_or_else(|| {
        error(
            "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
            "credentialChallenges 必须是数组",
        )
    })?;
    let mut validated = Vec::with_capacity(values.len());
    for challenge in values {
        let object = challenge.as_object().ok_or_else(|| {
            error(
                "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
                "credentialChallenge 字段无效",
            )
        })?;
        require_exact_fields(
            object,
            &["provider", "accountId", "reason"],
            "credentialChallenge",
        )
        .map_err(|_| {
            error(
                "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
                "credentialChallenge 字段无效",
            )
        })?;
        if object.get("provider").and_then(Value::as_str) != Some("codex") {
            return Err(error(
                "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
                "credentialChallenge provider 不受支持",
            ));
        }
        if object.get("reason").and_then(Value::as_str) != Some("accessRejected") {
            return Err(error(
                "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
                "credentialChallenge reason 不受支持",
            ));
        }
        let account_id = object.get("accountId").and_then(Value::as_str);
        if account_id.is_none()
            || account_id.is_some_and(|value| {
                value.is_empty() || value.len() > CREDENTIAL_CHALLENGE_ACCOUNT_ID_MAX
            })
        {
            return Err(error(
                "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
                "credentialChallenge accountId 无效",
            ));
        }
        validated.push(challenge.clone());
    }
    Ok(validated)
}

/// Build the one-shot Codex retry-only account list in the original account
/// order. Unknown challenge accounts are ignored and duplicate challenges do
/// not create another retry phase.
pub fn plan_codex_retry_only(
    account_order: &[String],
    challenges: &Value,
) -> Result<Option<Vec<String>>, CredentialValidationError> {
    let challenges = validate_credential_challenges(challenges)?;
    let challenged = challenges
        .iter()
        .filter_map(|challenge| challenge.get("accountId").and_then(Value::as_str))
        .collect::<BTreeSet<_>>();
    let mut seen = BTreeSet::new();
    let retry_accounts = account_order
        .iter()
        .filter(|account_id| challenged.contains(account_id.as_str()) && seen.insert(*account_id))
        .cloned()
        .collect::<Vec<_>>();
    Ok((!retry_accounts.is_empty()).then_some(retry_accounts))
}

fn require_exact_fields(
    object: &serde_json::Map<String, Value>,
    required: &[&str],
    label: &str,
) -> Result<(), CredentialValidationError> {
    let required = required.iter().copied().collect::<BTreeSet<_>>();
    let actual = object.keys().map(String::as_str).collect::<BTreeSet<_>>();
    if actual != required {
        return Err(error(
            "BRIDGE_INVALID_CREDENTIAL_UPDATE",
            &format!("{label} 字段无效"),
        ));
    }
    Ok(())
}

fn error(code: &str, message: &str) -> CredentialValidationError {
    CredentialValidationError {
        diagnostic: Diagnostic::new(code, "security", "credentials", message, false),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        is_expired, plan_codex_retry_only, read_antigravity_oauth, read_claude_token,
        read_codex_auth_file, read_grok_token, read_json_file, read_kimi_web_tokens_file,
        validate_credential_challenges, validate_credential_updates, AccountRefreshCoordinator,
        CredentialReadError, CredentialSource, ANTIGRAVITY_KEYCHAIN_ACCOUNT,
        ANTIGRAVITY_KEYCHAIN_SERVICE, CODEX_RETRY_MAX_ATTEMPTS,
    };
    use collector_runtime::CancellationToken;
    use serde_json::json;
    use std::collections::BTreeMap;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Barrier};
    use std::thread;
    use std::time::Duration;

    #[derive(Default)]
    struct FixtureSource {
        files: BTreeMap<PathBuf, Vec<u8>>,
        keychain: BTreeMap<String, String>,
        account_keychain: BTreeMap<(String, String), String>,
    }

    impl CredentialSource for FixtureSource {
        fn read_file(&self, path: &Path) -> Result<Option<Vec<u8>>, CredentialReadError> {
            Ok(self.files.get(path).cloned())
        }

        fn read_keychain(&self, service: &str) -> Result<Option<String>, CredentialReadError> {
            Ok(self.keychain.get(service).cloned())
        }

        fn read_keychain_account(
            &self,
            service: &str,
            account: &str,
        ) -> Result<Option<String>, CredentialReadError> {
            Ok(self
                .account_keychain
                .get(&(service.to_owned(), account.to_owned()))
                .cloned())
        }
    }

    #[test]
    fn accepts_only_frozen_rotation_update_shape() {
        let update = json!([{
            "provider": "kimi",
            "accountId": "account-a",
            "kind": "oauthTokens",
            "operation": "replace",
            "credentials": {"access_token": "redacted", "expiry": "2030-01-01T00:00:00Z"}
        }]);
        assert_eq!(
            validate_credential_updates(&update).unwrap(),
            update.as_array().unwrap().to_vec()
        );
        let invalid = json!([{
            "provider": "kimi",
            "accountId": "account-a",
            "kind": "oauthTokens",
            "operation": "replace",
            "credentials": {"secret": "must-not-pass"}
        }]);
        assert_eq!(
            validate_credential_updates(&invalid)
                .unwrap_err()
                .diagnostic
                .code,
            "BRIDGE_INVALID_CREDENTIAL_UPDATE"
        );
        assert!(!validate_credential_updates(&invalid)
            .unwrap_err()
            .diagnostic
            .message
            .contains("must-not-pass"));
    }

    #[test]
    fn validates_codex_access_rejected_challenge() {
        let challenge = json!([{
            "provider": "codex",
            "accountId": "account-a",
            "reason": "accessRejected"
        }]);
        assert_eq!(
            validate_credential_challenges(&challenge).unwrap(),
            challenge.as_array().unwrap().to_vec()
        );
        let invalid = json!([{
            "provider": "codex",
            "accountId": "account-a",
            "reason": "expired"
        }]);
        assert!(validate_credential_challenges(&invalid).is_err());
    }

    #[test]
    fn expiry_accepts_seconds_milliseconds_and_iso_without_guessing_unknown_values() {
        assert!(is_expired(Some(&json!(1_700_000_000i64)), 1_800_000_000));
        assert!(is_expired(
            Some(&json!(1_700_000_000_000i64)),
            1_800_000_000
        ));
        assert!(is_expired(
            Some(&json!("2026-08-20T00:00:00Z")),
            1_800_000_000
        ));
        assert!(!is_expired(Some(&json!("not-a-date")), 1_800_000_000));
        assert!(!is_expired(None, 1_800_000_000));
    }

    #[test]
    fn claude_reader_prefers_keychain_then_file_and_rejects_expired_injection() {
        let home = PathBuf::from("/fixture-home");
        let mut source = FixtureSource::default();
        source.keychain.insert(
            "Claude Code-credentials".to_owned(),
            r#"{"claudeAiOauth":{"accessToken":"keychain-token","expiresAt":1893456000}}"#
                .to_owned(),
        );
        source.files.insert(
            home.join(".claude/.credentials.json"),
            br#"{"claudeAiOauth":{"accessToken":"file-token"}}"#.to_vec(),
        );
        assert_eq!(
            read_claude_token(&source, &home, 1_800_000_000, None)
                .unwrap()
                .as_deref(),
            Some("keychain-token")
        );
        let expired = json!({
            "claudeAiOauth": {"accessToken": "injected-token", "expiresAt": 1}
        });
        let error = read_claude_token(&source, &home, 1_800_000_000, Some(&expired)).unwrap_err();
        assert_eq!(error.diagnostic.code, "CREDENTIAL_EXPIRED");
        assert!(!error.diagnostic.message.contains("injected-token"));

        let empty_keychain = FixtureSource {
            files: source.files.clone(),
            ..FixtureSource::default()
        };
        assert_eq!(
            read_claude_token(&empty_keychain, &home, 1_800_000_000, None)
                .unwrap()
                .as_deref(),
            Some("file-token")
        );
    }

    #[test]
    fn grok_reader_prefers_oidc_and_falls_back_to_legacy_file_entry() {
        let home = PathBuf::from("/fixture-home");
        let mut source = FixtureSource::default();
        source.files.insert(
            home.join(".grok/auth.json"),
            br#"{
                "https://accounts.x.ai/sign-in":{"key":"legacy-token"},
                "https://auth.x.ai::scope":{"key":"oidc-token"}
            }"#
            .to_vec(),
        );
        let injected = json!({"https://auth.x.ai::scope":{"key":"injected-oidc"}});
        assert_eq!(
            read_grok_token(&source, &home, 1_800_000_000, Some(&injected))
                .unwrap()
                .as_deref(),
            Some("injected-oidc")
        );
        assert_eq!(
            read_grok_token(&source, &home, 1_800_000_000, None)
                .unwrap()
                .as_deref(),
            Some("oidc-token")
        );
    }

    #[test]
    fn json_file_reader_is_read_only_and_ignores_malformed_content() {
        let path = PathBuf::from("/fixture/codex-auth.json");
        let mut source = FixtureSource::default();
        source
            .files
            .insert(path.clone(), br#"{"tokens":[]}"#.to_vec());
        assert_eq!(
            read_json_file(&source, &path).unwrap(),
            Some(json!({"tokens": []}))
        );
        source.files.insert(path.clone(), b"not-json".to_vec());
        assert_eq!(read_json_file(&source, &path).unwrap(), None);
    }

    #[test]
    fn cli_paths_and_antigravity_keychain_fallback_are_explicit() {
        let home = PathBuf::from("/fixture-home");
        let mut source = FixtureSource::default();
        source.files.insert(
            home.join(".codex/auth.json"),
            br#"{"tokens":{"access_token":"codex-fixture"}}"#.to_vec(),
        );
        source.files.insert(
            home.join(".config/kimi-dashboard/kimi-web-tokens.json"),
            br#"{"access_token":"kimi-fixture"}"#.to_vec(),
        );
        assert!(read_codex_auth_file(&source, &home).unwrap().is_some());
        assert!(read_kimi_web_tokens_file(&source, &home).unwrap().is_some());

        source.account_keychain.insert(
            (
                ANTIGRAVITY_KEYCHAIN_SERVICE.to_owned(),
                ANTIGRAVITY_KEYCHAIN_ACCOUNT.to_owned(),
            ),
            "go-keyring-base64:eyJ0b2tlbiI6eyJhY2Nlc3NfdG9rZW4iOiJhZ3ktdG9rZW4ifX0=".to_owned(),
        );
        let oauth = read_antigravity_oauth(&source, &home).unwrap().unwrap();
        assert_eq!(oauth["token"]["access_token"], "agy-token");
    }

    #[test]
    fn account_refresh_coordinator_runs_once_for_same_account() {
        let coordinator: Arc<AccountRefreshCoordinator<String, u32, String>> =
            Arc::new(AccountRefreshCoordinator::default());
        let calls = Arc::new(AtomicUsize::new(0));
        let barrier = Arc::new(Barrier::new(2));
        let mut handles = Vec::new();
        for _ in 0..2 {
            let coordinator = Arc::clone(&coordinator);
            let calls = Arc::clone(&calls);
            let barrier = Arc::clone(&barrier);
            handles.push(thread::spawn(move || {
                barrier.wait();
                coordinator
                    .run("account-a".to_owned(), &CancellationToken::new(), || {
                        calls.fetch_add(1, Ordering::SeqCst);
                        thread::sleep(Duration::from_millis(10));
                        Ok(42)
                    })
                    .unwrap()
            }));
        }
        let values = handles
            .into_iter()
            .map(|handle| *handle.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(values, vec![42, 42]);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn codex_retry_plan_is_ordered_deduplicated_and_one_shot() {
        let order = vec![
            "account-c".to_owned(),
            "account-a".to_owned(),
            "account-b".to_owned(),
        ];
        let challenges = json!([
            {"provider":"codex","accountId":"account-b","reason":"accessRejected"},
            {"provider":"codex","accountId":"account-a","reason":"accessRejected"},
            {"provider":"codex","accountId":"account-b","reason":"accessRejected"}
        ]);
        assert_eq!(
            plan_codex_retry_only(&order, &challenges).unwrap(),
            Some(vec!["account-a".to_owned(), "account-b".to_owned()])
        );
        assert_eq!(CODEX_RETRY_MAX_ATTEMPTS, 1);
        assert_eq!(
            plan_codex_retry_only(
                &order,
                &json!([{"provider":"codex","accountId":"unknown","reason":"accessRejected"}])
            )
            .unwrap(),
            None
        );
    }
}
