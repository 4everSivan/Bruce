# mddd 架构收尾与流程修复设计

> 日期: 2026-08-05  
> 状态: 已评审确认 (brainstorm §1–§6)  
> 范围: 全量架构收尾 (审查 P0–P2 + `docs/development/07-architecture-and-quota-refresh-optimization.md` 未完成项)  
> 交付: 一份总设计 + 分阶段实施计划 (另文 writing-plans)

---

## 1. 背景与问题

### 1.1 现状

`07` 阶段 A–E 已完成部分拆分:

- `CodexQuotaRecovery` / `ArtifactFinalizer` / `RefreshBackoffPolicy` / `RefreshErrorClassifier` 抽出
- Collector 拆出 `pricing` / `runtime` / `quota_services` / `local_usage` / `codex_compat` / `quota_official`
- `RefreshScheduler` 约 1164 → 789 行; `collect_usage.py` 约 2059 → 1311 行

复杂度被搬移多于被删除. 2026-08-05 严格代码审查指出的残余问题:

| 区域 | 问题 |
|------|------|
| `OnboardingCoordinator` (~1392) | God Object: 授权/扫描/7 Provider CRUD/设备码/本机探测 |
| `SettingsView` (~1273) | 七路 Provider switch, 与 Coordinator 1:1 扇出 |
| `collect_usage.py` (~1311) | App/CLI 双入口, 模块级 global 运行时 |
| `PanelViewModel` (~1084) | 模型+映射+Provider 展示特例混装 |
| `RefreshScheduler` | 仍编排整次刷新; `pendingRerun` 一布尔双义 |
| 凭证写回 | `try? saveCredential` 静默失败 |
| 过期语义 | Swift `SubscriptionCredentialEvaluator` 与 Python `quota_official` 双源镜像无契约测试 |
| Harness | 单文件 3k+ 行, 维护成本高 |

### 1.2 根因

新增订阅 Provider 需横穿 Settings → Coordinator → RunInput → Bridge → Python → Panel, 无单一扩展点. 刷新路径上触发原因与业务编排仍糊在 Scheduler.

### 1.3 关系文档

- 继承并收尾: `docs/development/07-architecture-and-quota-refresh-optimization.md`
- 冗余清理参考: `docs/development/06-redundant-legacy-audit.md`
- 本设计是架构债战役规格, 不重开产品需求

---

## 2. 目标与非目标

### 2.1 目标

1. 刷新触发/排队语义显式可推理 (`RefreshIntent`)
2. 凭证轮换写回失败可诊断 (禁止 `try?` 静默吞掉)
3. Scheduler 只做触发/容量/排程; 一次刷新由 `RefreshExecutionPipeline` 编排
4. Provider 扩展走注册表, 消灭跨层 if/switch 扇出
5. App/CLI 共享 service 处理核, 认证副作用隔离
6. 过期判定 Swift/Python 强制契约测试 (共享 fixture)
7. 核心生产文件与巨型 Harness 按职责拆分 (纯搬迁)

### 2.2 非目标 (硬门禁)

| 禁止 | 说明 |
|------|------|
| **改 UI 布局** | 不改 SwiftUI 视图层级, 间距, 字体层级, 卡片分区, 设置页区块顺序与控件排布 |
| 改菜单栏/面板视觉 | 不改 liquid glass 观感与颜色 token 的可见调整 |
| 加新 Provider / 新功能 | 本战役只重构与可观测性 |
| 删 CLI legacy | 保留 CLI 认证与 `run()` 契约 |
| 破坏 artifact 契约 | 字段名, status 语义, 账号顺序对外保持 |
| 服务端 / 新 DB | 不引入 |

### 2.3 唯一允许的用户可感知语义变化

- Keychain 凭证写回失败时: 增加 **诊断** (及在已有通道上将 module status 置为 `partial` 的可能)
- **不新增控件, 不改布局骨架**
- 若当前无合适展示位: 只进入 diagnostics / 既有状态 detail 通道, 不为写回失败新开 Settings 分区或 Alert 布局

### 2.4 UI 布局冻结的工程落法

