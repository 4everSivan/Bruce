## ADDED Requirements

### Requirement: Dead-code cleanup preserves the Rust collector contract

The Rust Collector cleanup SHALL preserve Bridge v1 validation, artifact v1 field names and serialization, metrics field semantics, provider ordering, previous-artifact behavior, cache semantics, and credential read/update behavior.

#### Scenario: Canonical artifact remains compatible

- **WHEN** the same canonical request and fixture inputs are processed before and after cleanup
- **THEN** the normalized artifact, response status, diagnostics, metrics fields, and credential output semantics remain equivalent

#### Scenario: Production local sources remain available

- **WHEN** the collector scans JSONL, OpenCode SQLite, or ZCode SQLite sources
- **THEN** the production source adapters continue to emit the same derived contributions and retain `sqlite_rows_read` metrics

### Requirement: Removed mechanisms are absent from production paths

The Rust workspace SHALL remove the verified zero-caller generic SQLite query module, test-only convenience APIs, unused wrappers, unused constants, and unused direct dependency declarations without introducing a replacement runtime or changing the Rust-only App execution path.

#### Scenario: Generic SQLite helper is not used by production sources

- **WHEN** the workspace is compiled and the source adapters are inspected
- **THEN** OpenCode and ZCode use their existing bounded source-specific queries, and no production module depends on the removed generic helper

#### Scenario: Removed test-only entry points are not exported

- **WHEN** the workspace is built with `cargo test --workspace`
- **THEN** deleted test-only entry points and wrappers have no remaining production or test references

### Requirement: Cleanup is verified by the existing gates

The cleanup SHALL be accepted only when Rust formatting, workspace tests, Clippy, canonical fixture validation, and the standard local verification script pass.

#### Scenario: Rust quality gates pass

- **WHEN** the cleanup is complete
- **THEN** `cargo fmt --check`, `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, and `zsh scripts/verify-local.sh` all exit successfully
