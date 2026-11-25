#![deny(unsafe_code)]

//! Bridge credential validation (updates / challenges). Host Keychain reads remain an App concern.

use collector_domain::Diagnostic;
use serde_json::Value;
use std::collections::BTreeSet;
use std::fmt::{self, Display, Formatter};

pub const CREDENTIAL_CHALLENGE_ACCOUNT_ID_MAX: usize = 256;
pub const UPDATE_ACCOUNT_ID_MAX: usize = 256;

const UPDATE_CREDENTIAL_FIELDS: &[&str] = &["access_token", "expiry", "id_token", "refresh_token"];

pub const CLAUDE_KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
pub const DEFAULT_CREDENTIAL_FILE_BYTES: usize = 4 * 1024 * 1024;

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
        if provider != "kimi" && provider != "stepfun" && provider != "claude" {
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
    use super::{validate_credential_challenges, validate_credential_updates};
    use serde_json::json;

    #[test]
    fn accepts_only_frozen_rotation_update_shape() {
        let update = json!([{
            "provider": "kimi",
            "accountId": "account-a",
            "kind": "oauthTokens",
            "operation": "replace",
            "credentials": {"access_token": "redacted", "expiry": "2030-01-01T00:00:00Z"}
        }, {
            "provider": "stepfun",
            "accountId": "account-b",
            "kind": "oauthTokens",
            "operation": "replace",
            "credentials": {"access_token": "redacted"}
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
}
