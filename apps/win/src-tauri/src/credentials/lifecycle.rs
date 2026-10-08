//! Credential write-back/recovery. Neither transport errors nor diagnostics contain response bodies.
use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use collector_domain::{BridgeResponse, Diagnostic, ResponseStatus};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexRefreshError {
    InvalidGrant,
    RateLimited,
    Transient,
    InvalidResponse,
}
fn diagnostic(response: &mut BridgeResponse, code: &str, retryable: bool) {
    response.diagnostics.push(Diagnostic::new(
        code,
        "security",
        "credentials",
        code,
        retryable,
    ));
    if response.status == ResponseStatus::Success {
        response.status = ResponseStatus::Partial;
    }
}

pub fn collect_with_recovery(
    root: &Path,
    credentials: CredentialPayloads,
    collect: impl FnMut(CredentialPayloads) -> Result<BridgeResponse, String>,
) -> Result<BridgeResponse, String> {
    collect_with_recovery_using(root, credentials, collect, refresh_codex)
}

/// Tests inject both the collector and OAuth transport; production performs at most one retry.
pub fn collect_with_recovery_using(
    root: &Path,
    initial: CredentialPayloads,
    mut collect: impl FnMut(CredentialPayloads) -> Result<BridgeResponse, String>,
    mut refresh: impl FnMut(&Value) -> Result<Value, CodexRefreshError>,
) -> Result<BridgeResponse, String> {
    let mut first = collect(initial.clone())?;
    apply_updates(root, &initial, &mut first)?;
    let challenges =
        collector_credential::validate_credential_challenges(&json!(first.credential_challenges))
            .map_err(|_| "CREDENTIAL_CHALLENGE_INVALID")?;
    first.credential_challenges.clear();
    let mut refreshed = serde_json::Map::new();
    let mut seen = std::collections::BTreeSet::new();
    for challenge in challenges {
        let id = challenge["accountId"].as_str().unwrap();
        if !seen.insert(id.to_owned()) {
            continue;
        }
        let Some(expected) = initial.get("codexQuotaAccounts").and_then(|v| v.get(id)) else {
            continue;
        };
        // A removed or manually replaced account must never be recreated by an in-flight request.
        let current = load_credentials(root);
        if current.get("codexQuotaAccounts").and_then(|v| v.get(id)) != Some(expected) {
            continue;
        }
        let result = if nonempty_string(expected.get("refresh_token")) {
            refresh(expected)
        } else {
            Err(CodexRefreshError::InvalidGrant)
        };
        match result {
            Ok(tokens) => {
                let Some(fields) = tokens.as_object() else {
                    diagnostic(&mut first, "CREDENTIAL_REFRESH_INVALID", false);
                    continue;
                };
                if !nonempty_string(fields.get("access_token"))
                    || fields.keys().any(|k| {
                        !["access_token", "refresh_token", "id_token", "expiry"]
                            .contains(&k.as_str())
                    })
                    || fields.values().any(|v| !v.is_string())
                    || !identity_matches(id, &tokens)
                {
                    diagnostic(&mut first, "CREDENTIAL_REFRESH_INVALID", false);
                    continue;
                }
                let mut updated = expected.clone();
                for (key, value) in fields {
                    updated[key] = value.clone();
                }
                updated["authorization_state"] = json!("connected");
                if compare_and_replace(root, "codexQuotaAccounts", id, expected, &updated)? {
                    refreshed.insert(id.to_owned(), updated);
                }
            }
            Err(CodexRefreshError::InvalidGrant) => {
                let mut updated = expected.clone();
                updated["authorization_state"] = json!("reauthRequired");
                compare_and_replace(root, "codexQuotaAccounts", id, expected, &updated)?;
                diagnostic(&mut first, "CREDENTIAL_REAUTH_REQUIRED", false);
            }
            Err(CodexRefreshError::RateLimited) => {
                diagnostic(&mut first, "PROVIDER_RATE_LIMIT", true)
            }
            Err(CodexRefreshError::Transient) => {
                diagnostic(&mut first, "CREDENTIAL_REFRESH_UNAVAILABLE", true)
            }
            Err(CodexRefreshError::InvalidResponse) => {
                diagnostic(&mut first, "CREDENTIAL_REFRESH_INVALID", false)
            }
        }
    }
    if refreshed.is_empty() {
        return Ok(first);
    }
    let retry_payload = CredentialPayloads::from([(
        "codexQuotaAccounts".into(),
        Value::Object(refreshed.clone()),
    )]);
    let mut retry = match collect(retry_payload.clone()) {
        Ok(r) => r,
        Err(_) => {
            diagnostic(&mut first, "CREDENTIAL_RETRY_FAILED", true);
            return Ok(first);
        }
    };
    apply_updates(root, &retry_payload, &mut retry)?;
    let challenges =
        collector_credential::validate_credential_challenges(&json!(retry.credential_challenges))
            .map_err(|_| "CREDENTIAL_CHALLENGE_INVALID")?;
    for challenge in challenges {
        let id = challenge["accountId"].as_str().unwrap();
        if let Some(expected) = refreshed.get(id) {
            let mut updated = expected.clone();
            updated["authorization_state"] = json!("reauthRequired");
            compare_and_replace(root, "codexQuotaAccounts", id, expected, &updated)?;
            diagnostic(&mut retry, "CREDENTIAL_REAUTH_REQUIRED", false);
        }
    }
    // Retry-only artifacts contain no local usage: replace matching Codex services only.
    let mut merged_retry = false;
    if let Some(services) = retry
        .artifact
        .as_ref()
        .and_then(|a| a.get("services"))
        .and_then(Value::as_array)
    {
        if let Some(current) = first
            .artifact
            .as_mut()
            .and_then(|a| a.get_mut("services"))
            .and_then(Value::as_array_mut)
        {
            for service in services {
                if !refreshed
                    .keys()
                    .any(|id| service["id"] == collector_provider::codex_service_id(id))
                {
                    continue;
                }
                if let Some(existing) = current
                    .iter_mut()
                    .find(|v| v.get("id") == service.get("id"))
                {
                    *existing = service.clone();
                    merged_retry = true;
                }
            }
        }
    }
    first.diagnostics.extend(retry.diagnostics);
    if merged_retry && retry.status == ResponseStatus::Success {
        let has_failed_entries = first.artifact.as_ref().is_some_and(|artifact| {
            ["agents", "services"].iter().any(|key| {
                artifact
                    .get(*key)
                    .and_then(Value::as_array)
                    .is_some_and(|entries| {
                        entries.iter().any(|entry| {
                            matches!(entry["status"].as_str(), Some("error" | "partial"))
                        })
                    })
            })
        });
        // Match mac ArtifactFinalizer: successful self-healing does not retain
        // obsolete provider failures. Keep security/store diagnostics intact.
        if !has_failed_entries {
            first.diagnostics.retain(|d| d.category != "provider");
            first.status = if first.diagnostics.is_empty() {
                ResponseStatus::Success
            } else {
                ResponseStatus::Partial
            };
        }
    }
    Ok(first)
}

