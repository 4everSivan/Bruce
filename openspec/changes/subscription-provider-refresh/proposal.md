## 状态

待 Haven Shen 确认. 本文是独立变更请求, 不修改现有产品需求基线.

## Why

当前订阅额度由 `agent-usage` Collector 统一采集, `RefreshScheduler.refresh(.agentUsage)` 会同时触发本地会话扫描和所有已启用 Provider 的额度查询. 订阅卡只有“刷新全部模块”入口, 用户无法只更新一个订阅.

这会带来三个直接问题:

- 只关心某个 Provider 时仍重复读取本机会话和其他 Provider 的凭证.
- 一个 Provider 的限流、认证或网络失败会拖慢整轮刷新, 也难以判断哪个订阅需要处理.
- UI 没有 Provider 级进行中状态, 不能给出精确的刷新反馈.

## What Changes

- 在订阅用量卡的每个 Provider 段增加独立刷新按钮, 保留底栏“刷新全部”行为.
- 将现有刷新管线扩展为 `all` 与 `subscriptionProviders` 两种范围. 单个 Provider 点击只进入目标 Provider 的额度采集.
- `OnboardingRunInputProvider` 按目标范围注入凭证; 定向请求只授予 `externalQuotas`, 不读取本地会话和本地价格.
- Bridge v1 增加受限的订阅定向刷新 context 字段, 对 Provider 名称、集合、布尔关系做 fail-closed 校验.
- Python Collector 增加额度-only 路径, 只构建并查询目标 Provider service; 复用现有 Provider handler、Codex token recovery 和 credential update 白名单.
- 增加 Provider 级快照合并: 保留当前 artifact 的 agents、其他 Provider services 和总成本; 只替换目标 Provider 的成功结果, 失败时按现有 `stale/unavailable` 语义保留最后成功额度.
- 增加 Provider 级刷新状态回调和测试, 不改变现有 artifact v1 字段契约, 不引入新数据库或新的凭证存储.

## Non-Goals

- 不改变自动刷新周期、并发上限、退出流程和全量刷新语义.
- 不新增 Provider, 不改变设置页凭证录入、Keychain 格式或 CLI 模式.
- 不把凭证、账号完整标识或外部响应写入 artifact、日志或诊断.
- 不重做订阅卡视觉样式. 只增加与现有 Provider header 一致的轻量按钮、禁用态和无障碍文案.
- 不进行实时账号或外部 API 验证; 默认验收使用脱敏 fixture 和注入式 HTTP.

## Impact

- Swift: `RefreshTypes`, `RefreshScheduler`, `RefreshExecutionPipeline`, `CollectorRunInput`, `ArtifactFinalizer`/额度合并器, `AppModel`, `ApplicationBootstrap`, `OnboardingCoordinator`.
- Python/Bridge: `collect_usage.py`, `service_catalog.py`, `runtime.py`, `bridge/security.py`, `bridge/schemas/request-v1.schema.json`.
- UI: `MenuBarViews.swift`, `SubscriptionCard.swift`.
- 测试: Python bridge/collector contract tests, `RefreshSchedulerHarness`, `PanelViewModelHarness` 或等价 UI 状态边界测试.

## Acceptance Summary

1. 点击 DeepSeek 时只查询 DeepSeek, 不查询 Kimi、Claude、Grok、Codex、Antigravity, 也不扫描本地会话.
2. 定向成功后 agents、总成本和其他 Provider 的 service 字段保持不变; 目标 Provider 更新为 fresh.
3. 定向失败后保留目标 Provider 最后成功窗口并显示 stale/上次成功时间; 无历史数据时显示 unavailable, 不伪造成功.
4. 连续点击同一 Provider 只产生一次运行; 全量刷新与定向刷新遵守现有容量和 pending 合并规则.
5. Codex 仍最多一次 forced refresh + 一次 retry-only, credential rotation 只写 Keychain.
6. UI 只显示目标 Provider 的 loading/disabled 状态, 失败说明沿用现有脱敏 note.
7. 离线测试通过项目标准脚本和新增边界测试; 真实账号验收仍按发布人工验收清单执行.
