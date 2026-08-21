## Why

当前只有 Codex 支持多账号订阅管理. 其余 6 个 provider (Kimi, DeepSeek, 火山引擎, Antigravity, Claude, Grok) 均为单条 Keychain 凭证, 无法同时管理多个账号的订阅额度. 用户在使用多个账号 (如个人 + 工作账号) 时只能保留一个, 切换需要重新录入凭证.

同时, 多账号场景下列表会显著变长. 需要默认折叠, 复用 Codex 多账号子卡样式, 折叠态只展示最关键的额度摘要 (如最低限制窗口), 展开后才显示全部窗口和余额.

## What Changes

- 为所有 provider 建立统一的多账号凭证存储模型, 复用 Codex v2 的 account-index + per-account record 架构.
- 每个账号有独立的凭证记录、验证状态和额度查询, 单账号失败不影响其他账号.
- 设置页为每个 provider 提供账号列表: 添加 (登录/粘贴/导入)、移除、重新授权, 复用现有 provider 管理组但按账号维度组织.
- 看板订阅用量卡: 单账号保持现有展示; 多账号时默认折叠, 折叠态展示账号数 + 最关键窗口 (最短重置周期的窗口) 的用量摘要, 展开后按账号子卡展示全部信息.
- Collector 侧: App 模式注入凭证改为按账号组装 (与现有 Codex codexQuotaAccounts 结构一致), artifact services 按账号展开.
- 凭证轮换: 保留现有 credentialUpdates 机制, 扩展到所有 provider 的多账号场景.
- 向后兼容: 现有单账号凭证在首次加载时自动迁移为单条账号记录, 用户无感.

## Capabilities

### Modified Capabilities

- `provider-onboarding-auth`: 从单凭证扩展到多账号凭证管理, 新增账号级添加/移除/重新授权/状态展示.

### New Capabilities

- `multi-account-dashboard`: 多账号订阅用量看板展示, 含折叠态摘要和展开态账号子卡.

## Impact

- `OnboardingConfiguration`: subscriptionProviders 配置结构不变 (仍按 provider 级别管理 enabled/order), 账号级凭证全在 Keychain.
- `OnboardingCoordinator`: 新增通用多账号 store (类比 CodexCredentialStore), 按 provider 类型实例化.
- `CollectorRunInput`: 注入凭证从单条改为账号字典, 与 Codex 的 codexQuotaAccounts 结构对齐.
- `PanelViewModelMapper`: 所有 provider 的多账号 services 按账号分组成 section + accounts, 复用 CodexAccountViewModel.
- `SubscriptionCard`: 新增折叠/展开交互, 折叠态展示最关键窗口摘要.
- `collect_usage.py`: App 模式按账号展开 service 条目, service.id 加账号后缀以区分.
- Keychain: 新增按 provider + accountID 的键命名规范, 旧单条键自动迁移.
- 测试: 新增多账号添加/移除/迁移/折叠展示的 harness 用例.
