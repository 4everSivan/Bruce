## ADDED Requirements

### Requirement: Canonical collector fixtures are strict

The collector SHALL maintain redacted golden fixtures for Bridge requests/responses, artifacts, diagnostics, local source records, SQLite responses, Provider responses, credential updates, and challenges. The fixture harness SHALL compare canonical JSON, stable arrays, status categories, diagnostics, updates, and challenges, normalizing only explicitly approved runtime fields.

#### Scenario: Runtime fields are the only normalized difference

- **WHEN** a Rust result is compared with an approved golden fixture
- **THEN** `runId`/generation timestamps and approved machine-specific paths may be normalized, but data values, arrays, status, diagnostics, updates, and challenges are compared strictly

#### Scenario: Parity mismatch is actionable

- **WHEN** a canonical result differs
- **THEN** the harness reports the fixture, JSON path, implementation values, and difference category without exposing secrets or raw session content

### Requirement: Performance gates use cold and warm matrices

The benchmark SHALL cover small/medium/large local histories, 1/10/64 account-scale data, 14/182 day windows, cold process/cache, warm unchanged, append, rewrite/truncate, provider success/failure, and credential expiry. It SHALL report P50/P95 wall time, CPU, RSS, disk IO, phase timings, HTTP count, retry count, and credential refresh count.

#### Scenario: Warm optimization is measured separately

- **WHEN** cold and unchanged warm cases are benchmarked
- **THEN** results report separate distributions and do not allow a fast cold result to hide a warm cache regression

#### Scenario: External latency is separated

- **WHEN** a benchmark includes network providers
- **THEN** collector processing and external wait are reported separately, and increasing concurrency is not accepted if request or refresh counts regress

### Requirement: Release artifacts pass security and runtime gates

Release validation SHALL verify the signed universal Rust binary, runtime manifest, package contents, absence of script source/secrets/data fixtures, stdout protocol purity, and App runtime discovery.

#### Scenario: Package scan rejects forbidden content

- **WHEN** a Release package contains script runtime/source, bridge source, token/cookie/private key, raw session, database, fixture, or unapproved debug artifact
- **THEN** packaging validation fails before signing/release

#### Scenario: Signed runtime is discoverable

- **WHEN** a Release App starts with a valid bundled Rust binary
- **THEN** architecture, executable, signature, manifest, stdin/stdout smoke, and artifact schema checks pass before scheduled refresh is enabled
