# Rust Codex 多账号额度链路补齐设计

日期: 2026-08-21

## 背景与现场证据

新版本 App 已经把 Codex 账号凭证注入 Bridge request, `CollectorRunInput` 也会携带 `codexQuotaAccounts` 和 `codexQuotaAccountOrder`. Swift 侧的 `CodexQuotaSnapshotMerger` 会等待每个注入账号对应的 Codex service; 如果首轮和 retry artifact 都没有该 service, 就记录 `CODEX_ACCOUNT_RESULT_MISSING` 和“未返回该账号额度结果”.

当前 Rust `collector-application` 的账号字段表只注册 Kimi、OpenCode Go、DeepSeek、智谱、火山、Claude 和 Grok, 没有注册 `codexQuotaAccounts`. 因此带有 Codex 账号的请求在 Rust 账号规划阶段被静默跳过, 最终服务列表为空, Swift 只能把历史结果降级为 stale. 这解释了现场快照中两个 Codex service 都是 `status:error`、note 为“未返回该账号额度结果”, 而其他订阅服务正常的现象.

## 目标

- Rust production collector 能按注入账号查询 Codex 额度, 每个账号独立产生可合并的 service.
- 保持现有 Bridge v1、artifact v1、service ID、窗口标签、账号顺序、失败保留和 stale 语义.
- 保留现有 Swift `CodexQuotaRecovery` 的 challenge/retry 协调, Rust 只返回结构化结果、credential update 和 credential challenge.
- 一个账号失败不能吞掉其他账号成功结果, 也不能把配置错误伪装成成功空数据.
- 不在 Rust 直接写 App Keychain 或第三方认证数据库, 不在日志和诊断中输出 token.
- 用脱敏 fixture 覆盖成功、部分失败、认证 challenge、限流/服务端错误、异常响应和多账号顺序.

## 非目标

- 不修改 Codex 设置页、账号删除 UI、Keychain 存储模型或 Swift recovery 流程.
- 不把 Codex 改造成没有特殊认证语义的通用 provider.
- 不改变 Python CLI 模式的现有读取和刷新行为.
- 不使用真实账号或真实网络作为默认测试依赖.
- 不处理 OpenSpec 7.3 的签名、notarization、安装升级和回滚验收.

## 方案选择

### 采用: Rust 独立 Codex quota adapter

在 Rust 账号执行层为 `codexQuotaAccounts` 增加明确的 Codex 分支, 由 provider 层复用现有 Codex quota 兼容规则和脱敏 fixture. 账号计划来自 `codexQuotaAccountOrder`, 但只接受经过 Bridge 校验且实际存在于 credentials 的账号. provider 为每个账号返回独立 service 或结构化 challenge/diagnostic. Swift 继续负责 retry-only request、challenge 过滤、凭证写回和快照合并.

这个边界与当前 Rust 迁移设计一致: Rust 是数据采集边界, Swift 是 App credential owner 和 recovery coordinator. Codex 特有的 challenge/retry 不会被普通 provider 抽象抹平.

### 不采用的方案

- 继续由 Swift 查询 Codex 云端额度: 改动最小, 但保留两套采集实现, Rust/Swift 结果和性能难以统一.
- 直接把 Codex 塞入通用 provider: 实现较快, 但容易丢失账号级 challenge、retry-only 顺序和 `CODEX_ACCOUNT_RESULT_MISSING` 所依赖的失败语义.

## 架构与数据流

```text
Swift CollectorRunInput
  └─ codexQuotaAccounts + codexQuotaAccountOrder
       ↓ Bridge v1 validation
Rust collector-application
  └─ Codex account planner (stable order, one plan per account)
       ↓
Rust collector-provider
  └─ Codex quota adapter / response parser
       ├─ success → one codex_<stable-hash> service per account
       ├─ auth challenge → credentialChallenges
       ├─ refresh result → validated credentialUpdates
       └─ failure → account-scoped diagnostic/status
       ↓
Swift CodexQuotaRecovery
  └─ filters injected-account challenges and performs one retry-only pass
       ↓
CodexQuotaSnapshotMerger
  └─ merges services, diagnostics and stale previous data by account
```

### 账号规划

