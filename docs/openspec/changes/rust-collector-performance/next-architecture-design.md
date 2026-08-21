# Rust Collector 后续架构迁移设计

状态: 已完成设计确认, 待用户审阅文档.

日期: 2026-08-21.

## 1. 设计结论

Bruce 的 Rust 重构采用三项 deepening 一体化推进:

1. 新增 `collector-application` module, 作为 Rust 采集的唯一 application orchestration 入口.
2. 由 application 统一编排 Provider、credential 和 runtime 的账号执行 seam.
3. 将 local、cache 和 aggregate 之间改为 domain-level contribution/change stream, 隐藏 JSONL、SQLite、cache 和删除重算细节.

迁移保持以下既有契约不变:

- `Bridge v1` stdin/stdout envelope、request 校验、runId、timeout、cancel 和退出语义.
- `artifact v1` 字段、单位、四舍五入、空值/空数组区别、稳定排序和状态类别.
- Swift `CollectorExecutable`、`CollectorRunner`、`RefreshExecutionPipeline` 以及上一份 artifact 的保留语义.
- App 模式凭证注入、`credentialUpdates`/`credentialChallenges` 校验和 Swift Keychain 写回归属.
- Release 只有 Rust 采集实现; Python 仅作为 Debug/Preview adapter.

本设计不把 Python/Rust 并行双跑作为 Release 架构, Python/Rust 差分只用于 fixture 和迁移验证.

## 2. 当前状态与问题

当前生产执行链路为:

```text
Swift CollectorRunner
  -> Bruce-collector binary
  -> collector-bridge::run_bytes
  -> collect_agent_usage
  -> collector-local::scan_tree_cached
  -> collector-aggregate::UsageAccumulator
```

当前 Rust workspace 已有 `collector-domain`、`collector-bridge`、`collector-local`、`collector-aggregate`、`collector-provider`、`collector-credential`、`collector-runtime` 和 binary target. 但存在三个结构性问题:

- `collector-bridge` 同时承担协议校验、能力判断、本地采集、artifact 组装和占位服务生成, interface 与 implementation 过近.
- Provider、credential 和 runtime 虽然已有实现, 但尚未通过真实的 application orchestration seam 进入完整生产执行路径.
- local 直接持有 aggregate accumulator, cache、source parser、文件变更和聚合实现互相泄漏, 限制了 warm refresh 和删除重算的 locality.

删除测试表明: 移除当前 Provider workspace 成员基本不改变 binary 的实际采集路径; 删除 runtime permit/queue 也基本不改变当前行为. 这说明这些 module 需要接入真实执行 seam, 而不是继续增加孤立的 helper.

## 3. 目标架构

### 3.1 依赖方向

```text
                         ┌─────────────────────┐
stdin/stdout             │ collector-bridge    │
Swift Runner ───────────>│ protocol + envelope │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │ collector-application│
                         │ run orchestration   │
                         └───┬─────┬─────┬─────┬┘
                             │     │     │     │
                  ┌──────────┘     │     │     └──────────┐
                  ▼                ▼     ▼                ▼
             collector-local  aggregate provider     credential
                  │                │     │                │
                  └────────────────┴─────┴────────────────┘
                                   │
                                   ▼
                         collector-domain

                         collector-runtime
                         为 application 与各 adapter 提供
                         deadline / cancel / budget / queue
```

目标依赖规则:

- `collector-domain` 只包含值对象、artifact 规则、状态和 contribution 类型, 不依赖文件系统、SQLite、HTTP、Keychain 或网络.
- `collector-application` 是唯一 composition module, 依赖 domain、local、aggregate、provider、credential 和 runtime.
- `collector-bridge` 只负责 request/response 协议、安全白名单、大小限制和 envelope, 不直接调用 local、Provider 或 credential implementation.
- `collector-local` 不依赖 Provider/credential, 不直接持有 `UsageAccumulator`.
- `collector-aggregate` 只消费 domain-level contribution/change, 不读取文件、SQLite 或网络.
- `collector-provider` 只负责 catalog、HTTP、parser 和 quota adapter, 不读取 Keychain, 不修改 artifact.
- `collector-credential` 只负责 credential source、expiry、refresh、update/challenge, 不直接修改 Swift Keychain.
- `collector-runtime` 不知道 Provider 业务, 只提供通用的 deadline、cancel、permit、bounded queue 和 account single-flight.
- binary target 只负责读取 stdin、调用 bridge、序列化 stdout, 不承载业务编排.