fn compare_and_replace(
    root: &Path,
    field: &str,
    id: &str,
    expected: &Value,
    updated: &Value,
) -> Result<bool, String> {
    let _guard = STORE_LOCK
        .lock()
        .map_err(|_| "CREDENTIAL_STORE_LOCK_FAILED")?;
    let mut latest = load_credentials(root);
    if latest.get(field).and_then(|v| v.get(id)) != Some(expected) {
        return Ok(false);
    }
    latest.get_mut(field).unwrap()[id] = updated.clone();
    save_unlocked(root, &latest)?;
    Ok(true)
}
fn apply_updates(
    root: &Path,
    expected: &CredentialPayloads,
    response: &mut BridgeResponse,
) -> Result<(), String> {
    let updates =
        collector_credential::validate_credential_updates(&json!(response.credential_updates))
            .map_err(|_| "CREDENTIAL_UPDATE_INVALID")?;
    response.credential_updates.clear();
    for update in updates {
        // Kimi API keys do not rotate (same rule as mac CredentialRotationMerge).
        if update["provider"] != "stepfun" {
            diagnostic(response, "CREDENTIAL_UPDATE_UNSUPPORTED", false);
            continue;
        }
        let id = update["accountId"].as_str().unwrap();
        let Some(old) = expected.get("stepfunQuotaAccounts").and_then(|v| v.get(id)) else {
            continue;
        };
        let Some(token) = update["credentials"]
            .get("access_token")
            .or_else(|| update["credentials"].get("refresh_token"))
            .filter(|v| nonempty_string(Some(v)))
        else {
            continue;
        };
        let mut updated = old.clone();
        updated["token"] = token.clone();
        compare_and_replace(root, "stepfunQuotaAccounts", id, old, &updated)?;
    }
    Ok(())
}
fn identity_matches(id: &str, tokens: &Value) -> bool {
    for key in ["access_token", "id_token"] {
        let Some(token) = tokens.get(key).and_then(Value::as_str) else {
            continue;
        };
        let Some(payload) = token.split('.').nth(1) else {
            continue;
        };
        if payload.len() > 32_768 {
            return false;
        }
        if let Ok(bytes) = URL_SAFE_NO_PAD.decode(payload) {
            if let Ok(claims) = serde_json::from_slice::<Value>(&bytes) {
                if let Some(actual) = claims
                    .get("https://api.openai.com/auth")
                    .and_then(|auth| auth.get("chatgpt_account_id"))
                    .and_then(Value::as_str)
                {
                    if actual != id {
                        return false;
                    }
                }
            }
        }
    }
    true
}
fn refresh_codex(account: &Value) -> Result<Value, CodexRefreshError> {
    use std::io::Read;
    let token = account
        .get("refresh_token")
        .and_then(Value::as_str)
        .ok_or(CodexRefreshError::InvalidGrant)?;
    // Same public client/end point as the mac App; redirect disabled to avoid disclosing the refresh token.
    let agent = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(30))
        .redirects(0)
        .build();
    let response = agent
        .post("https://auth.openai.com/oauth/token")
        .send_form(&[
            ("grant_type", "refresh_token"),
            ("client_id", "app_EMoamEEZ73f0CkXaXp7hrann"),
            ("refresh_token", token),
        ]);
    let response = match response {
        Ok(r) => r,
        Err(ureq::Error::Status(code, response)) => {
            if code == 429 {
                return Err(CodexRefreshError::RateLimited);
            }
            if code == 401 || code == 403 {
                return Err(CodexRefreshError::InvalidGrant);
            }
            if code >= 500 {
                return Err(CodexRefreshError::Transient);
            }
            let mut body = Vec::new();
            let _ = response.into_reader().take(65_537).read_to_end(&mut body);
            let error = serde_json::from_slice::<Value>(&body).ok();
            return Err(
                if error
                    .as_ref()
                    .and_then(|v| v.get("error"))
                    .and_then(Value::as_str)
                    == Some("invalid_grant")
                {
                    CodexRefreshError::InvalidGrant
                } else {
                    CodexRefreshError::InvalidResponse
                },
            );
        }
        Err(_) => return Err(CodexRefreshError::Transient),
    };
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(65_537)
        .read_to_end(&mut bytes)
        .map_err(|_| CodexRefreshError::Transient)?;
    if bytes.len() > 65_536 {
        return Err(CodexRefreshError::InvalidResponse);
    }
    let body: Value =
        serde_json::from_slice(&bytes).map_err(|_| CodexRefreshError::InvalidResponse)?;
    if !nonempty_string(body.get("access_token")) {
        return Err(CodexRefreshError::InvalidResponse);
    }
    let mut result = serde_json::Map::new();
    for key in ["access_token", "refresh_token", "id_token"] {
        if let Some(value) = body.get(key).filter(|v| nonempty_string(Some(v))) {
            result.insert(key.into(), value.clone());
        }
    }
    let seconds = body
        .get("expires_in")
        .and_then(Value::as_i64)
        .filter(|n| *n > 0 && *n <= 2_592_000)
        .unwrap_or(3600);
    result.insert(
        "expiry".into(),
        json!((chrono::Utc::now() + chrono::Duration::seconds(seconds)).to_rfc3339()),
    );
    Ok(Value::Object(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    use collector_domain::ResponseStatus;
    fn root() -> PathBuf {
        std::env::temp_dir().join(format!("c009-recovery-{}", uuid::Uuid::new_v4()))
    }
    fn response() -> BridgeResponse {
        BridgeResponse {
            schema_version: 1,
            run_id: "fixture".into(),
            generated_at: "2026-10-08T00:00:00Z".into(),
            status: ResponseStatus::Partial,
            artifact: Some(json!({})),
            credential_updates: vec![],
            credential_challenges: vec![],
            diagnostics: vec![],
        }
    }
    fn stored() -> CredentialPayloads {
        serde_json::from_value(json!({"codexQuotaAccounts":{"a":{"display_name":"A","access_token":"old-fixture","refresh_token":"refresh-fixture"}},"stepfunQuotaAccounts":{"s":{"token":"old-step-fixture"}}})).unwrap()
    }
    #[test]
    fn rotation_is_persisted_without_deleting_other_accounts() {
        let root = root();
        let creds = stored();
        save_credentials(&root, &creds).unwrap();
        let result=collect_with_recovery_using(&root,creds, |_| {let mut r=response();r.credential_updates.push(json!({"provider":"stepfun","accountId":"s","kind":"oauthTokens","operation":"replace","credentials":{"access_token":"new-step-fixture"}}));Ok(r)}, |_|panic!("no codex challenge")).unwrap();
        assert_eq!(
            load_credentials(&root)["stepfunQuotaAccounts"]["s"]["token"],
            "new-step-fixture"
        );
        assert!(load_credentials(&root).contains_key("codexQuotaAccounts"));
        assert!(result.credential_updates.is_empty());
    }
    #[test]
    fn challenge_refreshes_once_persists_then_retries_once() {
        let root = root();
        let creds = stored();
        save_credentials(&root, &creds).unwrap();
        let mut calls = 0;
        let mut refreshes = 0;
        let result = collect_with_recovery_using(
            &root,
            creds,
            |payload| {
                calls += 1;
                let mut r = response();
                if calls == 2 {
                    assert_eq!(
                        payload["codexQuotaAccounts"]["a"]["access_token"],
                        "new-fixture"
                    );
                }
                r.credential_challenges
                    .push(json!({"provider":"codex","accountId":"a","reason":"accessRejected"}));
                Ok(r)
            },
            |_| {
                refreshes += 1;
                Ok(json!({"access_token":"new-fixture"}))
            },
        )
        .unwrap();
        assert_eq!((calls, refreshes), (2, 1));
        assert_eq!(
            load_credentials(&root)["codexQuotaAccounts"]["a"]["refresh_token"],
            "refresh-fixture"
        );
        assert!(result.credential_challenges.is_empty());
    }
    #[test]
    fn concurrent_user_replacement_wins_over_inflight_refresh() {
        let root = root();
        let creds = stored();
        save_credentials(&root, &creds).unwrap();
        let mut calls = 0;
        collect_with_recovery_using(&root,creds, |_|{calls+=1;let mut r=response();r.credential_challenges.push(json!({"provider":"codex","accountId":"a","reason":"accessRejected"}));Ok(r)}, |_| {save_credential_account(&root,"codexQuotaAccounts","a",&json!({"display_name":"new user","access_token":"user-fixture","refresh_token":"user-refresh"})).unwrap();Ok(json!({"access_token":"late-fixture"}))}).unwrap();
        assert_eq!(
            load_credentials(&root)["codexQuotaAccounts"]["a"]["access_token"],
            "user-fixture"
        );
        assert_eq!(calls, 1);
    }
    #[test]
    fn invalid_grant_requires_reauth_and_has_no_secret_diagnostic() {
        let root = root();
        let creds = stored();
        save_credentials(&root, &creds).unwrap();
        let r = collect_with_recovery_using(
            &root,
            creds,
            |_| {
                let mut r = response();
                r.credential_challenges
                    .push(json!({"provider":"codex","accountId":"a","reason":"accessRejected"}));
                Ok(r)
            },
            |_| Err(CodexRefreshError::InvalidGrant),
        )
        .unwrap();
        assert_eq!(
            load_credentials(&root)["codexQuotaAccounts"]["a"]["authorization_state"],
            "reauthRequired"
        );
        assert!(r
            .diagnostics
            .iter()
            .any(|d| d.code == "CREDENTIAL_REAUTH_REQUIRED"));
        assert!(!serde_json::to_string(&r)
            .unwrap()
            .contains("refresh-fixture"));
    }

    #[test]
    fn refreshed_tokens_cannot_switch_account_identity() {
        let root = root();
        let creds = stored();
        save_credentials(&root, &creds).unwrap();
        let claims = URL_SAFE_NO_PAD.encode(
            br#"{"https://api.openai.com/auth":{"chatgpt_account_id":"different-account"}}"#,
        );
        let mut calls = 0;
        let result = collect_with_recovery_using(
            &root,
            creds,
            |_| {
                calls += 1;
                let mut r = response();
                r.credential_challenges
                    .push(json!({"provider":"codex","accountId":"a","reason":"accessRejected"}));
                Ok(r)
            },
            |_| Ok(json!({"access_token": format!("fixture.{claims}.fixture")})),
        )
        .unwrap();
        assert_eq!(calls, 1, "identity mismatch must not trigger a retry");
        assert_eq!(
            load_credentials(&root)["codexQuotaAccounts"]["a"]["access_token"],
            "old-fixture"
        );
        assert!(result
            .diagnostics
            .iter()
            .any(|d| d.code == "CREDENTIAL_REFRESH_INVALID"));
    }

    #[test]
    fn successful_recovery_finalizes_status_without_losing_local_usage_or_other_failures() {
        for other_failed in [false, true] {
            let root = root();
            let creds = stored();
            save_credentials(&root, &creds).unwrap();
            let service_id = collector_provider::codex_service_id("a");
            let mut calls = 0;
            let result = collect_with_recovery_using(
                &root,
                creds,
                |_| {
                    calls += 1;
                    let mut r = response();
                    r.artifact = Some(
                        json!({"agents": [{"id":"local-fixture", "status":"ok"}], "services": [
                            {"id":service_id,"status":if calls == 1 {"error"} else {"ok"}},
                            {"id":"other","status":if other_failed {"error"} else {"ok"}}
                        ]}),
                    );
                    if calls == 1 {
                        r.diagnostics.push(Diagnostic::new(
                            "PROVIDER_AUTH_REJECTED",
                            "provider",
                            "quota",
                            "fixture",
                            false,
                        ));
                        r.credential_challenges.push(
                            json!({"provider":"codex","accountId":"a","reason":"accessRejected"}),
                        );
                    } else {
                        r.status = ResponseStatus::Success;
                        r.artifact.as_mut().unwrap()["agents"] = json!([]);
                    }
                    Ok(r)
                },
                |_| Ok(json!({"access_token":"new-fixture"})),
            )
            .unwrap();
            assert_eq!(
                result.artifact.as_ref().unwrap()["agents"][0]["id"],
                "local-fixture"
            );
            assert_eq!(
                result.status,
                if other_failed {
                    ResponseStatus::Partial
                } else {
                    ResponseStatus::Success
                }
            );
            assert_eq!(result.diagnostics.is_empty(), !other_failed);
        }
    }
}
