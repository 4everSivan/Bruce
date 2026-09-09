# Bruce Collector Runtime Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox markers (- [ ]) for tracking.

**Goal:** Make Collector performance measurable by source, stop local scans at cancellation/deadline, add safe SQLite reuse, and preserve correct warm-cache status semantics.

**Architecture:** Extend the existing CollectionOutput diagnostics seam with source-scoped metrics while keeping the stable artifact unchanged. Add a read-only SQLite cache engine that reuses unchanged database contributions and only performs incremental reads when append-only behavior is provable. Propagate the existing CancellationToken through local file/row loops; if cancellation is observed, return a typed failure so Swift keeps the previous successful artifact. Fix Codex warm-cache found independently before enabling more cache paths.

**Tech Stack:** Rust 2024 workspace, collector-runtime::CancellationToken, rusqlite read-only connections, serde/serde_json, macOS proc_pid_rusage, existing Bridge v1, Swift CollectorRunner timeout seam, and the existing matrix fixture.

**Spec:** docs/superpowers/specs/2026-09-09-runtime-cpu-optimization-design.md

## Global Constraints

- Metrics are diagnostic-only and must not add stable fields to the user artifact or expose raw paths, credentials, JSONL, database payloads, or HTTP responses.
- Collector output remains Bridge v1 compatible; App Keychain writes remain owned by Swift.
- SQLite connections remain read-only; no DDL, VACUUM, migration, checkpoint write, or data repair is permitted.
- Cancellation and deadline are distinct from parse/schema errors and true empty results; partial results are not published after cancellation.
- Codex warm-cache hits must retain valid found and agent status semantics.
- Existing source order, bounded workers, response limits, refresh cadence, and previous-artifact retention remain unchanged.
- Tests and benchmarks use isolated HOME, temporary SQLite files, synthetic credentials, and injected HTTP; no live collection is required.

---

## File Map

- Modify: rust/Bruce-collector/crates/collector-application/src/context.rs — define source performance metric values alongside existing runtime counters.
- Modify: rust/Bruce-collector/crates/collector-application/src/lib.rs — collect source timings, expose metrics, pass cancellation to source scans, and preserve cancellation failure semantics.
- Modify: rust/Bruce-collector/crates/collector-bridge/src/lib.rs — propagate source metrics through CollectionOutput into the diagnostic writer.
- Modify: rust/Bruce-collector/crates/collector-bridge/src/metrics.rs — serialize source metrics and macOS CPU/RSS/resource usage without sensitive fields.
- Modify: rust/Bruce-collector/crates/collector-local/Cargo.toml — depend on collector-runtime for the shared cancellation token.
- Create: rust/Bruce-collector/crates/collector-local/src/sqlite_cache.rs — versioned database signature, cursor, cache entry, and read-only incremental engine.
- Modify: rust/Bruce-collector/crates/collector-local/src/sources.rs — cancellation-aware JSONL/SQLite loops and OpenCode/ZCode cache adapters.
- Modify: rust/Bruce-collector/bin/Bruce-collector/src/bin/matrix-fixture.rs — emit source-scoped metrics in isolated benchmark output.
- Modify: docs/openspec/changes/rust-collector-performance/benchmark-evidence.md — document the source-level evidence boundary and warm-cache interpretation.
- Test: existing Rust unit modules in collector-application, collector-bridge, and collector-local.

## Task 1: Add source-scoped Collector metrics

**Files:**
- Modify: rust/Bruce-collector/crates/collector-application/src/context.rs:1-35
- Modify: rust/Bruce-collector/crates/collector-application/src/lib.rs:45-65,301-482
- Modify: rust/Bruce-collector/crates/collector-bridge/src/lib.rs:85-160
- Modify: rust/Bruce-collector/crates/collector-bridge/src/metrics.rs:1-120
- Test: rust/Bruce-collector/crates/collector-bridge/src/metrics.rs new unit tests and collector-application/src/lib.rs tests.

