## Context

仪表盘启动和展示流程涉及四个主要链路:

1. **App 启动** (`MdddApp.init` -> `ApplicationBootstrap.startIfNeeded`): 创建 `OnboardingRunInputProvider` -> 创建 `OnboardingCoordinator` (内含 `SubscriptionService`) -> 启动 `RefreshScheduler` -> 扫描就绪度.
2. **凭证状态发布** (`SubscriptionService.init` -> `publishSubscriptionState`): 迁移旧凭证 -> 遍历 7 个 provider 判断 `credentialConfigured` -> 发布 summaries.
3. **刷新采集** (`RefreshScheduler` -> `RefreshExecutionPipeline` -> `OnboardingRunInputProvider.runInput`): lazy 触发 `accountStores` (含迁移) -> `assembleSubscriptionCredentials` -> Bridge -> Python collector.
4. **面板渲染** (`MenuBarDashboardView.body` -> `model.makePanelViewModel`): 新建 `PanelViewModelMapper` -> 解码 artifact -> 全量映射. 菜单栏标签独立解码同一 artifact.

### 性能瓶颈

**面板映射无缓存**: `MenuBarDashboardView.body` 每次求值调用 `model.makePanelViewModel()`, 内部新建 `PanelViewModelMapper().make()` 全量遍历 182 天 × 5 agent 的 daily 数据构建图表、热力图、按月统计, 遍历所有 service 分组构建订阅卡, 再次遍历 agent 构建逐小时分布. SwiftUI 在滚动、动画、状态变化时多次求值 body. `MenuBarLabelView` 独立创建 `MenuBarSummaryBuilder` 解码同一 artifact, 不复用 `AppModel` 的解码缓存.

**Keychain 读取风暴**: 启动时 `publishSubscriptionState` 对 7 个 provider 逐个调用 `credentialConfigured`, 每次创建 `ProviderAccountStore` (class) + `loadIndex` (Keychain 读) + 可能的 `hasConnectedAccount` (Keychain 读). 紧接着 `publishAllProviderAccountSummaries` 对 6 个 provider 各调 `loadIndex` 两次 (校正 + summaries). `ProviderAccountStore` 全项目无缓存, 11 处创建新实例.

**迁移重复执行**: `SubscriptionService.migrateLegacyCredentials` 和 `OnboardingRunInputProvider.accountStores` lazy var 各自独立遍历 6 个 provider 创建 store 执行迁移. 生产环境 SubscriptionService 先执行并删除旧键, RunInputProvider 随后执行发现无旧键 (幂等), 但仍创建 6 个 store 实例.

### 功能缺陷

Antigravity 多账号查询在 App 模式下断裂: `OnboardingRunInputProvider` 注入 `antigravityQuotaAccounts` (新键), 不注入 `antigravityOAuth` (旧键). `service_catalog._resolve_app` 从新键创建 `_Resolved` 条目但 `_agy_query_with_inject` 返回 None -> finalize 标记 "empty". `service_antigravity` 读旧键 `antigravity_oauth` -> 未注入 -> `_APP_MODE=true` -> 返回空列表. 最终 Antigravity 额度始终显示"未取到额度数据".

## Goals / Non-Goals

### Goals

- 面板映射结果按输入版本号缓存, 输入不变时不重算.
- 菜单栏标签摘要复用 `AppModel` 解码缓存.
- `ProviderAccountStore` 实例在 `SubscriptionService` 内复用.
- 启动时 `publishSubscriptionState` 从已发布 summaries 推导 `credentialConfigured`, 避免逐个实时读 Keychain.
- `publishAllProviderAccountSummaries` 每个 provider 只调一次 `loadIndex`.
- `OnboardingRunInputProvider` 迁移复用已创建的 `accountStores` 字典.
- 删除已确认的死代码 (`providerEnv` 字典, `service_catalog` 旧格式回退分支).
- 修复 Antigravity 多账号查询.

### Non-Goals

- 不改变 `PanelViewModelMapper` 的映射逻辑本身.
- 不改变 `ProviderAccountStore` 的 Keychain 存储格式.
- 不改变 Bridge 协议或 schema (白名单保留 `providerEnv` 兼容 CLI 模式).
- 不清理 Python 模块 global 变量 (独立后续工作).
- 不改变 `CredentialUpdateCoordinator` 的 store 创建 (独立模块, 不跨调用复用).

## Decisions

### 1. 版本号缓存策略

使用整数版本号 `panelCacheVersion` 标记缓存失效. 在所有影响面板/摘要输出的 `@Published` 属性的写入点自增版本号. `makePanelViewModel` / `makeMenuBarSummary` 比较版本号, 不变则返回缓存.

失效点 (必须全部覆盖):
- `setArtifact(_:for:)` - artifact 数据变更
- `setStatus(_:for:)` - 模块状态变更
- `setSubscriptionProviderOrder(_:)` - provider 排序变更
- `invalidateDeepSeekMonthlyUsage()` - DeepSeek 月度失效
- `updateDeepSeekMonthlyUsage` 内部写入 `deepSeekMonthlyUsage` - DeepSeek 月度更新

