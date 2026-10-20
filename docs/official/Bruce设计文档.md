# Bruce 设计文档

Bruce 将本机 AI Agent 的会话用量、参考费用和订阅额度汇集到桌面看板。系统由共享 Rust Collector、macOS 原生应用、Windows 托盘应用和独立宿主 Widget 组成；应用维护配置、凭据、刷新与呈现，Collector 输出标准用量工件。

本文按设计主题说明完整系统及其相互关系，详细契约和异常路径由各主题文档展开。范围包括当前工作区的实现及原设计声明；平台能力和未完成事项按对应来源区分。

## 系统边界与整体结构

Bruce 没有自有云端服务端。本地会话在本机读取，订阅查询按授权与账号输入访问外部 Provider。费用估算和订阅额度是两套口径：前者由 Token 与价格计算，后者由服务商窗口或余额产生，二者不能直接相减。

macOS 从 `BruceApp` 装配输入提供器、Runner、快照库、模型和调度器，经一次性 CLI 子进程调用 Collector；Windows 从 Tauri `run()` 进入后台调度，并在进程内调用相同 Bridge。Widget 接收独立宿主的 `data.main`，不由原生应用自动推送数据。

模块的主要连接方式如下。图中的 Collector 分支是普通采集抽象，定向恢复、离线暂停及额度门禁在对应设计中说明。

![macOS 经 stdio、Windows 经进程内调用共享 Bridge，Widget 使用独立宿主](../assets/km/system-architecture.svg)

图：Bruce 模块关系。当前实现按职责抽象，未表示运行中的部署实例。

| 设计主题 | 职责与主要依赖 | 详细设计 |
|---|---|---|
| 本地采集与计费 | 只读会话、归一化、缓存和价格折算；依赖来源适配与聚合 | [采集引擎与本地用量设计](采集引擎与本地用量设计.md) |
| 订阅额度查询 | 账号计划、服务请求与响应适配；依赖凭据输入和网络运行时 | [订阅额度查询设计](订阅额度查询设计.md) |
| 订阅配置与凭据 | 同意门控、账号、导入及受保护存储；依赖 Onboarding Core | [订阅配置与凭据管理设计](订阅配置与凭据管理设计.md) |
| macOS 应用装配 | 启动、对象组合、模型映射与退出；依赖 Collector 和原生框架 | [macOS 原生应用设计](macOS原生应用设计.md) |
| 菜单栏与看板 | 状态项、面板、可见性和主题；消费模型及配置 | [菜单栏与看板设计](菜单栏与看板设计.md) |
| 设置与价格校准 | 配置编辑、落盘和生效；向采集输入提供价格覆盖 | [设置中心与价格校准设计](设置中心与价格校准设计.md) |
| 刷新、快照与恢复 | 意图合并、门禁、执行、持久化和旧值保留 | [刷新生命周期设计](刷新生命周期设计.md) |
| Windows 平台适配 | Tauri IPC、托盘、配置、状态映射；依赖共享 Bridge | [Windows 应用设计](Windows应用设计.md) |
| 独立 Widget | 宿主事件、展示与动画生命周期；依赖浏览器环境 | [Widget 设计](Widget设计.md) |
| 工程验证与交付 | 验证、组包、版本和发布资产；依赖工具链与 CI | [构建、验证与发布](构建验证与发布.md) |

依据：[原系统设计](../devel/design/00-系统总体设计.md) 的领域分层与主题矩阵；[`BruceApp.swift`](../../apps/macos/Sources/BruceApp/BruceApp.swift)；[`apps/win/src-tauri/src/lib.rs`](../../apps/win/src-tauri/src/lib.rs) 的 `run()`；[`apps/widget/index.html`](../../apps/widget/index.html)。

<a id="local-usage"></a>
## 本地采集与计费设计

本地模块将不同 Agent 的会话转为统一用量贡献，再按日、模型、项目和小时聚合。输入包括 JSONL 与只读 SQLite；Collector 自有缓存用于避免重复解析，不能修改或修复第三方来源。路径覆盖、采集窗口和能力输入决定本轮读取范围，目录或文件存在本身不表示主链路实际扫描它。

聚合层保存输入、输出及缓存 Token 的语义，模型价格由内置表和用户覆盖项共同决定。费用属于参考估算；未知模型、无效价格、来源缺失和读取失败分别保留其诊断，不能用零费用表示所有未知情况。该设计向看板提供数据，接受设置设计的价格输入，并参与刷新设计的资源预算与取消。

