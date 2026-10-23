# Windows 快照与刷新状态

Windows 由一个后台采集线程更新 `SnapshotState` 中的采集结果，再将快照映射为看板 JSON。运行阶段描述刷新进度，服务新鲜度描述数据时效，LIVE 标记描述界面状态。三者应分别解释：刷新失败时可以保留旧卡片，LIVE 也不能作为本次采集成功的依据。

## 目录

- [1. 目标与范围](#chapter-1)
- [2. 参与者与契约](#chapter-2)
  - [2.1 刷新入口与唯一采集通道](#windows-triggers)
- [3. 流程设计](#chapter-3)
  - [3.1 重试与额度窗口唤醒](#windows-retry)
  - [3.2 从快照到界面状态](#windows-presentation)
- [4. 状态与数据变化](#chapter-4)
  - [4.1 快照阶段与结果应用](#windows-snapshot)
  - [4.2 服务级旧数据保留](#windows-carryover)
- [5. 异常与恢复](#chapter-5)
- [6. 场景推演](#chapter-6)
- [7. 参考文献](#chapter-7)
  - [7.1 原始资料与实现入口](#original-references)
  - [7.2 相关文档](#related)

<a id="chapter-1"></a>
## 1. 目标与范围

**功能需求**：本流程由后台线程或手动唤醒触发，完成内存快照更新与面板事件发布后，进入可中断的等待。

**边界与非目标**：界面读取缓存沿用现有结果，不额外发起采集。

<a id="chapter-2"></a>
## 2. 参与者与契约

<a id="windows-triggers"></a>
### 2.1 刷新入口与唯一采集通道

**功能需求**：托盘刷新、打开看板、设置保存、凭证更新和 `refresh_now` 都汇入同一条容量为 `1` 的手动通道，由唯一后台循环顺序执行采集，不阻塞 IPC，也不因界面隐藏而停止。

**方案机制**：`desktop::run()` 载入磁盘快照后调用 `scheduler::spawn`。线程启动即执行首次采集，后续按正常间隔、失败退避或手动唤醒继续。托盘刷新、打开看板、设置保存、凭证更新和 `refresh_now` 都调用 `request_manual_refresh`。

手动通道是 `sync_channel(1)`。提交端使用 `try_send`，采集中连续点击最多留下一个后续请求，不阻塞 IPC。循环在每次采集前吸收已排队请求，手动请求会清零重试计数。等待阶段的 `recv_timeout` 收到请求后立即进入下一次采集；看板隐藏不停止这个循环。

一次执行按以下顺序推进：

1. `begin_refresh` 把阶段设为 `refreshing`，先发布仍携带旧 artifact 的面板。
2. 载入应用凭证，调用 `collect_with_recovery`；首次调用执行配置采集，恢复调用只查询 Codex。
3. `apply_response` 验证并合并结果，尝试保存 `snapshot.json`。
4. 应用成功的响应后评估配额预警，再发布最新面板。
5. 选择一次正常间隔或退避等待；成功采集还会检查额度窗口边界。

`get_dashboard` 调用 `cached_panel`：先根据当前凭证裁剪内存服务，再映射面板。前端刷新按钮只发一个刷新意图，由后端事件带回后续结果。

**边界与非目标**：`cached_panel` 不执行 Collector。

依据：[`lib.rs`](../../apps/win/src-tauri/src/lib.rs) 的 `desktop::run`、`refresh_now`、凭证与设置命令；[`scheduler.rs`](../../apps/win/src-tauri/src/scheduler.rs) 的 `SchedulerControl`、`spawn`、`run_refresh_with_kind`、`cached_panel`；[`app.js`](../../apps/win/src/app.js) 的刷新按钮与 `init`。

<a id="chapter-3"></a>
## 3. 流程设计

<a id="windows-retry"></a>
### 3.1 重试与额度窗口唤醒

**功能需求**：失败轮次要按退避重试并在第 6 次失败后回到正常间隔；限流单独固定等待；成功采集后可在额度窗口重置边界处提前唤醒。

**方案机制**：采集成功等待配置间隔；失败的前 `5` 次重试等待退避，第 `6` 次失败后等待正常间隔，再重置计数。正常间隔加载时限制为 `60` 至 `86400` 秒。退避取代正常间隔，不把两段等待相加。

限流由诊断码 `PROVIDER_RATE_LIMIT` 或兼容分类 `rateLimit` 识别，固定等待 `300` 秒。其他失败从 `30` 秒起指数增加，叠加小于约 `10%` 的纳秒取模抖动，最大 `1800` 秒。手动来源通过 `manual_alert_reason` 延续到本次失败产生的退避重试，避免重试转为自动通知；进入下一正常周期后不再保留该来源。

成功采集后，`window_boundaries` 提取 `kind = windows` 服务中的整数 `resetsAt`。`boundary_wake` 只考虑严格在未来且未消费的边界，计算 `resetsAt + 20 秒 - 当前时间`，若比原等待短就采用。这里的 `20` 秒加在重置时刻之后；例如距离重置 `600` 秒，候选等待为 `620` 秒。每次只消费选中的边界，并移除过去的记录；未选中边界时保留原等待。

依据：[`scheduler.rs`](../../apps/win/src-tauri/src/scheduler.rs) 的 `compute_backoff`、`classify_rate_limited`、`spawn`；[`runtime_core.rs`](../../apps/win/src-tauri/src/runtime_core.rs) 的 `next_delay`、`manual_alert_reason`、`window_boundaries`、`boundary_wake`；[`scheduler_collector_coverage.rs`](../../apps/win/src-tauri/tests/scheduler_collector_coverage.rs) 的 `boundary_wake_never_crosses_future_window_reset` 规定 `600 + 20 = 620` 的预期。

<a id="windows-presentation"></a>
### 3.2 从快照到界面状态

**功能需求**：面板 JSON 在映射前过滤未启用 Provider 并按设置排列订阅段；运行阶段、服务新鲜度与 LIVE 标记分别表达执行进度、数据时效与界面时间文案，不能互相替代。

**方案机制**：`panel_json` 在 typed artifact 上先过滤未启用 Provider，调用纯映射器后再按设置顺序排列订阅段，并追加 `runtime.phase`、`lastSuccessAt`、`error`、`diagnosticCodes`。关闭 `usageEnabled` 时把 `usage` 与 `hourly` 置空。

运行阶段、服务新鲜度与 LIVE 标记分工如下。

| 层次 | 字段或规则 | 表达的事实 |
|---|---|---|
| 采集运行 | `runtime.phase` | 最近一次刷新流程所处阶段或结果 |
| 服务数据 | service 的 `freshness` | 当前窗口或余额是新鲜结果、借用旧值，还是无可用值 |
| 用量时间 | `usage.isLive` | artifact 的 `generatedAt` 相对当前时间在默认 `-300` 至 `2700` 秒内 |
| 窗口时间 | `resetText` | 重置时间已过时显示“刷新中”，不直接证明调度器正在执行 |

`publish` 根据运行阶段调整托盘提示与指示色，并发送 `dashboard-updated`。看板显示中文阶段及错误码，服务错误进入主看板诊断区；Agent 探测与缺少会话的说明放在设置页。`clear_snapshot_cache` 仅删除磁盘 `snapshot.json`，文件不存在视为成功，再提交手动刷新。

**边界与非目标**：关闭 `usageEnabled` 不删除存储中的用量数据。`usage.isLive` 由 artifact 时间决定，不检查 `runtime.phase`；窗口的“刷新中”也只是到期文案，两者均不能替代本次采集结果。`clear_snapshot_cache` 不立即清空 `SchedulerControl.snapshot`，所以新采集完成前仍可能看到内存中的卡片。

依据：[`runtime_core.rs`](../../apps/win/src-tauri/src/runtime_core.rs) 的 `SnapshotState::panel_json`、`clear_snapshot`；[`usage.rs`](../../apps/win/viewmodel/src/usage.rs) 的 `LIVE_LOOKBACK_SECS`、`DEFAULT_LIVE_THRESHOLD_SECS`、`make_usage`；[`subscription.rs`](../../apps/win/viewmodel/src/subscription.rs) 的 `reset_text`；[`scheduler.rs`](../../apps/win/src-tauri/src/scheduler.rs) 的 `publish`；[`app.js`](../../apps/win/src/app.js) 的 `renderStatus`、`render`；[`lib.rs`](../../apps/win/src-tauri/src/lib.rs) 的 `clear_snapshot_cache`。

<a id="chapter-4"></a>
## 4. 状态与数据变化

<a id="windows-snapshot"></a>
### 4.1 快照阶段与结果应用

**功能需求**：启动从磁盘快照恢复，一次刷新按阶段推进，有效响应合并为新 artifact，坏结果不替换旧 artifact；保存失败与采集失败的调度结果分开判断。

**方案机制**：图中的状态属于 `SnapshotState.phase`，`idle` 表示尚无采集结果，不表示后台线程暂停。图省略运行期间重复进入同一阶段的细节，失败分支以当前内存中是否存在有效 artifact 为界。

![Windows 快照从加载到刷新，以及成功、部分结果和失败保留之间的状态转移](../assets/km/windows-snapshot-state.svg)

图：Windows 快照阶段。依据静态实现展示启动加载与一次刷新生命周期，不代表 Windows 实机运行记录。

`begin_refresh` 只修改阶段，不清除旧 artifact、错误码或最近成功时间。因而刷新中仍可展示上一次数据及错误上下文。`apply_response` 则先更新受限格式的诊断码，再决定是否接受 artifact。

| 条件 | 阶段与错误 | artifact 与最近成功时间 |
|---|---|---|
| 快照文件不存在 | `idle`，无错误 | 无 artifact，无最近成功时间 |
| 文件无法读取，或 JSON / artifact 无效 | `failed`，`SNAPSHOT_READ_FAILED` 或 `SNAPSHOT_INVALID` | 不采用文件内容 |
| 有效持久快照恢复 | 有 artifact 为 `stale`，否则为 `failed`；`SNAPSHOT_RESTORED` | 保留已保存 artifact 与最近成功时间 |
| 开始刷新 | `refreshing` | 保留当前数据 |
| 有效 `Success` 响应 | `fresh`，清除错误 | 合并结果；将最近成功时间更新为响应的 `generatedAt` |
| 有效 `Partial` 响应 | `partial`，`COLLECTION_PARTIAL` | 合并结果；保留原最近成功时间 |
| 响应为 `Error`、缺 artifact、artifact 无效 | 有旧 artifact 为 `stale`，否则为 `failed`；分别记录 `COLLECTION_FAILED`、`ARTIFACT_MISSING`、`ARTIFACT_INVALID` | 不用坏结果替换旧 artifact |
| 快照保存失败 | 有 artifact 为 `stale`，否则为 `failed`；`SNAPSHOT_WRITE_FAILED` | 保留当前内存 artifact |

**边界与非目标**：持久化失败与采集失败没有完全相同的调度结果：`run_refresh_with_kind` 在 `apply_response` 成功后保存，保存失败会调用 `fail`，但仍按 `applied.is_ok()` 返回 `RefreshOutcome::Success`。这时面板为 `stale`，等待策略仍走采集成功路径，并可能评估通知。维护时应同时检查 `runtime.phase`、`runtime.error` 和调度返回值。

依据：[`runtime_core.rs`](../../apps/win/src-tauri/src/runtime_core.rs) 的 `SnapshotState::default`、`load`、`begin_refresh`、`apply_response`、`fail`、`save`、`validate_artifact`；[`scheduler.rs`](../../apps/win/src-tauri/src/scheduler.rs) 的 `run_refresh_with_kind`。

<a id="windows-carryover"></a>
### 4.2 服务级旧数据保留

**功能需求**：整体 `partial` 或失败时，本次未成功的服务可借同 ID 的合格旧展示字段继续显示；发布前按当前账号裁剪快照服务。

**方案机制**：响应整体为 `partial` 时，每个服务仍可能有不同的新鲜度。`merge_snapshot` 只遍历本次返回的服务 ID：服务状态为 `ok` 或 `empty` 时标记为 `fresh`；失败服务仅在同 ID 的历史项通过资格检查后借用旧展示字段。历史项必须具有可解析的 `capturedAt`，且新鲜度为 `fresh`、`stale`，或在没有新鲜度字段时状态为 `ok`、空字符串。

可借用字段限定为 `windows`、`balance`、`currency`、`plan`、`extra`、`kind`、`capturedAt`。合并不覆盖当前失败状态；借用成功后标记 `stale`，否则标记 `unavailable` 并移除 `capturedAt`。

发布前，`prune_credentials` 还按当前账号过滤快照服务。Codex 通过共享 `codex_service_id(account)` 生成的哈希标识匹配；其他服务按对应账号映射或 OAuth 字段检查。

整体失败时，`fail` 保留当前 artifact，并把满足历史资格的服务标为 `stale`。订阅映射对 `freshness = stale` 且具有 `capturedAt` 的账号生成“上次成功 HH:mm”；告警评估跳过 stale 服务。

**边界与非目标**：本次未返回的历史服务不会通过合并复活。删除账号后，即使磁盘快照仍含历史服务，下一次面板组装也会裁剪内存中的该服务。旧数值因此仍可供查看，但不会作为一条新鲜的超阈值提醒。

依据：[`runtime_core.rs`](../../apps/win/src-tauri/src/runtime_core.rs) 的 `qualified`、`merge_snapshot`、`SnapshotState::prune_credentials`、`fail`；[`subscription.rs`](../../apps/win/viewmodel/src/subscription.rs) 的 `last_success_text`、`make_subscription`；[`alerts.rs`](../../apps/win/src-tauri/src/alerts.rs) 的 `over_threshold_entries`。

<a id="chapter-5"></a>
## 5. 异常与恢复

**边界与非目标**：整体失败时保留合格的旧服务并标陈旧；没有旧工件时为 failed。磁盘写失败可以留下内存数据，并且调度返回值仍沿用采集成功路径；该差异不能通过一条“刷新失败”说明省略。

<a id="chapter-6"></a>
## 6. 场景推演

**方案机制**：按实现推演：磁盘存在有效快照时先恢复为 stale，首次采集进入 refreshing；有效 success 更新最近成功时间并进入 fresh。若下一轮失败，保留旧数据为 stale，等待退避。采集中连续点击只留下一个待执行手动请求；保存快照失败的轮次虽显示 stale，仍按 Success 选择下一等待。

<a id="chapter-7"></a>
## 7. 参考文献

<a id="original-references"></a>
### 7.1 原始资料与实现入口

- [lib.rs](../../apps/win/src-tauri/src/lib.rs)：本主题的原始声明或实现入口。
- [scheduler.rs](../../apps/win/src-tauri/src/scheduler.rs)：本主题的原始声明或实现入口。
- [app.js](../../apps/win/src/app.js)：本主题的原始声明或实现入口。

<a id="related"></a>
### 7.2 相关文档

- [Bruce 设计文档](Bruce设计文档.md#windows)：本主题在完整系统中的职责、关系和约束。
- [Windows 应用设计](Windows应用设计.md)：系统入口、IPC、配置门控、凭证恢复与证据范围。

最后更新：2026-10-20