不额外自增的点:
- `setModuleResult(_:)` - 内部调用 `setStatus`, 已覆盖
- `setMenuBarMetrics(_:)` - 不影响面板映射, 仅影响菜单栏标签的指标选择 (由 `MenuBarLabelView` 直接遍历 `model.menuBarMetrics`)

面板和菜单栏标签共享同一版本号: 面板输入 = {artifact, moduleStatuses, deepSeekMonthlyUsage, subscriptionProviderOrder}, 菜单栏标签输入 = {artifact, moduleStatuses}. 菜单栏标签是面板输入的子集, 面板失效时菜单栏标签必然失效.

### 2. ProviderAccountStore 缓存范围

`SubscriptionService` 持有 `accountStoreCache: [SubscriptionProviderID: ProviderAccountStore]`. `accountStore(for:)` 按需创建并缓存. 11 处直接创建改为调用缓存方法.

不在 `OnboardingRunInputProvider` 中跨实例缓存: `accountStores` lazy var 已是缓存, 只需消除迁移时的重复创建.

不在 `CredentialUpdateCoordinator` 中缓存: 它在刷新管线中独立运行, 每次只创建一个 store 做一次性写回, 缓存无收益.

### 3. credentialConfigured 推导路径

`credentialConfigured(_:)` 改为优先读 `model.providerAccountSummaries`:
1. 非 Codex: 检查 summaries 中是否有 connected 账号 -> 有则 true
2. summaries 为空 (尚未发布): 回退到 `accountStore(for:).loadIndex` + `hasConnectedAccount`
3. index 为空: 回退到 `legacyCredentialConfigured` (旧键检查)
4. Codex: 始终走 `legacyCredentialConfigured` (不经 ProviderAccountStore)

`publishSubscriptionState` 调用顺序:
1. `publishAllProviderAccountSummaries()` (一次遍历, 发布全部 summaries)
2. 遍历 7 个 provider, 从 `model.providerAccountSummaries` 推导 `credentialConfigured`
3. Codex 走 `legacyCredentialConfigured(.codex)` (含 `codexStore.hasConfiguredCredentials`)

### 4. publishAllProviderAccountSummaries 去重

每个 provider 只调一次 `loadIndex`:
1. `loadIndex()` -> 获得内存 index
2. 遍历 index.accounts, 对 `needsReauthorization` 且凭证非空的账号做校正 (loadRecord + updateAuthorizationState)
3. 从内存 index 构造 summaries (校正后的状态直接反映在 summaries 中, 不需重新 loadIndex)

`ProviderAccountStore` 新增 `summaries(from index: ProviderAccountIndex) -> [ProviderAccountSummary]` 重载. 原 `summaries()` 保留 (内部调 `loadIndex` 后委托给新方法), 兼容外部调用.

### 5. Antigravity 多账号修复方案

`service_antigravity` 增加 `antigravity_quota_accounts` 读取:
```python
injected_auth = _runtime_credential("antigravity_oauth")
if injected_auth is None:
    agy_accounts = _runtime_credential("antigravity_quota_accounts")
    if isinstance(agy_accounts, dict) and agy_accounts:
        first = list(agy_accounts.values())[0]
        injected_auth = (first or {}).get("oauth")
```

`service_catalog._resolve_app` 中 Antigravity 多账号分支跳过 `_Resolved` 创建 (注释说明由 `service_antigravity` 统一处理), 避免重复创建空条目.

### 6. 死代码清理范围

**Swift (`CollectorRunInput.assembleSubscriptionCredentials`)**:
- 删除 `var providerEnv: [String: JSONValue] = [:]` 声明 (从未被写入)
- 删除 `if !providerEnv.isEmpty { credentials["providerEnv"] = ... }` 分支

**Python (`service_catalog._resolve_app`)**:
- 删除 Kimi 旧格式回退: `elif run_ctx.credential("kimi_web_tokens") is not None`
- 删除 DeepSeek 旧格式回退: `else: deepseek_env = provider_env.get("deepseek")`
- 删除火山引擎旧格式回退: `else: volc_meta = provider_meta.get("volcengine")`
- 删除 Antigravity 旧格式回退: `elif run_ctx.credential("antigravity_oauth") is not None`
- 保留 Claude/Grok 的 `providerMeta.get("claude"/"grok").get("enabled")` 路径 (仍被使用)

**保留不动**:
- Bridge 白名单 `CREDENTIAL_FIELDS_BY_MODULE` 保留 `providerEnv` (兼容 CLI 模式)
- Bridge schema 保留 `providerEnv` 定义 (optional)
- Python `service_catalog._resolve_cli_cc_rows` 保留 (CLI 模式仍读 CC Switch)
