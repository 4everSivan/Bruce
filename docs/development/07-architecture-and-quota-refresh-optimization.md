# mddd 架构与额度刷新优化实施方案

> 版本: 1.0  
> 日期: 2026-08-04  
> 目标: 在保留现有 UI、artifact 契约和 CLI 兼容能力的前提下, 降低刷新链路复杂度, 让 Codex 额度刷新可预测、可测试、可诊断
> 实施进度: 阶段 A 完成 (CodexTokenError.refreshFailed 字符串 reason 收敛为 CodexRefreshFailureReason 枚举); 阶段 B 完成 (handleCodexChallenges + 3 辅助方法 + CodexChallenge/CodexRetryPhaseResult 提取到 CodexQuotaRecovery.swift); 阶段 C 完成 (ArtifactFinalizer 提取四源合并+诊断去重, RefreshBackoffPolicy 提取退避计算, RefreshErrorClassifier 提取错误分类; RefreshScheduler 从 1164 行减到 789 行); 阶段 D 全部完成 (pricing.py 提取 BUILTIN_PRICING/load_pricing/estimate_cost, runtime.py 提取时间工具+HTTP 工具+_RUNTIME_TZ/_RUNTIME_HTTP/TODAY/CUTOFF_TS/DAY_LIST 状态, quota_services.py 提取 DeepSeek/火山 service+解析/签名, local_usage.py 提取聚合+扫描器, codex_compat.py 提取 codex 查询主体 window_label/refresh/service_id/failure_kind/query_single_account; collect_usage.py 从 2059 行减到 1232 行, 6 个模块总计 2210 行); 阶段 E 部分完成 (07 §6.1 Python 路径从 configStore.pythonPath 注入 CollectorRunner; 06 §5 协议死分支清理 username/caFile/baseUrl/request_timeout 从 security.py 白名单+映射+schema 删除); verify-local.sh 全绿. 阶段 E 剩余 (AGY_CLIENT 注入源) 待续

## 1. 优化目标与边界

### 1.1 目标

- 将调度、执行、Codex 自愈、合并、发布和通知拆成职责单一的模块.
- 让一次刷新只有一个明确的生命周期: 触发、执行、可选恢复、合并、发布、排程.
- 保证同一账号在一个周期内最多一次 token 解析、最多一次强制刷新、最多一次重试.
- 统一失败状态、上次成功时间、诊断和凭证轮换的来源.
- 让 App 模式和 CLI 模式共享服务处理逻辑, 但不共享认证副作用.

### 1.2 非目标

- 不改变菜单栏面板的视觉基线和交互结构.
- 不删除 CLI legacy 认证流程, 不改变旧 artifact 的读取兼容.
- 不把第三方凭证写入 artifact、日志或源码.
- 不引入服务端或新的数据库.

## 2. 当前复杂度与主要问题

| 区域 | 当前问题 | 结果 |
|---|---|---|
| `RefreshScheduler.swift` | 同时负责 timer、并发容量、Collector 执行、Codex challenge/retry、四源 merger、诊断、凭证更新、通知 | 状态变量相互影响, 很难判断一次刷新是否已结束 |
| `CodexTokenManager.swift` | 同时负责缓存、OAuth refresh、Keychain 持久化、重试和重新授权状态 | 错误类型被字符串比较, 测试需要构造过多前置状态 |
| `collect_usage.py` | runtime 初始化、扫描、定价、全部 Provider quota、CLI/App 分支、兼容回写集中在一个文件 | 新增 Provider 或刷新策略会触碰无关逻辑 |
| `collect_services` 与 `_collect_app_services` | 两套入口重复维护服务状态和错误语义 | CLI/App 结果容易出现措辞或状态差异 |
| `pendingRerun` 等状态 | 触发原因、排队状态和重复刷新意图混在一个布尔量中 | timer、手动刷新和恢复重试可能互相覆盖 |
| App 运行环境 | Python 路径和 Antigravity 客户端凭证没有统一注入契约 | 本机配置与实际 Runner 行为可能不一致 |

## 3. 目标架构

### 3.1 Swift AppCore 分层

```text
RefreshScheduler (timer/state façade)
        |
        +--> RefreshTrigger / RefreshRunState
        +--> RefreshCapacityGate
        +--> RefreshExecutionPipeline
                    |
                    +--> CollectorInputBuilder
                    +--> CollectorRunner
                    +--> CodexQuotaRecovery (最多一次恢复/重试)
                    +--> CodexQuotaSnapshotMerger (四源合并)
                    +--> ArtifactPublisher
                    +--> CredentialUpdateCoordinator
                    +--> RefreshEventSink (诊断/通知)
```

建议新增或拆出的文件边界:

