## Context

Ponytail 审计 (2026-08-21) 对 `rust/Bruce-collector` workspace 逐项核实后确认一批零调用方代码与依赖. 该 workspace 刚完成纯 Rust 迁移并建立了 canonical parity fixture 与全量 cargo 测试门禁, 是执行机械清理的安全窗口.

关键现场事实:

- collector-application 生产聚合路径 (`aggregation.rs`, `lib.rs`) 使用 `UsageAccumulator` 的 `new`/`record`/`merge_delta`/`finalize`; 仅 `delta()` 没有生产调用方. `AggregateDelta` 是 `UsageContribution` 的兼容别名, `ModelDelta`/`ProjectDelta` 仍被 domain contribution 和 local adapter 使用.
- collector-local 的 `sqlite.rs` 通用有界查询机制无生产调用方; 真实数据源 opencode/zcode 在 `sources.rs` 各自手写查询.
- 所有生产 `finalize()` 调用传 `pricing: None`; `PricingTable` 仅在 aggregate 自测中构造. Swift 侧 (`CollectorActivationGate.swift:68`) 授予 `localPricing` capability, Bridge 白名单含该条目——这是跨进程契约, 必须保留.
- 生产入口目前传 `RuntimeLimits::default()`, 但 `RunContext::new` 仍接收限额参数; `RuntimeLimits.validate()` 保护通用配置, `InvalidLimits` 也服务 `BoundedQueue` 的非法容量错误, 不在本变更删除.
- `url`, `idna`, `idna_adapter`, `zeroize` 在 `crates/collector-provider/Cargo.toml` 声明但零源码 `use`; `ureq`/`rustls` 的传递依赖仍可能保留它们.
- 既有规格 `incremental-collector-refresh` 的 SHALL 条款要求记录 CPU/RSS/retry 等指标字段; 本变更不触碰 metrics 输出.

## Goals / Non-Goals

**Goals:**

- 删除全部经核实的零调用方公共项, 私有辅助和不可达脚手架, 以编译器与测试证明行为等价.
- 移除 4 个零引用 Cargo 直接依赖声明; 不假设 `ureq`/`rustls` 的传递依赖随之消失.
- 移除已确认不可达的 pricing 脚手架, 并用 artifact 回归测试固定当前 `null` 成本语义.
- 删除 SQLite 专用限额和 permit, 保留通用 `RuntimeLimits.validate()` 与 `InvalidLimits`.

**Non-Goals:**

- 不合并 `UsageAccumulator` 与 `UsageContributionBuilder` 的结构重复 (涉及 artifact 成型路径, 另立变更).
- 不修改 Bridge v1 协议, artifact 字段, metrics 字段集, capability 白名单, 服务排序, previous artifact 与凭证语义.
- 不引入新依赖, 不在本变更合并 credential/provider 的 base64 实现.
- 不做性能优化或正确性修复.

## Decisions

### D1: 删除顺序按依赖层级自底向上

顺序: 先迁移测试 (改用存活 API), 再删叶子项 (常量, 死函数, 包装器), 最后删机制块 (`sqlite.rs`, PricingTable). 每个crate删除后立即 `cargo check --workspace`, 以报错驱动画出连带引用的准确边界 (例如 `ProviderRequest.service` 字段的移除会波及所有构造点).

替代方案: 一次性删除后集中修错——否决, 因为跨 crate 连锁错误会掩盖单个条目的真实引用边界.

### D2: 只删除 `UsageAccumulator::delta()`, 保留 domain contribution 类型

`delta()` 零调用方可直接删. `AggregateDelta` 当前只是 `UsageContribution` 的兼容别名, `merge_delta()` 仍在生产路径使用; `ModelDelta`/`ProjectDelta` 是 contribution 序列化字段, 必须保留. 如删除别名, 仅将签名改为 `UsageContribution`, 不删除底层结构. 整体结构合并 (accumulator vs contribution builder) 改动聚合语义路径, 超出死代码范畴.

### D3: 删除 SQLite 资源槽位, 保留通用限额校验

`RuntimeLimits` 中的 `sqlite_readers`、`sqlite_batch_rows`、`sqlite_max_rows` 只服务被删除的通用 SQLite 查询机制, 随之删除; `local_workers`、`network_workers`、`account_tasks`、`response_body_bytes`、`aggregate_queue_capacity` 保留. `validate()`/`budgets()`/`InvalidLimits` 继续保护剩余限额和 `BoundedQueue` 容量. provider 侧 `runtime_limits_request` (无生产调用方) 可删除.

### D4: 暂不合并 base64 实现

credential 与 provider 的两个函数输出类型和边界语义不同. 为避免把编码工具塞入 domain 或引入新的公共 crate, 本变更保留两份小型实现; 共享工具另立变更并补充独立依赖审计.

### D5: sqlite.rs 整文件删除, 不保留作未来基础

两个真实数据源已各自手写查询且稳定运行; YAGI 原则下"未来可能的通用化"不构成保留理由. git 历史即恢复路径.

## Risks / Trade-offs

- [删除项存在动态引用 (serde 字符串, 反射式注册)] → 已逐项检索源码与 fixture; `cargo test --workspace`、Clippy 和 artifact fixture 门禁兜底.
- [`ProviderRequest.service` 实际被宏或 trait 默认方法读取] → D1 的逐级 `cargo check` 会立即暴露; 若证实有读取则该项退出本变更.
- [测试迁移改变覆盖语义] (`scan_tree_cached` 的测试改走 `_with_sink`) → 迁移时保持相同输入断言; parity fixture 验证生产行为不受影响.
- [与 rust-collector-performance 变更的工作树改动冲突] → 当前工作树已完成 Rust-only cutover; 实施前按文件检查现有 diff, 不覆盖用户未提交改动.

## Migration Plan

纯仓库内机械删除, 无部署步骤. 回滚 = git revert 单一 commit. 实施按 crate 分组提交, 每个 commit 保持 `cargo test --workspace` 绿.

## Deferred Follow-up

- credential/provider base64 合并不属于本变更. 若后续需要共享, 另立变更评估 `base64` 直接依赖、crate 依赖方向、输出类型和敏感数据边界.