1. Settings 拆分: 只允许文件剪切与同构子 View; 禁止改 `padding` / `spacing` / `frame` / 控件顺序
2. Panel: 默认只动 `MdddAppCore` 映射层; `Sources/MdddApp/Views/**` 默认零 diff
3. 每阶段 PR 对 Views / Settings 布局相关 diff 人工门禁: 布局修饰符数值变更 = 阻断
4. 回归: `zsh scripts/verify-local.sh`; 不以截图基线变更合理化布局改动

### 2.5 行为冻结

- artifact 字段, Bridge schema, 刷新次数上限 (Codex 一周期一次 forced refresh + 一次 retry), CLI 写回边界保持
- 不借重构统一产品文案 (App/CLI note 差异以契约测试锁定的现状为准)

---

## 3. 总策略与阶段

采用 **水平分层 (方案 B)**, 五阶段串行合入, 每阶段可独立回滚.

```text
S1  横切运行时止血
    RefreshIntent + CredentialUpdateCoordinator (可观测写回)

S2  刷新执行收口
    RefreshExecutionPipeline; Scheduler = timer/容量/排程 façade

S3  Provider 扩展模型
    Registry + inject/configured/workflow; Coordinator/Settings 文件拆分

S4  Collector 统一
    RunContext + 统一 build_quota_services; 过期双端 fixture

S5  展示映射与测试卫生
    Panel policy 拆分; Harness 拆分; CodexTokenManager 三分
```

第一阶段优先: S1 (与评审确认一致).

每阶段硬门禁:

1. `zsh scripts/verify-local.sh` 全绿
2. 不改 UI 布局
3. artifact / Bridge schema 无未文档化破坏
4. 无密钥进入诊断, 日志, artifact
5. 可独立回滚该阶段

---

## 4. S1 — RefreshIntent + 凭证写回可观测

### 4.1 问题

1. `pendingRerun: Bool` 同时表示同模块合并请求与跨模块容量排队, 丢失触发原因
2. `CollectorRunInput.apply(credentialUpdates:)` 使用 `try? saveCredential`, Keychain 失败静默

### 4.2 RefreshIntent 模型

新建轻量类型 (建议 `RefreshTypes.swift` 或并入现有 types 文件):

```text
enum RefreshTriggerReason: Equatable, Sendable {
  case timer
  case manual
  case wake
}

struct RefreshIntent: Equatable, Sendable {
  var reason: RefreshTriggerReason
  /// 一旦出现过 manual, 合并后仍视为 manual (保护额度预警不误弹)
  var includesManual: Bool
}
```

`ModuleScheduleState` 变更:

- 删除 `pendingRerun: Bool`
- 增加 `pendingIntent: RefreshIntent?`
- 保留 `lastTriggerWasManual`: 在真正 `startRefresh` 时由即将执行的 intent 的 `includesManual` 写入

**合并规则** (同模块再次 trigger):

```text
merge(existing?, incoming) -> RefreshIntent:
  includesManual = (existing?.includesManual ?? false)
                 || incoming.includesManual
                 || incoming.reason == .manual
                 || (existing?.reason == .manual)
  reason = 若 includesManual 或任一侧 reason == .manual -> .manual
           else 保留已有 reason (先到为主)
```

容量排队: 模块 A running, B 请求 → B.`pendingIntent = incoming`; A 完成后消费 `pendingIntent != nil && phase == idle`.

同模块 running 再请求: 只 merge 进 `pendingIntent`, 不启第二进程 (与现行为一致).

对外 API: 尽量保持 `triggerRefresh(for:isManual:)`, 内部转 Intent.

入口映射:

| 入口 | Intent |
|------|--------|
| `isManual: true` | `{ .manual, includesManual: true }` |
| timer | `{ .timer, includesManual: false }` |
| wake / reactivation | `{ .wake, includesManual: false }` |

### 4.3 CredentialUpdateCoordinator

从 `apply` / bootstrap 回调抽出 (`MdddAppCore`):

```text
struct CredentialUpdateApplyResult: Equatable {
  var appliedCount: Int
  var skippedCount: Int
  var failed: [CredentialUpdateFailure]
}

struct CredentialUpdateFailure: Equatable {
  var provider: String
  var accountId: String
  var reason: String  // 无密钥; 仅分类/系统错误摘要
}
```

