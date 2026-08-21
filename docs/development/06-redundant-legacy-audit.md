# Bruce 冗余代码与旧流程审计

> 原始审计日期: 2026-08-04
> 复核日期: 2026-08-20
> 实施日期: 2026-08-04
> 审计范围: Swift App/Core、Python Collector、Bridge、Widget 契约、测试与构建脚本
> 审计目的: 找出可以安全清理的残留代码和旧流程, 同时明确必须保留的兼容边界
> 实施状态: P1 符号清理已完成; 2026-08-20 复核确认协议候选项已不存在于当前代码, 文档中的原待办已关闭.

## 1. 审计结论

当前项目的主链路已经收敛为:

```text
本机数据/Keychain
    -> CollectorRunner
    -> Bridge v1 安全校验
    -> Python Collector
    -> artifact
    -> AppModel / PanelViewModel
    -> macOS 菜单栏面板
```

仍存在三类需要分阶段处理的内容:

1. **明确未引用的符号**: 可以在补齐编译和边界测试后直接删除, 风险最低.
2. **CLI 兼容流程**: 不是 App 主路径, 但仍服务命令行用户, 不能按“App 不使用”直接删除.
3. **协议/文档不一致**: 需要先决定兼容窗口, 再同步 schema、Bridge、Collector 和文档, 不能只删一侧字段.

## 2. 现有验证基线

审计依据为当前工作树源码、测试和构建结果. 在代码清理前必须保存以下基线:

| 验证项 | 当前基线 |
|---|---|
| Python 测试 | `python3 -m pytest tests/` 通过, 以当前测试收集数量为准 |
| Swift 构建 | `swift build --package-path macos/BruceApp` 通过 |
| Onboarding Core | 以 Harness 实际输出为准 |
| PanelViewModel | 以 Harness 实际输出为准 |
| Artifact | 以 Harness 实际输出为准 |
| CollectorRunner | 26 项通过 |
| RefreshScheduler | 以 Harness 实际输出为准 |
| NativeLifecycle | 以 Harness 实际输出为准 |
| Diagnostics | 以 Harness 实际输出为准 |
| LocalIntegration | 以 Harness 实际输出为准 |
| DeepSeekUsageLedger | 以 Harness 实际输出为准 |
| 标准入口 | `zsh scripts/verify-local.sh` 通过 |

构建中仍可能出现的既有警告需要单独记录, 不得把“清理未引用符号”和无关的 API 弃用一次性混改.

## 3. 可以安全清理的候选项

下表中的“证据”表示当前搜索和调用关系检查没有发现生产调用. 真正删除时仍必须按第 6 节顺序逐项验证.

| 优先级 | 文件/符号 | 现状与证据 | 清理动作 |
|---|---|---|---|
| P1 | `ArtifactModels.swift` 的 `ArtifactHeader` | 当前 artifact 解码和发布路径不读取该类型 | 删除类型及只依赖它的测试辅助代码 |
| P1 | `ArtifactModels.swift` 的 `WidgetDisplayState` | 原生面板和当前宿主不消费; 仅有自引用测试 | 删除类型和自引用测试 |
| P1 | `AppRuntime.swift` 的 `runningTaskCancellations`、`forceTerminationHandlers`、`acceptsNewTasks`、`registerRunningTask`、`finishRunningTask` | 当前生命周期实现没有调用这些成员 | 删除成员, 保留真实的终止和取消入口 |
| P1 | `RefreshScheduler.swift` 的 `refreshAll`、`runningModuleCount` | 调度器内部没有稳定调用方, 当前刷新走统一批次入口 | 删除旧入口, 保留统一刷新 API |
| P1 | `GlassTheme.swift` 的 `glassStatusPill`、`GlassStatusPillModifier` | 当前视图没有使用该 modifier | 删除 modifier 及无调用的样式常量 |
| P1 | `SettingsView.swift` 的 `connectionStatusText`、`connectionStatusIcon` | 设置页面已改用新的连接状态模型 | 删除死的计算属性和对应测试夹具 |
| P1 | `OnboardingCoordinator.swift` 的 `persistConnectionState`、`persistModuleSelection`、`revokeModule` | 当前状态保存/撤销由新的状态协调入口完成 | 删除旧包装方法, 先确认无外部调用 |
| P1 | `SubscriptionCredentialAccount` 的未使用 Codex v2 别名常量 | 仅保留兼容读取所需的实际键名 | 删除未引用 alias, 不删除 v2 读取兼容逻辑 |
| P1 | `CodexDeviceFlow.scope` | 目前 scope 只在初始化时固定, 外部没有读取 | 删除字段或改为私有常量, 保持协议请求不变 |
| P1 | `CodexCredentialStore.updateAuthorizationState` | 当前授权状态更新已由统一保存入口完成 | 删除未引用方法, 补一个“状态保存仍可用”的边界测试 |
| P1 | `collect_usage.py` 内嵌 `finalize().cost_of` | 定义后没有调用, 计算逻辑已内联 | 删除死函数, 不改变成本结果 |
| P1 | `CollectorRunInput.swift` 的 `refreshFailed` 同值分支 | 两个条件返回相同状态 | 合并为单一分支, 保留失败原因在诊断字段中 |
| P1 | `OnboardingRunInputProvider.attachCodexTokenInjector` 调用 | injector 已在初始化时注入, 重复 attach 没有行为收益 | 移除重复调用, 保留初始化注入和测试替身 |

