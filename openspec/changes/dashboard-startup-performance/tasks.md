## 1. 面板映射与菜单栏标签缓存 (P0)

- [x] 1.1 `AppModel` 新增 `cachedPanelViewModel: PanelViewModel?`, `cachedMenuBarSummary: MenuBarSummary?`, `panelCacheVersion: Int`, `lastPanelCacheVersion: Int` (初始 -1)
- [x] 1.2 `AppModel` 新增 `private func invalidatePanelCache()`, 内部 `panelCacheVersion += 1`; 在 `setArtifact`, `setStatus`, `setSubscriptionProviderOrder`, `invalidateDeepSeekMonthlyUsage`, `updateDeepSeekMonthlyUsage` 的 `deepSeekMonthlyUsage =` 写入点调用
- [x] 1.3 `makePanelViewModel()` 改为版本号检查: 版本号未变且缓存存在则返回缓存; 否则重算并缓存, 更新 `lastPanelCacheVersion`
- [x] 1.4 新增 `makeMenuBarSummary() -> MenuBarSummary`: 复用 `decodedAgentUsageArtifact()` 缓存 + 版本号检查; 内部构造 `MenuBarSummaryBuilder` 时传入已解码 artifact
- [x] 1.5 `MenuBarLabelView.summary` 改为 `model.makeMenuBarSummary()`; 删除内联 `MenuBarSummaryBuilder().build(...)`
- [x] 1.6 `MenuBarSummaryBuilder` 新增 `build(from decoded: AgentUsageArtifact?, moduleStatuses:)` 重载, 接受已解码 artifact, 避免重复解码; 原 `build(agentArtifact:moduleStatuses:)` 保留兼容测试
- [x] 1.7 Harness 测试: `setArtifact` 后 `makePanelViewModel` 返回新结果; 同一 artifact 多次调用返回同一缓存; `setStatus` 后缓存失效; `makeMenuBarSummary` 复用解码缓存 (LocalIntegrationHarness 新增 2 项)

## 2. ProviderAccountStore 缓存与 Keychain 读取优化 (P1)

- [x] 2.1 `ProviderAccountStore` 暴露 `provider` 只读属性 (从 `private let` 改为 `let`); 新增 `func summaries(from index: ProviderAccountIndex) -> [ProviderAccountSummary]` 重载
- [x] 2.2 `SubscriptionService` 新增 `private var accountStoreCache: [SubscriptionProviderID: ProviderAccountStore] = [:]` 和 `private func accountStore(for id: SubscriptionProviderID) -> ProviderAccountStore`
- [x] 2.3 替换 `SubscriptionService` 中全部 11 处 `ProviderAccountStore(provider: ..., credentialStore: credentialStore)` 为 `accountStore(for: ...)` (migrateLegacyCredentials, publishAllProviderAccountSummaries, credentialConfigured, saveProviderAccountCredential, accountSummaries, removeAccount, updateAccountAuthorizationState)
- [x] 2.4 `publishAllProviderAccountSummaries` 优化: 每个 provider 只调一次 `loadIndex`; 校正后从内存 index 构造 summaries (用 `summaries(from:)` 重载), 不二次读 Keychain; 校正后的 `needsReauthorization` 账号在 summaries 中显示为 `connected`
- [x] 2.5 `publishSubscriptionState` 优化: 先调 `publishAllProviderAccountSummaries()`, 再从 `model.providerAccountSummaries` 推导 `credentialConfigured` (有 connected 账号即 true); Codex 仍走 `legacyCredentialConfigured`; Claude/Grok 在 summaries 为空时回退 `legacyCredentialConfigured` (含本机探测)
- [x] 2.6 `credentialConfigured(_:)` 优化: 非 Codex 优先读 `model.providerAccountSummaries`; summaries 为空时回退 `accountStore(for:).loadIndex` + `hasConnectedAccount`; index 为空时回退 `legacyCredentialConfigured`; Codex 始终走 `legacyCredentialConfigured`
- [x] 2.7 Harness 测试: `publishAllProviderAccountSummaries` 每个 provider 只调一次 `loadIndex` (SubscriptionCredentialsHarness 新增 1 项); `credentialConfigured` 从 summaries 推导正确 (新增 1 项)

