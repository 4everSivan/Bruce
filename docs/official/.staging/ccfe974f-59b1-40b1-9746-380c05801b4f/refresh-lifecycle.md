# 刷新生命周期

Bruce 的刷新从 macOS 应用装配开始，经授权门控、调度、Rust 子进程、快照发布，再回到界面模型。`RefreshScheduler` 管理何时执行，`RefreshExecutionPipeline` 管理一次执行的先后关系，`CollectorRunner` 管理进程与 Bridge 协议。

## 启动与触发

`BruceApp` 装配 runner、快照库、运行输入提供器和共享凭据管理对象。`ApplicationBootstrap.startIfNeeded()` 先接好工件、状态、Provider 刷新及预警回调，再启动调度器读取缓存。配置侧完成扫描后，`OnboardingCoordinator.reconcileScheduler()` 依据统一同意、模块选择、就绪度、自有存储访问状态和应用生命周期启用或禁用模块。

调度支持定时、手动、唤醒/重新激活和 Provider 定向刷新。默认刷新周期为 1800 秒，缓存陈旧阈值为 3600 秒，容量上限为 2；当前 `CollectorModule` 只有 `agentUsage`，容量是实现边界，不表示实际有两个业务模块。启用模块且没有成功时间时，下一次调度延迟为 0；有成功时间时按剩余间隔计算，额度窗口边界可以提前唤醒。唤醒仅刷新已启用、允许自动刷新且到期的模块，`authRequired` 不自动重试。

依据：[`BruceApp.swift`](../../apps/macos/Sources/BruceApp/BruceApp.swift)；[`ApplicationBootstrap.swift`](../../apps/macos/Sources/BruceApp/ApplicationBootstrap.swift) 的 `startIfNeeded`；[`OnboardingCoordinator.swift`](../../apps/macos/Sources/BruceApp/OnboardingCoordinator.swift) 的 `reconcileScheduler`；[`RefreshScheduler.swift`](../../apps/macos/Sources/BruceAppCore/RefreshScheduler.swift) 的 `SchedulerConfiguration.default`、`scheduleNextRefresh`、`handleWakeOrReactivation`。

## 调度状态与意图合并

调度相位与界面状态分别表达“能否执行下一轮”和“如何呈现已有结果”。以下状态图概括启用、执行、失败与恢复；`stopped` 是调度器整体标记，不是模块相位。

![模块调度相位与带条件的执行、失败、取消转移](../assets/km/macos-scheduler-state.svg)

图：模块调度状态。展示常规启用与执行路径，整体停止标记与各相位叠加；显式禁用后在途任务的结果收尾未在图中展开，见下文。

`disabled` 经启用转为 `idle`；`idle` 接收可执行意图后进入 `running`。运行中收到请求或容量不足时，请求保存在 `pendingIntent`。合并保留手动属性，两个定向范围取 Provider 并集，任一全量范围优先。成功发布后回到 `idle` 并先排空同模块待处理意图；非 idle 收尾会丢弃待处理意图。

授权缺失进入 `authRequired`，只允许手动意图重新尝试；部分 Provider 授权诊断若仍有可发布工件，不使整个模块进入该相位。非授权失败进入 `backoff`：限流固定等待 300 秒，其他错误从 30 秒指数退避并加最多 10% 抖动，封顶 1800 秒。超过 5 次退避后归零计数、回 `idle`，等待正常周期。定向刷新失败后的退避重试范围为全量，手动属性继续保留。

取消清空待处理意图；有历史成功时回 `idle` 并显示 `stale`，没有历史成功则转 `disabled` 并显示 `notConfigured`。该路径不会触发周期完成回调。`disableModule` 将模块设为禁用并取消该模块定时器，未直接取消已启动进程；整体 `stop()` 才取消全部执行器任务。禁用后若在途执行继续完成，收尾方法仍会处理结果：成功可发布工件并把相位改为 `idle`，失败可转 `backoff` 或 `authRequired`。`enabled` 仍为 false，后续正常调度及 `startRefresh` 不会启动新任务；不能仅凭相位判断模块是否启用。

