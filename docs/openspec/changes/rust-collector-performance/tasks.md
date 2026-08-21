## 1. Phase 0: Baseline and contract freeze

- [x] 1.1 Add opt-in Python Bridge phase/resource metrics without changing artifact output or credential behavior
- [x] 1.2 Add a deterministic benchmark runner for isolated HOME, fixture input, cold/warm runs, and resource samples
- [x] 1.3 Create redacted Bridge request/response/artifact/status/diagnostic golden fixtures from existing tests
- [x] 1.4 Add canonical Python result normalization and secret scanning for differential fixtures
- [x] 1.5 Run the baseline matrix and record P50/P95 wall, CPU, RSS, disk, phase, HTTP, retry, and credential-refresh metrics

## 2. Rust workspace and Bridge vertical slice

- [x] 2.1 Create `rust/Bruce-collector` Cargo workspace with domain, bridge, local, aggregate, provider, credential crates and binary target
- [x] 2.2 Implement domain protocol/status/error types with no network, Keychain, or filesystem side effects
- [x] 2.3 Implement Rust Bridge v1 input validation, size limits, one stdout envelope, stderr separation, and exit codes
- [x] 2.4 Add Rust Bridge tests for valid request, malformed/unknown request, stdout pollution, oversized input, cancellation, and run ID
- [x] 2.5 Add Swift Runner harness coverage for discovering and invoking the Rust binary while preserving timeout/cancel semantics

## 3. Domain parity and local vertical slice

- [x] 3.1 Port time windows, timezone/day boundaries, status precedence, and artifact serialization rules
- [x] 3.2 Port token/cost/day/model/project aggregation and previous artifact merge rules
- [x] 3.3 Build Python/Rust differential runner with strict canonical artifact/status/diagnostic comparison
- [x] 3.4 Implement one JSONL source as a streaming Rust local adapter with bounded record memory
- [x] 3.5 Add local adapter parity tests for valid records, malformed lines, truncation, unknown fields, and empty input

## 4. Incremental local scanning and resource controls

- [x] 4.1 Define versioned `collector-cache-v1` schema with no raw session or credential fields
- [x] 4.2 Implement file identity/size/mtime/segment fingerprint and safe append offset validation
- [x] 4.3 Implement cache hit, append, rewrite/truncate, delete, version invalidation, corrupt cache rebuild, and atomic commit
- [x] 4.4 Implement read-only SQLite adapter with schema capability checks, parameterized bounded queries, and diagnostics
- [x] 4.5 Add centralized `RuntimeLimits`, bounded local/network workers, account single-flight, queue backpressure, and cancellation
- [x] 4.6 Add cold/warm/append/rewrite/delete/cache-corruption performance tests and verify no duplicate aggregate records

## 5. Read-only providers and credentials

- [x] 5.1 Port service catalog resolution, stable ordering, and read-only quota domain interfaces
- [x] 5.2 Port read-only quota providers and HTTP parsers using fixture clients with unchanged timeout/retry/error semantics
- [x] 5.3 Add App credential injection adapter and validated `credentialUpdates`/`credentialChallenges` output
- [x] 5.4 Port CLI file/Keychain reads and account-level expiry/refresh single-flight without direct App Keychain writes
- [x] 5.5 Add Provider and credential parity/error/secret-scan tests, including Codex retry-only behavior

## 6. Swift integration and packaging

- [x] 6.1 Add `CollectorExecutable` seam with Rust binary and Preview-only Python adapters
- [x] 6.2 Update runtime readiness, diagnostics, and settings compatibility to distinguish Rust runtime failures from legacy Python config
- [x] 6.3 Update Preview/runtime manifests and build scripts to use the same Rust artifact source
- [x] 6.4 Add Release manifest/package checks that reject Python fallback/source, secrets, data, fixtures, and wrong-architecture binaries
- [x] 6.5 Add Swift integration tests for scope, dedupe, previous artifact, Codex recovery, timeout, cancellation, and Release no-fallback

## 7. Performance hardening and cutover

- [x] 7.1 Run the full cold/warm/account-scale benchmark matrix against Python and Rust and compare target metrics
- [x] 7.2 Fix all unclassified differential parity, resource, cancellation, and diagnostics regressions
- [ ] 7.3 Verify signed universal Rust binary, notarization/staple/spctl, installation, upgrade, old cache rebuild, and rollback
- [x] 7.4 Run Python, Rust, Swift, package security, and standard local verification suites
- [x] 7.5 Produce requirement-by-requirement acceptance evidence and mark Release cutover readiness

## 8. Next Rust architecture migration

The detailed execution plan is `implementation-plan.md` in this change directory.

- [x] 8.1 Freeze the current contract fixtures and migration guardrails
- [x] 8.2 Add `collector-application` orchestration and reduce Bridge to protocol/envelope work
- [x] 8.3 Connect runtime budgets, Provider registry, credential execution, and account single-flight
- [x] 8.4 Isolate local/cache/aggregate with domain contribution and bounded change streaming
- [ ] 8.5 Run final parity, performance, security, Swift integration, and Release cutover gates
