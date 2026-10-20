# macOS 原生应用设计

macOS 应用将 Collector 的标准工件转换为菜单栏指标、订阅额度卡和本地用量图表。应用负责生命周期、调度装配、配置交互与原生呈现；本地会话扫描和服务商额度请求由 Rust Collector 执行。

## 应用入口与对象装配

`@main BruceApp` 是实际入口。初始化时优先使用可执行的 `BRUCE_COLLECTOR_PATH`，再查 App 资源中的 `Bruce-collector`；Debug 构建另向上查找仓库内 debug/release 产物。没有可执行文件时装配 `UnavailableCollectorAdapter`，并向配置侧提供不可用状态。

组合根创建一份 `AppModel`、`RefreshScheduler`、`AppRuntime` 和 `OnboardingCoordinator`。配置存储、访问策略控制器、受保护文件凭据库、Codex 凭据库及 token manager 在输入提供器与配置侧共享，使保存和刷新读取使用同一份状态。`ApplicationBootstrap.startIfNeeded()` 只绑定一次回调，并由 `AppRuntime` 启动调度器。

启动顺序先恢复快照，再准备已配置的凭据环境。`scheduler.start()` 在凭据迁移前读取本地缓存；未完成访问配置时，Bootstrap 跳过凭据迁移与 Codex 状态读取。配置完成后再补做启动准备、协调模块门控和发布账号状态。

依据：[`BruceApp.swift`](../../apps/macos/Sources/BruceApp/BruceApp.swift) 的 `init()`、`resolveRustCollectorURL()`；[`ApplicationBootstrap.swift`](../../apps/macos/Sources/BruceApp/ApplicationBootstrap.swift) 的 `startIfNeeded()`、`prepareKeychainBackedStartup()`；[`AppRuntime.swift`](../../apps/macos/Sources/BruceAppCore/AppRuntime.swift) 的 `startSchedulerIfNeeded()`。

## 对外契约与内部职责

| 组件 | 输入与输出 | 职责边界 |
|---|---|---|
| `RefreshScheduler` | `refresh(_:)`、`refreshSubscription(_:)`；状态、工件与预警回调 | 持有定时器、模块状态和待处理意图，完整执行过程见[刷新生命周期](刷新生命周期设计.md) |
| `AppModel` | `setStatus(_:for:)`、`setArtifact(_:for:)`；`makePanelViewModel()`、`makeMenuBarSummary()` | 保存 UI 可观察状态，缓存解码和映射结果 |
| `PanelViewModelMapper` | `make(agentUsage:moduleStatuses:providerOrder:) -> PanelViewModel` | 纯映射，生成用量、订阅和小时走势数据 |
| `OnboardingCoordinator` | 同意、配置、扫描、刷新等界面动作 | 通过就绪度与访问策略协调调度器；凭据操作委托 `SubscriptionService` |
| `MenuBarStatusItemController` | 模型发布与鼠标、快捷键事件 | 管理 `NSStatusItem`、无边框 `NSPanel` 与焦点 |

Bootstrap 将调度器工件回调接到 `AppModel.setArtifact`，状态回调接到 `setStatus`。模型只在原始工件变化时失效解码缓存；面板和菜单栏摘要分别记录映射缓存版本，避免一次面板重建掩盖摘要的待更新状态。SwiftUI 视图消费映射结果，不从视图发起会话扫描。

订阅显示另有验证门控：`AppModel` 只让配置验证状态满足呈现策略的 Provider 服务进入面板映射，用量 `agents` 不受该过滤影响。`SubscriptionMapping` 按 Provider 归组多账号，组装额度窗口、余额和账号摘要；用户顺序优先，缺少自定义顺序时余额型服务排在后面。工件无效或缺失时，映射器返回缺失诊断，相应卡片可以为空。

依据：[`AppModel.swift`](../../apps/macos/Sources/BruceAppCore/AppModel.swift) 的 `setArtifact(_:for:)`、`makePanelViewModel()`、`verifiedProviderIDs`、`decodedAgentUsageArtifact()`；[`PanelViewModel.swift`](../../apps/macos/Sources/BruceAppCore/PanelViewModel.swift) 的 `PanelViewModelMapper.make`；[`SubscriptionMapping.swift`](../../apps/macos/Sources/BruceAppCore/SubscriptionMapping.swift) 的 `makeSubscription`；[`UsageMapping.swift`](../../apps/macos/Sources/BruceAppCore/UsageMapping.swift) 的 `makeUsage`。

## 呈现与设置的协作边界

菜单栏状态项与看板消费共享模型，主题和可见性由原生控制器处理；独立设计见[菜单栏与看板设计](菜单栏与看板设计.md)。设置窗口、配置保存和价格覆盖由设置控制器及协调器处理，详见[设置中心与价格校准设计](设置中心与价格校准设计.md)。这些设计与应用装配协作，各自维护其输入、状态和失败语义。

依据：[`ApplicationBootstrap.swift`](../../apps/macos/Sources/BruceApp/ApplicationBootstrap.swift) 的窗口装配；[`MenuBarStatusItemController.swift`](../../apps/macos/Sources/BruceApp/MenuBarStatusItemController.swift)；[`OnboardingCoordinator.swift`](../../apps/macos/Sources/BruceApp/OnboardingCoordinator.swift)。

## 退出与恢复

退出交给 `ApplicationLifecycleCoordinator.beginTermination`：先停止调度、取消运行任务，无子进程时立即完成；仍有任务则等待默认 2 秒宽限期，再强制结束剩余进程。`AppDelegate` 返回 `terminateLater`，在完成回调中回复系统。取消退出时调用 `cancelTermination()` 恢复调度；真正退出时注销全局快捷键并拆除状态项。

`NativeLifecycleHarness` 定义了宽限期强制终止、空闲立即退出和取消退出恢复调度等期望。这些用例说明自动化覆盖目标，不代表特定 macOS 版本或实际焦点行为已验收。

依据：[`ApplicationLifecycleCore.swift`](../../apps/macos/Sources/BruceAppCore/ApplicationLifecycleCore.swift) 的 `beginTermination`、`cancelTermination`；[`ApplicationLifecycle.swift`](../../apps/macos/Sources/BruceApp/ApplicationLifecycle.swift) 的退出委托；[`NativeLifecycleHarness.swift`](../../apps/macos/Tests/Harnesses/NativeLifecycleHarness/NativeLifecycleHarness.swift) 的退出用例。

## 相关文档

- [Bruce 设计文档](Bruce设计文档.md#macos-app)：本主题在完整系统中的职责、关系和约束。
- [刷新生命周期](刷新生命周期设计.md)：说明调度、Bridge 子进程、快照发布和 UI 更新的完整交接。
- [订阅配置与凭据管理设计](订阅配置与凭据管理设计.md)：说明配置、授权门控和凭据存储边界。

最后更新：2026-10-19