### 3.1 清理约束

- 每次只处理一个候选组, 不在同一提交中同时重写刷新协议.
- 删除前用全仓符号搜索确认生产调用、测试调用和文档引用.
- 删除后至少运行受影响 Harness、Python 测试和 `swift build`.
- 若删除导致 artifact 字段、Keychain 键或 CLI 输出变化, 必须停止并改为兼容迁移方案.

## 4. 必须保留的旧流程与兼容边界

下列内容虽然不是 App 主路径, 但仍是已确认的兼容能力, 不能按“当前 Swift 没有调用”直接移除.

| 流程 | 必须保留的原因 | 后续处理 |
|---|---|---|
| CLI Codex legacy 路径 | 命令行 `run()` 仍支持本机 CLI/第三方认证文件, 并承担旧用户迁移 | 与 App 刷新管线解耦, 但保留单独的 `codex_compat.py` |
| Antigravity 文件优先、Keychain 回退 | 不同版本客户端的认证存储位置不同 | 维持只读回退, 禁止无授权写回 |
| Codex 旧 service ID 与 v2 迁移读取 | 旧 artifact 和旧 Keychain 仍可能存在 | 保留读取兼容, 新写入统一新格式 |
| `credentialUpdates` 协议和 Swift 消费方 | Kimi/Antigravity 令牌轮换需要回写 App Keychain | 保留协议, 后续将消费逻辑集中到凭证协调器 |
| `agent-usage/widget/index.html` 的宿主 helper 与 `tests/visual/host-bootstrap.js` | 视觉契约测试会主动加载这些 helper | 保留, 只清理确实未加载的分支 |
| `orcaCodexAuth` 注入字段 | Bridge 与 Collector 仍有兼容分支, 尚未完成替代方案决策 | 暂不删除, 在架构优化阶段决定删除或补齐真实注入方 |

## 5. 协议与实现不一致项

这些不是“直接删除”的死代码, 需要在施工时同步修改生产方、校验方、消费方和测试.

| 项目 | 当前问题 | 处理要求 |
|---|---|---|
| `bridge/security.py` 的 `username` | 2026-08-20 复核未发现代码、schema 或测试引用 | 保持删除状态, 不新增兼容字段 |
| `bridge/security.py` 的 `caFile -> ca_file` | 2026-08-20 复核未发现映射或消费方 | 保持删除状态, 不新增兼容字段 |
| request schema 的 `baseUrl` | 2026-08-20 复核未发现 schema 或运行时引用 | 保持删除状态, 不新增兼容字段 |
| `build_collector_context` 的 `request_timeout` | 2026-08-20 复核未发现未消费字段 | 保持唯一的现行 HTTP timeout 契约 |
| `AGY_CLIENT_ID`/`AGY_CLIENT_SECRET` | Collector 从环境读取, App 子进程环境白名单未注入 | 在正式支持 App 刷新前补安全注入源; 不硬编码、不伪造空凭证 |
| App Python 路径 | 当前由 Runner 接收已验证路径, 未发现旧固定路径消费 | 保持现行 Runner 契约, 不新增旁路读取 |
| 历史测试/文档数字 | 部分历史记录仍保留当时的测试数字 | 当前说明统一以 `AGENTS.md` 和验证脚本输出为准, 历史记录不回写 |