这组 seam 的 deletion test 是: 删除 application 会迫使排序、降级、凭证合并和资源限制重新散回 Bridge、Provider 和 Swift; 删除它会集中而不是转移复杂度, 因此 application 是值得 deepening 的 deep module.

### 3.2 Application orchestration

`collector-application` 创建单次 run 的 `RunContext`, 并拥有以下职责:

- 解析 collection window、timezone、capabilities 和 request limits.
- 建立 cancellation/deadline 传播链和 runtime budgets.
- 规划 local source、SQLite source、Provider catalog 和 account execution.
- 并行启动 local scan 与 external quota, 控制任务数量和 queue backlog.
- 收集 source change、quota result、diagnostics、credential updates/challenges.
- 在结果层统一排序、合并、状态降级和 artifact 序列化.
- 把协议级错误和业务级 partial 结果交给 Bridge 形成最终 envelope.

Application 不拥有原始凭证、原始会话或 Swift Keychain, 只在 run 生命周期内持有已注入的 credential view 和派生结果.

### 3.3 RunContext 与资源预算

`RunContext` 的逻辑内容包括:

- `runId`、采集时间、collection window、timezone.
- capabilities、目标 Provider/账号 descriptor 和 App/CLI 模式.
- `RuntimeLimits`、deadline、cancellation token.
- diagnostics collector、credential update/challenge collector.
- local cache version、pricing version 和 aggregation version.

runtime 统一提供:

- local worker permit.
- network worker permit.
- SQLite reader permit.
- account single-flight key, key 为 `provider + accountId`.
- response body 上限.
- aggregate bounded queue.
- cancellation/deadline 检查.

local 与 quota 可以并行, 但同一账号的 credential resolve、expiry check、refresh 和 quota 请求必须 single-flight. Provider adapter 不自行创建无上限任务, 所有任务都通过 RunContext 的 budget.

### 3.4 Provider 与 credential 执行 seam

账号级执行顺序为:

```text
catalog descriptor
  -> credential source resolve
  -> expiry / refresh decision
  -> account single-flight
  -> Provider adapter request
  -> bounded response parse
  -> quota domain result
  -> deterministic service result
```

Provider module 内部按职责组织为:

- catalog: Provider/账号 descriptor、稳定排序、目标筛选和 duplicate 检查.
- transport: HTTP request/response、timeout、response body 上限和 fixture client seam.
- adapter: 每个 Provider 的 request、签名、parser 和 quota domain mapping.
- result finalizer: `ok`、`empty`、`partial`、`error` 的统一映射.

Credential module 内部按职责组织为:

- source reader: App 注入值、文件和 Keychain 只读读取.
- expiry: 统一过期判定和时间单位处理.
- refresh coordinator: 同账号 single-flight、refresh retry 和更新记录.
- update/challenge validator: 只输出脱敏、结构合法的 update/challenge.

Rust 可以在受控 run 内执行必要的 token refresh, 但不直接写 Swift App Keychain. Swift 收到 `credentialUpdates` 后继续交给 `CredentialUpdateCoordinator` 写回; 失败只产生可诊断结果, 不阻塞其他账号 artifact 发布.

### 3.5 Local、cache 与 aggregate seam

新增 domain-level 的派生结果类型:

- `UsageContribution`: 不含原始会话内容和凭证的可聚合 usage contribution.
- `SourceDeltaChange`: 某个 source 的旧 contribution 移除和新 contribution 加入.

local module 对外输出 bounded change stream, 不暴露 parser、directory walker、SQLite connection 或 cache encoding. aggregate module 消费 change stream, 并负责 pricing、time window、token/cost/day/model/project fold.

cache 只保存以下派生信息:

- source identity、path digest、size、mtime、segment fingerprint、safe offset.
- cache schema/version、window/timezone/pricing/aggregation version.
- 每个 source 的派生 `UsageContribution`.

cache 不保存原始 JSONL、会话文本、OAuth response、access token 或 refresh token. 读写使用临时文件和 atomic rename, 损坏时不得覆盖上一份可用 cache.

变更规则:

| 文件状态 | local 输出 |
|---------|------------|
| unchanged | 不输出 change |
| append 且 fingerprint/offset 可证明安全 | 只输出新增 contribution |
| rewrite/truncate | 移除旧 contribution, 重算并加入新 contribution |
| delete | 移除旧 contribution |
| cache 版本、pricing、timezone 或 aggregation 变化 | 按安全范围重建 |
| cache 损坏或无法证明 append 安全 | 完整重建 |

application 通过 bounded queue 把 change 交给 aggregate, 不把 182 天全量历史记录一次性加载到内存.

## 4. 单次 run 数据流

```text
1. Bridge 读取并限制 request
2. Bridge 校验 schema、runId、timeouts、capabilities、credential scope
3. Application 创建 RunContext 和 RuntimeBudgets
4. 并行启动 local scan 与 quota catalog/account tasks
5. local 读取 cache, 解析增量 source, 推送 SourceDeltaChange
6. aggregate 消费 change, 生成 local usage aggregate
7. credential resolver 为账号执行只读读取/必要 refresh
8. Provider adapter 通过 bounded HTTP client 查询 quota
9. application 合并 local artifact、quota services、diagnostics 和 update/challenge
10. application 按固定 catalog/source 顺序完成 artifact/status
11. Bridge 验证 credential outputs, 写出唯一 JSON response envelope
12. Swift 校验 runId, 发布 artifact, 应用 credentialUpdates, 保留上一份结果语义
```

local 与 quota 的并行不改变输出顺序. 所有稳定数组在 application finalization 阶段按 catalog、source、account 和 model 规则排序.

## 5. 错误与状态语义

| 错误范围 | 处理 |
|---------|------|
| Bridge schema、字段、凭证范围、大小或序列化失败 | fail closed, 不生成伪造 artifact |
| 单个本地文件或 SQLite 失败 | 保留其他结果, `partial` + local diagnostic |
| 单个 Provider 或账号失败 | 该账号 `error/partial`, 其他账号继续 |
| credential 过期且 refresh 失败 | 输出 challenge/diagnostic, 不写回无效 token |
| Provider timeout、限流或可重试网络错误 | 记录 retryable diagnostic, 不阻塞其他账号 |
| 全局 cancel/deadline | 终止当前 run, Swift 保留上一份有效 artifact |
| 全部数据源不可用 | 不伪造 `empty`/`not_found`, 返回失败诊断并保留上一份结果 |

错误消息必须脱敏. Provider 原始 response、token、Keychain 值和 session 内容不得进入 stdout、artifact、diagnostic 或 cache.

## 6. 迁移切片

### Slice A: Application orchestration

目标:

- 新增 `collector-application` crate/module.
- 将 Bridge 的业务编排迁入 application.
- 保持现有 local + aggregate 行为和 artifact parity.
- Bridge 仅保留协议转换、验证、credential output validation 和 envelope.

完成条件:

- binary 只通过 Bridge -> application 进入采集.
- Python/Rust canonical artifact、status、diagnostics 完全一致.
- local-only differential、cancel、timeout、runId 和 previous artifact Swift harness 通过.

### Slice B: Provider / credential / runtime

目标:

- application 接入 catalog、credential resolver、Provider adapter 和 runtime budget.
- local 与 external quota 并行.
- 同账号 credential/provider single-flight.
- 保持 Codex retry-only 和 token manager ownership.

完成条件:

- Provider fixture client 与受控 HTTP fixture 覆盖成功、空额度、错误、超时、限流和 malformed response.
- credential fixture 覆盖文件、Keychain、过期、refresh、update、challenge 和 secret scan.
- 多账号 catalog 顺序、去重、失败隔离和 `credentialUpdates` parity 通过.
- account-scale benchmark 证明并发没有增加请求次数、重复 refresh 或资源峰值.

### Slice C: Local/cache/aggregate isolation

目标:

- 引入 `UsageContribution` 和 `SourceDeltaChange`.
- local 不再直接持有 `UsageAccumulator`.
- cache 对 parser、SQLite、文件遍历和 aggregate 隐藏.
- aggregate 只消费 bounded change stream.

完成条件:

- unchanged、append、rewrite、truncate、delete、cache corrupt、schema/version invalidation 全部 parity.
- 不重复计数, 删除能移除旧 contribution.
- warm refresh 的 disk read、wall time、CPU 和 RSS 满足门禁.
- cache 不含 raw session、OAuth 或 credential secret.

## 7. 性能与资源门禁

