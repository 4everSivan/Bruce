## ADDED Requirements

### Requirement: 面板映射缓存

系统必须 (MUST) 缓存 `PanelViewModel` 映射结果, 当且仅当输入 (artifact, moduleStatuses, deepSeekMonthlyUsage, subscriptionProviderOrder) 未变更时返回缓存值. 任何一个输入变更后, 下次调用必须重算.

#### Scenario: artifact 变更后缓存失效

- **WHEN** 刷新完成, scheduler 回调 `setArtifact` 写入新 artifact
- **THEN** 下次 `makePanelViewModel()` 重算, 不返回旧缓存

#### Scenario: 模块状态变更后缓存失效

- **WHEN** scheduler 回调 `setStatus` 更新模块运行状态
- **THEN** 下次 `makePanelViewModel()` 重算

#### Scenario: 输入未变更时返回缓存

- **GIVEN** 已调用过一次 `makePanelViewModel()`
- **WHEN** SwiftUI 多次求值 body 触发 `makePanelViewModel()`
- **THEN** 返回缓存的 `PanelViewModel`, 不执行映射计算

#### Scenario: DeepSeek 月度变更后缓存失效

- **WHEN** `updateDeepSeekMonthlyUsage` 写入新的月度状态
- **THEN** 下次 `makePanelViewModel()` 重算

### Requirement: 菜单栏标签摘要缓存

系统必须 (MUST) 缓存 `MenuBarSummary`, 复用 `AppModel` 的 artifact 解码缓存. 缓存失效策略与面板映射一致.

#### Scenario: 复用解码缓存

- **GIVEN** `makePanelViewModel()` 已解码 artifact
- **WHEN** `makeMenuBarSummary()` 被调用
- **THEN** 不重复执行 `ArtifactValidator.validate`, 复用已解码的 `AgentUsageArtifact`

#### Scenario: 状态变更后摘要失效

- **WHEN** 模块状态或 artifact 变更
- **THEN** 下次 `makeMenuBarSummary()` 重算

## MODIFIED Requirements

### Requirement: 启动时凭证状态发布

系统在启动时发布全部 provider 的凭证状态, 必须 (MUST) 最小化 Keychain 读取次数. 每个 provider 的 account-index 在一次启动发布流程中只读取一次.

#### Scenario: publishSubscriptionState 合并读取

- **WHEN** `SubscriptionService.init` 调用 `publishSubscriptionState`
- **THEN** 先执行 `publishAllProviderAccountSummaries` (每个 provider 一次 `loadIndex`), 再从已发布的 summaries 推导 `credentialConfigured`, 不再逐个实时读 Keychain

#### Scenario: credentialConfigured 优先读已发布 summaries

- **GIVEN** `providerAccountSummaries` 已发布到 `AppModel`
- **WHEN** `credentialConfigured(id)` 被调用
- **THEN** 优先从 `model.providerAccountSummaries[id]` 判断是否有 connected 账号; summaries 为空时回退到实时 Keychain 检查

### Requirement: ProviderAccountStore 实例复用

`SubscriptionService` 必须缓存 `ProviderAccountStore` 实例, 同一 provider 的多次访问复用同一实例, 避免 (MUST NOT) 重复创建.

#### Scenario: 多处访问同一 provider 的 store

- **GIVEN** `publishAllProviderAccountSummaries` 和 `credentialConfigured` 都需要访问 Kimi 的 store
- **WHEN** 在一次启动流程中先后访问
- **THEN** 复用同一 `ProviderAccountStore` 实例, 不创建新实例

### Requirement: 迁移复用已创建的 store

`OnboardingRunInputProvider.accountStores` lazy var 在初始化时必须 (MUST) 复用已创建的 store 实例执行迁移, 不得 (MUST NOT) 独立创建新 store 做迁移.

#### Scenario: accountStores 初始化时迁移

- **WHEN** `accountStores` lazy var 首次被访问
- **THEN** 先创建 6 个 provider 的 store, 再用这些 store 实例执行迁移, 不额外创建 store

### Requirement: Antigravity 多账号查询

App 模式下 Antigravity 多账号凭证注入后, 系统必须 (MUST) 正确查询额度, 不得 (MUST NOT) 返回空结果.

#### Scenario: App 模式注入 Antigravity 多账号凭证

- **GIVEN** `OnboardingRunInputProvider` 注入 `antigravityQuotaAccounts`
- **WHEN** `service_antigravity` 被调用
- **THEN** 从 `antigravity_quota_accounts` 读取第一个账号的 oauth 凭证执行查询, 返回额度结果

#### Scenario: service_catalog 不重复创建 Antigravity 条目

- **WHEN** `service_catalog._resolve_app` 处理 Antigravity 多账号凭证
- **THEN** 跳过 `_Resolved` 条目创建 (由 `service_antigravity` 统一处理), 避免重复创建空条目

## REMOVED Requirements

### Requirement: providerEnv 凭证注入

`CollectorRunInput.assembleSubscriptionCredentials` 中的 `providerEnv` 字典从未被写入, `if !providerEnv.isEmpty` 分支永远不执行. 删除该死代码.

#### Scenario: 删除后行为不变

- **GIVEN** App 模式刷新
- **WHEN** `assembleSubscriptionCredentials` 组装凭证
- **THEN** 不再声明 `providerEnv` 变量, 不再写入 `credentials["providerEnv"]`, Bridge 请求不含该键, 行为与删除前一致 (删除前该键也从未被写入)