## 6. 推荐施工顺序

1. **基线冻结**: 保存第 2 节验证结果和当前 artifact schema.
2. **P1 符号清理**: 按表格逐组删除, 每组单独编译和测试.
3. **Bridge 契约收敛**: 先更新 schema, 再更新安全白名单和 Collector, 最后更新测试.
4. **CLI 兼容隔离**: 将旧认证读取、刷新和写回移动到明确的兼容模块, 不与 App 模式共享可变状态.
5. **文档同步**: 更新设计文档、授权矩阵、CI 数字和发布验收, 删除已不存在的宿主描述.
6. **回归验证**: 运行 `zsh scripts/verify-local.sh`; 对 CLI 和 App 分别执行脱敏 fixture 测试.

任一步发现 artifact 字段缺失、Keychain 写入次数变化、账号顺序改变或失败状态被伪装为空数据, 立即回滚该组改动, 不继续下一组.

## 7. 审计完成标准

- P1 候选项全部有"已删除、保留并说明原因、或转为结构性决策"三者之一的结论.
- CLI legacy、Keychain 回退、Codex 迁移和 credential update 均有独立测试入口.
- Bridge schema、白名单、Collector context 和 Swift 消费方字段完全一致.
- 文档不再把已移除的宿主、旧测试数字或不存在的调用方当作当前事实.
- 代码清理不改变当前 UI 样式、artifact 兼容性和授权安全边界.

## 8. P1 符号清理实施记录 (2026-08-04)

### 8.1 已执行 (12 项)

| 候选项 | 文件 | 动作 | 验证 |
|--------|------|------|------|
| `ArtifactHeader` | `ArtifactModels.swift` | 删除类型 (无任何引用) | swift build + 全 Harness 通过 |
| `WidgetDisplayState` | `WidgetDisplayState.swift` + `NativeLifecycleHarness` | 删除类型 + 删除 `widgetStatesMapEveryNativeState` 测试 (生产零消费, 仅自引用测试) | NativeLifecycleHarness 5 passed (原 6) |
| `AppRuntime` 死成员 | `AppRuntime.swift` | 删除 `runningTaskCancellations`/`forceTerminationHandlers`/`registerRunningTask`/`finishRunningTask`; 简化 `hasRunningTasks`/`cancelRunningTasks`/`forceTerminateRunningTasks` (字典永远空, 注册无调用方) | swift build 通过 |
| `refreshAll`/`runningModuleCount` | `RefreshScheduler.swift` | 删除两个无调用方入口 | RefreshSchedulerHarness 55 passed |
| `glassStatusPill`/`GlassStatusPillModifier` | `GlassTheme.swift` | 删除 modifier 及私有类型 (无视图使用) | swift build 通过 |
| `connectionStatusText`/`connectionStatusIcon` | `SettingsView.swift` | 删除两个无调用方计算属性 | swift build 通过 |
| `persistConnectionState`/`persistModuleSelection`/`revokeModule` | `OnboardingCoordinator.swift` | 删除三个无调用方方法 (状态保存/撤销由新协调入口完成) | swift build 通过 |
| `CodexDeviceFlow.scope` | `DeviceAuthLogin.swift` | 删除未读取的 `scope` 常量 (OAuth 请求体未使用) | BruceOnboardingCoreHarness 143 passed |
| `CodexCredentialStore.updateAuthorizationState` | `CodexCredentialStore.swift` | 删除无调用方方法 | BruceOnboardingCoreHarness 143 passed |
| `collect_usage.py` 的 `cost_of` | `collect_usage.py` | 删除死函数 (计算已内联) | Python 115 passed |
| `CollectorRunInput.refreshFailed` 同值分支 | `CollectorRunInput.swift` | 合并双分支为单一返回; 同时将 `.success(accessToken:expiresAt:)` 带标签匹配改为无标签 | swift build 通过 |
| `attachCodexTokenInjector` 重复调用 | `BruceApp.swift` | 删除 line 49 重复 attach (初始化已注入) | swift build 通过 |