依据：[`RefreshTypes.swift`](../../apps/macos/Sources/BruceAppCore/RefreshTypes.swift) 的 `RefreshIntentMerge.merge`；[`RefreshScheduler.swift`](../../apps/macos/Sources/BruceAppCore/RefreshScheduler.swift) 的 `triggerRefresh`、`finishCycle`、`handleRunInputFailure`、`applyCompleted`、`handleBackoff`、`handleCancellation`；[`RefreshBackoffPolicy.swift`](../../apps/macos/Sources/BruceAppCore/RefreshBackoffPolicy.swift)。

## 一次执行的交接顺序

一次流水线执行按输入、采集、恢复、凭据写回和发布的顺序前进。图中“输入与凭据”表示职责集合，运行输入提供器和 `CredentialUpdateCoordinator` 是不同对象。

![单次刷新在调度器、输入凭据、Collector 与快照发布之间的顺序](../assets/km/refresh-sequence.svg)

图：单次刷新交互顺序。表示 `RefreshExecutionPipeline` 的主线及条件恢复，不表示已执行的运行记录。

1. **取得运行输入。** 全量使用 `runInput(for:)`，定向使用 `scopedRunInput(for:providers:)`。输入授权错误直接返回，不启动进程；其他输入错误按依赖缺失处理。
2. **读取上一份工件。** 每轮只从快照库读取一次，读取失败时用空的历史工件继续采集。该快照供后续失败保留与账号合并使用。
3. **执行首轮 Collector。** Runner 接收 `context` 与 `credentials`，产生 Bridge 响应或执行错误。
4. **执行条件恢复与合并。** `agentUsage` 可处理 Codex 账号挑战，恢复后的结果和历史快照由 finalizer 合并。定向范围使用 `ScopedQuotaSnapshotMerger` 把目标 Provider 结果合回完整工件，避免未刷新服务被覆盖。
5. **应用凭据轮换。** 非错误的可处理响应先应用 `credentialUpdates`。写回失败追加存储诊断，有工件且原状态成功时降为 `partial`。
6. **发布快照。** 没有工件时返回不可发布结果；有工件时经 `ArtifactStore.publish` 校验和保存。发布失败按存储错误处理，已经写回的凭据不会因此回滚。
7. **评估并回传。** 发布后计算额度预警候选，调度器回调 `AppModel` 并完成相位、下一轮定时器和待处理意图的更新。

Bridge `status == error` 或存在授权错误且无工件时，不应用凭据更新也不发布。流水线在运行输入后、首轮后和恢复后检查整体停止状态，停止则返回取消结果；执行器错误、输入失败和发布失败分别保留为不同结果类型。

依据：[`RefreshExecutionPipeline.swift`](../../apps/macos/Sources/BruceAppCore/RefreshExecutionPipeline.swift) 的 `run`、`finishPublishablePath`；[`RefreshScheduler.swift`](../../apps/macos/Sources/BruceAppCore/RefreshScheduler.swift) 的 `executeRefresh`、`apply`。

## Bridge 子进程边界

`CollectorRunner.run(module:context:credentials:) async throws -> CollectorRunOutput` 先校验可执行路径、同模块互斥与最多 2 个活动进程，再生成 `runId`，把 schema 版本、模块、超时、上下文和凭据编码为 stdin JSON。启动参数为空，环境只保留固定 `PATH`、locale 和临时目录；stdout、stderr 分别在 utility 队列读到结束，避免管道互相阻塞。

正常返回要求退出码为 0、响应可解码、schema 为 1、`runId` 一致，并且非 error 响应必须有工件。stderr 仅转为行数与字节数摘要；错误响应与进程失败是不同层次。默认本地扫描超时 30 秒、外部请求超时 10 秒、模块超时 90 秒；前两者随请求交给 Collector，Runner 自己监控模块超时。