详细设计：[采集引擎与本地用量设计](采集引擎与本地用量设计.md)；深入机制见[本地会话解析与计费](本地会话解析与计费.md)。

依据：[`collector-application/src/lib.rs`](../../core/collector/crates/collector-application/src/lib.rs) 的 `collect_local_usage()`；[`collector-aggregate/src/lib.rs`](../../core/collector/crates/collector-aggregate/src/lib.rs)；[`collector-domain/src/pricing.rs`](../../core/collector/crates/collector-domain/src/pricing.rs)。

<a id="provider-quota"></a>
## 订阅额度查询设计

额度模块将宿主注入的账号凭据组织成请求计划，通过各 Provider 的适配器转为窗口、余额及诊断。服务间局部失败保留其它结果；凭据更新和挑战经 Bridge 封套返回，宿主负责验证和持久化。Rust 生产路径不自行打开系统钥匙串。

查询是否发生同时受授权和本轮额度策略约束。当前 macOS 以历史服务时间戳决定本地专用采集或需要查询的 Provider；Bridge 接受 `localUsageOnly` 与 `quotaSkipProviders`，应用层据此跳过额度任务或账号计划。旧额度由宿主回填，必须与本轮真实查询结果区分；这些新增门禁不能推定 Windows 已采用相同策略。

详细设计：[订阅额度查询设计](订阅额度查询设计.md)；宿主策略及回填见[刷新生命周期设计](刷新生命周期设计.md)。

依据：[`collector-application/src/account.rs`](../../core/collector/crates/collector-application/src/account.rs) 的 `build_account_plan()`；[`collector-application/src/lib.rs`](../../core/collector/crates/collector-application/src/lib.rs)；[`collector-bridge/src/lib.rs`](../../core/collector/crates/collector-bridge/src/lib.rs) 的白名单；[`QuotaRefreshPolicy.swift`](../../apps/macos/Sources/BruceAppCore/QuotaRefreshPolicy.swift)。

<a id="credentials"></a>
## 订阅配置与凭据设计

配置描述选中的模块、Provider、统一同意、账号及展示偏好；凭据内容与可公开的配置、诊断分开管理。自动探测、用户明确导入和实际查询属于不同访问意图，授权门控决定何时允许读取外部登录态、装配订阅输入或启用采集。

凭据存储采用受保护文件和原子替换；外部数据库只读，系统凭据探测应避免触发交互式弹窗。多账号身份和顺序沿用来源声明，Codex 的发现、登录、刷新与挑战恢复由专门组件协调。应用内已有账号并不自动代表当前凭据有效，导入成功也不等于服务商查询成功。

详细设计：[订阅配置与凭据管理设计](订阅配置与凭据管理设计.md)。

依据：[原订阅与凭据设计](../devel/design/02-订阅额度与凭据安全存储.md)；[`CollectorRunInput.swift`](../../apps/macos/Sources/BruceAppCore/CollectorRunInput.swift)；[`ExternalCredentialReader.swift`](../../apps/macos/Sources/BruceOnboardingCore/ExternalCredentialReader.swift)；[`SubscriptionCredentialImport.swift`](../../apps/macos/Sources/BruceOnboardingCore/SubscriptionCredentialImport.swift)。

<a id="macos-app"></a>
## macOS 应用装配设计

应用组合根连接 Collector 执行器、快照库、运行输入、凭据写回、调度器和单一 `AppModel`。`ApplicationBootstrap` 先接通回调并启动缓存恢复，再处理配置与账号准备；因此本地快照展示不依赖外部登录态读取先完成。

`ArtifactStore` 维护持久化工件，`AppModel` 把工件、配置与就绪状态组合，经映射器交给菜单栏和面板。界面消费模型而不直接扫描会话。退出由生命周期协调器停止调度、取消任务并在宽限期后终止剩余进程；窗口、状态项和快捷键有各自的清理责任。

详细设计：[macOS 原生应用设计](macOS原生应用设计.md)。

依据：[`BruceApp.swift`](../../apps/macos/Sources/BruceApp/BruceApp.swift)；[`ApplicationBootstrap.swift`](../../apps/macos/Sources/BruceApp/ApplicationBootstrap.swift)；[`AppModel.swift`](../../apps/macos/Sources/BruceAppCore/AppModel.swift)；[`ApplicationLifecycleCore.swift`](../../apps/macos/Sources/BruceAppCore/ApplicationLifecycleCore.swift)。

