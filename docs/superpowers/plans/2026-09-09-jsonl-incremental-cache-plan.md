# Bruce JSONL Incremental Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing rebuildable file cache from the primary Kimi scanner to the remaining JSONL Agent sources without changing usage semantics.

**Architecture:** Extract the current file signature, manifest, append detection, and bounded cache writer into a reusable `collector-local` cache engine. Each source adapter converts a file into derived usage observations and a compact contribution; the engine owns unchanged/append/rewrite/delete decisions, while the adapter owns parser-specific deduplication and aggregation. The application keeps source ordering and bounded execution, and Codex retains its specialized tree-cache path.

**Tech Stack:** Rust 2024 workspace, `serde`/`serde_json`, SHA-256 fingerprints, buffered JSONL I/O, existing `SourceScan`, `UsageContribution`, `SourceDeltaChange`, bounded queue, and Cargo fixture tests.

**Spec:** `docs/superpowers/specs/2026-09-09-runtime-cpu-optimization-design.md`

## Global Constraints

- Cache entries contain derived contributions and signatures, never raw JSONL lines, credentials, provider responses, or unbounded source content.
- Cache identity includes source ID, parser version, aggregation version, window policy, and hashed file identity.
- Keep the current day-aware window identity unless compact contributions are changed to absolute-day buckets; never reuse relative day indexes across a day rollover.
- Unchanged files must not be opened for JSONL body parsing; append is allowed only after identity, prefix, tail, and newline checks pass.
- Rewrite, truncation, corruption, incompatible version, or uncertain identity must rebuild safely.
- Claude and CodeBuddy message-ID deduplication must remain correct across files; cached data cannot be summed blindly.
- Existing bounded queue, worker limits, artifact fields, source order, and failure/diagnostic semantics remain unchanged.
- Tests use temporary directories and synthetic JSONL; no real session directory or Keychain is required.

---

## File Map

- Create: `rust/Bruce-collector/crates/collector-local/src/cache.rs` — reusable cache entry, manifest, signature, append detection, and tree engine.
- Modify: `rust/Bruce-collector/crates/collector-local/src/lib.rs` — register/re-export the cache module and preserve the current Kimi cache wrapper.
- Modify: `rust/Bruce-collector/crates/collector-local/src/sources.rs` — define cached file payloads and source adapters for Kimi Work, Claude, CodeBuddy, Grok, and Pi.
- Modify: `rust/Bruce-collector/crates/collector-application/src/lib.rs` — call cached source functions with source-specific namespaces while leaving Codex tree cache separate.
- Test: `rust/Bruce-collector/crates/collector-local/src/cache.rs` — generic cache state transitions and cache privacy checks.
- Test: `rust/Bruce-collector/crates/collector-local/src/sources.rs` — source parser parity and deduplication parity.
- Test: `rust/Bruce-collector/crates/collector-application/src/lib.rs` — application-level source status and warm-result integration.

## Task 1: Extract and parameterize the existing cache engine

**Files:**
- Create: `rust/Bruce-collector/crates/collector-local/src/cache.rs`
- Modify: `rust/Bruce-collector/crates/collector-local/src/lib.rs:1-35,150-900`
- Test: `rust/Bruce-collector/crates/collector-local/src/cache.rs`

**Interfaces:**
- Produces `pub(crate) struct JsonlCacheConfig { cache_root: PathBuf, source_id: String, window: CollectionWindow, parser_version: u32, aggregation_version: u32, pricing_version: u32 }`.
- Produces `pub(crate) struct FileSignature { device: u64, inode: u64, size: u64, modified_ns: u64 }`.
- Produces `pub(crate) struct CachedFilePayload { contribution: CompactContribution, observations: Vec<CachedUsageObservation>, safe_offset: u64, head_fingerprint: String, prefix_tail_fingerprint: String }`.
- Produces `pub(crate) trait JsonlCacheAdapter` with `parse_file`, `merge_append`, and `aggregate` methods.
- Produces `pub(crate) fn scan_cached_jsonl_tree<A: JsonlCacheAdapter>(root: &Path, config: &JsonlCacheConfig, adapter: &A) -> io::Result<SourceScan>`.
- Preserves `scan_tree_cached_with_sink` as a compatibility wrapper for the existing Kimi primary path during this plan.

