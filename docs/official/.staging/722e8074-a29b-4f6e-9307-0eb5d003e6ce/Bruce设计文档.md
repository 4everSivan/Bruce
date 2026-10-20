# 系统设计

Bruce 将本机 AI Agent 会话的 Token 用量与费用估算、各订阅服务的额度集中展示在桌面看板。系统没有自有服务端：桌面应用持有配置、授权和凭据，Collector 读取本地数据并在具备相应输入时访问 Provider，界面消费标准 Artifact。

## 模块与职责

模块按职责和契约划分，Rust crate 与 Swift target 是模块内部的技术组织边界。

| 模块 | 职责 | 主要依赖 | 主设计 |
|---|---|---|---|
| 本地用量与计费 | 读取会话、聚合 Token、估算模型费用 | 文件与只读 SQLite、采集窗口、价格表 | [Collector 设计](采集引擎与本地用量设计.md) |
| 订阅额度查询 | 将注入凭据对应的服务响应转为额度、余额与诊断 | Provider 适配、网络运行时、Bridge 字段白名单 | [订阅额度查询设计](订阅额度查询设计.md) |
| macOS 原生应用 | 调度、快照、菜单栏、看板和设置交互 | Collector 子进程、凭据配置、SwiftUI / AppKit | [macOS 应用设计](macOS原生应用设计.md) |
| 订阅配置与凭据管理 | 依赖扫描、同意门控、账号与凭据读写 | 受保护文件、外部 CLI 登录态、Codex OAuth | [订阅配置与凭据管理](订阅配置与凭据管理设计.md) |
| Windows 托盘应用 | 托盘、设置、采集调度、快照与 WebView 看板 | 共享 Bridge、Rust 视图模型、Tauri | [Windows 应用设计](Windows应用设计.md) |
| 独立 Widget | 展示宿主提供的用量与额度，管理浏览器动画 | Daimon 数据、状态和主题事件 | [Widget 设计](Widget设计.md) |
| 工程交付 | 本地验证、组包、版本与 Release 资产 | Rust / Swift 工具链、CI、平台打包工具 | [构建、验证与发布](构建验证与发布.md) |

依据：[`apps/macos/Sources/BruceApp/BruceApp.swift`](../../apps/macos/Sources/BruceApp/BruceApp.swift) 的组合根；[`apps/win/src-tauri/src/lib.rs`](../../apps/win/src-tauri/src/lib.rs) 的 `run()`；[`core/collector/crates/collector-application/src/lib.rs`](../../core/collector/crates/collector-application/src/lib.rs) 的 `collect_agent_usage()`；[原系统设计](../devel/design/00-系统总体设计.md)。

## 两个桌面入口与共享引擎

模块的连接方式如下。图中的 Collector 分支对应普通采集路径，Codex 定向恢复另见[刷新生命周期](刷新生命周期设计.md)。

![macOS 经 stdio、Windows 经进程内调用共享 Bridge，Widget 使用独立宿主](../assets/km/system-architecture.svg)

图：Bruce 模块关系。当前实现按职责抽象，未表示运行中的部署实例。

macOS 从 `BruceApp` 装配 Runner、凭据存储、调度器和单一 `AppModel`。`ApplicationBootstrap` 先启动调度器读取可用快照，再按凭据访问配置准备迁移与账号状态。允许采集后，`CollectorRunner` 经子进程 stdin 发送请求、读取 stdout 响应，交给 Pipeline 处理。Windows 的 `main()` 进入 Tauri `run()`，后台调度线程直接调用 `collector_bridge::run_bytes_panic_safe()`；它共享协议和引擎，不启动同一个 macOS 子进程适配器。

Collector 普通路径按 `localSessions` 和 `externalQuotas` 组织本地与额度分支，最终合并为 `AgentUsageArtifact`。相同 Artifact 契约减少了双端数据语义差异，但凭据装配、门控、快照状态和呈现分别由两端负责，不能从共享 crate 推出界面与实机行为完全一致。Widget 只接收宿主的 `data.main`，不存在由原生 App 打包并自动推送数据的连接。