<a id="dashboard"></a>
## 菜单栏与看板设计

状态项将图标与指标绘成单张图像，保持布局稳定，并在模型更新后读取新值重绘。额度环规按选定的最低或平均剩余值呈现，刷新动画与文本宽度由原生控制器管理。看板使用独立 `NSPanel` 承载 SwiftUI 内容，卡片折叠保留标题与摘要。点击开关的逻辑状态与 AppKit 异步的可见性分开维护，避免失焦通知抢先改变第二次点击的结果；隐藏、遮挡与退出还影响动画是否继续执行。

经典、液态玻璃和 Nothing 是三种界面偏好。主题解析同时考虑持久化配置及系统能力：不支持液态玻璃时回退经典，Nothing 保留自身分支。明暗偏好与玻璃变体分别作用于原生材质。该设计消费设置与模型，系统能力回退和窗口焦点规则由原生控制器落实。

详细设计：[菜单栏与看板设计](菜单栏与看板设计.md)。

依据：[原菜单栏设计](../devel/design/03-菜单栏状态与多风格原生渲染.md)；[`MenuBarStatusItemController.swift`](../../apps/macos/Sources/BruceApp/MenuBarStatusItemController.swift)；[`DashboardPanelVisibility.swift`](../../apps/macos/Sources/BruceAppCore/DashboardPanelVisibility.swift)；[`ThemeResolution.swift`](../../apps/macos/Sources/BruceOnboardingCore/ThemeResolution.swift)。

<a id="settings-pricing"></a>
## 设置与价格校准设计

设置中心以六类侧栏组织展示、刷新、模型计费、订阅和维护等配置，并通过协调器保存及通知相应消费者。菜单栏指标可预览、选择和拖拽排序；模型价格表支持搜索、用量/自定义筛选、单项校准与重置，配置预览展示覆盖集合。设置窗口由单例控制器管理，打开时进入有 Dock 图标的普通应用呈现，关闭后恢复菜单栏模式。菜单栏交互、配置持久化和采集策略分别归其所属组件负责。

价格校准写入 `pricingOverrides`，下一轮输入携带覆盖值供 Collector 重新聚合。当前 `persistPricingOverrides()` 保存成功后触发刷新，原设计中“内存热重算、无需重新扫描”的目标与这条实现链路不同。刷新间隔的设置还须区分本地采集周期与订阅额度查询门禁，不能把一个控件解释为所有网络请求的统一周期。

详细设计：[设置中心与价格校准设计](设置中心与价格校准设计.md)。

依据：[原设置设计](../devel/design/04-设置中心与价格校准交互.md)；[`SettingsView.swift`](../../apps/macos/Sources/BruceApp/SettingsView.swift)；[`OnboardingCoordinator.swift`](../../apps/macos/Sources/BruceApp/OnboardingCoordinator.swift) 的 `persistPricingOverrides()`；[`CollectorRunInput.swift`](../../apps/macos/Sources/BruceAppCore/CollectorRunInput.swift)。

<a id="refresh-snapshot"></a>
## 刷新、快照与恢复设计

调度器接收定时、手动、唤醒和退避意图，处理同模块合并、并发容量、授权与网络门禁；流水线负责一次执行的先后关系。当前流水线先读取上一份工件并形成额度策略，再装配输入、执行采集、按条件恢复与回填、应用凭据更新，最后发布快照。凭据写回失败和快照发布失败属于不同结果，不能假定二者具有统一回滚事务。

离线时自动意图暂停，直接手动刷新仍可执行一次；恢复联网后按暂停标记或陈旧程度补偿。额度查询与本地采集解耦，手动触发、窗口边界、服务新鲜度和限流冷却有不同优先级。当前与 previous 快照用于启动展示及失败回退，服务级陈旧状态与模块调度相位也分别维护。

详细设计：[刷新生命周期设计](刷新生命周期设计.md)。

依据：[`RefreshScheduler.swift`](../../apps/macos/Sources/BruceAppCore/RefreshScheduler.swift)；[`RefreshExecutionPipeline.swift`](../../apps/macos/Sources/BruceAppCore/RefreshExecutionPipeline.swift)；[`NetworkReachability.swift`](../../apps/macos/Sources/BruceAppCore/NetworkReachability.swift)；[`QuotaRefreshPolicy.swift`](../../apps/macos/Sources/BruceAppCore/QuotaRefreshPolicy.swift)；[`ArtifactStore.swift`](../../apps/macos/Sources/BruceAppCore/ArtifactStore.swift)。

