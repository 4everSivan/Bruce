## Context and Evidence

已检查当前实现:

- `MenuBarViews.swift` 的底栏只调用 `coordinator.refresh(module)`, 订阅卡 Provider 段没有刷新动作.
- `RefreshScheduler` 的状态、timer、容量和 pending intent 以 `CollectorModule` 为粒度; 当前 `agentUsage` 是唯一 Collector module.
- `OnboardingRunInputProvider.agentUsageInput()` 一次组装所有已启用 Provider 的 credentials.
- `collect_usage._collect()` 在同一轮执行本地 agents、`service_catalog`、Antigravity 和 Codex, `service_catalog` 没有目标 Provider 过滤入口.
- `ArtifactStore.publish()` 原子替换整个 `agent-usage` artifact. 现有 `CodexQuotaSnapshotMerger` 只覆盖 Codex 的四源合并, 不能直接承接非 Codex 的局部 artifact.
- `SubscriptionMapping` 已按 Provider 分组并支持多账号, `SubscriptionCard` 已有 Provider header 和 per-account 状态展示, 可在现有边界上增加动作.

现有 `docs/development/01-bruce-design.md` 的标题末尾和正文末尾没有同时出现“已确认/冻结”, 因此本次按独立变更请求处理, 不把它宣称为已冻结的新验收基线.

## Options and Decision

### 方案 A: UI 按钮继续触发全量刷新

改动最小, 但按钮名称与行为不一致, 仍会访问其他 Provider 和本机会话, 无法满足“单独刷新某个订阅”. 不采用.

### 方案 B: 新建独立 SubscriptionRefreshService

可以快速绕过现有 Scheduler, 但会复制 CollectorRunner、容量、退避、凭证写回和 ArtifactStore 发布逻辑, 容易出现两套刷新状态与并发控制. 不采用.

### 方案 C: 在现有 Scheduler/Pipeline 中增加定向范围, 推荐

用同一条调度、取消、容量、credential update 和原子发布链路, 只把刷新目标从隐含的“整个 agentUsage”提升为显式范围. Collector 返回目标 service 子集, Swift 在发布前把它合并回上一次完整 artifact. 这样单 Provider 请求真正隔离, 同时不破坏现有面板和 artifact 消费者.

## Domain and Scheduling Contract

新增一个纯值 `RefreshScope`:

```text
all
subscriptionProviders(Set<SubscriptionProviderID>)
```

`RefreshIntent` 携带 `scope` 和现有 `reason/includesManual`.

- `refresh(.agentUsage)` 仍创建 `all`.
- `refreshSubscription(provider)` 创建只含一个 Provider 的 scope.
- 同一 Provider 的重复点击合并为一次.
- 多个定向 Provider 在同一 module 尚未运行时合并为 Provider 集合.
- 任一全量 intent 优先于定向集合, 保证一次全量刷新不会被局部请求削弱.
- 仍遵守 module capacity、单 module 单运行、pending rerun、取消和 backoff.
- 定向手动刷新不触发额度阈值系统通知, 与现有手动全量刷新一致.

定向运行仍使用 `agent-usage` snapshot, 但回调增加 Provider 级状态:

```text
subscriptionRefreshState(provider, .started | .finished | .failed | .cancelled)
```

Provider 级状态与现有 Settings 的 `busySubscriptionProviders` 分离, 避免凭证导入进行中被误显示为额度刷新.

## UI Contract

订阅卡每个 Provider header 右侧放置独立 `arrow.clockwise` 按钮:

- 单账号和多账号 section 都显示同一位置.
- 多账号名称继续负责展开/折叠; 刷新按钮是兄弟控件, 点击不改变折叠状态.
- 目标 Provider 刷新时按钮显示小型进度指示并禁用; 全量 agentUsage 刷新时所有 Provider 刷新按钮禁用.
- 未配置、未启用或当前 module 不可运行时禁用按钮.
- `accessibilityLabel`: `刷新 <Provider 名称> 订阅额度`; 进行中改为 `正在刷新 <Provider 名称> 订阅额度`.
- 查询失败仍使用当前 `note` 和 `lastSuccessText`; 不新增凭证或网络原文弹窗.

建议的数据流:

```text
SubscriptionCard
  -> OnboardingCoordinator.refreshSubscription(provider)
  -> RefreshScheduler.refreshSubscription(provider)
  -> RefreshExecutionPipeline(scope: .subscriptionProviders(...))
  -> CollectorRunner / Bridge / Python quota-only collector
  -> ScopedQuotaSnapshotMerger(previous, first, retry)
  -> ArtifactStore.publish(full artifact)
  -> AppModel artifact + provider refresh state
```

UI 只消费 `SubscriptionViewModel`、Provider refresh state 和 coordinator action, 不读取凭证或 artifact 原始 JSON.

## Input and Bridge Contract

定向请求在 `context` 中增加:

```json
{
  "subscriptionQuotaOnly": true,
  "subscriptionProviders": ["deepseek"],
  "capabilities": ["externalQuotas"]
}
```

约束:

- `subscriptionProviders` 只允许 `SubscriptionProviderID` 的 raw value, 非空、去重, 数量不超过 provider 总数.
- `subscriptionQuotaOnly=true` 必须携带 `subscriptionProviders`.
- 携带 `subscriptionProviders` 时必须为 quota-only request; 全量 request 不带这两个字段.
- Bridge v1 保持 `schemaVersion=1`, 仅扩大显式白名单; unknown field、未知 Provider、错误类型和空数组 fail-closed.
- `OnboardingRunInputProvider` 只注入目标 Provider 的 `*QuotaAccounts` 和对应 `providerMeta`; 不把其他 Provider 凭证带进子进程.
- Codex 仍携带 `codexQuotaAccounts` 与匹配的 `codexQuotaAccountOrder`; refresh token/id token 不离开 Swift/Keychain.
- 定向请求不携带 `localSessions`/`localPricing` 也不要求 `days`, Python 不扫描会话、不加载价格.

collector context 使用 snake case 映射 `subscription_quota_only` / `subscription_providers`, 其他路径保持兼容.

## Collector Contract

新增 `collect_subscription_quota_only(ctx)` 或等价 façade:

- `_configure_runtime` 仍是唯一运行时入口.
- 从 `subscription_providers` 解析目标集合.
- 只调用目标 Provider 的现有 handler. 特殊 Provider 不绕过已有边界: Antigravity 继续走 `service_antigravity`, Codex 继续走账号查询和既有 recovery, 官方订阅继续使用注入 OAuth.
- 输出仍是 artifact v1 形状: `module`, `generatedAt`, `agents`, `services`, `totalCostUsd`. 定向路径的 `agents=[]`, `totalCostUsd=null`, `services` 只包含目标 Provider.
- Provider 内多账号保持独立 service, 单账号失败不阻断其他账号.
- 目标集合非法或凭证未装配时返回可诊断失败, 不伪造空的 success artifact.

## Snapshot Merge and Failure Semantics

新增 `ScopedQuotaSnapshotMerger` 或将现有 merger 泛化为 Provider 过滤模式. 输入为 `previous`, `first`, optional `retry`, target Provider 集合和 Codex token decisions.

规则:

1. `agents`、`totalCostUsd` 和非目标 Provider services 从 `previous` 保留; 没有 previous 时保持安全空值.
2. 目标 service 按稳定 `service.id` 合并; 不按展示名或数组位置匹配.
3. 目标结果 `status=ok` 或有效 `empty` 时采用本轮数据, 补 `freshness=fresh`.
4. 目标结果为 error/partial 时保留脱敏失败状态; 若 previous service 具备有效 `capturedAt` 且 freshness 为 fresh/stale, 复制 windows/plan/extra/kind/capturedAt 并标记 `freshness=stale`; 否则标记 `unavailable` 且不写 capturedAt.
5. 本轮目标账号/service 不再出现时不从 previous 复活; 已断开账号不会重新展示.
6. Codex 的 account order、legacy ID 兼容、一次 forced refresh + 一次 retry-only 继续复用现有规则, 但合并结果必须再保留非 Codex previous services.
7. 根 artifact 仍通过现有 `ArtifactValidator` 和原子 `ArtifactStore.publish` 校验. 不新增敏感字段.
8. 定向运行的 response status 以本次目标 Provider 结果计算, 不因被保留的其他 Provider 历史 stale/error 把本次目标成功误报为失败. 全量运行继续按整个 artifact 计算.

credential updates 在 publish 前按现有 `CredentialUpdateCoordinator` 应用. Provider 定向刷新失败时不写入空 credential, 不清除旧 artifact.

## Error and Cancellation Handling

- 运行输入缺少目标 Provider 授权: 不启动 Collector, Provider 状态为 `failed/authRequired`, 其他 Provider 不受影响.
- Bridge schema、Collector 进程或存储失败: 目标 Provider 显示失败; 若有 previous 则保留 stale 数据.
- App stop/cancel: 清除目标 loading, 保留当前 artifact, 不触发完成通知.
- 全量刷新与定向刷新冲突时按 scope 合并契约处理, 不并行启动两个 `agentUsage` 进程.
- 任何错误消息都经过现有脱敏层; 测试断言不得包含 token、secret、完整 OAuth 内容.

## Testing and Acceptance Evidence

### Python/Bridge

- request schema/security: valid single/multiple Provider, missing pair, unknown Provider, duplicate/empty/wrong type, credential scope.
- quota-only collector: only target handler called; no local session/pricing access; selected multi-account output and per-account failure.
- Codex target: existing challenge/retry contract remains at most one forced refresh and one retry.

### Swift Core

- `RefreshIntentMerge`: same Provider dedupe, different Provider union, all wins.
- `OnboardingRunInputProvider`: target credential whitelist and Codex account order.
- merger: preserve unrelated agents/services, successful replacement, stale fallback, unavailable without previous, disconnected service non-resurrection, targeted status.
- scheduler: provider state callbacks, capacity queue, duplicate clicks, cancellation, full-vs-targeted precedence.

### UI and integration

- Provider header button action and accessibility labels compile and render for single/multi-account sections.
- `zsh scripts/verify-local.sh` and relevant harnesses pass. Real Provider network/account behavior remains a separate manually authorized release acceptance item.