**Interfaces:**
- Produces pub struct SourcePerformanceMetric { pub source_id: String, pub elapsed_ms: u64, pub stats: ScanStats }.
- Adds source_metrics: Vec<SourcePerformanceMetric> to CollectionOutput; this is an internal Rust output field, not an artifact field.
- Produces fn timed_source_scan<F>(source_id: &'static str, scan: F) -> (SourceScan, SourcePerformanceMetric) where F: FnOnce() -> SourceScan.
- Produces build_metrics_payload(stats: &CollectionScanStats, metrics: &CollectionMetrics, source_metrics: &[SourcePerformanceMetric]) -> serde_json::Value with a sources array containing id, elapsed_time_ms, files_visited, json_lines_parsed, and related counters.

- [ ] **Step 1: Write failing metrics serialization tests**

Extract a pure build_metrics_payload(...) -> serde_json::Value function from write_if_enabled and test source fields without touching a process-global environment variable:

    #[test]
    fn metrics_payload_exposes_source_counts_without_sensitive_values() {
        let source = SourcePerformanceMetric {
            source_id: "claude-code".to_owned(),
            elapsed_ms: 17,
            stats: ScanStats {
                files_visited: 3,
                json_lines_parsed: 9,
                bytes_read: 512,
                ..ScanStats::default()
            },
        };
        let payload = build_metrics_payload(
            &CollectionScanStats::default(),
            &CollectionMetrics::default(),
            &[source],
        );
        assert_eq!(payload["sources"][0]["id"], "claude-code");
        assert_eq!(payload["sources"][0]["json_lines_parsed"], 9);
        let text = payload.to_string();
        assert!(!text.contains("/Users/"));
        assert!(!text.contains("refresh_token"));
    }

Add an application assertion that source metric IDs are stable and ordered exactly like the source loop, rather than depending on completion order.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-bridge metrics -- --nocapture
    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-application source_metrics -- --nocapture

Expected: compilation or test failure because SourcePerformanceMetric, source_metrics, and the pure payload function are not present.

- [ ] **Step 3: Add the metric type and time every local source**

Add the type in context.rs, add the vector to CollectionOutput and LocalCollection, and wrap each source call in collect_local_usage:

    let started = Instant::now();
    let source = scan_claude(&claude, &context.window);
    source_metrics.push(SourcePerformanceMetric {
        source_id: "claude-code".to_owned(),
        elapsed_ms: started.elapsed().as_millis() as u64,
        stats: source.stats.clone(),
    });

Use one helper to avoid missing a source. Keep the existing source order and merge aggregate ScanStats exactly as before.

- [ ] **Step 4: Add process CPU, system CPU, RSS, and source fields to diagnostic output**

Reuse the existing macOS proc_pid_rusage call in collector-bridge/src/metrics.rs. Capture a start snapshot before collection and an end snapshot after collection; serialize user CPU milliseconds, system CPU milliseconds, and peak/physical footprint when available. Keep null on unsupported platforms or failed reads.

The payload shape must remain diagnostic-only:

    {
      "cpu_user_ms": 12.4,
      "cpu_system_ms": 1.2,
      "peak_rss_bytes": 12345678,
      "sources": [
        {"id": "claude-code", "elapsed_time_ms": 17, "json_lines_parsed": 9}
      ]
    }

Propagate source_metrics through all CollectionOutput construction and Bridge destructuring paths, including error and Codex retry-only paths with an empty vector.

- [ ] **Step 5: Run metrics and workspace tests**

Run:

    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-bridge
    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-application
    cargo fmt --manifest-path rust/Bruce-collector/Cargo.toml --all -- --check

Expected: all tests pass, and no stable artifact JSON changes occur.

- [ ] **Step 6: Commit source metrics**

    git add rust/Bruce-collector/crates/collector-application/src/context.rs \
      rust/Bruce-collector/crates/collector-application/src/lib.rs \
      rust/Bruce-collector/crates/collector-bridge/src/lib.rs \
      rust/Bruce-collector/crates/collector-bridge/src/metrics.rs
    git commit -m "perf(collector): expose source-level runtime metrics"

## Task 2: Fix Codex warm-cache found semantics

**Files:**
- Modify: rust/Bruce-collector/crates/collector-local/src/sources.rs:1303-1367
- Modify: rust/Bruce-collector/crates/collector-application/src/lib.rs:557-577 only if the application assertion requires a narrow status guard.
- Test: rust/Bruce-collector/crates/collector-local/src/sources.rs Codex cache tests and collector-application/src/lib.rs.

**Interfaces:**
- scan_codex_cached(...) -> SourceScan remains the public function.
- Warm cache hit returns found=true whenever at least one valid selected Codex file is present.
- finalize_local_agent continues to map found=false to not_found only for genuinely missing sources.

- [ ] **Step 1: Add the failing warm-cache assertion**

Extend codex_cached_scan_skips_unchanged_files_and_increments_on_append:

    assert!(warm.found, "unchanged cached Codex files still count as found");

Add an application fixture with one Codex rollout file and empty alternate source paths. Run the application twice and assert that the Codex agent's second-run status is not not_found.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local codex_cached_scan_skips -- --nocapture
    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-application codex_warm_cache -- --nocapture

Expected: the warm source assertion fails on the current stats.files_scanned > 0 logic.

- [ ] **Step 3: Derive found from selected files, not parsed lines**

Use the selected candidate count or files_visited > 0 after collect_codex_files has successfully discovered eligible files. Keep files_scanned as “body parsed on this run” for metrics; do not change its meaning to make the status test pass.

- [ ] **Step 4: Run Codex and parity tests**

Run:

    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local codex
    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-application

Expected: cold, warm, append, duplicate, conflict, and application status tests pass.

- [ ] **Step 5: Commit the correctness fix**

    git add rust/Bruce-collector/crates/collector-local/src/sources.rs \
      rust/Bruce-collector/crates/collector-application/src/lib.rs
    git commit -m "fix(collector): preserve Codex status on warm cache hits"

## Task 3: Propagate cancellation through local scans

**Files:**
- Modify: rust/Bruce-collector/crates/collector-local/Cargo.toml
- Modify: rust/Bruce-collector/crates/collector-local/src/sources.rs:230-323,518-1660
- Modify: rust/Bruce-collector/crates/collector-application/src/lib.rs:301-482
- Test: rust/Bruce-collector/crates/collector-local/src/sources.rs and collector-application/src/lib.rs.

**Interfaces:**
- Add collector-runtime as a dependency of collector-local.
- Produce pub enum SourceScanError { Io(std::io::Error), Runtime(collector_runtime::RuntimeError) } with From conversions.
- Add cancellation-aware variants such as scan_claude_with_cancellation(root, window, cancellation) -> Result<SourceScan, SourceScanError> for each uncached JSONL source and for OpenCode/ZCode.
- Keep existing scan_claude, scan_codebuddy, scan_kimi_tree, scan_grok, scan_pi, scan_opencode, and scan_zcode wrappers for existing tests; wrappers use a fresh token and preserve their current empty-on-read-error behavior.

- [ ] **Step 1: Add failing cancellation tests**

Create a large temporary JSONL fixture and cancel before scanning its first directory, then cancel from a callback after the first parsed line. Assert that the typed result reports runtime cancellation and no success SourceScan is returned:

    let cancellation = CancellationToken::new();
    cancellation.cancel();
    let result = scan_kimi_tree_with_cancellation(&root, &window, &cancellation);
    assert!(matches!(
        result,
        Err(SourceScanError::Runtime(RuntimeError::Cancelled))
    ));

Add an application-level test that a cancelled local run returns the existing LOCAL_SOURCE_CANCELLED diagnostic path and does not publish a newly assembled partial artifact.
For deterministic mid-file cancellation, add a cfg(test) line probe to the
private JSONL scan implementation. The production entry point passes no probe;
the test probe calls CancellationToken::cancel() after the first parsed line.
This keeps the production API limited to the cancellation token while making
the boundary test independent of thread scheduling.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local cancellation -- --nocapture
    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-application cancelled_local -- --nocapture

Expected: compilation fails because source functions do not accept a cancellation token.

- [ ] **Step 3: Add checks at directory, file, and line boundaries**

Thread &CancellationToken through scan_jsonl_tree, walk_jsonl_tree, and scan_jsonl_file. Check before directory recursion, after each directory entry, before File::open, and once per bounded line. Convert RuntimeError::Cancelled and RuntimeError::DeadlineExceeded into SourceScanError::Runtime.

Do not check only once per file; a large transcript must stop while it is being read. Do not retain or emit the partially built contribution after an error.

- [ ] **Step 4: Add checks to SQLite loops and cache publication boundaries**

Use the same token in SQLite row iteration and before cache manifest update. A cancelled run may finish already-complete per-file cache writes, but it must not replace the source manifest or publish a partial aggregate. The next run must discover the incomplete manifest and safely rebuild/reconcile.

- [ ] **Step 5: Map cancellation in application orchestration**

Before invoking each secondary source, call context.cancellation.check(). Use the cancellation-aware functions and map runtime cancellation/deadline to the existing diagnostic. Stop the remaining source loop immediately. Keep parse/schema/I/O diagnostics on their existing source-specific paths.

The Rust Bridge returns an error response without a new artifact for cancellation/deadline; Swift CollectorRunner continues to preserve the previous successful artifact when the process ends as cancelled or timed out.

- [ ] **Step 6: Run cancellation and workspace validation**

Run:

    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local
    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-application
    cargo test --manifest-path rust/Bruce-collector/Cargo.toml --workspace --locked
    cargo clippy --manifest-path rust/Bruce-collector/Cargo.toml --workspace --all-targets --locked -- -D warnings

Expected: cancelled scans stop at a bounded read boundary and all existing source semantics remain passing.

- [ ] **Step 7: Commit cancellation plumbing**

    git add rust/Bruce-collector/crates/collector-local/Cargo.toml \
      rust/Bruce-collector/crates/collector-local/src/sources.rs \
      rust/Bruce-collector/crates/collector-application/src/lib.rs
    git commit -m "perf(collector): stop local scans on cancellation"

## Task 4: Add a read-only SQLite cursor cache

**Files:**
- Create: rust/Bruce-collector/crates/collector-local/src/sqlite_cache.rs
- Modify: rust/Bruce-collector/crates/collector-local/src/lib.rs to register/re-export compact cache types.
- Modify: rust/Bruce-collector/crates/collector-local/src/sources.rs:1489-1660,1740-1830
- Test: rust/Bruce-collector/crates/collector-local/src/sources.rs existing OpenCode/ZCode tests plus new cache tests.

**Interfaces:**
- Produces SqliteSignature { device, inode, size, modified_ns, wal_size, wal_modified_ns }.
- Produces SqliteCursor { rowid: Option<i64>, timestamp_millis: Option<i64> }.
- Produces SqliteCacheEntry { schema_version, source_id, parser_version, signature, cursor, contribution: CompactContribution }.
- Produces SqliteCacheConfig { cache_root: PathBuf, source_id: String, parser_version: u32, window: CollectionWindow }.
- Produces SqliteReadResult { contribution: UsageContribution, cursor: SqliteCursor, found: bool, rows_read: u64, diagnostic: Option<String> }.
- Produces trait SqliteIncrementalAdapter with exact methods: source_id() -> &'static str; schema_fingerprint(&Connection) -> Result<String, SourceScanError>; read_full(&Connection, &CollectionWindow, &CancellationToken, &mut ScanStats) -> Result<SqliteReadResult, SourceScanError>; read_since(&Connection, &SqliteCursor, &CollectionWindow, &CancellationToken, &mut ScanStats) -> Result<SqliteReadResult, SourceScanError>; merge_delta(&UsageContribution, &UsageContribution, &CollectionWindow) -> UsageContribution.
- Produces scan_sqlite_cached<A: SqliteIncrementalAdapter>(path: &Path, config: &SqliteCacheConfig, adapter: &A, cancellation: &CancellationToken) -> Result<SourceScan, SourceScanError>.

- [ ] **Step 1: Add failing unchanged/append/rewrite tests**

For both OpenCode and ZCode, create a temporary database, run a cold scan, run an unchanged scan, insert an append-only row, then rewrite the database into a new file. Assert cache reuse, cursor advancement, and full-rebuild fallback:

    let cold = scan_opencode_cached(&db_path, &window, &cache_root, &token).unwrap();
    let warm = scan_opencode_cached(&db_path, &window, &cache_root, &token).unwrap();
    assert_eq!(warm.stats.sqlite_rows_read, 0);

    insert_message(&db_path, &new_message);
    let appended = scan_opencode_cached(&db_path, &window, &cache_root, &token).unwrap();
    assert_eq!(
        appended.contribution,
        scan_opencode(&db_path, &window).contribution
    );

Add a test that unknown schema and row-cap fallback produce a diagnostic rather than an empty successful contribution.
The SQLite test module must define concrete fixture helpers: create each
database using the existing OpenCode/ZCode schema setup, new_message returns one
valid message.data payload, insert_message appends one row, and the rewrite
helper writes a replacement database to a temporary path before an explicit
rename. The helpers must use the same read-only scan entry points as production
and must not bypass signature or cursor validation.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local opencode -- --nocapture
    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local zcode -- --nocapture

Expected: failure because the SQLite cache functions and cursor types do not exist.

- [ ] **Step 3: Implement signature and cache entry validation**

Open each database with the existing read-only OpenFlags. Compute high-resolution file and WAL signatures. Reuse a cache entry only when source ID, schema/parser version, signature, and window identity match. If size/mtime/WAL state is uncertain, rebuild instead of assuming unchanged.

Do not use PRAGMA operations that write or checkpoint the database. Cache writes use the same project-owned cache directory and atomic file replacement as JSONL cache entries.

- [ ] **Step 4: Implement OpenCode incremental reads**

Keep the current schema discovery and message.data JSON parser. When the recognized schema has a reliable rowid/timestamp cursor, query only rows after the cursor and merge their contribution. Use the existing bounded MAX_SOURCE_ROWS cap. When the schema is unknown or the cursor cannot prove append-only behavior, use the full bounded fallback and attach the existing diagnostic classification.

The implementation must not use LIKE '%tokens%' for an unchanged database and must not claim zero usage when candidate rows are truncated or malformed.

- [ ] **Step 5: Implement ZCode incremental reads**

Use model_usage.started_at and row identity where available. Preserve the current newest-row ordering and 10,000-row cap. When an in-place update, database rewrite, schema change, or missing cursor prevents a safe delta, rebuild the source contribution and refresh the cursor.

- [ ] **Step 6: Run SQLite parity and cancellation tests**

Run:

    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local opencode -- --nocapture
    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local zcode -- --nocapture
    cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local cancellation -- --nocapture

Expected: cold and cached contributions match, unchanged scans read zero rows, append reads only new rows when provable, and cancellation leaves no partial published source result.

- [ ] **Step 7: Commit the SQLite cache**

    git add rust/Bruce-collector/crates/collector-local/src/sqlite_cache.rs \
      rust/Bruce-collector/crates/collector-local/src/lib.rs \
      rust/Bruce-collector/crates/collector-local/src/sources.rs
    git commit -m "perf(collector): cache unchanged SQLite sources"

## Task 5: Update isolated benchmark evidence and run final gates

**Files:**
- Modify: rust/Bruce-collector/bin/Bruce-collector/src/bin/matrix-fixture.rs:95-150
- Modify: docs/openspec/changes/rust-collector-performance/benchmark-evidence.md
- Read: scripts/verify-local.sh
- No real runtime data is modified.

**Interfaces:**
- Matrix output includes the source metrics from CollectionOutput.
- Benchmark documentation distinguishes aggregate totals from per-source evidence and explicitly states that fixture results do not prove live-account CPU behavior.

- [ ] **Step 1: Add a failing matrix assertion for source metrics**

Extend the fixture output test or parser to require a sources array containing the stable source IDs. Require warm unchanged cases to report zero JSONL parsing for every cached source, rather than only checking aggregate totals.

- [ ] **Step 2: Run the matrix fixture and verify the current evidence gap**

Run:

    cargo run --manifest-path rust/Bruce-collector/Cargo.toml \
      --release --bin matrix-fixture -- \
      --output /tmp/bruce-rust-collector-matrix.json

Expected before implementation: the source-level assertions fail or the output lacks the sources array.

- [ ] **Step 3: Emit source metrics from the matrix fixture**

Serialize output.source_metrics into the existing fixture metrics object. Preserve the current injected HTTP, synthetic credentials, isolated HOME, and redacted output behavior.

- [ ] **Step 4: Update benchmark evidence wording and matrix requirements**

Document per-source cold/warm/append/rewrite/delete expectations. State that aggregate cache_hits or json_lines_parsed=0 is insufficient to prove every source is warm unless source metrics are present. Keep raw benchmark JSON under the existing ignored local benchmark directory.

- [ ] **Step 5: Run all local gates**

Run:

    env CARGO_HOME=/tmp/bruce-cargo-home-final cargo fmt \
      --manifest-path rust/Bruce-collector/Cargo.toml --all -- --check
    env CARGO_HOME=/tmp/bruce-cargo-home-final cargo test \
      --manifest-path rust/Bruce-collector/Cargo.toml --workspace --locked
    env CARGO_HOME=/tmp/bruce-cargo-home-final cargo clippy \
      --manifest-path rust/Bruce-collector/Cargo.toml --workspace --all-targets \
      --locked -- -D warnings
    swift build --package-path macos/BruceApp
    swift run --package-path macos/BruceApp PanelViewModelHarness
    swift run --package-path macos/BruceApp RefreshSchedulerHarness "$PWD"

Expected: Rust and Swift gates pass, existing artifact semantics remain unchanged, and source-level metrics are present only in diagnostics/benchmark output.

- [ ] **Step 6: Profile and record the final evidence**

Use Instruments Time Profiler and Activity Monitor for Bruce idle, panel open, Collector refresh, and Widget host. Record average CPU, CPU time, refresh wall time, logical/physical reads, parsed lines, SQLite rows, and peak RSS. Do not mark live-account root cause confirmed from fixture results alone.

- [ ] **Step 7: Commit benchmark documentation**

    git add rust/Bruce-collector/bin/Bruce-collector/src/bin/matrix-fixture.rs \
      docs/openspec/changes/rust-collector-performance/benchmark-evidence.md
    git commit -m "docs(perf): record source-level collector evidence"