取消或超时先 `Process.terminate()`，默认 2 秒后仍未退出则发 `SIGKILL`。完成时先移出活动任务、取消计时器，再恢复等待 continuation；被请求取消或超时的任务优先返回对应终止结果，不把随后到达的 stdout 当成功。

依据：[`CollectorRunner.swift`](../../apps/macos/Sources/BruceAppCore/CollectorRunner.swift) 的 `CollectorTimeouts.default`、`SystemCollectorProcessLauncher.launch`、`beginRun`、`complete`、`scheduleForceTermination`。

## 快照与界面更新

快照默认保存在 `~/Library/Application Support/Bruce/snapshots/agent-usage.json`，上一份有效快照为 `agent-usage.previous.json`，元数据在 `metadata/modules.json`。`publish` 先验证新工件，保留有效旧工件，原子写入当前文件，最后写入成功时间等元数据。它不是跨快照与元数据的单一事务；元数据失败仍可能已有新快照落盘，调度器只在整个发布调用成功后更新内存成功状态。

`load` 优先读取当前工件，损坏或不兼容时可回退 previous；previous 也失败时尝试一次底层备份回滚。schema v0 的迁移先保留原始备份，未知新 schema 拒绝；回退结果强制陈旧并记录 schema 错误。启动缓存恢复不要求先访问凭据。

发布成功后，调度器先回调新工件，再发布 `fresh` 或 `partial`。`AppModel` 失效相关缓存，按呈现门控过滤订阅服务，再经 `PanelViewModelMapper` 生成三类卡片。菜单栏和面板使用同一解码结果，分别维护摘要/映射缓存。Provider 定向刷新另有 `started/finished/failed/cancelled` 回调，仅维护目标按钮的刷新集合；它与凭据导入 busy 状态独立。

依据：[`ArtifactStore.swift`](../../apps/macos/Sources/BruceAppCore/ArtifactStore.swift) 的 `publish`、`load`、`migrateV0`、`storedArtifact`；[`ApplicationBootstrap.swift`](../../apps/macos/Sources/BruceApp/ApplicationBootstrap.swift) 的回调装配；[`AppModel.swift`](../../apps/macos/Sources/BruceAppCore/AppModel.swift) 的缓存与映射入口。

## 预警、后台与退出

预警仅针对 5 小时窗口已用量严格大于 80% 的条目，跳过 `freshness == stale` 的服务。调度器以 `serviceID|windowLabel` 去重，每次同步阈值集合，只有非手动刷新出现新跨越才投递；启动从缓存恢复该集合以避免重启重复提醒。`QuotaAlertNotifier` 受应用开关控制，首次实际投递才请求系统通知权限，系统未授权时不发送。

整体退出先停止调度并取消子进程，等待默认 2 秒宽限后强制终止剩余任务。取消退出会恢复调度；手动刷新在调度器仍为停止状态时也会先调用 `start()` 恢复。面板隐藏只约束动画与视图计时器，不关闭后台调度。

依据：[`QuotaAlertEvaluator.swift`](../../apps/macos/Sources/BruceAppCore/QuotaAlertEvaluator.swift) 的 `overThresholdEntries`；[`QuotaAlertNotifier.swift`](../../apps/macos/Sources/BruceApp/QuotaAlertNotifier.swift) 的 `deliver`；[`RefreshScheduler.swift`](../../apps/macos/Sources/BruceAppCore/RefreshScheduler.swift) 的 `loadCachedSnapshot`、`applyCompleted`、`refresh`；[`ApplicationLifecycleCore.swift`](../../apps/macos/Sources/BruceAppCore/ApplicationLifecycleCore.swift)。

## 相关文档

- [macOS 原生应用设计](macos-design.md)：说明应用装配、模型映射和窗口生命周期。
- [订阅配置与凭据管理设计](credentials-design.md)：说明运行输入的授权、账号和外部只读来源。

最后更新：2026-10-18