- [ ] **Step 1: Write failing generic cache tests**

Move the existing cold/warm/append/rewrite/corrupt/delete scenario into `cache.rs` and add source identity and privacy assertions:

```rust
#[test]
fn cache_identity_isolated_by_source_and_version() {
    let first = test_config("kimi-work", 2, 2);
    let other_source = test_config("claude-code", 2, 2);
    let other_parser = test_config("kimi-work", 3, 2);

    write_fixture_entry(&first, "fixture.jsonl");
    assert!(matches!(load_for(&first, "fixture.jsonl"), CacheLoad::Entry(_)));
    assert!(!cache_identity_matches_for_test(&other_source, "fixture.jsonl"));
    assert!(!cache_identity_matches_for_test(&other_parser, "fixture.jsonl"));
}

#[test]
fn cache_entry_does_not_contain_raw_jsonl_fields() {
    let cache_text = serialized_fixture_cache_entry();
    assert!(!cache_text.contains("inputOther"));
    assert!(!cache_text.contains("refresh_token"));
    assert!(!cache_text.contains("/Users/"));
}
```

Retain the existing assertions that a warm scan has `cache_hits == 1` and `lines_seen == 0`, that a safe append reads only one line, and that deletion emits a removal change.

Define the test-only helpers used above in cache.rs: test_config creates an
isolated JsonlCacheConfig, write_fixture_entry writes through the real atomic
cache writer, load_for invokes the real loader, and
cache_identity_matches_for_test compares the loaded entry against the supplied
source/parser identity. serialized_fixture_cache_entry serializes a derived
CachedFilePayload only; it must not manufacture raw JSONL or credential fields.

- [ ] **Step 2: Run the focused Rust tests and verify the extraction tests fail**

Run:

```bash
cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local cache -- --nocapture
```

Expected: compilation fails because `cache.rs`, the parameterized source identity, or the test helpers do not exist yet.

- [ ] **Step 3: Move cache-only types and helpers into `cache.rs`**

Move `FileSignature`, `CacheWindow`, `CacheEntry`, `CompactContribution`, `CacheManifest`, `CacheLoad`, `process_cached_file`, `reconcile_deleted_cache`, `append_is_safe`, `make_cache_entry`, `load_cache`, and the atomic cache writer from `lib.rs` into the new module. Keep `ScanStats`, `LocalUsageRecord`, `scan_path`, and `scan_path_from_offset` in `lib.rs`.

Parameterize the hard-coded Kimi identity. The cache identity check must use all of the following values:

```rust
entry.schema_version == CACHE_SCHEMA_VERSION
    && entry.source_kind == config.source_id
    && entry.parser_version == config.parser_version
    && entry.aggregation_version == config.aggregation_version
    && entry.window == CacheWindow::from_config(config)
```

Use `source_id` in manifest names and entries so Kimi Work, Claude, CodeBuddy, Grok, and Pi cannot reuse one another's cache files.

- [ ] **Step 4: Implement the adapter-neutral payload and trait**

Add a derived observation type containing only fields required to rebuild source deduplication:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub(crate) struct CachedUsageObservation {
    pub dedupe_key: Option<String>,
    pub timestamp_millis: i64,
    pub model: Option<String>,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
    pub project: Option<String>,
}

