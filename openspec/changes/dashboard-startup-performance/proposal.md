## Why

仪表盘启动和展示存在卡顿, 根因有三:

1. **面板映射无缓存**: `MenuBarDashboardView.body` 每次求值都调用 `model.makePanelViewModel()`, 内部新建 `PanelViewModelMapper` 全量遍历 artifact (182 天 × 5 agent + 订阅分组 + 逐小时). SwiftUI 在滚动、动画、状态变化时多次求值 body, 每次都重算. 菜单栏标签独立解码同一 artifact, 不复用 `AppModel` 的解码缓存.

2. **Keychain 读取风暴**: 启动时 `SubscriptionService.init` 对 7 个 provider 逐个调用 `credentialConfigured` (每次创建 `ProviderAccountStore` + `loadIndex`), 紧接着 `publishAllProviderAccountSummaries` 再对 6 个 provider 各 `loadIndex` 两次. `ProviderAccountStore` 是 class 但全项目无缓存, 同一 provider 的 index 在一次操作链中被重复读取.

3. **遗留迁移重复执行**: `SubscriptionService.migrateLegacyCredentials` 和 `OnboardingRunInputProvider.accountStores` lazy var 各自独立遍历 6 个 provider 创建 store 执行迁移, 共创建 12 个 store 实例 (6 个重复).

此外发现 Antigravity 多账号查询在 App 模式下断裂: `service_catalog._agy_query_with_inject` 返回 None, `service_antigravity` 也因旧键 `antigravity_oauth` 未注入而返回空, 导致 Antigravity 额度始终显示"未取到额度数据".

## What Changes

- `AppModel` 缓存 `PanelViewModel` 和 `MenuBarSummary`, 按版本号失效; artifact 解码复用已有缓存.
- `SubscriptionService` 持有 `ProviderAccountStore` 字典缓存, 避免重复创建和 Keychain 读取.
- `OnboardingRunInputProvider.accountStores` 迁移复用已创建的 store 实例, 不再独立创建.
- `publishAllProviderAccountSummaries` 每个 provider 只调一次 `loadIndex`, 同时用于校正和 summaries.
- `publishSubscriptionState` 从已发布的 `providerAccountSummaries` 推导 `credentialConfigured`, 不再逐个实时读 Keychain.
- 删除 `CollectorRunInput.assembleSubscriptionCredentials` 中从未写入的 `providerEnv` 死代码.
- 删除 `service_catalog._resolve_app` 中 App 模式永远不会命中的旧格式回退分支 (kimi_web_tokens / provider_env.deepseek / provider_meta.volcengine / antigravity_oauth).
- 修复 Antigravity 多账号查询: `service_antigravity` 从 `antigravity_quota_accounts` 读取凭证; `service_catalog` 跳过 Antigravity 避免重复创建空条目.

## Capabilities

### Modified Capabilities

- `dashboard-rendering`: 面板和菜单栏标签的 view model 映射增加缓存层, 输入变更时自动失效.
- `credential-pipeline`: 启动时凭证状态发布和 Keychain 读取路径合并优化, ProviderAccountStore 实例复用.

## Impact

- `AppModel`: 新增 `cachedPanelViewModel`, `cachedMenuBarSummary` 和版本号机制; `makePanelViewModel` / `makeMenuBarSummary` 改为缓存读取.
- `MenuBarViews`: `MenuBarLabelView.summary` 改为调用 `model.makeMenuBarSummary()`.
- `SubscriptionService`: 新增 `accountStore(for:)` 缓存; `publishSubscriptionState` / `publishAllProviderAccountSummaries` / `credentialConfigured` 优化读取路径.
- `CollectorRunInput`: `migrateLegacyCredentialsIfNeeded` 复用 `accountStores` 字典; 删除 `providerEnv` 死代码.
- `ProviderAccountStore`: 新增 `summaries(from:)` 重载, 暴露 `provider` 只读属性.
- `service_catalog.py`: 删除 4 个死格式回退分支; Antigravity 跳过 `_Resolved` 创建.
- `collect_usage.py`: `service_antigravity` 增加从 `antigravity_quota_accounts` 读取多账号凭证.
- 测试: 新增缓存失效回归测试; 现有 162 项 Python 测试 + 全部 Swift Harness 不受影响.