账号顺序以 `context.codexQuotaAccountOrder` 为准, 不以 JSON object 的无序遍历为准. retry-only request 只包含 Swift 选中的 challenge 账号. 账号 ID、display name 和 service ID 生成规则必须复用既有 Codex 兼容实现, 避免同一账号刷新后产生新的 service.

### Provider 边界

Codex adapter 只接收一个已解析的账号凭证和可替换的 HTTP/clock 依赖, 返回 quota domain result. 它不得访问 Swift Keychain, 不得读取 `~/.codex/auth.json` 作为 App 模式的隐式 fallback, 不得把完整 HTTP response 写入诊断. CLI 模式已有行为保持不变, 本次只补齐 App 注入账号到 Rust 的路径.

响应解析以当前 Python Codex 兼容实现和现有 provider fixture 为行为基线, 重点保持:

- Codex 服务端额度窗口的标签、单位、百分比和时间字段.
- 可诊断的 HTTP 状态分类和 malformed response 分类.
- 401/认证失效转为结构化 challenge 或账号级失败, 不伪造空额度.
- 账号级结果顺序和 credential challenge 顺序稳定.

## 错误与安全语义

- 成功账号继续输出 service; 失败账号只输出自己的 diagnostic, 不阻断其他账号.
- 未返回账号结果仍由 Swift merger 负责判定为 `CODEX_ACCOUNT_RESULT_MISSING`, Rust 不输出伪造 service.
- 认证 challenge 必须包含经过 schema 校验的 account ID 和 challenge 类型, 不包含 access token、refresh token 或完整响应体.
- credential update 只允许现有 Bridge 白名单字段, Swift 执行实际 Keychain 写回.
- token 仅存在于本次 provider 调用内存中; debug、metrics、stderr、artifact 和 test failure 输出均需经过 secret scan.
- retry 只执行一次且只针对首轮返回、同时属于本次注入账号集合的 challenge, 与现有 Swift recovery 语义一致.

## 测试设计

### Rust provider fixture

增加脱敏 HTTP fixture/client 测试, 至少覆盖:

1. 单账号成功: 输出一个 Codex service, 窗口和 service ID 稳定.
2. 多账号成功: 按 `codexQuotaAccountOrder` 输出, 不因 JSON 键顺序改变.
3. 部分失败: 成功账号保留, 失败账号有诊断, 不生成空成功 service.
4. 401 或认证 challenge: 输出合法 `credentialChallenges`, 不泄漏凭证.
5. 429/5xx/timeout: 分类保持现有语义, 不把失败变成零用量.
6. malformed/缺字段响应: 返回可诊断错误, 不 panic, 不发布伪造额度.
7. retry-only: 只执行 challenge 账号, 重复 challenge 和未知账号被过滤.

### 应用与 Swift 集成

- 注入 `codexQuotaAccounts` 的 sanitized Bridge request 不再得到空 service 列表.
- 无 Codex 账号时不新增 provider 请求或 service.
- 现有 `CodexQuotaRecovery` 和 `CodexQuotaSnapshotMerger` harness 全部通过.
- previous artifact、stale、账号删除/排序和 partial provider failure 的既有断言不回归.

### 验证命令

- `cargo test --workspace`.
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`.
- Codex fixture differential/parity 检查和 secret scan.
- `swift build --package-path macos/BruceApp`.
- Codex 相关 Swift harness、`CollectorRunnerHarness` 和 `RefreshSchedulerHarness`.
- `zsh scripts/build-test-app.sh`, 再用隔离 fixture 执行 bundled Rust collector smoke.

默认不调用真实 Codex endpoint; 只有用户明确授权现场账号验证时, 才单独执行真实额度请求, 并保留原有 Production Operation Mode 和凭证副作用约束.

## 验收标准

本设计完成的必要结果是: 当前两个 Codex 注入账号在相同凭证和配置下, Rust 首轮至少返回成功 service 或账号级可诊断 challenge/failure, 不再因为 provider 未注册而产生空服务列表; challenge 账号能沿现有 Swift recovery 完成一次 retry; 多账号顺序、状态、窗口、stale 和安全边界通过 fixture 与 harness 验证.