pub(crate) trait JsonlCacheAdapter {
    fn source_id(&self) -> &'static str;
    fn parse_file(
        &self,
        path: &Path,
        window: &CollectionWindow,
        offset: u64,
    ) -> io::Result<(CachedFilePayload, ScanStats)>;
    fn merge_append(
        &self,
        previous: CachedFilePayload,
        appended: CachedFilePayload,
        window: &CollectionWindow,
    ) -> CachedFilePayload;
    fn aggregate(
        &self,
        files: &BTreeMap<String, CachedFilePayload>,
        window: &CollectionWindow,
    ) -> SourceScan;
}
```

The engine must use the existing bounded cache writer and atomic rename. It may write a completed file entry during a scan, but it must update the source manifest only after the complete tree scan succeeds.

- [ ] **Step 5: Run cache tests and existing local tests**

Run:

```bash
cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local
cargo fmt --manifest-path rust/Bruce-collector/Cargo.toml --all -- --check
```

Expected: generic cache transitions and all pre-existing `collector-local` tests pass.

- [ ] **Step 6: Commit the cache engine extraction**

```bash
    git add rust/Bruce-collector/crates/collector-local/src/cache.rs \
      rust/Bruce-collector/crates/collector-local/src/lib.rs
git commit -m "refactor(collector): parameterize local JSONL cache"
```

## Task 2: Add cached additive source adapters

**Files:**
- Modify: `rust/Bruce-collector/crates/collector-local/src/sources.rs:1-330,518-1473`
- Modify: `rust/Bruce-collector/crates/collector-local/src/lib.rs` if `CompactContribution` or `record_into` visibility is required.
- Test: `rust/Bruce-collector/crates/collector-local/src/sources.rs` existing source tests and new cached parity tests.

**Interfaces:**
- Produces `scan_kimi_tree_cached(root, window, cache_root) -> SourceScan`.
- Produces `scan_grok_cached(roots, window, cache_root) -> SourceScan`.
- Produces `scan_pi_cached(root, window, cache_root) -> SourceScan`.
- Keeps `scan_kimi_tree`, `scan_grok`, and `scan_pi` as uncached parity/reference functions for tests.

- [ ] **Step 1: Add failing cold/warm parity tests**

For each additive source, create a temporary tree containing two valid records and one ignored record. Assert that the cached result equals the uncached result and that the second cached run does not parse JSONL:

```rust
let expected = scan_kimi_tree(&root, &window);
let cold = scan_kimi_tree_cached(&root, &window, &cache_root);
let warm = scan_kimi_tree_cached(&root, &window, &cache_root);

assert_eq!(cold.contribution, expected.contribution);
assert!(warm.stats.cache_hits > 0);
assert_eq!(warm.stats.json_lines_parsed, 0);
assert_eq!(warm.contribution, expected.contribution);
```

Repeat the same shape for Grok and Pi using their current valid fixture record formats.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local cached -- --nocapture
```

Expected: failure because the cached source functions and adapter implementations do not exist.

- [ ] **Step 3: Implement additive observation parsing**

Reuse the existing parsing rules inside `scan_kimi_tree`, `scan_grok`, and `scan_pi`, but emit `CachedUsageObservation` values instead of immediately mutating one tree-level builder. For additive records set `dedupe_key` to `None`; preserve timestamp, model, token buckets, and project mapping exactly.

The adapter's `aggregate` method must build a fresh `UsageContributionBuilder` from all cached file payloads and return `found=true` when at least one eligible file was selected, including an unchanged cache hit.

- [ ] **Step 4: Implement append, rewrite, and deletion behavior**

Use the generic engine for all three state transitions:

```rust
let first = scan_kimi_tree_cached(&root, &window, &cache_root);
append_complete_jsonl_line(&path, &record(3));
let appended = scan_kimi_tree_cached(&root, &window, &cache_root);
rewrite_jsonl_file(&path, &[record(9)]);
let rewritten = scan_kimi_tree_cached(&root, &window, &cache_root);
remove_file(&path);
let deleted = scan_kimi_tree_cached(&root, &window, &cache_root);
```

Assert that appended output is `first + delta`, rewritten output contains only the replacement contribution, and deleted output no longer contains the removed file.

- [ ] **Step 5: Run source parity and static checks**

Run:

```bash
cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local
cargo clippy --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local --all-targets -- -D warnings
```

Expected: all source parsers and cache transitions pass without warnings.

- [ ] **Step 6: Commit additive source caching**

```bash
git add rust/Bruce-collector/crates/collector-local/src/sources.rs \
  rust/Bruce-collector/crates/collector-local/src/lib.rs
git commit -m "perf(collector): cache additive JSONL sources"
```

