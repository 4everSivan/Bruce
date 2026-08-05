## 1. 存储模型泛化

- [x] 1.1 创建 `ProviderAccountIndex` 通用模型 (provider, accounts: [Entry], Entry 含 accountID, displayName, credentialKeyHash, authorizationState)
- [x] 1.2 创建 `ProviderAccountRecord` 通用模型 (accountID, displayName, authorizationState, updatedAt + provider 特定凭证字段 credentialJSON)
- [x] 1.3 创建 `ProviderAccountStore` (类比 CodexCredentialStore), 支持按 provider 实例化的 index 读写、record 读写、账号添加/移除
- [x] 1.4 定义各 provider 的 accountID 生成规则 (DeepSeek: api key 前 8 位; 火山: AK 前 8 位; Kimi: token hash 前 16 位; Claude/Grok: token SHA-256 前 16 位; Antigravity: token hash 前 16 位)
- [x] 1.5 定义各 provider 旧单条 Keychain 键到新 account-index 的迁移逻辑 (ProviderAccountKeys.legacyKeys + 迁移测试)
- [x] 1.6 Harness 测试: index 读写、record 读写、账号添加/移除、迁移成功、重复账号检测 (5 项, 15 项总计)

## 2. 设置页多账号管理

- [x] 2.1 各 provider 管理组上方新增账号列表 (providerAccountList: displayName + 状态 + 移除按钮)
- [x] 2.2 账号行展示: displayName + 状态图标 (已连接/需要重新登录/已撤销) + 移除按钮
- [x] 2.3 添加账号: 复用现有录入/导入入口 (每 provider 现有管理 UI 不变), 去重由 ProviderAccountStore.addAccount 保证
- [x] 2.4 移除账号: coordinator.removeAccount -> SubscriptionService.removeAccount (删除 record + index 条目)
- [x] 2.5 enabled 开关保持 provider 级别, 控制该 provider 全部账号的额度查询
- [x] 2.6 Harness 测试: providerAccountSummariesExposeNonSensitiveInfo + providerAccountStoreRemoveLastAccountKeepsEmptyIndex (21 项总计)

## 3. 旧凭证迁移

- [x] 3.1 App 启动时检测旧单条 Keychain 键, 迁移为单账号 record + index (SubscriptionService.migrateLegacyCredentials)
- [x] 3.2 迁移成功后标记旧键待删除, 下次启动时删除 (cleanupLegacyCredentials)
- [x] 3.3 迁移失败保留旧键, 不创建不完整 index, 下次启动重试 (catch 块静默跳过)
- [x] 3.4 Harness 测试: 各 provider 旧键迁移、迁移失败恢复、旧键清理 (providerAccountStoreMigrationSkipsWithExistingIndex + providerAccountStoreCleanupAfterMigration)

## 4. Collector 按账号注入

- [x] 4.1 `OnboardingRunInputProvider` 按账号组装凭证 (每个 provider 的 `*QuotaAccounts` 字典, 类比 codexQuotaAccounts 结构; 旧单条键自动迁移到 ProviderAccountStore 后注入)
- [x] 4.2 `collect_usage.py` / `service_catalog.py` App 模式按账号展开 service 条目 (service.id = `<provider>_<accountID>`; 旧格式回退保留)
- [x] 4.3 单账号查询失败不阻断其他账号 (per-account query 独立, finalize 折叠错误到该账号)
- [x] 4.4 Python 测试: 160 项通过; CollectorRunnerHarness + SubscriptionCredentialsHarness 更新为多账号注入格式

## 5. 看板多账号映射

- [x] 5.1 `SubscriptionMapping` 按 provider 分组多账号 services (泛化 Codex 分组逻辑到所有 provider)
- [x] 5.2 `CodexAccountViewModel` 保持原名, `codexAccounts` 改名为 `accounts` (非可选数组)
- [x] 5.3 `SubscriptionProviderSection` 的 accounts 字段适用于所有 provider (不限于 codex app)
- [x] 5.4 多账号 (>=2) 时 section 携带 collapsedWindow; 单账号不携带 (isMultiAccount 计算属性)
- [x] 5.5 折叠态计算: 取所有账号中 usedPercent 最高的最短重置周期窗口作为摘要 (SubscriptionPresentationPolicy.collapsedWindow)
- [x] 5.6 Harness 测试: 现有 36 项 PanelViewModel 测试全部通过 (含多账号分组、单账号兼容)

## 6. 看板折叠/展开交互

- [x] 6.1 `SubscriptionCard` 多账号 section 默认折叠, 点击 section header 切换
- [x] 6.2 折叠态: provider 名称 + 账号数 + 整体状态 + 最关键窗口摘要 (collapsedWindow)
- [x] 6.3 展开态: `CodexAccountCard` 改名为 `ProviderAccountCard`, 适用于所有 provider
- [x] 6.4 折叠态整体状态取最差 (error > partial > ok) (codexGroupStatus 泛化)
- [x] 6.5 Harness 测试: PanelViewModel 36 项通过

## 7. 凭证轮换扩展

- [x] 7.1 `credentialUpdates` 支持按 provider + accountID 路由 (CredentialUpdateCoordinator 多账号路径写回 per-account record)
- [x] 7.2 单账号轮换不影响其他账号的凭证 (per-account record 独立更新)
- [x] 7.3 测试: 多账号轮换合并 (coordinatorRotationMultiAccountWritesPerAccountRecord + coordinatorRotationMultiAccountUnknownAccountFallsBack), 19 项通过

## 8. 集成验证

- [x] 8.1 迁移验证: 旧单账号配置启动后自动迁移 (migrateLegacyAccountsIfNeeded 测试覆盖), 看板和设置页正常展示
- [x] 8.2 多账号端到端: 添加多账号 -> 刷新 -> 看板折叠展示 -> 展开 -> 移除账号 (ProviderAccountStore + 映射层 + 折叠 UI 测试覆盖)
- [x] 8.3 单账号兼容: 只有单账号的 provider 展示与当前版本一致 (isMultiAccount 计算属性 + 单账号 section 路径)
- [x] 8.4 全部 verify-local.sh 通过 (Python 160 项 + 全部 Swift Harness)
