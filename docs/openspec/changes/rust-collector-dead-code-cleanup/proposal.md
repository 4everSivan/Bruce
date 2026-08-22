## Why

Ponytail 全仓库审计确认 `rust/Bruce-collector` 存在约 1100 行无生产调用方的代码和 4 个零引用依赖. 这些死代码增加维护面并掩盖真实数据流 (例如两个真实 SQLite 数据源各自手写查询, 而通用查询机制无人使用), 应在纯 Rust 迁移刚完成、canonical parity fixture 齐备的窗口期一次性清除.

审计中两项结论经现场核实后修正, 不进入本变更:

- `UsageAccumulator` 并非纯死代码, 它是 collector-application 生产聚合路径的载体; 仅其 `delta()` 方法没有生产调用方. `AggregateDelta` 是 `UsageContribution` 的兼容别名, `merge_delta()` 仍在生产路径使用; `ModelDelta`/`ProjectDelta` 仍属于 domain contribution 序列化结构, 不删除.
- `cpu_user_ms`, `peak_rss_bytes`, `retry_count` 等恒为空指标字段被既有 `incremental-collector-refresh` 规格的 SHALL 条款要求记录, 本变更不得删除.

## What Changes

- 删除零调用方机制: collector-local 的 `sqlite.rs` 通用有界查询机制 (`SqliteBoundedQuery`/`read_bounded_sqlite_rows`/`check_sqlite_schema`/`SqliteLimits`; opencode/zcode 数据源均走 `sources.rs` 自有查询), 以及 collector-runtime 的 SQLite permit 和对应 SQLite 专用 limits 字段. 真实 SQLite 数据源、`sqlite_rows_read` 指标和 `rusqlite` 依赖保留.
- 删除不可达脚手架: collector-aggregate 的 `PricingTable`/`Pricing`/`estimate_cost`, 同时移除 `UsageAccumulator::finalize` 的可选 pricing 参数. 当前生产和 canonical fixture 均传 `None`, 因此 artifact 的现行 `null` 成本语义保持不变; 这是删除未接入的潜在成本估算能力, 必须由任务和测试明确覆盖.
- 删除仅测试引用的公共项: `retain_previous_artifact` (domain), `scan_tree` + `visit_tree` (local, 当前生产入口是 `scan_tree_cached_with_sink`), `runtime_limits_request` 与 `parse_json_body` (provider, 连同其自测), `UsageAccumulator::delta()`, 角色字符串常量 (`PROVIDER_ROLE` 与 `SUPPORTED_PROVIDER_APPS`), `CODEX_RETRY_MAX_ATTEMPTS`.
- 删除纯透传包装: collector-credential 的 `AccountRefreshCoordinator` (调用方直接使用 `AccountSingleFlight`).
- 保留运行时限额校验: 虽然当前生产入口传 `RuntimeLimits::default()`, `RunContext::new` 仍接受限额配置, 且 `InvalidLimits` 还被 `BoundedQueue::new` 使用; 本变更只移除 SQLite 专用字段和 permit, 不删除通用校验错误路径.
- 暂不合并重复 base64 解码: credential 返回原始 bytes, provider 返回 UTF-8 text, 共享位置会改变 crate 依赖方向; 该优化另立变更.
- 收缩单调用方参数与字段: `resolve_service_catalog` 移除恒为 `None` 的 `target_apps` 参数; `ProviderRequest.service` 字段若经编译器证实零读取则移除.
- 迁移测试后删除便利入口: `LocalScanResult` + `scan_tree_cached` (测试改用 `scan_tree_cached_with_sink` 和测试内 contribution 汇总).
- 清理 Cargo 直接依赖声明: collector-provider 移除源码零引用的 `url`, `idna`, `idna_adapter`, `zeroize`; 这些包仍可能由 `ureq`/`rustls` 作为传递依赖保留在 Cargo.lock.

明确不做 (超出死代码范畴或受契约保护):

- 不合并 `UsageAccumulator` 与 `UsageContributionBuilder` 的整体结构 (涉及 artifact 成型路径重构, 另立变更).
- 不删除 `ModelDelta`、`ProjectDelta`、`UsageContribution` 或其底层结构; 如删除 `AggregateDelta` 兼容别名, 必须改 `merge_delta` 为直接接收 `UsageContribution`.
- 不修改 Bridge v1 契约, artifact 字段, 指标输出语义, capability 白名单和凭证行为.
- 不触碰 `physical_disk_read_bytes` 公共重导出 (matrix-fixture bin 在用).

## Capabilities

### New Capabilities

- `rust-collector-maintainability`: Rust Collector 的生产数据流和现行 artifact 契约必须在死代码清理后保持可验证, 且已删除的旧机制不得重新进入 workspace 生产路径.

### Modified Capabilities

None. 不改变任何既有需求语义: artifact v1 兼容性, Bridge 行为, 缓存与并发语义, 指标字段集均保持不变. 实现必须通过既有 cargo workspace 测试与 parity fixture 门禁证明行为等价.

## Impact

- **Rust**: `rust/Bruce-collector/crates/` 下 collector-aggregate, collector-local, collector-provider, collector-credential, collector-runtime, collector-domain 的源码与内联测试; `crates/collector-provider/Cargo.toml` 依赖表. 预计净删约 500-800 行 (不含测试迁移带来的少量改写).
- **契约**: 无变化. Bridge v1, artifact 结构, metrics 输出, 服务排序, previous artifact 语义均不动.
- **验证**: `cargo test --manifest-path rust/Bruce-collector/Cargo.toml --workspace`, `cargo clippy --workspace --all-targets`, `cargo fmt --check`, 以及 `zsh scripts/verify-local.sh` 全量门禁; 涉及聚合路径的任务以 canonical parity fixture 通过为准.
- **风险**: 删除为编译器可验证的机械操作; 最大风险点是 pricing 参数移除、SQLite limits 与 `ProviderRequest.service` 的连带清理, 以 `cargo check`/`cargo test` 和 artifact fixture 差分为准逐级收敛.