依据：[`ApplicationBootstrap.swift`](../../apps/macos/Sources/BruceApp/ApplicationBootstrap.swift) 的 `startIfNeeded()`；[`CollectorRunner.swift`](../../apps/macos/Sources/BruceAppCore/CollectorRunner.swift)；[`apps/win/src-tauri/src/main.rs`](../../apps/win/src-tauri/src/main.rs)；[`apps/win/src-tauri/src/collector.rs`](../../apps/win/src-tauri/src/collector.rs) 的 `run_configured_collection()`；[`collector-application/src/lib.rs`](../../core/collector/crates/collector-application/src/lib.rs) 的 `collect_agent_usage_with_dependencies_inner()`；[`apps/widget/index.html`](../../apps/widget/index.html)。

## 数据发布与状态责任

macOS 的一轮刷新由 `RefreshScheduler` 接收触发和合并意图，`RefreshExecutionPipeline` 负责输入、采集、Codex 恢复、结果合并、凭据更新和 Artifact 发布。凭据写回早于快照发布；写回失败可保留可用数据并附诊断，发布失败则返回独立错误。完整顺序、异常和停止规则由[刷新生命周期](刷新生命周期设计.md)统一说明。

`ArtifactStore` 持有当前与 previous 快照，`AppModel` 将它们与配置状态组合，经 mapper 形成菜单栏和面板数据。Windows 则由 `SnapshotState` 持有 Artifact、阶段、诊断和最后成功时间，`get_dashboard` 读取缓存并映射 Panel，不另起一轮采集。两端各自持久化快照，不能互换文件路径或状态枚举。

依据：[`RefreshExecutionPipeline.swift`](../../apps/macos/Sources/BruceAppCore/RefreshExecutionPipeline.swift) 的 `run()`、`finishPublishablePath()`；[`ArtifactStore.swift`](../../apps/macos/Sources/BruceAppCore/ArtifactStore.swift)；[`apps/win/src-tauri/src/runtime_core.rs`](../../apps/win/src-tauri/src/runtime_core.rs) 的 `SnapshotState`；[`apps/win/src-tauri/src/lib.rs`](../../apps/win/src-tauri/src/lib.rs) 的 `get_dashboard()`。

## 全局约束与实现差异

凭据是受控运行输入，不进入命令行参数。Bridge 响应中的 `credentialUpdates` 是受校验的凭据回传通道，因此完整 stdout 响应也应按敏感数据处理。外部 SQLite 数据源只读；应用自有快照、缓存与配置分别落在平台数据目录中。构建输出目录与这些用户运行数据目录是不同概念。

模型成本来自本地价格表及用户覆盖值，是估算费用。Provider 额度来自各家服务的窗口或余额，不能与本地成本直接相减。无法解析的价格、失败账号和陈旧快照有各自的缺失或降级语义，详见相应模块正文。

当前工作区的 Claude 读取、导入和设置交互包含 C060 的修改；变更卡仍为 `in_progress`。Windows 也保留未闭环的实现与实机事项，且 Provider 配置和请求装配有具体差异。这些状态影响相关行为的验收结论，不应被文档发布状态覆盖。

依据：[`CollectorRunInput.swift`](../../apps/macos/Sources/BruceAppCore/CollectorRunInput.swift)；[`collector-bridge/src/lib.rs`](../../core/collector/crates/collector-bridge/src/lib.rs) 的凭据更新校验；[C060 变更卡](../devel/change/C060.json)；[Windows 待办](../devel/todo/now.md)；[原 Windows 设计](../devel/design/05-Windows平台适配.md)。

## 相关文档

- [本地会话解析与计费](本地会话解析与计费.md)：聚合、增量与费用缺失的详细规则。
- [订阅配置与凭据管理](订阅配置与凭据管理设计.md)：凭据来源、授权与存储边界。
- [Windows 快照与刷新状态](Windows快照与刷新状态.md)：另一端的状态责任与失败处理。

最后更新：2026-10-18
