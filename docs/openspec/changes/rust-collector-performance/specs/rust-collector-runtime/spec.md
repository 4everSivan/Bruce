## ADDED Requirements

### Requirement: Rust collector uses the Bridge v1 process seam

The production collector SHALL be a signed Rust executable that reads one Bridge v1 JSON request from stdin and writes one Bridge v1 JSON response envelope to stdout. The Swift runner SHALL retain run ID validation, timeout, cancellation, stderr limits, and process termination behavior.

#### Scenario: Rust request produces one valid response

- **WHEN** the runner sends a valid Bridge v1 request and closes stdin
- **THEN** the Rust executable returns exactly one response envelope with the same `runId`, a valid schema, and no diagnostic text on stdout

#### Scenario: Invalid request fails closed

- **WHEN** the Rust executable receives an unknown schema, missing required field, malformed JSON, or an input over the configured limit
- **THEN** it returns a structured protocol error, does not collect data, and does not print credentials or raw input to stdout/stderr

### Requirement: Rust runtime selection is explicit

Preview and Release SHALL select an explicit `RustBinaryAdapter`. The App SHALL NOT contain or invoke a script fallback.

#### Scenario: Missing Rust runtime fails closed

- **WHEN** the Rust executable is unavailable or fails runtime validation
- **THEN** the App reports a collector runtime error and does not invoke another interpreter or publish an empty artifact

#### Scenario: Release does not fallback to another runtime

- **WHEN** the Release Rust executable is missing, not executable, wrong-architecture, or fails runtime validation
- **THEN** the App reports a collector runtime error and does not download a replacement or silently show an empty artifact

### Requirement: Artifact and failure semantics remain compatible

The Rust collector SHALL preserve artifact v1 fields, units, rounding, null/empty distinctions, stable service/account/model ordering, status categories, partial diagnostics, previous artifact retention, and last-success semantics.

#### Scenario: Successful artifact is parity compatible

- **WHEN** the Rust collector receives a frozen request and fixture input
- **THEN** its canonicalized artifact values and stable ordering match the approved golden contract after only explicitly approved runtime-field normalization

#### Scenario: Partial provider failure is preserved

- **WHEN** one provider fails while other scoped sources succeed
- **THEN** Rust returns the approved partial/error diagnostics and successful data categories without converting the failure into configured-but-empty data

### Requirement: App credential ownership remains in Swift

Rust SHALL consume App credentials through the Bridge request, SHALL return only validated `credentialUpdates` and `credentialChallenges`, and SHALL NOT write App Keychain entries or third-party authentication databases directly.

#### Scenario: Credential refresh returns an update

- **WHEN** an injected account requires the existing allowed refresh path
- **THEN** Rust returns one validated update for that account and Swift performs the existing Keychain write coordination

#### Scenario: Device challenge is returned to the App

- **WHEN** a provider requires a device-code or interactive challenge
- **THEN** Rust returns a structured challenge without logging the token/secret and Swift remains responsible for UI presentation