| 文件 | 单一职责 |
|---|---|
| `RefreshTypes.swift` | `RefreshTrigger`、`RefreshRunState`、结果和失败类型 |
| `RefreshBackoffPolicy.swift` | 退避、下一次执行时间和抖动计算, 不启动刷新 |
| `RefreshExecutionPipeline.swift` | 编排一次完整刷新, 不持有长期 timer |
| `CodexQuotaRecovery.swift` | 解析 challenge、选择账号、强制刷新 token、生成 retry input |
| `RefreshEvent.swift` | 诊断、通知和 UI 状态所需的结构化事件 |
| `RefreshScheduler.swift` | 保留 timer、容量闸门和队列状态, 调用 pipeline |

`RefreshScheduler` 不再直接实现 Collector 细节, 也不再直接拼接 Codex TaskGroup. 所有执行结果通过结构化值返回.

### 3.2 OnboardingCore 分层

将 `CodexTokenManager` 拆成三个可替换边界:

```text
CodexTokenResolver
    -> CodexOAuthClient
    -> CodexCredentialStore
    -> CredentialStateReducer
```

- `CodexCredentialStore`: 只负责 Keychain/index 读写、原子保存和存储错误.
- `CodexOAuthClient`: 只负责设备码、refresh、token endpoint 请求.
- `CodexTokenResolver`: 负责缓存命中、过期判断和账号级并发去重.
- `CredentialStateReducer`: 将成功、需要重新授权、撤销、存储阻断归一为枚举, 禁止字符串比较.

### 3.3 Python Collector 分层

保留现有 `run(ctx)`、`run_app(ctx)` 作为稳定 façade, 内部按职责拆分:

```text
collector/
  runtime.py          # 路径、时间、网络和 context 适配
  local_usage.py      # 会话扫描、token 聚合、成本计算
  pricing.py          # 内置价目与外部补充价目
  quota_services.py   # Kimi/DeepSeek/火山/Antigravity 等服务查询
  codex_compat.py     # CLI legacy 认证读取、刷新和写回
  collect_usage.py    # façade: 组装上下文并返回 artifact
```

App 模式只通过注入凭证进入 `quota_services.py`; `codex_compat.py` 的磁盘认证和写回必须由 `not app_mode` 守卫包围.

## 4. 统一额度刷新流程

一次刷新严格按以下顺序执行:

1. **触发**: timer、手动刷新、启动恢复或上一轮排队请求产生 `RefreshTrigger`.
2. **容量检查**: 若已有刷新运行, 只记录待处理触发原因, 不启动第二个批次.
3. **读取快照**: 本轮只读取一次 previous artifact 和账号索引.
4. **构造输入**: 统一生成 Collector context、凭证快照和模块选择.
5. **首次采集**: 执行一次普通 Collector, 得到 `first` 结果.
6. **Codex 恢复**: 仅当结果包含可恢复 challenge 时, 交给 `CodexQuotaRecovery` 执行一次强制解析.
7. **定向重试**: 只对恢复成功且仍需查询的账号执行一次 retry-only Collector.
8. **四源合并**: `previous + first + retry + decisions` 只经过一个 merger.
9. **凭证更新**: 先验证 update schema, 再由 `CredentialUpdateCoordinator` 写入 Keychain.
10. **原子发布**: 生成完整 artifact, 校验必要字段, 原子替换内存快照.
11. **事件与通知**: 发布成功/部分失败/暂不可用等结构化事件, 再更新菜单栏和通知.
12. **排程**: 由 backoff policy 计算下一次时间; 不在 backoff callback 内直接递归调用 `startRefresh`.

任何失败都必须产生明确的 `failureKind`, 不得用空服务列表伪装成功. `capturedAt` 表示本轮采集时间; `lastSuccessAt` 只在该服务成功时更新.

## 5. Codex 刷新规则

### 5.1 去重与次数上限

- 一个刷新周期内, 同一 account ID 只允许一个 token resolution task.
- challenge 账号只允许一次 forced refresh.
- forced refresh 后只允许一次 retry-only Collector.
- 最终只允许一次 artifact publication.
- 下一个周期才允许重新尝试, 不在当前周期内递归重试.

### 5.2 service ID 与兼容

- 新写入使用稳定的 hash service ID.
- 读取 previous 时同时接受旧前缀 ID 和新 hash ID, 通过 account ID/index 做兼容匹配.
- 迁移完成后不再生成旧 ID, 但旧 artifact 在至少一个发布周期内可被合并.
- display name 与 service ID 分离: name 只承担用户可读名称, 不参与账号匹配.

### 5.3 失败与重新授权