流程:

1. 解析 JSON → `CredentialRotationUpdate` (仍拒绝 codex)
2. `CredentialRotationMerge.mergedJSON`
3. `saveCredential` **传播错误, 禁止 `try?`**
4. 单条失败记入 `failed`, 继续后续条目
5. 返回 `CredentialUpdateApplyResult`

可观测性:

- `onCredentialUpdates` 改为 **同步返回** `CredentialUpdateApplyResult` (或 Coordinator 由 Scheduler 持有)
- `failed` 非空: 诊断 `code=CREDENTIAL_PERSIST_FAILED`, `stage=credentialUpdate`; 有 artifact 且原 success → 降为 `partial`
- 禁止为写回失败新增 Alert / Settings 分区

### 4.4 S1 测试

| 用例 | 期望 |
|------|------|
| running 时 3 次 manual | 只再跑 1 次; includesManual |
| 容量满排队 | 槽位释放后按 pending intent 启动 |
| timer 合并进 manual pending | 执行时不弹额度预警 |
| 写回成功 | Keychain 更新; status 与现一致 |
| 写回失败 | partial (有 artifact) + 诊断; 无密钥 |
| codex rotation | 仍跳过 |
| 多条部分失败 | 成功条已写; 失败在 failed |

### 4.5 S1 非目标

不抽 Pipeline; 不改 Provider 注册表; 不改 Python; 不改 Views body.

### 4.6 S1 回滚

恢复 `pendingRerun` + 原 `apply`; 无 schema migration.

---

## 5. S2 — RefreshExecutionPipeline

### 5.1 目标

一次刷新 = Pipeline 一次调用; Scheduler 只映射结果到 phase/timer. 行为与 Codex 恢复次数/合并顺序与现一致. 零 Views 改动.

### 5.2 边界

```text
RefreshScheduler
  - states / timers / capacity / wake / RefreshIntent
  - 调用 pipeline.run
  - apply(PipelineResult) → phase, onStatusChange, scheduleNext, onQuotaAlerts

RefreshExecutionPipeline
  - 无 timer, 无长期 ModuleScheduleState
  - 依赖: CollectorExecuting, RunInput?, ArtifactStore,
          CredentialUpdateCoordinator, CodexQuotaRecovery,
          ArtifactFinalizer, CodexChallengeHandling?
```

### 5.3 固定生命周期

```text
1. resolveRunInput
2. loadPreviousArtifact   (一轮只读一次)
3. firstCollect
4. optionalCodexRecovery  (仅 agentUsage; 现有语义)
5. finalize               (ArtifactFinalizer)
6. applyCredentialUpdates
7. publish + 合并 credential 失败诊断
8. evaluateQuotaAlerts    (纯输入; 是否弹由 Scheduler 结合 includesManual)
9. return PipelineResult
```

失败映射与现 `handleRunInputFailure` / `handleResult` 一致 (authRequired, backoff 分类, storage 等).

`CompletedRun`: 最终 response, credentialApply, quota 候选, diagnostics, includesManual.  
credential 失败且原 success → response.status partial (在 Pipeline 落地).

### 5.4 Codex 特例

S2 不泛化多 Provider recovery. 仅调用现有 `CodexQuotaRecovery`. 禁止为空扩展加空框架层.

### 5.5 与 S1 衔接

- Request 携带 `RefreshIntent`
- 删除 fire-and-forget 写回回调; Coordinator 由 Pipeline 持有
- `onRunCycleCompleted` 仍在 Scheduler apply 末尾

### 5.6 S2 测试

无 challenge 成功; challenge+recovery; recovery 失败仍 finalize; run input auth; publish 失败; credential 写失败; cancel/stopped.

可新增 Pipeline harness 或从 Scheduler harness 迁执行路径用例.

### 5.7 S2 非目标

Provider 注册表; Python; TokenManager 三分; 改默认刷新间隔/capacity.

### 5.8 S2 回滚

`executeRefresh` 内联恢复; 无持久化格式变更.

---

## 6. S3 — Provider 注册表 + Onboarding/Settings 拆分

