# Bruce 设计文档

Bruce 将本机 AI Agent 的会话用量、参考费用和服务端订阅额度汇总到桌面看板。共享 Rust Collector 负责数据生产，macOS 和 Windows 客户端分别负责配置、凭据管理、刷新调度与界面呈现。独立 Widget 由外部宿主提供数据。

## 目录

- [1. 简介](#chapter-1)
- [2. 需求](#chapter-2)
- [3. 目标](#chapter-3)
- [4. 功能设计](#chapter-4)
  - [4.1 采集与本地计费](#capability-1)
  - [4.2 订阅与账号](#capability-2)
  - [4.3 原生交互与设置](#capability-3)
  - [4.4 刷新与恢复](#capability-4)
  - [4.5 分析工作台](#capability-5)
  - [4.6 Windows 与 Widget](#capability-6)
- [5. 架构设计](#chapter-5)
  - [5.1 数据与状态归属](#shared-state)
  - [5.2 刷新主干协作](#backbone-flow)
- [6. 详细设计](#chapter-6)
  - [6.1 本地采集与计费设计](#local-usage)
  - [6.2 订阅额度查询设计](#provider-quota)
  - [6.3 订阅配置与凭据设计](#credentials)
  - [6.4 macOS 应用装配设计](#macos-app)
  - [6.5 菜单栏与看板设计](#dashboard)
  - [6.6 设置与价格校准设计](#settings-pricing)
  - [6.7 刷新、快照与恢复设计](#refresh-snapshot)
  - [6.8 Windows 平台适配设计](#windows)
  - [6.9 独立 Widget 设计](#widget)
  - [6.10 工程验证与交付设计](#delivery)
  - [6.11 Agent 用量分析与跨源归并设计](#agent-analytics)
  - [6.12 Windows 用量工作台设计](#windows-workbench)
- [7. 参考文献](#chapter-7)
  - [7.1 原始设计与实现入口](#source-references)
  - [7.2 相关文档](#related-reading)

<a id="chapter-1"></a>
## 1. 简介

本文面向采集、订阅和桌面客户端的维护者，介绍系统需求、功能点与责任边界，并链接到对应的详细设计。原始会话、配置和凭据保存在本机，订阅查询按授权访问外部 Provider。本地费用估算与服务端额度采用不同的统计口径。

主要领域对象为 `AgentUsageArtifact`（展示工件）、`TokenBucket`（四类 Token）与宿主快照。Bridge 负责受控请求和响应；UI 不直接扫描会话，Collector 不拥有长期调度或用户窗口。

依据：[原系统设计](../devel/design/00-系统总体设计.md)；[`collector-domain/src/lib.rs`](../../core/collector/crates/collector-domain/src/lib.rs)；[`BruceApp.swift`](../../apps/macos/Sources/BruceApp/BruceApp.swift)。

<a id="chapter-2"></a>
## 2. 需求

原系统设计的场景是多 Agent 并行开发时统一查看消耗与不同订阅窗口，避免在多个网页间切换。原采集设计要求只读异构来源、窗口聚合、多维统计和价格覆盖；订阅设计要求账号级查询与安全凭据；菜单栏和设置设计要求轻量常驻、主题与用户配置；分析设计进一步要求宽窗口的历史趋势和来源归并。

| 原始需求 | 当前实现与边界 | 详细位置 |
|---|---|---|
| 多源 Token 与参考成本 | JSONL/SQLite 适配、来源去重与缓存；部分来源为估算 | [本地解析](本地会话解析与计费.md#normalization) |
| 窗口/余额查询 | 注入账号后查询 Provider；客户端和服务失败独立表达 | [额度执行](订阅额度查询设计.md#account-execution) |
| 凭据安全与低干扰 | 自有受保护文件、外部只读；真实系统交互仍需对应环境证据 | [凭据边界](订阅配置与凭据管理设计.md#external-oauth) |
| 常驻看板与可配置展示 | 菜单栏指标、面板、主题、设置及价格覆盖 | [原生呈现](菜单栏与看板设计.md#metrics) |
| 长周期分析与渠道归并 | 五档范围、跨源模型与导出；旧工件缺少明细时部分统计不可用 | [分析工作台](Agent用量分析设计.md#chapter-5) |
| Windows 与独立 Widget | Tauri 共享引擎、Widget 宿主事件；平台集成分别验收 | [Windows](Windows应用设计.md#windows-limits)、[Widget](Widget设计.md#host-contract) |

角色包括本机开发者、提供会话的 Agent、额度 Provider 和 Widget 宿主。外部日志结构、OAuth/API 鉴权、操作系统通知和窗口框架属于依赖边界。

依据：[原采集设计](../devel/design/01-数据采集与多模型计费引擎.md)、[原订阅设计](../devel/design/02-订阅额度与凭据安全存储.md)、[原菜单栏设计](../devel/design/03-菜单栏状态与多风格原生渲染.md)、[原设置设计](../devel/design/04-设置中心与价格校准交互.md)、[原 Windows 设计](../devel/design/05-Windows平台适配.md)、[原分析设计](../devel/design/06-Agent用量分析与Token统计工作台.md)。

<a id="chapter-3"></a>
## 3. 目标

原系统设计声明引擎与 UI 解耦、本地优先、成本感知与低干扰交互。非目标是代理模型对话、修改外部会话、修复第三方数据库或建立中心化同步。当前实现以宿主长期调度与一次性采集分工，支持部分结果和旧值保留；这些机制不提供跨凭据文件、工件与元数据的统一事务。

原采集设计给出扫描延迟、峰值内存等性能目标，分析设计给出切换延迟目标；本文没有相应运行测量，目标不作为当前达标结论。原设计中的"缓存零冗余 I/O""全历史精确模型统计""无扫描热重算"等声明也须对照实际缓存遍历、Top 5 截断、比例估算和保存后刷新路径理解。

依据：[原系统设计](../devel/design/00-系统总体设计.md) 的目标与非目标；[原采集设计](../devel/design/01-数据采集与多模型计费引擎.md) 的性能指标；[原分析设计](../devel/design/06-Agent用量分析与Token统计工作台.md) 的验收目标；[`RefreshExecutionPipeline.swift`](../../apps/macos/Sources/BruceAppCore/RefreshExecutionPipeline.swift)。

<a id="chapter-4"></a>
## 4. 功能设计

功能点按入口、规则和可观察结果分解。下面的索引指向主要解释位置；跨模块刷新只在刷新生命周期中完整展开，其它文章说明自身输入与效果。

<a id="capability-1"></a>
### 4.1 采集与本地计费

**功能需求**：用户需要在本机直接看到各 Agent 会话消耗的 Token 与参考费用，且不改动第三方会话文件。宿主发送受控请求，Collector 只读扫描来源，把去重贡献聚合为 Token、趋势与参考费用。缓存依据来源和窗口决定复用、追加或重建，不能把缓存命中解释成零文件读取。

| 功能点 | 主要规则与结果位置 |
|---|---|
| Bridge请求校验与跨宿主调用 | [采集引擎与本地用量设计](采集引擎与本地用量设计.md#bridge-contract) |
| 本地与额度并行编排及工件装配 | [采集引擎与本地用量设计](采集引擎与本地用量设计.md#collection-flow) |
| 取消、资源限制与诊断封套 | [采集引擎与本地用量设计](采集引擎与本地用量设计.md#cancellation) |
| 时间窗口与多源只读扫描 | [本地会话解析与计费](本地会话解析与计费.md#source-window) |
| 来源去重与Token归一化 | [本地会话解析与计费](本地会话解析与计费.md#normalization) |
| 文件/SQLite/整树缓存复用追加重建 | [本地会话解析与计费](本地会话解析与计费.md#cache) |
| 贡献替换与多维聚合 | [本地会话解析与计费](本地会话解析与计费.md#contributions) |
| 价格匹配与四类Token计费 | [本地会话解析与计费](本地会话解析与计费.md#pricing) |

<a id="capability-2"></a>
### 4.2 订阅与账号

**功能需求**：用户授权并配置账号后，需要看到服务商返回的窗口与余额，且单个账号失败不影响其它结果。用户同意、可用账号与当前额度策略共同决定是否查询。Provider 内的有限续期与宿主的凭据存储、定向恢复各有边界，服务失败允许与本地结果并存。

| 功能点 | 主要规则与结果位置 |
|---|---|
| 多账号计划与固定结果顺序 | [订阅额度查询设计](订阅额度查询设计.md#account-plan) |
| 限额并发与服务隔离 | [订阅额度查询设计](订阅额度查询设计.md#account-execution) |
| Provider窗口余额适配与Cline条件查询 | [订阅额度查询设计](订阅额度查询设计.md#provider-adapters) |
| Claude到期续期与401重试 | [订阅额度查询设计](订阅额度查询设计.md#claude-refresh) |
| 凭据更新、Codex挑战与宿主门禁 | [订阅额度查询设计](订阅额度查询设计.md#credential-updates) |
| 非敏感配置与自有凭据隔离存储 | [订阅配置与凭据管理设计](订阅配置与凭据管理设计.md#storage) |
| 统一同意与自动输入门控 | [订阅配置与凭据管理设计](订阅配置与凭据管理设计.md#activation-gate) |
| Claude外部读取和较新CLI凭据选择 | [订阅配置与凭据管理设计](订阅配置与凭据管理设计.md#external-oauth) |
| Codex发现登录与可用token决议 | [订阅配置与凭据管理设计](订阅配置与凭据管理设计.md#codex-accounts) |
| 轮换合并、写回与失败降级 | [订阅配置与凭据管理设计](订阅配置与凭据管理设计.md#rotation-writeback) |

<a id="capability-3"></a>
### 4.3 原生交互与设置

**功能需求**：用户需要一个常驻菜单栏看板和独立设置中心完成展示配置，启动、模型失效与退出各有明确规则。组合根装配共享模型，菜单栏与设置分别持有交互状态。配置保存后，主题、指标和调度按各自路径生效；价格覆盖还触发 Collector 刷新。

| 功能点 | 主要规则与结果位置 |
|---|---|
| 启动装配、缓存恢复与延后凭据准备 | [macOS原生应用设计](macOS原生应用设计.md#bootstrap) |
| 共享模型失效和呈现过滤 | [macOS原生应用设计](macOS原生应用设计.md#app-contract) |
| 优雅退出、强制终止与取消退出 | [macOS原生应用设计](macOS原生应用设计.md#termination) |
| 指标选择与额度环规绘制 | [菜单栏与看板设计](菜单栏与看板设计.md#metrics) |
| 面板点击切换与失焦关闭 | [菜单栏与看板设计](菜单栏与看板设计.md#panel-toggle) |
| 主题解析、卡片折叠与隐藏释放 | [菜单栏与看板设计](菜单栏与看板设计.md#theme) |
| 设置窗口与偏好模型 | [设置中心与价格校准设计](设置中心与价格校准设计.md#settings-window) |
| 指标编辑与主题生效 | [设置中心与价格校准设计](设置中心与价格校准设计.md#settings-navigation) |
| 价格校准保存、重置与刷新 | [设置中心与价格校准设计](设置中心与价格校准设计.md#pricing-activation) |
| 锁屏暂停开关保存与生效 | [设置中心与价格校准设计](设置中心与价格校准设计.md#lock-preference) |
| Windows独立设置校验 | [设置中心与价格校准设计](设置中心与价格校准设计.md#windows-settings) |

<a id="capability-4"></a>
### 4.4 刷新与恢复

**功能需求**：定时、手动、系统事件和重试等多种触发需要合并去重并按门禁执行；离线、锁屏与失败恢复要有明确行为。各类触发先经门禁与意图合并。离线暂停自动轮次，锁屏只抑制非手动的新额度查询；发布与凭据写回的失败不会统一回滚。

| 功能点 | 主要规则与结果位置 |
|---|---|
| 定时手动定向触发与意图合并 | [刷新生命周期设计](刷新生命周期设计.md#scheduler-state) |
| 离线暂停与联网补偿 | [刷新生命周期设计](刷新生命周期设计.md#offline-quota) |
| 锁屏本地采集与解锁补偿 | [刷新生命周期设计](刷新生命周期设计.md#screen-lock) |
| 额度节流、限流冷却和旧服务回填 | [刷新生命周期设计](刷新生命周期设计.md#offline-quota) |
| 单轮凭据恢复、发布和告警 | [刷新生命周期设计](刷新生命周期设计.md#refresh-sequence) |
| 快照写入、损坏回退与取消退出 | [刷新生命周期设计](刷新生命周期设计.md#snapshot) |

<a id="capability-5"></a>
### 4.5 分析工作台

**功能需求**：用户要在已有工件范围内查看长周期趋势，并按原始渠道与 Agent 下钻，同时清楚哪些数字含估算。工作台从已有工件选范围并派生模型和趋势，允许按原始渠道及 Agent 下钻。历史分配、部分 Token 构成、轮次和费用含估算，导出格式保留各自数据范围。

| 功能点 | 主要规则与结果位置 |
|---|---|
| 时间范围、KPI与估算口径 | [Agent用量分析设计](Agent用量分析设计.md#time-kpi) |
| 模型归一化与保留来源渠道 | [Agent用量分析设计](Agent用量分析设计.md#model-normalization) |
| 时间桶和趋势系列派生 | [Agent用量分析设计](Agent用量分析设计.md#timeline-flow) |
| Agent及项目下钻和Token构成 | [Agent用量分析设计](Agent用量分析设计.md#analytics-display) |
| 探针重检与CSV/JSON导出 | [Agent用量分析设计](Agent用量分析设计.md#export) |

<a id="capability-6"></a>
### 4.6 Windows 与 Widget

**功能需求**：Windows 与 Widget 是两条独立呈现路径，各自管理调度、凭据与动画，不继承 macOS 全部运行行为。Windows 使用独立调度、凭证和窗口规则；Widget 消费宿主事件并自行管理动画。

| 功能点 | 主要规则与结果位置 |
|---|---|
| Windows主题、字体与项目终端形态 | [Windows应用设计](Windows应用设计.md#windows-theme) |
| Windows工作台范围、曲线与模型汇总 | [Windows用量工作台设计](Windows用量工作台设计.md#windows-ranges) |
| Tauri启动与窗口IPC | [Windows应用设计](Windows应用设计.md#windows-startup) |
| 授权配置与凭据装配 | [Windows应用设计](Windows应用设计.md#windows-config) |
| 受限凭据落盘与Codex恢复 | [Windows应用设计](Windows应用设计.md#windows-credentials) |
| 面板映射、告警与导出 | [Windows应用设计](Windows应用设计.md#windows-mapping) |
| 容量一手动通道与后台循环 | [Windows快照与刷新状态](Windows快照与刷新状态.md#windows-triggers) |
| 快照阶段与旧服务保留 | [Windows快照与刷新状态](Windows快照与刷新状态.md#windows-snapshot) |
| 退避和窗口边界唤醒 | [Windows快照与刷新状态](Windows快照与刷新状态.md#windows-retry) |
| 缓存映射与可见性补绘 | [Windows快照与刷新状态](Windows快照与刷新状态.md#windows-presentation) |
| 宿主事件与缺失数据处理 | [Widget设计](Widget设计.md#host-contract) |
| 用量额度展示与日期对齐 | [Widget设计](Widget设计.md#display) |
| 像素场可见性、交互与销毁 | [Widget设计](Widget设计.md#animation) |

工程交付通过验证脚本、Universal 2 组包与 tag CI 完成，操作入口与检查边界见[构建验证与发布](构建验证与发布.md)。

<a id="chapter-5"></a>
## 5. 架构设计

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
| Agent 用量分析 | 从缓存工件派生范围 KPI、模型归并和趋势；依赖 AppModel 与价格目录 | [Agent 用量分析设计](Agent用量分析设计.md) |
| 独立 Widget | 宿主事件、展示与动画生命周期；依赖浏览器环境 | [Widget 设计](Widget设计.md) |
| 工程验证与交付 | 验证、组包、版本和发布资产；依赖工具链与 CI | [构建、验证与发布](构建验证与发布.md) |

依据：[原系统设计](../devel/design/00-系统总体设计.md) 的领域分层与主题矩阵；[`BruceApp.swift`](../../apps/macos/Sources/BruceApp/BruceApp.swift)；[`apps/win/src-tauri/src/lib.rs`](../../apps/win/src-tauri/src/lib.rs) 的 `run()`；[`apps/widget/index.html`](../../apps/widget/index.html)。

<a id="shared-state"></a>
### 5.1 数据与状态归属

Collector 持有单次运行预算、取消令牌和可重建缓存；宿主持有配置、凭据、快照、调度与 UI 状态。服务 freshness、调度 phase、界面的 LIVE 或"刷新中"标签分别表达数据时效、执行状态和时间文案。分析范围、图表模式和展开集合只存在于视图内。

Bridge 的请求与响应构成宿主和 Collector 的边界，凭据是受控运行输入，不进入命令行参数。`credentialUpdates` 是敏感的凭据回传通道，因此完整 stdout 也须按敏感数据处理。配置与凭据决定输入权限，采集与额度模块产生工件，调度及快照决定数据时效，映射与界面决定读者看到的状态。

各设计中的"成功""可用""陈旧"和"已验收"有不同含义。能发布部分工件不代表全部 Provider 成功，保留旧窗口不代表本轮重新查询，静态代码和自动化期望也不证明真实凭据或设备表现。未完成的平台与凭据事项由研发卡片记录，仍需对应环境验证。

依据：[`CollectorRunInput.swift`](../../apps/macos/Sources/BruceAppCore/CollectorRunInput.swift)；[`collector-bridge/src/lib.rs`](../../core/collector/crates/collector-bridge/src/lib.rs)；[研发变更总账](../devel/change/index.json)。

<a id="backbone-flow"></a>
### 5.2 刷新主干协作

macOS 的主干交接如下，Provider 续期和宿主恢复在各自位置执行。

![单轮刷新从旧快照和输入经采集恢复、凭据写回再发布](../assets/km/refresh-sequence.svg)

图：macOS 刷新主干。共享此图只说明系统协作，具体网络、锁屏和失败守卫见[刷新生命周期](刷新生命周期设计.md#refresh-sequence)。

发布前先应用凭据更新，再持久化工件，最后回调模型；凭据保存与快照不是单一事务。Windows 在进程内调用 Bridge，Widget 没有从此链路自动接收推送。

依据：[`RefreshExecutionPipeline.swift`](../../apps/macos/Sources/BruceAppCore/RefreshExecutionPipeline.swift)；[`ArtifactStore.swift`](../../apps/macos/Sources/BruceAppCore/ArtifactStore.swift)；[`apps/win/src-tauri/src/collector.rs`](../../apps/win/src-tauri/src/collector.rs)；[`apps/widget/index.html`](../../apps/widget/index.html)。

<a id="chapter-6"></a>
## 6. 详细设计

各主题保留独立详细设计；下列章节说明系统级契约、关键机制与依赖，内部算法和正常、异常推演见对应详设。每节按「功能需求 → 设计目标 → 方案机制 → 边界与非目标」展开：先说明这一节解决什么问题，再列出从需求推出的设计取向，随后写实现机制，最后单独划清不做什么与失败语义。

<a id="local-usage"></a>
### 6.1 本地采集与计费设计

**功能需求**：用户需要在本机直接看到各个 AI Agent 会话消耗的 Token 与参考费用，且不能改动或修复第三方会话文件、数据库；结果按日、模型、项目和小时聚合后供菜单栏看板展示。

**设计目标**：
- 只读外部来源（满足：不修改第三方会话与数据库）；
- 增量复用缓存（满足：重复扫描不重复解析）；
- 费用仅作参考估算，未知情况显式保留诊断（满足：不用零费用掩盖失败）；
- 与设置价格、刷新预算衔接（满足：接受价格覆盖，参与取消与资源限制）。

**方案机制**：本地模块把不同 Agent 的会话转为统一用量贡献，再按日、模型、项目和小时聚合。输入包括 JSONL 与只读 SQLite；Collector 自有缓存用于避免重复解析，依据来源和窗口决定复用、追加或重建，不能修改或修复第三方来源。聚合层保存输入、输出及缓存 Token 的语义，模型价格由内置表和用户覆盖项共同决定。路径覆盖、采集窗口和能力输入决定本轮读取范围，目录或文件存在本身不表示主链路实际扫描它。

**边界与非目标**：费用属于参考估算；未知模型、无效价格、来源缺失和读取失败分别保留其诊断，不能用零费用表示所有未知情况。该模块向看板提供数据，接受设置设计的价格输入，并参与刷新设计的资源预算与取消。

详细设计：[采集引擎与本地用量设计](采集引擎与本地用量设计.md)；深入机制见[本地会话解析与计费](本地会话解析与计费.md)。

依据：[`collector-application/src/lib.rs`](../../core/collector/crates/collector-application/src/lib.rs) 的 `collect_local_usage()`；[`collector-aggregate/src/lib.rs`](../../core/collector/crates/collector-aggregate/src/lib.rs)；[`collector-domain/src/pricing.rs`](../../core/collector/crates/collector-domain/src/pricing.rs)。

<a id="provider-quota"></a>
### 6.2 订阅额度查询设计

**功能需求**：菜单栏展示的订阅窗口与余额必须来自服务商实时查询，不能由本地会话费用推算；多个账号并行查询时，单个服务商失败不能拖垮其它账号结果；查询过程中凭据可能刷新，更新结果须安全交回宿主保管，Collector 本身不接触系统钥匙串。

**设计目标**：
- 查询授权归宿主（满足：本轮是否查询由授权与额度策略共同决定）；
- 服务故障隔离（满足：局部失败保留其它账号结果）；
- 凭据不落地 Collector（满足：刷新结果经 Bridge 封套回传，Rust 生产路径不自行打开系统钥匙串）。

**方案机制**：模块把宿主注入的账号凭据组织成请求计划，通过各 Provider 的适配器转为窗口、余额及诊断；凭据更新和挑战经 Bridge 封套返回，由宿主验证和持久化。

查询是否发生同时受授权和本轮额度策略约束。双端宿主使用共享额度策略结合历史服务时间戳、启用的 Provider 与刷新意图，决定本地专用采集或需要查询的 Provider。Bridge 使用 `localSessions`、`externalQuotas` 能力与跳过集合控制本轮查询；旧额度由宿主回填，必须与本轮真实查询结果区分。

Claude 在到期前 60 秒内尝试主动续期，未成功刷新且查询遇到 401 时可再补救；成功查询的轮换指令经过封套交给宿主。

**边界与非目标**：服务间局部失败保留其它结果；共享计算不代表两端宿主的完整调度及系统交互相同；失败、空态和更新写回不构成一个远端/本地事务。

详细设计：[订阅额度查询设计](订阅额度查询设计.md)；宿主策略及回填见[刷新生命周期设计](刷新生命周期设计.md)。

依据：[`collector-application/src/account.rs`](../../core/collector/crates/collector-application/src/account.rs) 的 `build_account_plan()`；[`collector-application/src/lib.rs`](../../core/collector/crates/collector-application/src/lib.rs)；[`collector-bridge/src/lib.rs`](../../core/collector/crates/collector-bridge/src/lib.rs) 的白名单；[`QuotaRefreshPolicy.swift`](../../apps/macos/Sources/BruceAppCore/QuotaRefreshPolicy.swift)。

<a id="credentials"></a>
### 6.3 订阅配置与凭据设计

**功能需求**：用户需要一个入口管理选中的模块、Provider、统一同意、账号及展示偏好；凭据属于敏感数据，必须与可公开配置分离落盘；自动探测、用户明确导入和实际查询是三种不同访问意图，未经授权不应读取外部登录态。

**设计目标**：
- 配置与凭据分离存储（满足：敏感凭据单独保护）；
- 按访问意图门控授权（满足：探测、导入、查询分别放行）；
- 外部凭据只读、避免交互弹窗（满足：不打扰用户，不修复外部数据）。

**方案机制**：配置描述选中的模块、Provider、统一同意、账号及展示偏好；凭据内容与可公开的配置、诊断分开管理。授权门控决定何时允许读取外部登录态、装配订阅输入或启用采集。凭据存储采用受保护文件和原子替换；外部数据库只读，系统凭据探测应避免触发交互式弹窗。多账号身份和顺序沿用来源声明，Codex 的发现、登录、刷新与挑战恢复由专门组件协调。

Claude 通过外部 security 子进程和本地文件顺序读取，已存 claude-cli 与 CLI 以到期值比较选择输入；令牌在 Collector 内可续期，宿主只回写自有存储；缺旧嵌套对象时的轮换格式限制仍影响后续复用。

**边界与非目标**：应用内已有账号并不自动代表当前凭据有效，导入成功也不等于服务商查询成功。

详细设计：[订阅配置与凭据管理设计](订阅配置与凭据管理设计.md)。

依据：[原订阅与凭据设计](../devel/design/02-订阅额度与凭据安全存储.md)；[`CollectorRunInput.swift`](../../apps/macos/Sources/BruceAppCore/CollectorRunInput.swift)；[`ExternalCredentialReader.swift`](../../apps/macos/Sources/BruceOnboardingCore/ExternalCredentialReader.swift)；[`SubscriptionCredentialImport.swift`](../../apps/macos/Sources/BruceOnboardingCore/SubscriptionCredentialImport.swift)。

<a id="macos-app"></a>
### 6.4 macOS 应用装配设计

**功能需求**：应用启动后要尽快展示本地已有数据，同时异步完成配置与账号准备；退出时有序停止调度、取消在途任务，不留孤儿进程；界面只消费模型，不直接扫描会话。

**设计目标**：
- 快照展示不依赖外部登录（满足：缓存恢复先于凭据准备）；
- 单一共享模型驱动界面（满足：UI 不直接读会话）；
- 生命周期有序退出（满足：宽限期后终止剩余进程）。

**方案机制**：应用组合根连接 Collector 执行器、快照库、运行输入、凭据写回、调度器和单一 `AppModel`。`ApplicationBootstrap` 先接通回调并启动缓存恢复，再处理配置与账号准备，因此本地快照展示不依赖外部登录态读取先完成。`ArtifactStore` 维护持久化工件，`AppModel` 把工件、配置与就绪状态组合，经映射器交给菜单栏和面板。退出由生命周期协调器停止调度、取消任务，并在宽限期后终止剩余进程。

**边界与非目标**：窗口、状态项和快捷键有各自的清理责任，不由组合根统一处理。

详细设计：[macOS 原生应用设计](macOS原生应用设计.md)。

依据：[`BruceApp.swift`](../../apps/macos/Sources/BruceApp/BruceApp.swift)；[`ApplicationBootstrap.swift`](../../apps/macos/Sources/BruceApp/ApplicationBootstrap.swift)；[`AppModel.swift`](../../apps/macos/Sources/BruceAppCore/AppModel.swift)；[`ApplicationLifecycleCore.swift`](../../apps/macos/Sources/BruceAppCore/ApplicationLifecycleCore.swift)。

<a id="dashboard"></a>
### 6.5 菜单栏与看板设计

**功能需求**：菜单栏要在有限宽度内稳定展示指标并支持打开看板，模型更新时重绘不能跳变；主题须适配系统能力；点击开关的可见性变化不能被失焦通知抢先改变。

**设计目标**：
- 布局稳定、重绘不跳变（满足：模型更新后读取新值重绘单张图像）；
- 逻辑状态与可见性分离（满足：避免失焦通知覆盖第二次点击）；
- 主题按系统能力回退（满足：不支持液态玻璃时回退经典）。

**方案机制**：状态项将图标与指标绘成单张图像，保持布局稳定，并在模型更新后读取新值重绘。额度环规按选定的最低或平均剩余值呈现，刷新动画与文本宽度由原生控制器管理。看板使用独立 `NSPanel` 承载 SwiftUI 内容，卡片折叠保留标题与摘要。点击开关的逻辑状态与 AppKit 异步的可见性分开维护，避免失焦通知抢先改变第二次点击的结果。

经典、液态玻璃和 Nothing 是三种界面偏好。主题解析同时考虑持久化配置及系统能力：不支持液态玻璃时回退经典，Nothing 保留自身分支；明暗偏好与玻璃变体分别作用于原生材质。

**边界与非目标**：隐藏、遮挡与退出还影响动画是否继续执行；该设计消费设置与模型，系统能力回退和窗口焦点规则由原生控制器落实。

详细设计：[菜单栏与看板设计](菜单栏与看板设计.md)。

依据：[原菜单栏设计](../devel/design/03-菜单栏状态与多风格原生渲染.md)；[`MenuBarStatusItemController.swift`](../../apps/macos/Sources/BruceApp/MenuBarStatusItemController.swift)；[`DashboardPanelVisibility.swift`](../../apps/macos/Sources/BruceAppCore/DashboardPanelVisibility.swift)；[`ThemeResolution.swift`](../../apps/macos/Sources/BruceOnboardingCore/ThemeResolution.swift)。

<a id="settings-pricing"></a>
### 6.6 设置与价格校准设计

**功能需求**：用户需要一个集中窗口编辑展示、刷新、模型计费、订阅和维护等配置；调整模型价格后，下一轮采集应使用新价格；刷新间隔、锁屏等开关保存后即时生效；设置页同时承载分析工作台入口。

**设计目标**：
- 配置按消费者分发（满足：保存后通知各自负责的组件生效）；
- 价格覆盖进入下一轮采集输入（满足：重新聚合而非内存热改）；
- 开关失败保留旧值（满足：不让坏配置进入运行态）。

**方案机制**：设置中心以六类侧栏组织展示、刷新、模型计费、订阅和维护等配置，并通过协调器保存及通知相应消费者。菜单栏指标可预览、选择和拖拽排序；模型价格表支持搜索、用量/自定义筛选、单项校准与重置，配置预览展示覆盖集合。设置窗口由单例控制器管理，打开时进入有 Dock 图标的普通应用呈现，关闭后恢复菜单栏模式。

价格校准写入 `pricingOverrides`，下一轮输入携带覆盖值供 Collector 重新聚合；当前 `persistPricingOverrides()` 保存成功后触发刷新。刷新间隔保存后同时更新本地采集周期与订阅额度新鲜度周期；429 冷却仍独立保持 30 分钟。锁屏开关先保存配置再通知调度器。

**边界与非目标**：原设计中"内存热重算、无需重新扫描"的目标与当前实现链路不同；手动、边界和恢复意图有各自规则，设置周期并非所有网络请求的固定间距；锁屏开关失败保持旧值；Agent 用量分区挂载分析工作台，其数据派生和精度由独立[分析设计](Agent用量分析设计.md)说明；菜单栏交互、配置持久化和采集策略分别归其所属组件负责。

详细设计：[设置中心与价格校准设计](设置中心与价格校准设计.md)。

依据：[原设置设计](../devel/design/04-设置中心与价格校准交互.md)；[`SettingsView.swift`](../../apps/macos/Sources/BruceApp/SettingsView.swift)；[`OnboardingCoordinator.swift`](../../apps/macos/Sources/BruceApp/OnboardingCoordinator.swift) 的 `persistPricingOverrides()`；[`CollectorRunInput.swift`](../../apps/macos/Sources/BruceAppCore/CollectorRunInput.swift)。

<a id="refresh-snapshot"></a>
### 6.7 刷新、快照与恢复设计

**功能需求**：定时、手动、系统事件和重试等多种触发要合并去重后有序执行；离线、锁屏、限流时行为可控；启动展示与失败回退要有旧快照可用；凭据写回与快照发布的失败互不伪装成对方成功。

**设计目标**：
- 意图合并与并发门禁（满足：同模块重复触发合并，容量受控）；
- 分场景抑制（满足：离线暂停自动轮次，锁屏只抑制非手动新查询）；
- 旧值保留可回退（满足：当前与 previous 快照支撑启动展示和失败回退）；
- 失败语义独立（满足：凭据写回失败与快照发布失败不假定统一回滚）。

**方案机制**：调度器接收定时、手动、唤醒和退避意图，处理同模块合并、并发容量、授权与网络门禁；流水线负责一次执行的先后关系。当前流水线先读取上一份工件并形成额度策略，再装配输入、执行采集、按条件恢复与回填、应用凭据更新，最后发布快照。

离线时自动意图暂停，直接手动刷新仍可执行一次；恢复联网后按暂停标记或陈旧程度补偿。额度查询保留独立策略，但生产配置将其新鲜度周期与本地采集间隔联动；手动触发、窗口边界、服务新鲜度和限流冷却仍有不同优先级。当前与 previous 快照用于启动展示及失败回退，服务级陈旧状态与模块调度相位也分别维护。

锁屏暂停默认启用，但只作用于非手动的新轮次；不取消在途请求。解锁补偿受模块状态、自动刷新、60 秒去重及网络门禁约束。

**边界与非目标**：凭据写回失败和快照发布失败属于不同结果，不能假定二者具有统一回滚事务；解锁补偿不保证每次解锁都立即查额度。

详细设计：[刷新生命周期设计](刷新生命周期设计.md)。

依据：[`RefreshScheduler.swift`](../../apps/macos/Sources/BruceAppCore/RefreshScheduler.swift)；[`RefreshExecutionPipeline.swift`](../../apps/macos/Sources/BruceAppCore/RefreshExecutionPipeline.swift)；[`NetworkReachability.swift`](../../apps/macos/Sources/BruceAppCore/NetworkReachability.swift)；[`QuotaRefreshPolicy.swift`](../../apps/macos/Sources/BruceAppCore/QuotaRefreshPolicy.swift)；[`ArtifactStore.swift`](../../apps/macos/Sources/BruceAppCore/ArtifactStore.swift)。

<a id="windows"></a>
### 6.8 Windows 平台适配设计

**功能需求**：Windows 端要复用共享 Rust 采集逻辑，同时按自身托盘、窗口、IPC 和凭据规则运行，不照搬 macOS 全部行为；看板需要透明窗口、平滑曲线和 Nothing 主题形态。

**设计目标**：
- 共享协议、各自实现（满足：采集逻辑复用，调度、存储、界面分别维护）；
- 缓存即查询，不另启采集（满足：界面读取缓存 Panel）；
- 主题仅改展示（满足：不改变共享采集规则）。

**方案机制**：Windows 使用 Tauri 提供托盘、窗口、设置与 IPC，后台线程在进程内调用共享 Rust Bridge。`SnapshotState` 保存工件、阶段、诊断和最近成功时间；`get_dashboard` 读取缓存并映射 Panel，不因为界面查询另启一轮采集。

Windows 看板新增透明窗口配置和平滑曲线；Nothing 使用本地 Doto/Space 字体、纯黑几何底座、固定阈值图例及 PRJ.CONSOLE 项目形态。

**边界与非目标**：Windows 与 macOS 共享协议及部分视图模型语义，但凭据装配、调度、存储路径和界面实现分别维护；配置差异、错误恢复和真实系统交互必须按 Windows 来源解释，共享 crate 或 fixture 对拍不能证明双端的授权、窗口、快捷键与设备行为完全相同；主题只作用于展示；源码与原卡片目标的局部尺寸差异在平台详设中说明；设置页的新分析工作台另有自己的窗口和估算规则，见[工作台设计](#windows-workbench)。

详细设计：[Windows 应用设计](Windows应用设计.md)；状态细节见[Windows 快照与刷新状态](Windows快照与刷新状态.md)。

依据：[原 Windows 设计](../devel/design/05-Windows平台适配.md)；[`apps/win/src-tauri/src/lib.rs`](../../apps/win/src-tauri/src/lib.rs)；[`apps/win/src-tauri/src/runtime_core.rs`](../../apps/win/src-tauri/src/runtime_core.rs)；[`apps/win/viewmodel/src/lib.rs`](../../apps/win/viewmodel/src/lib.rs)。

<a id="widget"></a>
### 6.9 独立 Widget 设计

**功能需求**：Widget 是单文件浏览器界面，由外部宿主喂数并自行呈现用量与额度；它不能假定原生应用会自动推送数据，也不自己管理采集。

**设计目标**：
- 数据口径由供数方负责（满足：日期对齐、Agent 状态归宿主）；
- 展示与动画生命周期归 Widget（满足：缺数据时按现有状态规则处理）。

**方案机制**：Widget 通过宿主的数据、状态和主题事件更新。它读取 `data.main` 并维护自己的展示逻辑，缺少宿主数据时按现有状态规则处理。

**边界与非目标**：原生应用的构建清单没有把该文件当成自动供数界面，因此两条展示路径不能混为同一部署关系；Widget 的 Token 与额度展示依赖输入口径一致；动画、可见性与释放属于 Widget 的生命周期责任，宿主负责提供事件和口径一致的数据。

详细设计：[Widget 设计](Widget设计.md)。

依据：[`apps/widget/index.html`](../../apps/widget/index.html) 的 `render()`、`renderStatus()` 及宿主事件；[`scripts/runtime-manifest.zsh`](../../scripts/runtime-manifest.zsh) 的打包清单。

<a id="delivery"></a>
### 6.10 工程验证与交付设计

**功能需求**：改动需要一条标准本地验证入口，分层覆盖 Rust、Swift、fixture、Harness 和集成检查；平台打包要组装应用与 Collector，版本号统一；开发机目录状态不能被当作安装环境约定。

**设计目标**：
- 单一验证入口分层覆盖（满足：本地验证、CI、平台安装各担其责）；
- 版本与产物统一来源（满足：版本由根目录 `VERSION` 提供）；
- 环境隔离（满足：构建目录、用户运行数据、知识文档分别维护）。

**方案机制**：工程验证入口覆盖 Rust、Swift、fixture、Harness 和集成检查；平台打包脚本组装应用及 Collector，版本由根目录 `VERSION` 提供。tag CI、Preview 产物与手工签名公证路径各有责任。

**边界与非目标**：不能把开发机某次目录状态当成安装环境的约定；本地验证、CI 作业和平台安装验证覆盖不同责任；正式交付需分别核对作业结果、产物组成与平台验证记录。

详细设计：[构建、验证与发布](构建验证与发布.md)。

依据：[`scripts/verify-local.sh`](../../scripts/verify-local.sh)；[`scripts/runtime-manifest.zsh`](../../scripts/runtime-manifest.zsh)；[`scripts/build-test-app.sh`](../../scripts/build-test-app.sh)；[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)；[部署指南](../guide/01-本地部署指南.md)。

<a id="agent-analytics"></a>
### 6.11 Agent 用量分析与跨源归并设计

**功能需求**：用户要在设置页查看所选时间范围的 KPI、趋势、模型汇总和 Agent 下钻；分析只消费已解码工件，不替代 Collector 的原始统计；部分历史构成含估算，导出要保留各自数据范围。

**设计目标**：
- 派生而非重采（满足：消费 AppModel 已解码工件）；
- 模型归并保留来源身份（满足：归一模型键同时保留原渠道和 Agent 身份）；
- 估算口径显式声明（满足：部分 Token 构成、费用、轮次为估算）。

**方案机制**：分析工作台由设置页进入，消费 AppModel 已解码工件。ModelNormalizer 按所选范围选择今日模型、月模型或比例回退，再归一模型键并保留原渠道和 Agent 身份；内存派生结果分别供 KPI、趋势、模型卡和 Agent 卡使用。趋势使用小时、日或七项日期桶；模型系列按全范围份额分配；导出 CSV 为所选范围的模型汇总，JSON 为完整工件。

**边界与非目标**：部分 Token 构成、费用和轮次为估算；全部历史只覆盖当前工件范围；CSV 和 JSON 都不是 Bridge 凭据响应；状态、导出失败和原设计未接入项在详细设计中说明。

详细设计：[Agent 用量分析设计](Agent用量分析设计.md)。

依据：[`ModelNormalizer.swift`](../../apps/macos/Sources/BruceAppCore/ModelNormalizer.swift)；[`AnalyticsModels.swift`](../../apps/macos/Sources/BruceAppCore/AnalyticsModels.swift)；[`AgentUsageWorkbenchView.swift`](../../apps/macos/Sources/BruceApp/Settings/AgentUsageWorkbenchView.swift)；[原分析设计](../devel/design/06-Agent用量分析与Token统计工作台.md)。

<a id="windows-workbench"></a>
### 6.12 Windows 用量工作台设计

Windows 设置页通过 `get_usage_analytics` 读取缓存中的完整工件，由 Rust 分析器按所选时间范围计算 KPI、趋势、规范模型与 Agent 明细，再由前端绘制。切换范围会发起新的缓存计算，旧请求迟到时不能覆盖新的请求结果；这一步不发起采集。分析能力与 macOS 共享数据口径的对拍目标，但各端渲染和系统交互分别实现。

旧工件缺少明细时，模型、缓存或费用可能不可用；不能以缺失值推断零费用。CSV 导出范围内模型汇总，JSON 导出完整缓存工件；重新检查只提交后台刷新意图，不代表该轮已经完成。

<a id="shared-policy"></a>
### 6.13 跨端共享策略设计

共享策略负责额度查询门禁、旧服务回填、窗口边界唤醒和重试退避。Windows 进程内直接调用 Rust；macOS 使用只含纯数据的 JSON 经静态链接的 C ABI 进入同一策略核心。策略不读取凭据、不访问网络，也不发布工件；调度与持久化仍由宿主负责。

按 Provider 的新鲜度和 429 冷却可以跳过自动查询；手动刷新与窗口边界意图具有不同的绕过规则。跳过或失败后的旧值回填不等同本次查询成功。边界集合由宿主管理；调用失败时 macOS 对边界唤醒和退避分别采用原间隔或上限回退。

<a id="software-update"></a>
### 6.14 软件更新设计

设置中心提供自动及手动版本检查、跳过版本、下载和安装入口。发布清单为双端提供版本和平台资产；自动检查失败静默，手动检查失败可提示。macOS 校验清单、包体 SHA-256 与应用包后替换旧应用并尝试重启；Windows 通过 updater 插件验证签名并运行安装器。取消 Windows 下载只丢弃完成后的结果，不保证中止传输。

两端安装、失败恢复和信任校验不同；清单存在、构建通过或静态代码可见均不证明实际安装成功。发布环境的签名密钥与设备验收仍须单独核实。

<a id="chapter-7"></a>
## 7. 参考文献

<a id="source-references"></a>
### 7.1 原始设计与实现入口

- [系统总体设计](../devel/design/00-系统总体设计.md)：目标、边界与跨端交付约束。
- [采集设计](../devel/design/01-数据采集与多模型计费引擎.md)、[订阅设计](../devel/design/02-订阅额度与凭据安全存储.md)：数据生产和授权声明。
- [菜单栏设计](../devel/design/03-菜单栏状态与多风格原生渲染.md)、[设置设计](../devel/design/04-设置中心与价格校准交互.md)：交互与配置声明。
- [Windows 设计](../devel/design/05-Windows平台适配.md)、[分析工作台设计](../devel/design/06-Agent用量分析与Token统计工作台.md)：平台与分析需求。
- [`main.rs`](../../core/collector/bin/Bruce-collector/src/main.rs)、[`BruceApp.swift`](../../apps/macos/Sources/BruceApp/BruceApp.swift)、[`Windows lib.rs`](../../apps/win/src-tauri/src/lib.rs)、[`Widget`](../../apps/widget/index.html)：真实入口。

<a id="related-reading"></a>
### 7.2 相关文档

- [术语表](术语表.md)：领域名词与项目上下文。
- [刷新生命周期](刷新生命周期设计.md)：跨模块刷新、恢复与发布的主要解释。
- [构建验证与发布](构建验证与发布.md)：工具链、产物与平台验证边界。

最后更新：2026-10-30