- 401/过期且可刷新: 进入 `recoverable`.
- refresh token 无效、撤销或 Keychain 被阻断: 进入 `needsReauthorization` 或 `storageBlocked`.
- 网络、限流或服务暂时错误: 保留 previous 的 last success 信息, 当前采集标记 `temporarilyUnavailable`.
- 失败时不得伪造新的成功时间, 也不得删除仍可展示的旧快照.

## 6. 必须先修复的运行时契约

### 6.1 Python 解释器路径

设置页选择的 Python 路径必须传入 `CollectorRunner`. Runner 启动前需要:

- 解析并标准化路径.
- 验证文件可执行且版本满足项目要求.
- 将最终路径写入诊断, 但不写入 artifact.
- 启动失败时显示“解释器不可用”, 不回退到未声明的系统 Python.

### 6.2 Antigravity OAuth 客户端凭证

Collector 需要 `AGY_CLIENT_ID`/`AGY_CLIENT_SECRET` 时, App 必须从明确的安全来源注入. 施工时只能选择以下一种并写入授权矩阵:

1. 从 App Keychain 读取并通过一次性子进程环境注入.
2. 明确声明 App 模式不支持该查询, 以可诊断状态结束.

禁止硬编码、写入 artifact、写入普通日志或从未知环境变量静默读取.

### 6.3 DeepSeek 月度数据初始化

旧配置缺少 `usageTrackingID` 时, Collector 应执行一次可诊断的配置迁移或返回明确的“缺少追踪标识”状态. 迁移必须原子写入、可回滚, 且不覆盖用户已有凭证.

## 7. 分阶段施工计划

### 阶段 A: 类型和边界冻结

- 新增 `RefreshTypes`、`RefreshEvent` 和结构化错误枚举.
- 将字符串失败原因集中映射到枚举.
- 为现有 scheduler 补充状态转移测试, 不改变行为.

### 阶段 B: 拆出 Codex 恢复管线

- 把 challenge 解析、账号筛选、forced refresh 和 retry input 移到 `CodexQuotaRecovery`.
- 复用 `CodexTokenBatchResolver`, 删除 scheduler 内重复 TaskGroup/chunking.
- 保持四源 merger 的输入顺序和旧 artifact 兼容.

### 阶段 C: 拆出执行与发布

- `RefreshExecutionPipeline` 负责一次刷新, `RefreshScheduler` 只负责触发和容量.
- `CredentialUpdateCoordinator` 在发布前处理轮换凭证.
- `ArtifactPublisher` 执行 schema 校验和原子发布.

### 阶段 D: Collector 分层

- 先移动纯函数和数据模型, 再移动 Provider handler.
- `codex_compat.py` 单独保留 CLI 旧流程.
- App/CLI 的服务状态统一使用一个 finalize helper.

### 阶段 E: 运行时契约与清理

- 接通 Python 路径选择.
- 决定并实现 Antigravity 客户端凭证来源.
- 执行 `06-redundant-legacy-audit.md` 的 P1 清理.
- 同步 Bridge schema、白名单和测试.

## 8. 测试与验收

### 8.1 单元和边界测试

- scheduler 状态: idle/running/queued/backoff/finished.
- 同一账号重复 challenge 的去重.
- forced refresh 成功、失败、超时、撤销和 Keychain 阻断.
- previous/first/retry/decision 四源合并与旧 service ID.
- 凭证轮换只写 Keychain, 不写 artifact 或日志.
- App/CLI context 字段白名单和 schema 一致性.
- Python 路径选择、不可执行路径和启动失败.
- 缺少 DeepSeek 追踪标识时的迁移/诊断.

### 8.2 必须保持的行为

- `zsh scripts/verify-local.sh` 全部通过.
- artifact 字段、账号顺序、服务状态和 last-success 语义不回退.
- UI 读取模型和现有布局不因内部拆分改变.
- CLI legacy 认证流程仍可用, App 模式不读取未授权的本机认证文件.

## 9. 复杂度门禁与回滚

- 新增模块必须有单一职责和明确输入/输出, 禁止把状态再塞回 scheduler.
- 任何跨模块共享可变数组、全局 token 或隐式时间源都必须拒绝.
- 每个阶段保持可独立回滚; 不允许把架构拆分和 schema 破坏性迁移放在同一提交.
- 若出现刷新次数增加、旧 artifact 被丢弃、凭证写入次数增加或失败被显示为成功, 立即回滚该阶段.

## 10. 完成标准

- scheduler 只保留触发、容量和排程状态.
- Codex 恢复流程可以在独立 Harness 中测试.
- Collector façade 保持稳定, Provider 逻辑可单独测试.
- 一次刷新路径可用结构化事件完整重放.
- 所有兼容流程有明确保留期限或删除决策, 不再依靠注释解释“暂时不要删”.
