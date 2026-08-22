## 1. Correct the cleanup boundary

- [x] 1.1 Confirm current production and test references for every proposed deletion, including `UsageContribution`, `ModelDelta`, `ProjectDelta`, `RuntimeError::InvalidLimits`, and `sqlite_rows_read`
- [x] 1.2 Keep the Rust-only App/runtime, Bridge v1, artifact v1, metrics fields, credential behavior, and provider ordering outside the deletion scope

## 2. Remove low-risk leaf code

- [x] 2.1 Delete `UsageAccumulator::delta()` and remove only the obsolete `AggregateDelta` compatibility alias if all signatures are changed to `UsageContribution`; retain `ModelDelta` and `ProjectDelta`
- [x] 2.2 Remove `retain_previous_artifact`, `scan_tree`, `visit_tree`, `scan_tree_cached`, and `LocalScanResult` after migrating inline tests to live APIs
- [x] 2.3 Remove `AccountRefreshCoordinator`, `runtime_limits_request`, `parse_json_body`, `PROVIDER_ROLE`, `SUPPORTED_PROVIDER_APPS`, and `CODEX_RETRY_MAX_ATTEMPTS` only after reference scans and test updates
- [x] 2.4 Remove `ProviderRequest.service` only if `cargo check` and source search confirm no provider implementation or contract consumer reads it

## 3. Remove the generic SQLite mechanism safely

- [x] 3.1 Delete `collector-local/src/sqlite.rs` and its module/export/test references
- [x] 3.2 Remove SQLite-only fields and permits from `RuntimeLimits`/`RuntimeBudgets`, while retaining direct source-specific SQLite queries, `rusqlite`, and `sqlite_rows_read`
- [x] 3.3 Preserve `RuntimeLimits.validate()` and `RuntimeError::InvalidLimits` for remaining limits and bounded queue capacity

## 4. Remove unreachable aggregate pricing scaffolding

- [x] 4.1 Remove `Pricing`, `PricingTable`, and `estimate_cost`; simplify `UsageAccumulator::finalize` without changing current null cost output
- [x] 4.2 Update aggregate tests and add an explicit regression assertion for absent cost fields / unchanged artifact serialization

## 5. Dependency and documentation cleanup

- [x] 5.1 Remove only the unused direct `collector-provider` dependency declarations; verify transitive `ureq`/`rustls` dependencies remain intentional
- [x] 5.2 Keep credential/provider base64 implementations unchanged in this change and document the deferred shared-helper decision
- [x] 5.3 Run Rust fmt, workspace tests, Clippy, fixture scan, Swift integration verification, and OpenSpec validation
