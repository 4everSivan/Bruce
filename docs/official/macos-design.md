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
| `RefreshScheduler` | `refresh(_:)`、`refreshSubscription(_:)`；状态、工件与预警回调 | 持有定时器、模块状态和待处理意图，完整执行过程见[刷新生命周期](refresh-lifecycle.md) |
| `AppModel` | `setStatus(_:for:)`、`setArtifact(_:for:)`；`makePanelViewModel()`、`makeMenuBarSummary()` | 保存 UI 可观察状态，缓存解码和映射结果 |
| `PanelViewModelMapper` | `make(agentUsage:moduleStatuses:providerOrder:) -> PanelViewModel` | 纯映射，生成用量、订阅和小时走势数据 |
| `OnboardingCoordinator` | 同意、配置、扫描、刷新等界面动作 | 通过就绪度与访问策略协调调度器；凭据操作委托 `SubscriptionService` |
| `MenuBarStatusItemController` | 模型发布与鼠标、快捷键事件 | 管理 `NSStatusItem`、无边框 `NSPanel` 与焦点 |

Bootstrap 将调度器工件回调接到 `AppModel.setArtifact`，状态回调接到 `setStatus`。模型只在原始工件变化时失效解码缓存；面板和菜单栏摘要分别记录映射缓存版本，避免一次面板重建掩盖摘要的待更新状态。SwiftUI 视图消费映射结果，不从视图发起会话扫描。

订阅显示另有验证门控：`AppModel` 只让配置验证状态满足呈现策略的 Provider 服务进入面板映射，用量 `agents` 不受该过滤影响。`SubscriptionMapping` 按 Provider 归组多账号，组装额度窗口、余额和账号摘要；用户顺序优先，缺少自定义顺序时余额型服务排在后面。工件无效或缺失时，映射器返回缺失诊断，相应卡片可以为空。

依据：[`AppModel.swift`](../../apps/macos/Sources/BruceAppCore/AppModel.swift) 的 `setArtifact(_:for:)`、`makePanelViewModel()`、`verifiedProviderIDs`、`decodedAgentUsageArtifact()`；[`PanelViewModel.swift`](../../apps/macos/Sources/BruceAppCore/PanelViewModel.swift) 的 `PanelViewModelMapper.make`；[`SubscriptionMapping.swift`](../../apps/macos/Sources/BruceAppCore/SubscriptionMapping.swift) 的 `makeSubscription`；[`UsageMapping.swift`](../../apps/macos/Sources/BruceAppCore/UsageMapping.swift) 的 `makeUsage`。

## 菜单栏、面板与主题

`AppDelegate.applicationDidFinishLaunching` 将应用设为 accessory，并安装状态项。`MenuBarStatusItemController` 用固定标识维护 `NSStatusItem`，将图标与指标绘制为一张图像，避免图像和标题分别变化引发布局抖动。模型发布后，控制器在下一轮主线程读取新值并重绘。

仪表盘由无边框 `NSPanel` 承载，SwiftUI 内容通过 `DashboardGlassPanelController` 挂载。逻辑开关状态独立于 AppKit 异步更新的 `isVisible`，使失焦事件不会抢先改写第二次点击的结果。面板退出、失焦和遮挡状态会更新 SwiftUI 可见性；隐藏面板保留视图树，因此持续动画、刷新进度和滚动条看门狗分别受可见性策略约束。

主题解析由 `ThemeResolution.resolve(interfaceStyle:glassStyle:isSupported:)` 完成。经典、液态玻璃、Nothing 是三种界面偏好；液态玻璃在系统能力不足时降级为经典，Nothing 不依赖玻璃能力。未保存界面偏好时，支持液态玻璃的系统默认采用液态玻璃，否则采用经典。明暗偏好由 Bootstrap 设置 `NSApp.appearance`，影响窗口级材质。

依据：[`ApplicationLifecycle.swift`](../../apps/macos/Sources/BruceApp/ApplicationLifecycle.swift) 的 `applicationDidFinishLaunching`；[`MenuBarStatusItemController.swift`](../../apps/macos/Sources/BruceApp/MenuBarStatusItemController.swift) 的 `install()`；[`DashboardPanelVisibility.swift`](../../apps/macos/Sources/BruceAppCore/DashboardPanelVisibility.swift)；[`DashboardPanelAnimationPolicy.swift`](../../apps/macos/Sources/BruceAppCore/DashboardPanelAnimationPolicy.swift)；[`ThemeResolution.swift`](../../apps/macos/Sources/BruceOnboardingCore/ThemeResolution.swift)。

## 设置窗口与价格配置

设置窗口由单例 `SettingsWindowController` 管理。打开时切为 regular 并显示 Dock 图标，关闭时恢复 accessory；Dock 再次打开应用时前置已有窗口。`Cmd+,` 统一进入该控制器，SwiftUI 的 `Settings` 场景只保留空锚点。

模型价格覆盖保存于配置的 `pricingOverrides`。`OnboardingCoordinator.persistPricingOverrides()` 保存成功后调用 `scheduler.refresh(.agentUsage)`，下一轮输入将覆盖项注入 Collector 重新聚合与折算。原[设置设计](../devel/design/04-设置中心与价格校准交互.md) 声明“内存热重算、无需重新扫描”，但当前调用链实际触发 Collector 刷新；维护时应以该调用行为评估开销与生效时间。

依据：[`ApplicationBootstrap.swift`](../../apps/macos/Sources/BruceApp/ApplicationBootstrap.swift) 的 `SettingsWindowController`；[`OnboardingCoordinator.swift`](../../apps/macos/Sources/BruceApp/OnboardingCoordinator.swift) 的 `persistPricingOverrides()`；[`CollectorRunInput.swift`](../../apps/macos/Sources/BruceAppCore/CollectorRunInput.swift) 的 `agentUsageInput()`。

## 退出与恢复

退出交给 `ApplicationLifecycleCoordinator.beginTermination`：先停止调度、取消运行任务，无子进程时立即完成；仍有任务则等待默认 2 秒宽限期，再强制结束剩余进程。`AppDelegate` 返回 `terminateLater`，在完成回调中回复系统。取消退出时调用 `cancelTermination()` 恢复调度；真正退出时注销全局快捷键并拆除状态项。

`NativeLifecycleHarness` 定义了宽限期强制终止、空闲立即退出和取消退出恢复调度等期望。这些用例说明自动化覆盖目标，不代表特定 macOS 版本或实际焦点行为已验收。

依据：[`ApplicationLifecycleCore.swift`](../../apps/macos/Sources/BruceAppCore/ApplicationLifecycleCore.swift) 的 `beginTermination`、`cancelTermination`；[`ApplicationLifecycle.swift`](../../apps/macos/Sources/BruceApp/ApplicationLifecycle.swift) 的退出委托；[`NativeLifecycleHarness.swift`](../../apps/macos/Tests/Harnesses/NativeLifecycleHarness/NativeLifecycleHarness.swift) 的退出用例。

## 相关文档

- [刷新生命周期](refresh-lifecycle.md)：说明调度、Bridge 子进程、快照发布和 UI 更新的完整交接。
- [订阅配置与凭据管理设计](credentials-design.md)：说明配置、授权门控和凭据存储边界。

最后更新：2026-10-18
