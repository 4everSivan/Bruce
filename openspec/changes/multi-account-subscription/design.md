## Context

当前 7 个 provider 的凭证管理分为两类:

1. **Codex**: 已有完整的多账号体系 -- v2 账号索引 (`CodexAccountIndex`) + 每账号独立记录 (`CodexAccountRecord`) + token 管理器 + 账号级状态 + 看板账号子卡分组.
2. **其余 6 个 (Kimi, DeepSeek, 火山引擎, Antigravity, Claude, Grok)**: 单条 Keychain 凭证, 无账号索引, 无多账号支持.

用户需要为每个 provider 管理多个账号的订阅额度. 同时, 多账号列表可能很长, 需要折叠展示.

现有 Codex 多账号架构的核心组件:
- `CodexCredentialStore`: 管理 index + per-account record 的 Keychain 读写
- `CodexAccountIndex`: 账号元数据索引 (accountID, email, authorizationState, credentialKeyHash)
- `CodexAccountRecord`: 单账号完整凭证 (accessToken, refreshToken, expiresAt, ...)
- `CodexTokenManager`: token 续期和刷新
- `CollectorRunInput`: `codexQuotaAccounts` 按账号注入 access token
- `PanelViewModelMapper`: Codex services 按 app=="codex" 分组成 section + codexAccounts
- `SubscriptionCard`: `CodexAccountCard` 子卡展示每个账号的窗口和状态

设计目标: 把 Codex 的多账号模式推广到所有 provider, 同时引入折叠展示.

## Goals / Non-Goals

### Goals

- 为所有 7 个 provider 提供多账号凭证管理: 添加、移除、重新授权、状态展示.
- 复用 Codex v2 的 account-index + per-account record 架构, 不为每个 provider 重新设计存储.
- 看板多账号默认折叠, 折叠态展示账号数 + 最关键窗口摘要; 展开后按账号子卡展示.
- 旧单账号凭证自动迁移为单条账号记录, 用户无感.
- 单账号保持现有展示不变.
- Collector App 模式按账号注入凭证, artifact services 按账号展开.

### Non-Goals

- 不改变 provider 级别的 enabled/order 配置 (仍在 subscriptionProviders 字典).
- 不引入跨 provider 的账号合并或统一登录.
- 不改变 Codex 现有的设备码登录流程 (已有且可用).
- 不改变 CLI 模式的凭证读取方式.
- 不在本变更中实现新 provider 的 OAuth 登录 (仅扩展现有凭证录入/导入为多账号).

## Decisions

### 1. 统一多账号存储: 泛化 Codex v2 架构

将 Codex 的 account-index + per-account record 模式泛化为所有 provider 共用:

```
Keychain service: com.mddd.dashboard.credentials
  ├─ <provider>:account-index     → JSON {accounts: [{accountID, displayName, credentialKeyHash, ...}]}
  ├─ <provider>:account:<hash>    → JSON {凭证体, updatedAt, ...}
  └─ (旧) <provider>:<单条键>      → 迁移读取, 成功后删除
```

每个 provider 的 account-index 结构统一为 `ProviderAccountIndex`:
- `provider`: SubscriptionProviderID
- `accounts`: [Entry] — 每条含 accountID, displayName, credentialKeyHash, authorizationState
- 不保存 token, 只保存元数据

每账号凭证记录 `ProviderAccountRecord`:
- provider 特定字段 (Kimi: access/refresh token; DeepSeek: api key; 火山: ak/sk; ...)
- 通用字段: accountID, displayName, authorizationState, updatedAt

选择该方案是因为 Codex v2 已经验证了 index + per-account record 的可行性和安全性, 重复设计会增加无谓的复杂度. 备选方案是为每个 provider 设计独立的存储, 但这会导致 7 套不同的读写逻辑.

### 2. 账号标识: provider 自定义 + 去重

每个 provider 的账号标识方式不同:
- **Kimi**: access_token 中的用户信息或粘贴时手动命名
- **DeepSeek**: API key 前缀 (前 8 位) 作为标识
- **火山引擎**: AccessKey 前 8 位
- **Antigravity**: OAuth token 中的用户信息
- **Claude**: OAuth accessToken 的 SHA-256 前 16 位
- **Grok**: OAuth key 的 SHA-256 前 16 位
- **Codex**: 已有 accountID (不变)

accountID 在同一 provider 内唯一. 添加重复账号时 (相同 accountID) 提示已存在, 不覆盖.

选择 provider 自定义标识是因为各 provider 的凭证结构差异大, 统一用 hash 会导致用户无法区分账号. 用可读前缀 + 去重更友好.

### 3. 折叠展示: 最关键窗口 + 账号数

多账号 (>= 2) 时 section 默认折叠:

**折叠态**:
- Provider 名称 + 账号数 (如 "3 个账号")
- 最关键窗口: 取所有账号中 usedPercent 最高的那个账号的最短重置周期窗口
  - 如: 某账号 5h 窗口已用 92% > 某账号 5h 窗口已用 68%, 展示 "5h 92%"
- 整体状态: 取所有账号中最差状态 (error > partial > ok)

**展开态**:
- 复用 CodexAccountCard 样式, 每个账号一个子卡
- 子卡内展示该账号的全部窗口、余额和状态
- 泛化 CodexAccountViewModel → ProviderAccountViewModel (字段不变, 适用所有 provider)

