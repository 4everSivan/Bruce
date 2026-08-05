## ADDED Requirements

### Requirement: 多账号凭证存储

系统必须 (MUST) 为每个订阅 provider 支持多账号凭证存储, 复用 account-index + per-account record 架构. 账号索引只保存元数据 (accountID, displayName, authorizationState, credentialKeyHash), 凭证本体保存在独立的 per-account Keychain 条目中.

#### Scenario: 添加新账号

- **WHEN** 用户为已有一个账号的 provider 添加第二个账号
- **THEN** 系统创建新的 account-index 条目和 per-account 凭证记录, 两个账号共存且可独立查询额度

#### Scenario: 添加重复账号

- **WHEN** 用户添加的账号标识与已有账号相同
- **THEN** 系统提示"该账号已存在", 不覆盖已有凭证

#### Scenario: 移除单个账号

- **WHEN** 用户移除多账号 provider 中的一个账号
- **THEN** 系统删除该账号的 record 和 index 条目, 其他账号不受影响

#### Scenario: 旧单条凭证自动迁移

- **WHEN** 系统首次加载且检测到旧的单条 Keychain 凭证
- **THEN** 系统将旧凭证迁移为单条账号记录, 创建 account-index, 迁移成功后下次启动删除旧键

#### Scenario: 迁移失败保留旧键

- **WHEN** 旧凭证迁移过程中出现异常
- **THEN** 系统保留旧 Keychain 键不删除, 不创建不完整的 index, 在下次启动时重试

### Requirement: 账号标识与去重

系统必须 (MUST) 为每个 provider 的账号生成唯一标识, 用于 Keychain 键和 artifact service ID 区分. 标识来源因 provider 而异 (API key 前缀, OAuth token hash 等), 在同一 provider 内唯一.

#### Scenario: 基于凭证前缀生成标识

- **WHEN** 用户添加 DeepSeek 账号
- **THEN** 系统取 API key 前 8 位作为 accountID, 在 DeepSeek provider 内去重

#### Scenario: 基于 OAuth token 生成标识

- **WHEN** 用户添加 Claude 或 Grok 账号
- **THEN** 系统取 accessToken/key 的 SHA-256 前 16 位作为 accountID, 在该 provider 内去重

### Requirement: 账号级状态管理

系统必须 (MUST) 为每个账号维护独立的验证状态 (connected / needsReauthorization / error), 单账号验证失败不影响其他账号的额态查询.

#### Scenario: 单账号验证失败

- **WHEN** 多账号 provider 中一个账号的凭证过期或验证失败
- **THEN** 该账号标记为 needsReauthorization, 其他账号继续正常查询额度, 看板展示该账号的失败状态

#### Scenario: 全部账号验证成功

- **WHEN** provider 的全部账号凭证均有效
- **THEN** 每个账号独立查询额度, 各自返回独立的 service 条目

## ADDED Requirements (Dashboard)

### Requirement: 多账号折叠展示

当 provider 有 2 个及以上账号时, 看板订阅用量卡必须 (MUST) 默认折叠该 provider 的 section, 折叠态只展示账号数和最关键额度摘要. 用户可点击展开查看全部账号详情.

#### Scenario: 折叠态展示最关键窗口

- **WHEN** 某 provider 有 3 个账号且处于折叠态
- **THEN** section 展示 provider 名称、"3 个账号"文案、整体状态图标, 以及所有账号中 usedPercent 最高的最短重置周期窗口摘要 (如 "5h 92%")

#### Scenario: 展开态展示账号子卡

- **WHEN** 用户点击折叠态 section 展开
- **THEN** section 展开为账号子卡列表, 每个子卡复用 CodexAccountCard 样式, 展示该账号的全部窗口、余额和状态

#### Scenario: 单账号不折叠

- **WHEN** provider 只有 1 个账号
- **THEN** section 保持现有单账号展示, 不显示折叠/展开控件

#### Scenario: 折叠态整体状态取最差

- **WHEN** 多账号中一个账号状态为 error, 其余为 ok
- **THEN** 折叠态整体状态显示 error, 提示用户展开查看详情

### Requirement: ProviderAccountViewModel 通用化

系统必须 (MUST) 将 CodexAccountViewModel 泛化为 ProviderAccountViewModel, 适用于所有 provider 的多账号展示. 字段结构保持不变 (id, name, plan, status, note, windows, lastSuccessText).

#### Scenario: 非 Codex provider 多账号映射

- **WHEN** Kimi 有 2 个账号的 artifact services 进入映射层
- **THEN** 映射层按 provider 分组, 每个 service 条目映射为一个 ProviderAccountViewModel, section 携带 accounts 数组

#### Scenario: 余额型 provider 多账号

- **WHEN** DeepSeek 有 2 个账号
- **THEN** 每个 ProviderAccountViewModel 携带各自的余额和月度统计, 折叠态不展示余额行, 展开态在每个子卡内展示

## MODIFIED Requirements

### Requirement: 应用内官方登录窗口 (MODIFIED)

系统必须 (MUST) 为支持 OAuth 或设备授权的服务提供应用发起的登录窗口或系统授权会话. 对多账号 provider, 每次登录创建新的账号记录, 不覆盖已有账号.

#### Scenario: 用户为已有账号的 provider 添加新账号

- **WHEN** 用户在设置页点击"添加账号"并完成登录
- **THEN** 系统创建新的 account-index 条目, 不修改已有账号的凭证, 新账号出现在账号列表末尾

#### Scenario: 不支持 OAuth 的 provider 多账号

- **WHEN** 用户为仅支持 PAT/API key 的 provider (如 DeepSeek) 添加第二个账号
- **THEN** 系统提供与首次添加相同的安全录入入口, 新 API key 独立保存为新的 per-account record

### Requirement: Keychain 凭证存储 (MODIFIED)

系统必须 (MUST) 将应用持有的凭证按 provider + accountID 范围存储在 macOS Keychain 中. 账号索引和 per-account 凭证均以 `<provider>:account-index` 和 `<provider>:account:<hash>` 命名, 与单账号时代的旧键隔离.

#### Scenario: 保存多账号凭证

- **WHEN** 用户为某 provider 添加第二个账号
- **THEN** 系统在 Keychain 中创建新的 `account:<hash>` 条目, 更新 `account-index` 追加新账号元数据, 不修改第一个账号的凭证

#### Scenario: 删除单账号凭证

- **WHEN** 用户移除某账号
- **THEN** 系统删除对应的 `account:<hash>` Keychain 条目, 从 `account-index` 移除该条目, 其他账号的 Keychain 条目不受影响

### Requirement: 统一授权确认与细粒度控制 (MODIFIED)

系统必须 (MUST) 在首次启用自动采集前提供统一授权确认. enabled 开关在 provider 级别控制该 provider 全部账号的额度查询.

#### Scenario: 禁用 provider 停止全部账号查询

- **WHEN** 用户关闭某多账号 provider 的 enabled 开关
- **THEN** 系统停止该 provider 全部账号的额度查询, 不删除任何账号凭证

#### Scenario: 移除 provider 删除全部账号

- **WHEN** 用户在设置页移除某 provider
- **THEN** 系统删除该 provider 的全部账号 record 和 account-index, 清理全部相关 Keychain 条目