以当前隔离 HOME、无网络、无真实凭证的 Python 基线和 Rust 结果为基准, 继续区分:

- cold/warm process wall time.
- P50/P95 wall time.
- parent/child CPU time.
- peak RSS.
- disk read bytes、files、lines、rows.
- phase timing、HTTP request count、retry count、credential refresh count.

目标保持开发文档 014 已确认的方向:

- full refresh P50 至少降低 40%.
- P95 至少降低 30%.
- unchanged warm refresh wall time 至少降低 60%.
- CPU 和 peak RSS 至少降低 30%.
- warm disk read 至少降低 60%.
- HTTP、retry 和 credential refresh 次数不得因并发增加.

网络主导场景必须单独报告 HTTP wait 与 Collector processing, 不用增加并发掩盖 Provider 变慢.

## 8. 测试与发布门禁

### Contract tests

- Python/Rust canonical artifact、status、diagnostic、stable arrays 严格差分.
- credential updates/challenges 只允许显式运行时字段归一化.
- Bridge stdout 单 envelope、stderr 分离、大小限制、runId、cancel 和 timeout.

### Module tests

- domain window/status/contribution 纯逻辑测试.
- local parser、SQLite read-only、cache hit/append/rewrite/delete/rebuild 测试.
- aggregate change stream、pricing、dedupe 和排序测试.
- Provider parser、transport limits、retry/error mapping、catalog 测试.
- credential source、expiry、refresh single-flight、redaction 测试.
- runtime permit、queue、cancel、deadline、account single-flight 测试.

### Integration and release tests

- application fake adapter 集成测试, 不触碰真实凭证.
- 多账号 HTTP fixture account-scale benchmark.
- `python3 scripts/check-collector-fixtures.py` secret scan.
- `python3 scripts/differential-collector.py --request tests/fixtures/bridge/agent-usage/request-valid.json --rust rust/Bruce-collector/target/debug/Bruce-collector` parity.
- `CI=true zsh scripts/verify-local.sh` 全套本地验证.
- Release bundle 拒绝 Python fallback、source、data、fixture、secret 和错误架构.
- universal Rust binary、Developer ID、notarization、staple、spctl、安装升级、旧 cache 重建和 rollback.

## 9. 回滚与安全边界

- 每个 slice 通过独立 commit/变更边界保留上一版 Rust module, 失败时回退到上一 slice.
- cache schema 变化只能新增 version; 发现不兼容时删除派生 cache 并 cold rebuild.
- Rust 不写第三方 SQLite, CC Switch 和 Antigravity 数据库继续使用 read-only URI.
- Rust 不直接写 Swift App Keychain, credential update 只能经 Swift coordinator 写回.
- Release 不通过运行时 flag 恢复 Python fallback; 生产回滚使用上一版已签名 Bruce App.
- Preview 可以选择 Python adapter 做对照, 但不得把 Preview fallback 打入 Release binary.
- 所有 benchmark、fixture、诊断和日志使用脱敏数据, 不把真实 token、session 或 OAuth response 写入仓库.

## 10. 非目标

- 不重写 SwiftUI、PanelViewModel、RefreshScheduler 或设置 UI.
- 不新增 Provider、Agent、服务端同步、常驻 daemon 或自定义 RPC.
- 不改变 artifact 字段、单位、排序、状态或用户可见语义.
- 不把原始 session、OAuth response 或 token 持久化进 Bruce cache.
- 不在第一阶段引入 Swift/Rust FFI.
- 不把 Python 作为 Release 运行时依赖.

## 11. 最终验收标准

只有同时满足以下条件, 才能把 Python Collector 标记为“已由 Rust 生产替代”:

1. Slice A/B/C 的 differential parity、错误语义和 credential output 全部通过.
2. local warm/append/rewrite/delete/cache rebuild 的 correctness 和性能门禁全部通过.
3. 多账号 quota 的 account-scale fixture 证明并发、single-flight、retry 和资源预算有效.
4. Rust/Swift/Python fixture/security/standard verification 全部通过.
5. Release 包只含签名、可执行、目标架构正确的 Rust Collector, 不含 Python fallback 或敏感数据.
6. 安装、升级、旧 cache 重建和回滚演练完成.
7. Developer ID、notarization、staple、spctl 证据齐全.

在第 7 项发布证据完成前, 只能称为“Rust 已接入 Release 路径并完成本地验证”, 不能称为 Release cutover ready.