### 6.1 目标

1. 单一 `ProviderRegistry` 描述凭证账户, 注入形状, configured 规则
2. 新 Provider 主干 diff ≈ 注册 + 新文件
3. Coordinator 保留 consent/scan/gate/reconcileScheduler/外观与间隔
4. 订阅 CRUD → `SubscriptionService` (Coordinator 可留 thin façade)
5. 行为冻结 + UI 布局冻结

### 6.2 ProviderDescriptor (MdddOnboardingCore)

```text
ProviderDescriptor:
  id, credentialAccounts, injectionKind, configuredRule

InjectionKind:
  kimiWebTokensJSON
  deepseekAPIKeyEnv
  volcengineUsageScriptKeys
  codexQuotaAccounts
  antigravityOAuthJSON
  claudeMetaEnabledPlusOptionalOAuth
  grokMetaEnabledPlusOptionalOAuth

ConfiguredRule:
  allCredentialAccountsNonEmpty
  codexHasConfiguredRecords
  claudeAppOrLocalProbe
  grokAppOrLocalProbe
```

统一 `assembleCredentials(...)` 按 `InjectionKind` 派发; 输出 JSON 形状与现 Bridge 白名单字段完全一致.

### 6.3 子步

| 子步 | 内容 |
|------|------|
| S3a | Registry + ConfiguredRule + 统一 assemble; 行为测锁定 |
| S3b | `SubscriptionService` 搬迁订阅方法; Coordinator thin façade 保持 Settings 调用点 |
| S3c | Settings 按文件拆 7 个 section; **禁止布局属性变更** |
| S3d | `LocalCredentialProbe` 集中本机/Keychain 探测 |

### 6.4 Codex / DeepSeek

- Codex: `InjectionKind.codexQuotaAccounts` 仍委托 token manager; 设备码可迁 `CodexDeviceLoginSession`, UI 布局冻结
- DeepSeek: `DeepSeekSaveTransaction` 只改调用方归属, 不改事务步骤

### 6.5 AppModel 投影

`claudeLocalAvailable` 等字段保留, 避免改绑定; 刷新时机不变.

### 6.6 成功标准

- 无 per-provider if 链于 assemble / configured 主干 (规则在枚举内)
- Onboarding/Subscription/CollectorRunner harness 全绿
- Views 布局零意图变更

### 6.7 S3 非目标

Python 统一 (S4); Panel policy (S5); 必须删除 thin façade; 改 `reconcileProviderOrder` 语义.

### 6.8 回滚

S3a–d 各自可逆; OnboardingConfiguration 字段不变.

---

## 7. S4 — Collector 统一 + 过期双端契约

### 7.1 目标

| 目标 | 说明 |
|------|------|
| 单一 service 构建核 | App/CLI 共用描述→查询→finalize |
| Mode 只影响凭证来源 | 不复制业务分支 |
| 显式 RunContext | 单次 run 路径/时间/http/凭证/updates |
| 过期契约测试 | 同 fixture 约束 Swift + pytest |
| 行为冻结 | artifact/status/CLI 写回边界不变 |

### 7.2 RunContext

数据类承载 home, paths, now, timezone, http, days, timeout, app_mode, credentials, capabilities, credential_updates, credential_challenges.

`run` / `run_app` 构造 context 传入 collect. 过渡期可薄包装; **禁止新代码新增 global 依赖**.

### 7.3 统一 `build_quota_services(ctx)`

声明式 `ServiceSpec` (service_id, display_name, app, source, query).  
`resolve_credentials(ctx, spec)` 是唯一 mode 分叉点.  
finalize 统一 empty/error note 截断.

Claude/Grok: 同一 query 实现; 无凭证策略以**现有契约测试锁定的现状**为准, 不借机改产品文案.

Codex/Antigravity: App 不走 `codex_compat` 磁盘写回; AGY 缺 client 可诊断降级保持.

### 7.4 过期 fixture

目录建议: `tests/fixtures/credential-expiry/`  

矩阵与现 Evaluator 一致: nil/无法解析→未过期; 数字 >1e12 毫秒否则秒; ISO 失败→未过期.