<a id="windows"></a>
## Windows 平台适配设计

Windows 使用 Tauri 提供托盘、窗口、设置与 IPC，后台线程在进程内调用共享 Rust Bridge。`SnapshotState` 保存工件、阶段、诊断和最近成功时间；`get_dashboard` 读取缓存并映射 Panel，不因为界面查询另启一轮采集。

Windows 与 macOS 共享协议及部分视图模型语义，但凭据装配、调度、存储路径和界面实现分别维护。配置差异、错误恢复和真实系统交互必须按 Windows 来源解释；共享 crate 或 fixture 对拍不能证明双端的授权、窗口、快捷键与设备行为完全相同。

详细设计：[Windows 应用设计](Windows应用设计.md)；状态细节见[Windows 快照与刷新状态](Windows快照与刷新状态.md)。

依据：[原 Windows 设计](../devel/design/05-Windows平台适配.md)；[`apps/win/src-tauri/src/lib.rs`](../../apps/win/src-tauri/src/lib.rs)；[`apps/win/src-tauri/src/runtime_core.rs`](../../apps/win/src-tauri/src/runtime_core.rs)；[`apps/win/viewmodel/src/lib.rs`](../../apps/win/viewmodel/src/lib.rs)。

<a id="widget"></a>
## 独立 Widget 设计

Widget 是单文件浏览器界面，通过宿主的数据、状态和主题事件更新。它读取 `data.main` 并维护自己的展示逻辑，缺少宿主数据时按现有状态规则处理。原生应用的构建清单没有把该文件当成自动供数界面，因此两条展示路径不能混为同一部署关系。

Widget 的 Token 与额度展示依赖输入口径一致；日期对齐和 Agent 状态由提供数据的一侧负责。动画、可见性与释放属于 Widget 的生命周期责任，宿主负责提供事件和口径一致的数据。

详细设计：[Widget 设计](Widget设计.md)。

依据：[`apps/widget/index.html`](../../apps/widget/index.html) 的 `render()`、`renderStatus()` 及宿主事件；[`scripts/runtime-manifest.zsh`](../../scripts/runtime-manifest.zsh) 的打包清单。

<a id="delivery"></a>
## 工程验证与交付设计

工程验证入口覆盖 Rust、Swift、fixture、Harness 和集成检查；平台打包脚本组装应用及 Collector，版本由根目录 `VERSION` 提供。构建目录、用户运行数据和知识文档分别维护，不能把开发机某次目录状态当成安装环境的约定。

tag CI、Preview 产物与手工签名公证路径各有责任。本地验证、CI 作业和平台安装验证覆盖不同责任。正式交付需分别核对作业结果、产物组成与平台验证记录。

详细设计：[构建、验证与发布](构建验证与发布.md)。

依据：[`scripts/verify-local.sh`](../../scripts/verify-local.sh)；[`scripts/runtime-manifest.zsh`](../../scripts/runtime-manifest.zsh)；[`scripts/build-test-app.sh`](../../scripts/build-test-app.sh)；[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)；[部署指南](../guide/01-本地部署指南.md)。

## 共享约束与设计衔接

Bridge 的请求与响应构成宿主和 Collector 的边界，凭据是受控运行输入，不进入命令行参数。`credentialUpdates` 是敏感的凭据回传通道，因此完整 stdout 也须按敏感数据处理。配置与凭据决定输入权限，采集与额度模块产生工件，调度及快照决定数据时效，映射与界面决定读者看到的状态。

各设计中的“成功”“可用”“陈旧”和“已验收”有不同含义。能发布部分工件不代表全部 Provider 成功，保留旧窗口不代表本轮重新查询，静态代码和自动化期望也不证明真实凭据或设备表现。未完成的平台与凭据事项由研发卡片记录，仍需对应环境验证。

依据：[`CollectorRunInput.swift`](../../apps/macos/Sources/BruceAppCore/CollectorRunInput.swift)；[`collector-bridge/src/lib.rs`](../../core/collector/crates/collector-bridge/src/lib.rs)；[研发变更总账](../devel/change/index.json)。

## 相关文档

- [术语表](术语表.md)：查询 Bridge、Artifact、快照和调度等名称的项目语境。
- [刷新生命周期设计](刷新生命周期设计.md)：追踪跨设计的一轮刷新和结果发布。

最后更新：2026-10-19

