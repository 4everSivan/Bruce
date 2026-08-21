## ADDED Requirements

### Requirement: Unchanged local inputs use a rebuildable incremental cache

The collector SHALL store only versioned derived aggregates and file/database metadata under `~/Library/Application Support/Bruce/collector-cache-v1/`. It SHALL reuse unchanged local inputs, continue from a verified append offset when safe, and rebuild affected entries when identity, content, schema, window, timezone, pricing, or aggregation versions invalidate them.

#### Scenario: Warm unchanged refresh skips file bodies

- **WHEN** a source file identity, size, mtime, segment fingerprint, window, timezone, and parser versions are unchanged
- **THEN** the collector reuses its derived delta, reports a cache hit, and does not parse the unchanged file body again

#### Scenario: Append reads only the safe tail

- **WHEN** a file has the same verified prefix and only appended complete records
- **THEN** the collector parses only the appended range and produces the same aggregate as a full rebuild

#### Scenario: Rewrite or corrupt cache rebuilds safely

- **WHEN** a file is rewritten/truncated, a fingerprint mismatches, cache validation fails, or a cache version is unsupported
- **THEN** the collector discards the affected entry, performs a bounded full rebuild, reports the rebuild reason, and does not publish fabricated empty data

### Requirement: External SQLite remains read-only and bounded

The collector SHALL open CC Switch and other third-party SQLite databases read-only, perform capability/schema checks, use parameterized queries, select only required columns, and bound rows held in memory. It SHALL NOT execute DDL, migration, repair, or writes.

#### Scenario: Compatible database is read in batches

- **WHEN** an external database has a supported schema
- **THEN** the collector reads required rows in bounded batches and reports the number of rows read without loading the complete database into memory

#### Scenario: Locked or incompatible database is diagnosable

- **WHEN** a database is locked, missing a required table, or has an unsupported schema
- **THEN** the collector returns the existing diagnostic/status category and does not treat the source as a successful empty source

### Requirement: Refresh concurrency has explicit resource budgets

The collector SHALL use centralized runtime limits for local workers, network workers, SQLite readers, per-account credential tasks, response body size, and aggregate queue backlog. It SHALL apply backpressure and cancellation rather than creating unbounded tasks or queues.

#### Scenario: Independent work runs concurrently within limits

- **WHEN** local source scans and independent read-only quota requests are ready
- **THEN** they may run concurrently within the configured budgets, while result arrays remain in catalog/source order

#### Scenario: Same account is single-flight

- **WHEN** multiple paths request the same account token or quota in one refresh
- **THEN** token resolution and refresh happen at most once for that account and dependent requests share the resulting state

#### Scenario: Cancellation applies backpressure

- **WHEN** the runner cancels or reaches the deadline
- **THEN** the collector stops scheduling new work, cancels bounded in-flight work, publishes no partial cache/credential update, and returns the existing cancellation/timeout status

### Requirement: Resource metrics are available without sensitive data

The collector SHALL record wall time, CPU time, peak RSS, disk reads, files visited/changed, parsed lines, SQLite rows, phase timings, HTTP request count, credential refresh count, and cache hit/reason metrics in controlled diagnostics or benchmark output. Metrics SHALL NOT contain tokens, raw session text, or complete external responses.

#### Scenario: Benchmark records comparable metrics

- **WHEN** the same fixture is executed repeatedly in Python and Rust
- **THEN** both implementations report comparable phase and resource metrics keyed by fixture/build/input hash