改任一侧过期逻辑必须同 PR 更新 fixture 或双端测试.

### 7.5 子 PR 顺序

1. S4a 过期 fixture + 双端契约 (先锁再动)
2. S4b RunContext 接线
3. S4c 统一 build_quota_services, 删重复 `_collect_app_services` 实现
4. S4d 清理 façade 大段与死 global

### 7.6 验收

现有 pytest 全绿; Bridge schema 不变; 理想无 SwiftUI Views diff; verify-local 全绿.

### 7.7 非目标

改价目/成本; 新 Provider; 删 CLI; 改 artifact schemaVersion.

---

## 8. S5 — Panel / Harness / CodexTokenManager

### 8.1 S5a Panel

拆分建议:

```text
PanelModels.swift
PanelViewModelMapper.swift
UsageMapping.swift
SubscriptionMapping.swift
SubscriptionPresentationPolicy.swift
```

Policy 冻结规则: kimi_coding→kimi 排序键; volcengine 显示名剥离; 加量包文案隐藏; deepseek 月度挂载; codex 分组; partial 占位 skip.

禁止改 LIVE 默认阈值, 14 日窗口, 默认排序算法.  
Views 默认零 diff.

### 8.2 S5b Harness

按场景拆文件, 不改断言语义. Scheduler / OnboardingCore 等巨石按 MARK 切开.  
verify-local 显式覆盖全部 executable.  
实施时可与 S1–S4 穿插 (例如改 Scheduler 前先拆 intent 相关用例).

### 8.3 S5c CodexTokenManager 三分

```text
CodexCredentialStore     (已有)
CodexOAuthClient         (已有)
CodexTokenResolver       (缓存, 过期, in-flight 去重)
CredentialStateReducer   (纯函数状态归一, 禁字符串散落比较)
```

可保留 `CodexTokenManager` 类型名作 façade, 减少调用方 churn.  
不改 OAuth endpoint, v2 schema, 迁移语义.

### 8.4 S5 非目标

新卡片; 新诊断 UI 区; 删 CLI; 性能专项.

---

## 9. 风险与缓解

| 风险 | 缓解 |
|------|------|
| S3 一次迁 7 Provider 巨大 PR | 强制 S3a–d; Settings 先 façade |
| S4 悄悄改 note/status | S4a 先锁 fixture; 金样对比 |
| Pipeline 漏 cancel/stopped | S2 专用用例 |
| Intent 合并改额度预警 | 锁 includesManual 与 onQuotaAlerts |
| Panel 拆分改渲染 | Panel harness; Views 零 diff |
| Harness 拆分漏跑 | verify-local 列全 |
| 工期膨胀 | 阶段串行; 不混 schema 破坏与重构 |

---

## 10. 完成定义 (战役结束)

- [ ] Scheduler 无长期业务编排; Pipeline 可独立测一轮刷新
- [ ] `pendingRerun` 布尔不存在; 意图可解释
- [ ] 凭证写回失败可诊断且无密钥泄漏
- [ ] 新 Provider 扩展路径有文档化注册表步骤
- [ ] App/CLI 共用 service 构建核; mode 仅解析凭证
- [ ] 过期规则双端同 fixture
- [ ] Panel 映射与 policy 分文件; 核心 God Object 显著瘦身
- [ ] `verify-local.sh` 全绿; UI 布局无故意变更

---

## 11. 实施计划衔接

详细 task 级计划由 writing-plans 产出至:

`docs/superpowers/plans/2026-08-05-architecture-remediation-implementation-plan.md`

计划必须:

- 按 S1→S5 排序, 含子步与验证命令
- 每步标注 UI 布局门禁
- 每步可回滚说明
- 不包含实现代码提交本身

---

## 12. 决策记录

| 决策 | 选择 |
|------|------|
| 范围 | 全量架构收尾 |
| 行为 | 严格行为冻结; 唯一增强为凭证写回可诊断 |
| UI | **所有改动均不允许修改 UI 布局** |
| 交付 | 一份总设计 + 分阶段实施计划 |
| 策略 | 水平分层方案 B |
| 第一阶段 | S1 RefreshIntent + 凭证写回 |
