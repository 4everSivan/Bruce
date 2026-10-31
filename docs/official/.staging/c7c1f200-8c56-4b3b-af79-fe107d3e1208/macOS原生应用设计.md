# macOS 原生应用设计

macOS 应用消费 Collector 的标准工件，将其映射为菜单栏指标、订阅额度卡和本地用量图表。应用管理生命周期、调度装配、配置交互和原生呈现，Rust Collector 执行本地会话扫描与服务商额度请求。

## 目录

- [1. 目标与职责](#chapter-1)
- [2. 对外契约](#chapter-2)
  - [2.1 对外契约与内部职责](#app-contract)
- [3. 内部结构](#chapter-3)
  - [3.1 呈现与设置的协作边界](#collaboration)
- [4. 详细设计](#chapter-4)
  - [4.1 解码缓存与分析消费者](#model-consumers)
- [5. 流程与状态](#chapter-5)
  - [5.1 应用入口与对象装配](#bootstrap)
- [6. 异常与恢复](#chapter-6)
  - [6.1 退出与恢复](#termination)

<a id="chapter-1"></a>
## 1. 目标与职责

**功能需求**：原生界面需要由持久快照、调度器和可观察模型驱动，而不是视图直接扫描会话；设置保存与采集读取必须看到同一份凭据状态。

**设计目标**：
- 组合根共享对象（满足：设置保存与采集读取使用同一份状态，避免两条路径各自持有不一致的凭据状态）。

**方案机制**：应用通过持久快照、调度器和可观察模型驱动原生界面。组合根让设置保存与采集读取共享对象，避免两条路径各自持有不一致的凭据状态。

<a id="chapter-2"></a>
## 2. 对外契约

<a id="app-contract"></a>
### 2.1 对外契约与内部职责

**功能需求**：视图只消费映射结果；调度器的工件与状态回调要接到模型，订阅显示按验证门控过滤后再进入面板映射。

| 组件 | 输入与输出 | 职责边界 |
|---|---|---|
| `RefreshScheduler` | `refresh(_:)`、`refreshSubscription(_:)`；状态、工件与预警回调 | 持有定时器、模块状态和待处理意图；一轮依次读取历史、确定策略、启动采集并发布有效工件 |
| `AppModel` | `setStatus(_:for:)`、`setArtifact(_:for:)`；`makePanelViewModel()`、`makeMenuBarSummary()` | 保存 UI 可观察状态，缓存解码和映射结果 |
| `PanelViewModelMapper` | `make(agentUsage:moduleStatuses:providerOrder:) -> PanelViewModel` | 纯映射，生成用量、订阅和小时走势数据 |
| `OnboardingCoordinator` | 同意、配置、扫描、刷新等界面动作 | 通过就绪度与访问策略协调调度器；凭据操作委托 `SubscriptionService` |
| `MenuBarStatusItemController` | 模型发布与鼠标、快捷键事件 | 管理 `NSStatusItem`、无边框 `NSPanel` 与焦点 |

**方案机制**：Bootstrap 将调度器工件回调接到 `AppModel.setArtifact`，状态回调接到 `setStatus`。模型只在原始工件变化时失效解码缓存；面板和菜单栏摘要分别记录映射缓存版本，避免一次面板重建掩盖摘要的待更新状态。SwiftUI 视图消费映射结果，不从视图发起会话扫描。

订阅显示另有验证门控：`AppModel` 只让配置验证状态满足呈现策略的 Provider 服务进入面板映射，用量 `agents` 不受该过滤影响。`SubscriptionMapping` 按 Provider 归组多账号，组装额度窗口、余额和账号摘要；用户顺序优先，缺少自定义顺序时余额型服务排在后面。

**边界与非目标**：工件无效或缺失时，映射器返回缺失诊断，相应卡片可以为空。

<a id="chapter-3"></a>
## 3. 内部结构

<a id="collaboration"></a>
### 3.1 呈现与设置的协作边界

**功能需求**：菜单栏、看板与设置窗口各自负责呈现与持久化，应用装配只划协作边界，不替各模块持有状态。

**方案机制**：菜单栏状态项与看板消费共享模型，主题和可见性由原生控制器处理。设置窗口管理编辑交互，协调器保存配置并通知主题、菜单栏和刷新调度器；价格覆盖保存成功后触发采集刷新。

**边界与非目标**：这些设计与应用装配协作，各自维护其输入、状态和失败语义。

<a id="chapter-4"></a>
## 4. 详细设计

<a id="model-consumers"></a>
### 4.1 解码缓存与分析消费者

**功能需求**：设置中的分析工作台复用同一份解码工件，不重复解码，也不另读会话。

**方案机制**：`AppModel.setArtifact` 在原始工件变化后失效解码与呈现缓存。菜单栏摘要和面板各自跟踪缓存版本；设置中的分析工作台也消费同一份解码工件。`WorkbenchAnalytics` 按所选时间范围聚合 Agent 用量、模型明细和时间序列；今日直接使用 today 桶，其它日期范围使用 daily，全部历史的模型明细使用 monthModels。旧工件缺少明细或缓存拆分时，对应指标为空，由视图显示“—”，不会估算缺失数据。

<a id="chapter-5"></a>
## 5. 流程与状态

<a id="bootstrap"></a>
### 5.1 应用入口与对象装配

**功能需求**：应用启动后先展示本地已有快照，再异步完成配置与凭据准备；入口要先解析可用的 Collector 可执行文件，装配失败时给出不可用状态而不是崩溃。

**设计目标**：
- 快照展示不依赖外部登录（满足：`scheduler.start()` 在凭据迁移前读取本地缓存）；
- 共享状态单一（满足：配置存储、凭据库及 token manager 在输入提供器与配置侧共享）；
- 回调只绑定一次（满足：`startIfNeeded()` 只绑定一次回调）。

**方案机制**：应用装配与退出属于同一生命周期，控制边界如下。

![启动先恢复快照，退出停止调度并等待或终止运行任务](../assets/km/macos-app-lifecycle.svg)

图：macOS 应用生命周期。凭据准备受配置门控；取消退出会恢复调度。

`@main BruceApp` 是实际入口。初始化时优先使用可执行的 `BRUCE_COLLECTOR_PATH`，再查 App 资源中的 `Bruce-collector`；Debug 构建另向上查找仓库内 debug/release 产物。没有可执行文件时装配 `UnavailableCollectorAdapter`，并向配置侧提供不可用状态。

组合根创建一份 `AppModel`、`RefreshScheduler`、`AppRuntime` 和 `OnboardingCoordinator`。额度门禁、旧值回填、窗口边界与退避由共享 Rust 策略计算；macOS 以进程内静态库 C ABI 交换不含凭据的策略请求，采集任务仍由独立 Collector 子进程执行。配置存储、访问策略控制器、受保护文件凭据库、Codex 凭据库及 token manager 在输入提供器与配置侧共享，使保存和刷新读取使用同一份状态。`ApplicationBootstrap.startIfNeeded()` 只绑定一次回调，并由 `AppRuntime` 启动调度器。

启动顺序先恢复快照，再准备已配置的凭据环境。`scheduler.start()` 在凭据迁移前读取本地缓存；未完成访问配置时，Bootstrap 跳过凭据迁移与 Codex 状态读取。配置完成后再补做启动准备、协调模块门控和发布账号状态。

<a id="chapter-6"></a>
## 6. 异常与恢复

<a id="termination"></a>
### 6.1 退出与恢复

**功能需求**：退出时有序停止调度、取消在途任务，宽限期后强制结束剩余进程；取消退出要恢复调度，真正退出要清理快捷键与状态项。

**方案机制**：退出交给 `ApplicationLifecycleCoordinator.beginTermination`：先停止调度、取消运行任务，无子进程时立即完成；仍有任务则等待默认 2 秒宽限期，再强制结束剩余进程。`AppDelegate` 返回 `terminateLater`，在完成回调中回复系统。取消退出时调用 `cancelTermination()` 恢复调度；真正退出时注销全局快捷键并拆除状态项。

**边界与非目标**：`NativeLifecycleHarness` 定义了宽限期强制终止、空闲立即退出和取消退出恢复调度等期望。这些用例说明自动化覆盖目标，不代表特定 macOS 版本或实际焦点行为已验收。

最后更新：2026-10-30