## Task 3: Preserve cross-file deduplication for Claude and CodeBuddy

**Files:**
- Modify: `rust/Bruce-collector/crates/collector-local/src/sources.rs:550-700,900-1100`
- Test: `rust/Bruce-collector/crates/collector-local/src/sources.rs` Claude and CodeBuddy test sections.

**Interfaces:**
- Produces `scan_claude_cached(root, window, cache_root) -> SourceScan`.
- Produces `scan_codebuddy_cached(root, window, cache_root) -> SourceScan`.
- `CachedUsageObservation.dedupe_key` contains a stable source-local digest, never the raw message ID.
- Claude aggregation keeps the maximum token snapshot per message ID digest; CodeBuddy aggregation keeps the existing project/session scope plus message ID semantics.

- [ ] **Step 1: Add failing cross-file dedupe parity tests**

Construct two files with the same logical message ID and increasing token snapshots, plus a direct usage record. Compare uncached and cached output:

```rust
let uncached = scan_claude(&root, &window);
let cached = scan_claude_cached(&root, &window, &cache_root);
assert_eq!(cached.contribution, uncached.contribution);

let warm = scan_claude_cached(&root, &window, &cache_root);
assert_eq!(warm.contribution, uncached.contribution);
assert_eq!(warm.stats.json_lines_parsed, 0);
```

