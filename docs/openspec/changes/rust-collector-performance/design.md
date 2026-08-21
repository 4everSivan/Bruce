## Context

Bruce 当前通过 `CollectorRunner -> Rust Bruce-collector` 完成采集. 该边界承担 stdin/stdout Bridge v1、超时、取消、`runId`、artifact 校验和凭证更新返回, Swift 的 `RefreshScheduler` 与 `RefreshExecutionPipeline` 也已经完成去重、scope 和 Codex recovery 逻辑.

开发文档 014 已确定生产实现使用 `rust/Bruce-collector/`, 采用独立进程而不是 Swift/Rust 双向 FFI. 本次实现还必须解决 182 天窗口下历史文件重复扫描、SQLite 重复读取、外部额度请求串行和中间对象造成的刷新耗时与资源问题.

约束:

- Bridge v1、artifact v1、状态、服务排序、失败保留和 credential update/challenge 语义必须兼容.
- App 模式凭证由 Swift 注入; Rust 返回更新, Swift 继续负责 Keychain 写回.
- 第三方 SQLite 只读, cache 可删除并重建, 不保存原始会话或 token.
- Preview 与 Release 都只使用 Rust; runtime 缺失时 fail-closed.

## Goals / Non-Goals

**Goals:**

- 先以脱敏 fixture 和基线指标冻结既有行为.
- 建立 Rust 独立进程和窄的 `CollectorExecutable` seam.
- 将纯 domain/aggregate、local reader、read-only provider、credential adapter 分层迁移.
- 通过派生 cache、流式解析和 bounded concurrency 降低 warm refresh 的 wall time、CPU、IO 和 peak RSS.
- 使用 canonical parity、资源 benchmark、secret scan、Swift Runner harness 和 Release 包扫描作为阶段门禁.

**Non-Goals:**

- 不重写 SwiftUI、刷新调度器或凭证 UI.
- 不新增 Agent/Provider、服务端同步、常驻 daemon 或自定义 RPC.
- 不改变现有数据字段、单位、四舍五入、服务顺序和错误状态.
- 不在第一阶段一次性重写全部 OAuth 协议; 先保持 adapter 行为.

## Decisions

### 1. 采用独立 Rust 进程, 保留 Bridge v1

`Bruce-collector` 从 stdin 读取一份 JSON request, 向 stdout 输出一份 response envelope. `CollectorRunner` 保留 timeout、cancel、stderr 限制和 `runId` 校验.

选择原因:

- 复用现有稳定的进程生命周期和协议测试.
- 避免 Swift/Rust FFI 的对象生命周期、错误和版本耦合.
- Release 可以通过单个签名 universal binary 控制运行时依赖.

替代方案: Swift/Rust FFI 能减少进程启动, 但会把 domain 类型和生命周期耦合到 UI, 迁移风险更高; 常驻 daemon 可减少启动但增加权限、崩溃恢复、版本升级和状态清理复杂度, 暂不采用.

### 2. 采用 deep modules 和 adapter seam

Cargo workspace 拆为 `collector-domain`、`collector-bridge`、`collector-local`、`collector-aggregate`、`collector-provider`、`collector-credential` 和 binary composition. 外部文件、SQLite、HTTP、Keychain 通过可注入 interface 进入, 不让 provider 或 reader 直接修改 artifact 或 Swift Keychain.

选择原因:

- domain/aggregate 可在无网络和无凭证条件下先完成 parity.
- local/provider implementation 可以替换, 上层只依赖 quota/usage domain 结果.
- 复杂规则集中在深模块, 减少跨层状态和重复逻辑.

### 3. 使用可重建的增量 cache

`~/Library/Application Support/Bruce/collector-cache-v1/` 保存 cache schema/version、路径 digest、file identity、size、mtime、segment fingerprint、窗口/时区/pricing/aggregation version 和派生 aggregate delta. 不保存原始行、会话文本、OAuth response 或 token.

未变化文件复用 delta; 只追加且旧 fingerprint 匹配时从安全 offset 继续; rewrite、truncate、delete、schema/version/timezone/pricing 变化或 cache 损坏时按最小安全范围失效并重算. cache 采用临时文件加原子 rename, 失败不覆盖上一次可用版本.

选择原因:

- warm refresh 的主要收益来自跳过未变化历史数据, 单纯换语言不能解决重复 IO.
- 派生 cache 可删除重建, 回滚和隐私边界清晰.

替代方案: 每轮全量重扫实现简单但无法解决核心问题; 持久化原始索引更快但扩大敏感数据存储和 schema 维护面, 不采用.

### 4. 使用固定上限的并发

默认本地扫描 worker 4、网络 worker 4、每个 SQLite 数据库 1 个 reader、同一账号 credential task 1 个, 聚合 channel 设 1,024 条 backlog. `RuntimeLimits` 统一注入, 支持取消和 deadline.

