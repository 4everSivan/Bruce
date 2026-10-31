# Windows 应用设计

Windows 应用由 Tauri 托盘壳承载看板和独立设置窗口。宿主在进程内调用共享 Rust Collector，再将采集结果映射为前端展示模型。调度、快照、凭证存储和系统交互由 Windows 端自行实现，行为对齐以 macOS 的 Swift 视图模型为基准。

Windows 原生 WebView2、托盘气泡、系统热键、SID ACL 与真实 Agent 路径的验收范围，需结合目标环境证据判断。

## 目录

- [1. 目标与职责](#chapter-1)
- [2. 对外契约](#chapter-2)
  - [2.1 职责与接口](#windows-contract)
- [3. 内部结构](#chapter-3)
  - [3.1 配置与采集授权](#windows-config)
  - [3.2 共享包的依赖方向](#windows-dependencies)
- [4. 详细设计](#chapter-4)
  - [4.1 凭证存储与恢复](#windows-credentials)
  - [4.2 视图模型、告警与维护](#windows-mapping)
  - [4.3 Fluent 与 Nothing 呈现](#windows-theme)
  - [4.4 Agent 用量工作台](#windows-workbench)
- [5. 流程与状态](#chapter-5)
  - [5.1 启动、刷新与展示](#windows-startup)
- [6. 异常与恢复](#chapter-6)
  - [6.1 对齐范围与证据边界](#windows-limits)

<a id="chapter-1"></a>
## 1. 目标与职责

**功能需求**：Windows 壳要把共享 Collector 协议接入 Tauri，并承担本平台的窗口、IPC、凭证和调度。

**边界与非目标**：共享逻辑的验证范围与 Windows 系统交互验收分别判断，不能合并成一个验收结论。

<a id="chapter-2"></a>
## 2. 对外契约

<a id="windows-contract"></a>
### 2.1 职责与接口

**功能需求**：前端看板与设置页通过一组固定 IPC 向壳请求看板、设置、账号、凭据补丁、导出与窗口操作；壳读取内存快照返回面板，发布前按当前凭证裁剪服务，不在界面查询时另起采集。

**方案机制**：`main()` 仅调用 `bruce_win_lib::run()`。启用 `desktop` feature 后，`desktop::run()` 注册 Tauri 插件、加载持久快照、创建共享调度状态、注册热键与托盘菜单，最后启动采集线程。采集由启动后的调度循环显式发起，模块初始化本身不扫描会话。

| 组件 | 负责的行为 | 依赖与输出 |
|---|---|---|
| Tauri 壳 | 托盘、窗口、IPC、热键、配额气泡 | 维护 `SchedulerControl`，向前端发布事件 |
| `collector.rs` | 根据设置筛选能力与凭证，构造采集请求 | 进程内调用 `collector_bridge::run_bytes_panic_safe`，返回 `BridgeResponse` |
| `runtime_core.rs` | 快照验证、合并、持久化、面板组装与窗口策略 | 接收 artifact，调用纯 Rust 视图模型 |
| `credentials.rs` 与 `credentials/lifecycle.rs` | 应用自有凭证存储、轮换回写、Codex 恢复 | 以元数据向前端展示账号；凭证供采集与恢复使用 |
| `viewmodel` | 用量、逐小时、订阅与诊断的纯数据映射 | `PanelViewModelMapper::make` 产生 `PanelViewModel` |
| `app.js` 与 `settings.js` | 看板绘制、局部展开状态、表单与命令调用 | 消费 IPC 返回值及 `dashboard-updated`、`settings-updated` 事件 |

下列 IPC 是前端与后端的主要边界。表中的字段名保留前端调用形式；Rust 参数经过 Tauri 序列化。

| 命令 | 输入 | 返回或效果 |
|---|---|---|
| `get_dashboard` | 无 | `Result<Value, String>`；读取内存快照并组装面板，发布前按当前凭证裁剪服务，不执行采集 |
| `refresh_now` | 无 | 向容量为 `1` 的调度通道提交手动刷新请求 |
| `get_runtime_info` | 无 | 版本、数据与缓存目录、快照位置、运行状态、诊断、用量及模型汇总 |
| `get_settings` / `save_settings_command` | 保存时传入 `settings: AppSettings` | 加载设置；或校验、替换热键、持久化并发布设置变更 |
| `get_credential_accounts` | 无 | `field`、`accountId`、`displayName`、`authorizationState` 元数据 |
| `save_credential_account` / `remove_credential_account` | `field`、`accountId`，保存另传 `payload` | 修改单个账号，成功后请求刷新 |
| `save_credentials_command` | `payloads` 字段补丁 | 有值覆盖，`null` 删除，未提及的字段保留 |
| `import_codex_auth` | `auth` JSON | 从 `tokens.account_id` 及令牌字段导入应用自有存储 |
| `clear_snapshot_cache` | 无 | 删除磁盘快照并请求刷新；内存中的有效 artifact 不在此命令内清空 |
| `export_billing` / `export_diagnostics` | 可选 `path` | 返回导出文件的完整路径，失败返回错误 |
| `open_settings` / `hide_dashboard` / `quit_app` | 无 | 呈现设置、隐藏看板并记录位置、或 `app.exit(0)` |

**边界与非目标**：`get_dashboard` 不执行采集；`clear_snapshot_cache` 只删除磁盘快照并请求刷新，内存中的有效 artifact 不在此命令内清空。


<a id="chapter-3"></a>
## 3. 内部结构

<a id="windows-config"></a>
### 3.1 配置与采集授权

**功能需求**：Windows 端要在本机确定独立的数据根、设置、凭证与快照位置，并把用户的授权与开关翻译成采集请求的能力与凭证注入；配置缺失或损坏时回落到默认值，不让坏配置阻断启动。

**方案机制**：Windows 数据根优先取去除首尾空白后的 `%APPDATA%\Bruce`，缺失或空白时使用用户目录下的 `AppData\Roaming\Bruce`。非 Windows 开发运行使用 `Library/Application Support/Bruce-Windows-Dev`，与 macOS 原生应用的数据目录隔离。设置位于数据根的 `config/settings.json`，凭证位于 `credentials.json`，快照位于 `snapshot.json`。Collector 缓存根由共享 `collector_local::default_cache_root` 解析。

| 设置 JSON 字段 | 默认值 | 校验或生效方式 |
|---|---|---|
| `consentVersion` | `0` | 允许 `0`、`1`；仅 `1` 可向共享采集请求注入订阅凭证 |
| `usageEnabled` | `true` | 为假时移除 `localSessions` 能力，并隐藏面板的 `usage`、`hourly` |
| `enabledProviders` | `PROVIDERS` 的全部 `10` 项 | 保存时拒绝未知或重复项；控制凭证筛选与订阅展示 |
| `providerOrder` | 空数组 | 调整订阅段顺序；映射后再次排序 |
| `pricingOverrides` | 空对象 | 最多 `512` 个模型；支持价格、币种、备注字段，价格须为非负有限数值 |
| `refreshIntervalSecs` | `1800` | 保存范围为 `60` 至 `86400` 秒；加载时先钳制到此范围 |
| `notificationsEnabled` | `true` | 控制自动刷新时的配额通知投递 |
| `theme` | `fluent` | 仅允许 `fluent`、`nothing` |
| `cardOrder` | `usage`、`subscription`、`hourly` | 拒绝未知或重复卡片；前端补齐未列出的卡片 |
| `hotkey` | 空字符串 | 空值关闭热键；非空值由插件解析与注册 |

设置缺失或 JSON 损坏时回落默认值；缺少字段由 `serde(default)` 补齐，未知字段忽略。界面提供 `3`、`6` 分钟预设，也支持输入 `1` 至 `1440` 分钟的自定义值。确认授权立即写入 `consentVersion = 1` 和 `usageEnabled = true`，撤销立即写入 `0` 与 `false`，两种动作均调用保存命令并触发刷新。

采集侧分开判断这两个开关：`consentVersion == 1` 决定是否注入订阅凭证，`usageEnabled` 决定是否扫描本机会话。请求默认回看 `182` 天；本地扫描、外部请求与模块预算分别为 `120`、`30`、`150` 秒。价格覆盖通过请求上下文传入共享 Collector。

**边界与非目标**：默认 `consentVersion = 0` 并不关闭默认启用的本机会话扫描，不能把界面上的一次授权说明理解为采集侧对两类能力使用同一条件。设置页与 `PROVIDERS` 含 Cline，但当前凭证校验器没有 `clineQuotaAccounts` 的账号字段分支，`build_configured_request` 也没有 `cline` 的凭证映射。视图模型可以展示已有 Cline service，不代表 Windows 设置页的新增、保存与出站查询链路已完整接通。Jev 由订阅展示策略隐藏。


<a id="windows-dependencies"></a>
### 3.2 共享包的依赖方向

**功能需求**：视图模型要在不依赖 Tauri 的前提下把领域工件转成纯展示值，让壳、视图模型与 Bridge 的编译方向保持清晰。

![Windows 壳依赖视图模型和 Bridge，两者共享领域类型](../assets/km/windows-build-dependencies.svg)

图：四个第一方包之间的 Cargo 编译依赖，箭头从消费者指向提供方。图只展示这四个包的直接关系，不包含 Bridge 的应用层或第三方依赖，也不表示运行调用顺序。

**方案机制**：`bruce-win-viewmodel` 不依赖 Tauri，接收领域工件后生成纯展示值；Tauri 壳消费视图模型和 Bridge，并直接使用领域类型。

**边界与非目标**：共享输入类型不意味着两端前端会使用同一套分析算法。


<a id="chapter-4"></a>
## 4. 详细设计

<a id="windows-credentials"></a>
### 4.1 凭证存储与恢复

**功能需求**：应用要在本机安全保存自有账号凭证，回写时不覆盖已被人工改动的账号；首轮响应携带的凭证更新与 Codex 挑战在 Windows 自身凭据边界内恢复，失败结果留在响应诊断中。

**方案机制**：账号清单 IPC 只返回显式列出的元数据，已保存的密钥不会回传前端。单账号更新与完整字段补丁共用存储互斥锁，先在锁内读取最新文件，再修改与写回。账号映射须为对象；读取时拒绝链接或重解析点、超过 `4 MiB` 的文件及无效字段。

Windows 写入器取得进程令牌的当前 SID，为父目录和仍为空的临时文件设置受保护 DACL，再写入内容、同步文件并以 `MoveFileExW` 替换目标。非 Windows 开发分支采用目录 `0700`、文件 `0600`。

Windows 的恢复在自身凭据边界内完成，关系如下。

![首轮响应经账号比较和有限Codex重试，替换匹配服务](../assets/km/windows-credential-recovery.svg)

图：Windows 凭据恢复。账号删除或手动替换会阻止旧请求回写；失败诊断留在响应中。

调度器用 `collect_with_recovery` 消费共享响应中的凭证更新与挑战。当前回写支持 StepFun 令牌轮换；写回以请求前的账号值作比较。Codex 挑战按账号去重，每个账号至多尝试一次令牌刷新，成功账号合并为一次仅查询 Codex 的重试；该重试不重复本地会话和其他 Provider。`InvalidGrant` 把账号标为 `reauthRequired`。重试结果只替换首次 artifact 中匹配的 Codex 服务。

Codex 的 `refresh_token`、`id_token`、`expiry` 等恢复字段留在应用存储侧，注入共享 Bridge 时仅保留 `access_token`、`display_name`，并排除 `reauthRequired` 账号。设置页通过文件选择器读取用户指定的 JSON，再调用导入命令。

**边界与非目标**：收权失败会中止写入，并保留既有凭证文件。账号已删除或被人工替换时不覆盖新值；账号删除或手动替换会阻止旧请求回写，失败诊断留在响应中。重试结果保留本地用量与其他服务。后端导入函数不自行打开外部 CLI 文件。


<a id="windows-mapping"></a>
### 4.2 视图模型、告警与维护

**功能需求**：看板要把可选 artifact 映射成用量、订阅、逐小时与诊断四部分，并在输入缺失时给出空态；配额预警只在真正超阈值时投递一次；维护页导出账单 CSV 与限定字段的诊断 JSON，不泄露凭证。

**方案机制**：`PanelViewModelMapper::make` 接受可选 `AgentUsageArtifact` 和调用方注入的时间，输出用量、订阅、逐小时与诊断四部分。输出字段使用 camelCase；输入缺失时三张业务卡为 `None`，并产生 `MissingArtifact`。用量映射聚合今日 Token，取日期并集最后 `14` 天制作日柱，并形成月度、热力图与模型统计。订阅映射按 Provider 分组，保留窗口、余额、账号状态和过期数据的上次成功时间。

看板前端区分单账号、多账号和纯余额三种形态。多账号默认折叠，展开时显示账号子卡；纯余额型显示余额与状态双槽。当前展示使用余额字段。

配额预警仅识别 `5` 小时窗口并跳过 `freshness = stale` 的服务。已用比例大于 `50%`、大于 `80%`、大于或等于 `95%` 分别进入 50、80、95 档。去重键为 `serviceID|windowLabel`，仅向更高档跨越时投递，跌回 50% 以下后清除该键；手动刷新及其退避重试更新跨越状态但不投递，关闭预警也仍更新去重状态。自动刷新产生预警时，调度器展示锚定托盘的 `quota-alert` 窗口并发出 `quota-alert-bubble` 事件；它不是系统 Toast。

维护页可导出 UTF-8 BOM 的账单 CSV 和限定字段的诊断 JSON。诊断文件仅取版本、平台、模块阶段、最近成功、错误码与诊断码，不加入凭证、账号、完整本机路径或用量明细。设置页诊断预览另保留目录末段名。

**边界与非目标**：DeepSeek 月度消费账本已按 C020 移除；凭证存储中仍有写入 `deepseek-tracking-id` 的残留逻辑，不应据此推断月度账本仍在运行。前端优先打开系统保存对话框，取消时不导出；对话框不可用时回落数据根下的 `exports/`。


<a id="windows-theme"></a>
### 4.3 Fluent 与 Nothing 呈现

**功能需求**：看板与设置页在 fluent、nothing 两种主题间切换展示样式；主题只改外观，不改采集、凭据、告警或计费口径。

**方案机制**：`theme` 保存为 fluent 或 nothing。看板的 `applySettings` 应用 body 类后重绘已有面板，设置页则通过 `applyTheme` 切换同名类。Tauri 的 dashboard 配置新增 `transparent: true`；Fluent 面板使用 16px 圆角、阴影与半透明背景。

Nothing 使用 `#000000` 面板、10px 圆角、关闭背景模糊和阴影，卡片以 `#111111`、3px 圆角和细描边区分。字体通过本地 @font-face 注册 Doto、Space Grotesk、Space Mono 常规与粗体；文件位于 src/fonts。Hero 最终规则为 Doto 48px，并仍保留 radial-gradient 背景声明。含小数点的总量文本按第一个点拆分，以 `.dot-square` 替代该字符；LIVE 灯为 5×5px 实心方格。

订阅卡的 Nothing 分支追加固定三档图例：<50、50–79、≥80，颜色为 `#4A9E5C`、`#D4A843`、`#E44B47`。Agent 项目明细改为 PRJ.CONSOLE，保留名称、Token 与份额，每行六个刻度，亮格数为 `max(share>0 ? 1 : 0, min(6, round(share×6)))`。Fluent 继续使用原项目分布组件，展开状态仍由前端集合持有。

当前工作树还实现 Agent 和模型的品牌身份徽章：Windows 前端调用品牌徽章模块，用 Agent ID 或模型键选择图形与系列色；模块缺失时回退原色点。该内容来自尚未提交的源码，需在交付前重查其稳定性与实际资源。

**边界与非目标**：透明配置与圆角阴影是配置及 CSS 声明，不是 WebView2 合成效果的实机结论。当前 CSS 方块为 5×5px，不能把 C066 文字中的 4×4px 目标当成实际尺寸。图例本身不新增阈值判定。这些选择器和格式分支没有更改采集、凭据、告警或计费口径；工作台也有 Nothing 字体、颜色和几何覆写，但不能由样式推断其数据算法已与 macOS 等价。


<a id="windows-workbench"></a>
### 4.4 Agent 用量工作台

**功能需求**：设置页按所选时间范围展示分析快照，并支持模型与 Agent 展开、趋势维度切换及导出。

**方案机制**：设置页调用 `get_usage_analytics`，后端从缓存 artifact 生成范围快照，默认七天。Rust `viewmodel::analytics` 镜像 macOS 的 `WorkbenchAnalytics`：总量来自汇总桶，模型和费用来自范围明细，缺少明细时不以固定价格或模型份额估算。今日按小时、近 7/30 天与本月按日、全部历史按月展示。前端以序号丢弃过期异步结果；Agent、模型、Token 构成及费用可切换系列，CSV 导出范围内模型，JSON 导出完整缓存工件。

**边界与非目标**：全部历史仅覆盖工件已有历史；未定价桶不代表零费用，系统图表、文件对话框和交互效果仍需目标环境验证。


<a id="chapter-5"></a>
## 5. 流程与状态

<a id="windows-startup"></a>
### 5.1 启动、刷新与展示

**功能需求**：应用启动时预建看板与设置窗口，启动完成后直接呈现看板（用户双击启动本身就是一次显式唤出）；托盘与热键随时唤出看板并请求一次手动刷新；再次启动时唤出既有实例的看板而不是新起进程。前端只经 IPC 读缓存、经事件接收后台更新，不直接调用 Collector。

**方案机制**：Tauri 在启动时预建 `dashboard`、`settings`、`preview` 和 `quota-alert` 四个隐藏窗口。看板无装饰、启用透明通道、跳过任务栏并置顶；设置窗口为 `1000 × 680`，最小 `980 × 620`。`setup` 末尾经统一入口 `reveal_dashboard`（先 `record_shown` 再 `show`）呈现看板；`open_settings` 优先呈现已有窗口，窗口缺失时通过 `run_on_main_thread` 兜底创建。单实例由 `tauri-plugin-single-instance` 保证，第二次启动只唤出既有面板后退出。

托盘左键和全局热键切换看板。打开时根据显示器工作区、DPI 与托盘矩形重新计算位置和尺寸，然后请求一次手动刷新。看板失焦或关闭时隐藏，设置窗口失焦保持可见，关闭时隐藏。托盘点击对刚发生的看板失焦隐藏设置 `300 ms` 防抖，前端 `Escape` 调用 `hide_dashboard`。

后台线程不受看板可见性控制。它依次执行采集、凭证恢复、快照更新、预警判定与事件发布，再选择一次可被手动请求中断的等待。失败时保留合格旧数据并进入退避；手动请求可中断等待。`get_dashboard` 和前端刷新按钮均不直接调用 Collector。

前端缓存读取与后台采集通过不同通道协作，关系如下。

![Windows前端通过IPC读取缓存并通过事件接收后台更新](../assets/km/windows-ipc-flow.svg)

图：Windows IPC 与后台通道。读取面板不采集；手动意图经唯一后台循环执行，前端隐藏时保留待绘结果。

看板前端启动时先订阅事件，再取设置与缓存面板；设置页先并发加载设置、凭证、价格、运行信息、面板与更新信息，完成后注册面板事件监听。`dashboard-updated` 到达后重建卡片栈；页面隐藏时只保存待展示面板，恢复可见时补绘一次。退出菜单与 `quit_app` 调用 `app.exit(0)`。

**边界与非目标**：保存的 `panelX`、`panelY` 不作为下次唤出的定位依据。账号与 Agent 的展开状态存于前端集合，跨数据刷新保留，不落盘。采集线程的循环没有独立的退出消息分支。


<a id="chapter-6"></a>
## 6. 异常与恢复

<a id="windows-limits"></a>
### 6.1 对齐范围与证据边界

**边界与非目标**：设计基线选择共享采集引擎、独立 Windows UI 与 Rust 视图模型。液态玻璃、浅色外观和 Daimon Widget 不迁移；Windows 提供深色 Fluent 与 Nothing 风格。C012 记录的是当时九家 Provider 色板对齐的历史验证，当前代码已扩展 Cline 并调整 Z.ai 色值，应以当前品牌色表判断实际数值。

`mac_parity_golden_matches` 使用 `valid`、`partial`、`empty` 三个 artifact，按 f64 归一数值后比较 Rust 输出与 macOS golden。`runtime_coverage.rs`、`collector_configuration.rs` 及生产 HTML/JS 的控制 DOM/IPC 用例分别约束状态策略、请求门控与前端事件行为。这些测试代码规定固定输入下的预期，不等于当前执行结果，也不涵盖 Windows 系统集成验收。

C009 已归档且状态为 `closed`；其历史记录仍将当时的 Windows 真机 WebView2、窗口焦点、热键、系统 Toast、SID ACL 与真实 Agent 和凭证路径列为未知。后续预警改为托盘气泡；不能用旧 Toast 记录推断气泡已实测。发布判断需要分别检查当前自动化结果与目标环境证据。


最后更新：2026-10-30