## 3. RunInputProvider 迁移去重 (P1)

- [x] 3.1 `OnboardingRunInputProvider.accountStores` lazy var: 先创建 stores 字典, 再用已创建的 store 实例遍历调用 `migrateLegacyAccountsIfNeeded`, 不额外创建 store; 删除独立 `migrateLegacyCredentialsIfNeeded()` 方法
- [x] 3.2 验证 `CollectorRunnerHarness.runInputAssemblesAllProvidersCombined` 仍通过 (直接创建 provider + 旧格式凭证 -> lazy accountStores 触发迁移 -> 凭证正确注入)

## 4. 死代码清理 (P2)

- [x] 4.1 `CollectorRunInput.assembleSubscriptionCredentials`: 删除 `var providerEnv` 声明和 `if !providerEnv.isEmpty` 分支
- [x] 4.2 `service_catalog._resolve_app`: 删除 Kimi 旧格式回退 (`elif run_ctx.credential("kimi_web_tokens")`)
- [x] 4.3 `service_catalog._resolve_app`: 删除 DeepSeek 旧格式回退 (`else: deepseek_env = provider_env.get("deepseek")`)
- [x] 4.4 `service_catalog._resolve_app`: 删除火山引擎旧格式回退 (`else: volc_meta = provider_meta.get("volcengine")`)
- [x] 4.5 `service_catalog._resolve_app`: 删除 Antigravity 旧格式回退 (`elif run_ctx.credential("antigravity_oauth")`), 改为跳过注释
- [x] 4.6 验证 Python 契约测试 `test_bridge_contract.py` 全部 162 项通过

## 5. Antigravity 多账号查询修复 (P2)

- [x] 5.1 `collect_usage.service_antigravity`: 在 `injected_auth = _runtime_credential("antigravity_oauth")` 后增加 `antigravity_quota_accounts` 回退读取 (取第一个账号的 oauth)
- [x] 5.2 `service_catalog._resolve_app`: Antigravity 多账号分支跳过 `_Resolved` 创建, 注释说明由 `service_antigravity` 统一处理
- [x] 5.3 Python 测试: 新增 `test_service_antigravity_reads_quota_accounts` 验证从 `antigravity_quota_accounts` 读取凭证
- [x] 5.4 验证现有 `test_bridge_contract.py` 中 Antigravity 相关测试仍通过

## 6. 全量验证与打包

- [x] 6.1 `python3 -m pytest tests/` (162 项 + 新增 1 项 = 163 项)
- [x] 6.2 `swift build --package-path macos/MdddApp`
- [x] 6.3 `swift run --package-path macos/MdddApp MdddOnboardingCoreHarness` (172 项)
- [x] 6.4 `swift run --package-path macos/MdddApp PanelViewModelHarness` (40 项)
- [x] 6.5 `swift run --package-path macos/MdddApp SubscriptionCredentialsHarness` (23 项 + 新增 2 项 = 25 项)
- [x] 6.6 `swift run --package-path macos/MdddApp CollectorRunnerHarness` (26 项)
- [x] 6.7 `swift run --package-path macos/MdddApp RefreshSchedulerHarness` (62 项)
- [x] 6.8 `swift run --package-path macos/MdddApp DeepSeekUsageLedgerHarness` (17 项)
- [x] 6.9 `swift run --package-path macos/MdddApp LocalIntegrationHarness` (3 项 + 新增 2 项 = 5 项)
- [x] 6.10 `swift run --package-path macos/MdddApp NativeLifecycleHarness` (6 项)
- [x] 6.11 `swift run --package-path macos/MdddApp ArtifactStoreHarness` (5 项)
- [x] 6.12 `swift run --package-path macos/MdddApp DiagnosticsHarness` (8 项)
- [x] 6.13 `zsh scripts/verify-local.sh` 全量通过
- [x] 6.14 `zsh scripts/build-test-app.sh` 打包成功