Repeat with CodeBuddy's `codebuddy_scope(path, value)` behavior and verify that records with different project/session scopes do not collapse into one message.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local claude -- --nocapture
cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local codebuddy -- --nocapture
```

Expected: failure because cached dedupe adapters are not present.

- [ ] **Step 3: Emit derived dedupe observations**

For Claude, hash the existing message ID with a source-specific domain separator before storing it. For CodeBuddy, hash the existing scope-plus-message-ID key. Store the selected token snapshot, timestamp, model, project, and the digest. For records without an ID, keep `dedupe_key=None` and preserve direct-record behavior.

- [ ] **Step 4: Aggregate all file payloads through the source-specific dedupe rule**

Build the same `best` maps currently used by the uncached functions, but source them from cached observations:

```rust
for observation in observations {
    match observation.dedupe_key.as_ref() {
        Some(key) => select_larger_or_newer_snapshot(&mut best, key, observation),
        None => direct.push(observation.clone()),
    }
}
```

The selection rule must remain Claude's per-counter maximum with latest timestamp metadata and CodeBuddy's total-token/latest-timestamp replacement rule.

- [ ] **Step 5: Verify cold/warm/append/rewrite parity**

Run:

```bash
cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local claude -- --nocapture
cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-local codebuddy -- --nocapture
cargo fmt --manifest-path rust/Bruce-collector/Cargo.toml --all -- --check
```

Expected: uncached and cached contribution fields match for duplicate snapshots, direct records, append, and rewrite cases.

- [ ] **Step 6: Commit dedupe-preserving adapters**

```bash
git add rust/Bruce-collector/crates/collector-local/src/sources.rs
git commit -m "perf(collector): preserve dedupe in cached agent sources"
```

## Task 4: Integrate cached sources into application orchestration

**Files:**
- Modify: `rust/Bruce-collector/crates/collector-application/src/lib.rs:301-482`
- Test: `rust/Bruce-collector/crates/collector-application/src/lib.rs` application tests.

**Interfaces:**
- `collect_local_usage` continues returning `LocalCollection` and aggregate `ScanStats`.
- Source order remains `kimi-work`, `claude-code`, `codex`, `codebuddy`, `grok`, `opencode`, `pi`, `zcode`.
- Kimi Code primary and Codex continue using their existing specialized paths; the new cache namespace is used for the other JSONL sources.

- [ ] **Step 1: Add a fixture integration test for warm source status**

Build a temporary HOME with explicit `context.paths` for Kimi Work, Claude, CodeBuddy, Grok, and Pi, write one valid record for each, run `collect_agent_usage_with_dependencies` twice, and assert:

```rust
assert_eq!(first.artifact["agents"], second.artifact["agents"]);
assert!(second.scan_stats.cache_hits >= first.scan_stats.cache_hits);
assert_eq!(second.scan_stats.json_lines_parsed, 0);
```

The assertion must compare each source's status and contribution fields, not only the combined token total.

- [ ] **Step 2: Run the application test and verify failure**

Run:

```bash
cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-application warm_source -- --nocapture
```

Expected: failure because application orchestration still invokes uncached source functions.

- [ ] **Step 3: Pass source-specific cache namespaces into the source calls**

Create one cache root from the injected HOME, then call the cached functions without changing the existing source order:

```rust
let cache_root = default_cache_root(&home);
let source_results = [
    ("kimi-work", scan_kimi_tree_cached(&kimi_work, &context.window, &cache_root)),
    ("claude-code", scan_claude_cached(&claude, &context.window, &cache_root)),
    ("codex", scan_codex_cached(&codex_roots, &context.window, &cache_root)),
    ("codebuddy", scan_codebuddy_cached(&codebuddy, &context.window, &cache_root)),
    ("grok", scan_grok_cached(&grok_roots, &context.window, &cache_root)),
    ("opencode", scan_opencode(&opencode, &context.window)),
    ("pi", scan_pi_cached(&pi, &context.window, &cache_root)),
    ("zcode", scan_zcode(&zcode, &context.window)),
];
```

Use source IDs in cache paths; do not let one source's manifest or hashed file digest collide with another source.

- [ ] **Step 4: Preserve diagnostic and missing-source semantics**

Keep the existing `finalize_local_agent` path unchanged except for consuming the cached `SourceScan`. A cache hit with a valid file must yield `found=true`; cache corruption must yield the same source contribution/status as a successful full rebuild plus a diagnostic. A missing root must retain `not_found` rather than a cache error.

- [ ] **Step 5: Run application and workspace validation**

Run:

```bash
cargo test --manifest-path rust/Bruce-collector/Cargo.toml -p collector-application
cargo test --manifest-path rust/Bruce-collector/Cargo.toml --workspace --locked
cargo clippy --manifest-path rust/Bruce-collector/Cargo.toml --workspace --all-targets --locked -- -D warnings
```

Expected: all existing provider/application tests and the new warm-source integration test pass.

- [ ] **Step 6: Commit application integration**

```bash
git add rust/Bruce-collector/crates/collector-application/src/lib.rs
git commit -m "perf(collector): use incremental cache for local JSONL sources"
```

## Task 5: Run the JSONL cache acceptance matrix

**Files:**
- Read: `rust/Bruce-collector/crates/collector-local/src/lib.rs`
- Read: `rust/Bruce-collector/crates/collector-local/src/sources.rs`
- Read: `docs/openspec/changes/rust-collector-performance/benchmark-evidence.md`
- No source modification required unless a failed invariant identifies a concrete bug.

**Interfaces:**
- Uses source-specific cached functions from Tasks 2-4.
- Produces local benchmark JSON only; it does not modify tracked fixture or production data.

- [ ] **Step 1: Run the focused cache matrix**

Run:

```bash
env CARGO_HOME=/tmp/bruce-cargo-home-jsonl-cache cargo test \
  --manifest-path rust/Bruce-collector/Cargo.toml \
  -p collector-local -- --nocapture
```

Expected: cold/warm/append/rewrite/delete and corruption cases pass for every cached JSONL source.

- [ ] **Step 2: Compare cached and uncached stable artifacts**

Run the application fixture cases for 14 and 182 days and compare agent status, token buckets, daily values, model values, project values, and cost. Normalize only generated timestamps and run IDs.

- [ ] **Step 3: Confirm warm parsing and read reductions**

For warm unchanged runs, require `json_lines_parsed == 0` for every cached JSONL source and record cache hits by source. If aggregate `ScanStats` cannot prove this per source, use the source metrics from the Collector performance plan rather than claiming the entire run is warm.

- [ ] **Step 4: Record acceptance without committing local output**

Keep redacted benchmark output under the existing ignored local benchmark directory. Do not add session contents, raw paths, credentials, or generated JSON to Git.