### 8.2 未执行 (1 项, 审计描述有误)

| 候选项 | 原因 |
|--------|------|
| `SubscriptionCredentialAccount` Codex v2 别名 | 审计称"未引用", 实际 `codexAccounts`/`codexActiveAccount` 有大量测试引用 (CollectorRunnerHarness, BruceOnboardingCoreHarness); 且与 `CodexCredentialModels.legacyAccounts`/`legacyActiveAccount` 是不同用途的常量组, 不应删除 |

### 8.3 不在 P1 范围 (07 约束保留)

以下虽在旧版审计中列为可删除, 但 07 文档 §1.2 明确"不删除 CLI legacy 认证流程", 因此保留:

- CLI Codex legacy 路径 (`_codex_refresh` 刷新管道, CLI 写回三件套)
- `codex_quota_account_order` credentials 回退 (CLI 兼容)
- `_record_credential_update("codex", ...)` (CLI legacy 分支, App 模式不可达, 与 Bridge `UPDATE_PROVIDERS` 不交叉)

### 8.4 回归验证结果

- `swift build --package-path macos/BruceApp`: 通过 (仅 1 个既有 ActorIsolatedCall warning, 非本次引入)
- `python3 -m pytest tests/`: 115 passed
- `zsh scripts/verify-local.sh`: 全绿 (Python 115 + Onboarding 143 + PanelViewModel 32 + ArtifactStore 4 + CollectorRunner 26 + RefreshScheduler 55 + NativeLifecycle 5 + Diagnostics 8 + LocalIntegration 3 + DeepSeekUsageLedger 17)

### 8.5 历史待办复核结果

- `bridge/security.py` 的 `username`/`caFile`/`baseUrl`/`request_timeout`: 已确认当前仓库无残留, 不再作为施工任务.
- `AGY_CLIENT_ID`/`AGY_CLIENT_SECRET`: 仍按现行运行环境注入策略保留, 不在本次死代码清理中改动.
- App Python 路径: 仍由 Runner 的已验证路径契约负责, 不在本次死代码清理中改动.
- 历史测试/文档数字: README、CI 和工具链文档已改为动态描述或现行产物名称.

### 8.6 2026-08-20 复核说明

本次复核只清理文档中的过时结论, 不恢复已删除的类型、协议字段或旧宿主流程. `MenuBarStatusItemController` 是当前菜单栏入口, `MenuBarExtra` 仅作为历史实现名出现在源码注释中.

## 8.7 2026-08-20 收敛施工记录

本轮审查中的可执行项已完成, 并以 `zsh scripts/verify-local.sh` 作为统一验收入口:

| 项目 | 处理结果 |
|------|----------|
| Collector 运行上下文 | 生产采集、额度 catalog、Codex/Antigravity、订阅定向刷新和本地扫描均显式传递 `RunContext`; `run_app` 正常路径不再读取最近一次运行指针 |
| 兼容 seam | `_ACTIVE_RUN_CONTEXT`、`_RUNTIME_CREDENTIAL_UPDATES`、`_RUNTIME_CREDENTIAL_CHALLENGES` 以及 `runtime` 的日期/HTTP setter 仅保留给旧直接测试和 CLI 兼容调用, 生产业务不得新增引用 |
| Swift 颜色工具 | `Color(hex:)` 和 `Color.adaptive` 集中到 `GlassTheme.swift`, 卡片和设置页重复 extension 已删除 |
| App 打包清单 | `scripts/runtime-manifest.zsh` 成为 Preview/Release 唯一运行时文件清单, 两个打包脚本共享校验和复制逻辑 |
| OpenSpec | `docs/openspec` 为正式唯一真源, 根 `openspec` 仅为兼容符号链接 |
| 文档和产物 | README、CI、工具链、设计、审计和发布文档已同步当前状态与 `dist/Bruce.app`/`dist/Bruce.zip` 产物名 |

验证结果: Python `246 passed`; Swift build、全部 Harness、Preview App 组装、bundle 签名校验均通过. 正式版签名、公证和 Gatekeeper 仍只受外部 Developer ID/API Key 配置约束, 不属于代码残留.
