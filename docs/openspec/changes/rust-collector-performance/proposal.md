## Why

Bruce 已完成从脚本 Collector 到 Rust Collector 的运行时切换. 本变更记录 Rust 迁移后的性能优化、兼容性验证和发布边界, 重点解决 182 天窗口和较多账号下的刷新耗时、CPU、IO 与 memory 占用.

## What Changes

- 新增签名的 Rust `Bruce-collector` 独立进程, 通过既有 stdin/stdout Bridge v1 与 Swift App 通信.
- 保持 artifact v1、状态、诊断、服务排序、scope refresh、previous artifact 和凭证更新语义兼容.
- Preview 与 Release 共用 Rust runtime seam; 运行时缺失时 fail-closed, 不提供脚本 fallback.
- 为 JSONL、rollout 和只读 SQLite 引入版本化、可重建且不保存敏感数据的增量扫描 cache.
- 对本地扫描、只读 quota 请求和账号凭证任务设置有上限的并发、去重、取消和 backpressure.
- 建立 canonical parity fixture、资源指标、性能基线、包内容安全扫描和回滚验收.
- 保留 Swift `RefreshScheduler`、`RefreshExecutionPipeline`、Keychain 写回协调和 UI, 不引入复杂 Swift/Rust FFI.

## Capabilities

### New Capabilities

- `rust-collector-runtime`: Rust Collector 的 Bridge v1 进程边界、请求/响应、运行时选择、凭证副作用和 Release 打包要求.
- `incremental-collector-refresh`: 本地增量扫描、派生 cache、受控并发、资源指标和失败回退策略.
- `collector-parity-validation`: canonical fixture、性能基线、资源/安全扫描和 Rust cutover 门禁.

### Modified Capabilities

- None. 既有 `theme-presentation` capability 不改变; 本变更要求实现保持现有 Collector/Artifact 行为兼容, 不修改既有产品需求语义.

## Impact

- Rust: 新增 `rust/Bruce-collector/` Cargo workspace、domain/local/aggregate/provider/credential/bridge crates 和 binary.
- Rust/Bridge: 增加只读性能指标与脱敏 fixture 采集, 并由 Rust Bridge 统一输出.
- Swift: `CollectorRunner` 下方增加 `CollectorExecutable` seam, 运行时探测和 Release manifest 校验; `RefreshScheduler` 与 UI 保持调用方式.
- Packaging: `scripts/runtime-manifest.zsh`、Preview/Release 构建和签名扫描只允许 Rust runtime 文件.
- Tests: Rust workspace tests、canonical fixture、cache invalidation/资源 benchmark、Swift Runner/runtime fail-closed tests.
- Data: `~/Library/Application Support/Bruce/collector-cache-v1/` 只存可重建派生数据和文件元数据, 不提交仓库、不包含 token 或原始会话.