本地扫描与独立只读 quota 可并行; 同一账号的 token resolve、expiry、refresh 和 quota 串行; Codex retry/recovery 保持在初次结果判定后的既有阶段. 结果以 catalog/source index 排序后输出.

选择原因:

- 隐藏的串行等待可减少 wall time.
- 有界队列和账号 single-flight 防止 CPU、RSS、socket、Provider rate-limit 随数据量无界增长.

替代方案: 无上限 async task 可在小数据上更快, 但会把资源和限流风险转化为不稳定刷新, 不采用.

### 5. Preview 与 Release 单 Rust

Swift 使用 `CollectorExecutable` seam 和 `RustBinaryAdapter`. Preview 与 Release 都只发现随包或开发环境提供的 Rust binary; Rust 缺失、不可执行或协议失败时 fail-closed. Release manifest 不包含 Collector 源码或开发 fixture.

选择原因:

- 迁移期间可以定位真实 parity 差异并保持用户可用.
- Release 最终没有两套生产实现, 避免运行时选择不确定和包体泄露.

### 6. 以既有行为基线设置性能门禁

Phase 0 记录 wall、CPU、RSS、disk read、files/lines/rows、phase timing、HTTP 和 credential refresh 次数. 目标为 full refresh P50 -40%、P95 -30%、warm unchanged wall -60%、CPU/RSS -30%、warm disk read -60%, 且 HTTP/refresh 次数不得增加. 外部服务延迟单独分解, 不用加并发掩盖 Provider 变慢.

## Risks / Trade-offs

- [Parity 差异] 实现细节可能改变排序、四舍五入或错误分类 → 生成 golden fixture, 严格比较 artifact、status、diagnostics、updates/challenges, 运行时字段只做显式归一化.
- [Cache 漏读] 编辑器 rewrite 或不可靠 mtime 可能让追加判断失效 → 使用 identity + size + mtime + segment fingerprint, 无法证明安全时完整重建.
- [Provider 限流] 并发额度请求可能增加限流 → global/provider/account 三级预算, 保留现有 timeout、retry/backoff, 记录请求计数.
- [凭证副作用] Rust refresh 可能重复写回或改变账号顺序 → 同账号 single-flight, Swift 仍是 App Keychain owner, differential fixture 比较 update 次数和顺序.
- [Release 包错误] binary 架构/签名或 fallback 文件错误会导致启动无数据 → runtime manifest、universal 架构检查、签名/Notarization、包内容 secret scan 和 smoke test.
- [资源目标不适用于网络主导场景] 外部服务延迟可能占据绝大部分 wall time → 同时报告 Collector phase 与 HTTP wait, 分场景设定本地处理门禁.
- [Provider 回归] Provider 协议风险高 → 维持 Rust adapter 的分层测试, 每阶段可回退到上一版已签名 Bruce App.

## Migration Plan

1. Phase 0: 建立 Rust Bridge 的 phase/resource metrics、脱敏 request/response/artifact/provider/local fixtures 和 benchmark script.
2. Phase 1: 创建 Cargo workspace、Bridge skeleton、输入大小限制、stdout 单 envelope、退出码和 Runner harness.
3. Phase 2: 固化 domain/time/status/artifact/aggregate, 建立 canonical fixture harness.
4. Phase 3: 迁移一个 JSONL source, 再扩展 local source、SQLite read-only 和 cache invalidation.
5. Phase 4: 按低风险到高风险迁移 read-only quota provider, 保持请求/重试/状态契约.
6. Phase 5: 迁移文件/Keychain reader、OAuth refresh、credentialUpdates/challenges, 保持 Swift 写回.
7. Phase 6: 接入 Swift executable seam、Preview selector 和 Release readiness.
8. Phase 7-8: 做性能硬化、Preview 双跑和脱敏差分, 解决所有未分类 parity 差异.
9. Phase 9: 生成签名 universal Release, 做安装/升级/回滚验收.

回滚顺序:

- 删除或失效 cache, 回到完整 Rust 扫描.
- Preview 缺少 Rust binary 时 fail-closed.
- Release 通过正式签名的上一版 Bruce App 回滚, 不替换单个 binary.

## Open Questions

- Phase 0 实测后最终 local/network worker 上限和 response body 硬上限.
- segment fingerprint 的大小、算法和 cache entry 编码.
- 性能目标是否按机器档位分层, 以及哪些指标作为 Bruce 1.0.0 硬门禁.
- Release runner 的 Xcode、macOS、Rust target、签名和 notarization 能力.
- 脱敏 metrics 是否只保留本地 benchmark, 还是增加明确 opt-in 的汇总诊断.