选择"最高用量的最短窗口"作为折叠摘要是因为它传达了最紧急的信息 (是否快用完了). 备选方案是取平均用量, 但平均值会掩盖个别账号的耗尽状态.

### 4. 设置页: 账号列表替代单凭证表单

每个 provider 的管理区从单凭证表单改为账号列表:
- 顶部: 添加账号按钮 (复用现有录入/导入方式)
- 列表: 每行一个账号 — 显示名 + 状态 + 移除按钮
- 点击账号名可展开凭证管理 (更换/重新验证)
- 第一个添加的账号自动设为"主账号" (展示在最前, 顺序可拖拽)

保留现有 provider 级别的 enabled 开关和排序. enabled 控制该 provider 全部账号的额度查询.

### 5. Collector 注入: 按账号展开

App 模式凭证注入改为按账号字典:

```json
{
  "kimiQuotaAccounts": {
    "<accountID>": {"access_token": "...", "refresh_token": "...", "display_name": "..."}
  },
  "deepseekQuotaAccounts": {
    "<accountID>": {"api_key": "...", "display_name": "..."}
  }
}
```

Collector 对每个账号独立查询, artifact services 按账号展开:
- service.id = `<provider>_<accountID>` (如 `kimi_coding_a1b2c3d4`)
- service.name = `<displayName>`
- service.app = provider rawValue

这与 Codex 的 `codexQuotaAccounts` + `codexQuotaAccountOrder` 模式一致.

### 6. 迁移: 旧单条凭证自动转单账号记录

首次加载时检测旧 Keychain 键:
- 旧键存在且新 index 不存在 → 创建 index + record, 旧键保留 (迁移后下次删除)
- 旧键存在且新 index 已有账号 → 忽略旧键 (用户已手动添加新账号)
- 旧键不存在 → 无操作

迁移不修改旧键值, 只读取后写入新键. 迁移成功后在下次 App 启动时删除旧键.

### 7. 命名: ProviderAccountViewModel 替代 CodexAccountViewModel

将 `CodexAccountViewModel` 泛化为 `ProviderAccountViewModel`, 字段不变:
- id, name, plan, status, note, windows, lastSuccessText

`SubscriptionProviderSection.codexAccounts` 改名为 `accounts` (类型 `ProviderAccountViewModel?`).
`SubscriptionCard` 的 `CodexAccountCard` 改名为 `ProviderAccountCard`.

## Risks / Trade-offs

### Keychain 条目数增长

7 个 provider × 多账号 = 可能 20+ 条 Keychain 条目. 缓解: Keychain 本身为系统级存储, 条目数不影响性能; index 只读一次, 按需加载 record.

### 迁移风险

旧凭证迁移失败会导致用户需要重新录入. 缓解: 迁移只读取不删除旧键, 失败时保留旧键并提示; 迁移成功后下次启动才删除旧键.

### Collector 凭证注入复杂度

按账号注入需要 Collector 侧逐账号查询, 单账号失败不影响其他. 缓解: 复用 Codex 的批量决议 + 四源合并模式, 已验证可行.

### 折叠态信息不足

折叠只展示一个窗口可能不够. 缓解: 折叠态额外展示整体状态图标 (ok/error/partial), 用户可快速判断是否需要展开.

## Migration Plan

### Phase 1: 存储模型泛化

1. 创建 `ProviderAccountIndex` / `ProviderAccountRecord` 通用模型
2. 创建 `ProviderAccountStore` (类比 CodexCredentialStore), 按 provider 实例化
3. 实现旧单条凭证迁移逻辑
4. Harness 测试: 迁移、index 读写、record 读写

### Phase 2: 设置页多账号管理

1. 各 provider 管理组改为账号列表
2. 添加账号: 复用现有录入/导入入口, 增加去重检查
3. 移除账号: 删除 record + index 条目
4. 账号状态展示: connected / needsReauthorization / error
5. Harness 测试: 添加/移除/迁移/重复检测

### Phase 3: Collector 按账号注入

1. `OnboardingRunInputProvider` 按账号组装凭证
2. `collect_usage.py` App 模式按账号展开 service
3. 单账号失败不阻断其他账号
4. Python 测试: 多账号注入 + service 展开

### Phase 4: 看板折叠展示

1. `SubscriptionMapping` 按 provider 分组多账号 services
2. 折叠态: 最关键窗口 + 账号数 + 整体状态
3. 展开态: ProviderAccountCard 子卡 (复用 CodexAccountCard 样式)
4. `ProviderAccountViewModel` 替代 `CodexAccountViewModel`
5. Harness 测试: 折叠/展开映射

### Phase 5: 凭证轮换扩展

1. `credentialUpdates` 支持按 provider + accountID 路由
2. 单账号轮换不影响其他账号
3. 测试: 多账号轮换合并

## Open Questions

- Kimi/Antigravity 的 OAuth 刷新在多账号下是否需要 per-account refresh token 管理 (当前 Codex 有 token manager, 其他 provider 暂无)?
- 折叠态是否需要记住用户的展开/折叠偏好 (跨会话)? 默认折叠, 首次展开后记住?
- DeepSeek 月度账本在多账号下是否需要按账号隔离? (当前 usageTrackingID 是 provider 级别)
