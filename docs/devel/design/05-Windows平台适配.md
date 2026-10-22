# Windows 平台适配设计方案

<!-- @topic: WindowsCompat -->
> **文档ID**: DESIGN-WINDOWS ｜ **状态**: 现行基线
> **最后更新**: 2026-10-21 ｜ **所属总体**: [00-系统总体设计.md](00-系统总体设计.md) ｜ **对应 Topic**: `WindowsCompat`
> 📌 **变更总账**: 参见 [变更总账 (WindowsCompat)](../change/index.json#WindowsCompat)

---

## 1. 简介 (Introduction)

本文档定义 Bruce 从 macOS 菜单栏应用向 **Windows 10/11 托盘常驻应用** 扩展的完整技术方案。Windows 版与 mac 版共享同一采集引擎（`core/collector`，Rust）与同一 artifact 数据契约，UI 层独立实现，行为一致性由双端 fixture 对拍测试锁定。

三项方向性决策已于 2026-10-06 由用户拍板：

| 决策点 | 结论 |
|---|---|
| UI 技术路线 | **Tauri 2**（Rust 后端 + WebView2 前端），collector 以 Rust lib 进程内嵌入，不经 stdio Bridge |
| 首版功能范围 | **首版全量**：本地会话扫描 + 订阅额度出站查询 + 配额通知 + 全局热键 + 设置中心 + Onboarding 凭证引导一次对齐 |
| Core 逻辑归属 | **Windows 侧 Rust 实现 + 双端 fixture 对拍**：`BruceAppCore` 的视图模型/调度逻辑在 Windows 侧以 Rust 重实现，与 mac Swift 端用同一组 artifact fixture 逐字段对拍 |

关键背景（2026-10-06 实测，基线 v0.9.0 / `0a7f2e2`）：当前代码库已完成大量跨平台铺垫，Rust 采集端的 Windows 化剩余改动**已收敛至 1 处硬编码路径**；主要工作量在 Windows UI 壳与视图模型层的全新实现（对齐 mac 侧约 31k 行 Swift 的能力矩阵）。

---

## 2. 目标与非目标 (Goals & Non-Goals)

### 2.1 目标 (Goals)
1. **单引擎双平台**：`core/collector` 保持唯一采集真理源，Windows 端进程内调用，artifact schema 与 mac 完全一致（`schemas/agent-usage-v1.json`）；
2. **托盘常驻形态**：Windows 托盘图标 + 点击弹出置顶看板面板，对齐 mac 菜单栏交互模型；
3. **首版全量功能矩阵**：会话扫描、订阅额度、配额 Toast 通知、全局热键、设置中心与价格校准、Onboarding 凭证引导全部交付；
4. **行为一致性可证明**：视图模型层双端 fixture 对拍，同一 artifact 输入下 mac Swift 输出与 Windows Rust 输出逐字段一致；
5. **双平台 CI**：`windows-latest` CI job 覆盖 Rust 全量测试，mac 侧现有 3 job 不回退。

### 2.2 非目标 (Non-Goals)
1. **液态玻璃不移植**：`NSGlassEffectView` / macOS 26 门控（`GlassTheme.swift` 等）为 mac 独占，Windows 恒走 Fluent/经典风格分支；
2. **浅色外观不移植（恒深色）**：Windows 看板与设置恒为深色观感，等价于 mac `Color.adaptive` 的 dark 侧 1:1 复刻（styles.css token 即按 dark 侧数值标注），mac 随系统深浅自适应的能力不镜像（C012 回写显式豁免）。真浅色主题如需立项，走功能设计入口另立 T 卡；
3. **Daimon Widget 不迁移**（`apps/widget/`）：Windows 无 Daimon 宿主；
4. **Linux 不承诺**：路径表天然大部分覆盖 Linux，但不做适配、不做验收；
5. **mac 侧不做架构重构**：Swift Core 保持 mac 事实源地位，Windows 适配严禁反向污染 mac 代码路径；
6. **不充当代理/网关**：延续 00 总体设计红线，仅旁路只读分析。

---

## 3. 需求分析 (Requirements)

### 3.1 Rust Collector 依赖面实测（基线 v0.9.0 / `0a7f2e2`）

> ⏱ **时间点存档**：下表是立项时的实测快照，`文件:行号` 与「结论」列均以该提交为准。此后文件增长会导致行号漂移（例如缓存根条目现位于 `collector-local/src/lib.rs` 的 `default_cache_root`），**请勿按现行树复核本表行号**；各项的实际落地状态见本节末「后续落地」与 §6.1。

| 模块 | 现状 | 结论 |
|---|---|---|
| 会话源路径表 | 已是独立跨平台模块 `collector-application/src/paths.rs`：opencode 含 `%LOCALAPPDATA%`/`%APPDATA%` 探测（:59-96）；kimi-work 含 3 组 Windows 候选（:107-175）；orca 含 `%APPDATA%` 分支（:178-193）；claude/codex/grok/pi/zcode/codebuddy 走 `~/.xxx` 布局（:25-52, :196-208），Windows 上天然解析为 `%USERPROFILE%\.xxx` | **已就绪**，待真机实测回填 |
| kimi-work / orca 源 | 路径探测按目录存在性自动空转，Windows 无对应应用时零输出 | **无需禁用决策** |
| 凭证读取 | `collector-credential/src/lib.rs:74-78`：`read_keychain` trait 默认 `Ok(None)`（Keychain 归属 Swift App 侧）；Claude CLI 走 注入→Keychain trait→文件回退 `~/.claude/.credentials.json`（:169-187），无 `/usr/bin/security` 子进程依赖 | **已就绪**，Windows 补一个 `CredentialSource` 实现即可 |
| 缓存文件身份与权限 | inode/dev 身份非 unix 回落 `(0, 0)`（`collector-local/src/sources.rs:361-370`、`lib.rs:324`）；0600 权限仅 `#[cfg(unix)]`（`lib.rs:829, 868`） | **已就绪** |
| 平台度量 | `collector-bridge/src/metrics.rs:9-32`：`physical_disk_read_bytes` 非 macOS 恒 `None` | **已就绪**，可选后续接 PDH |
| 纯逻辑 crates | `collector-runtime`（预算/取消原语）、`collector-aggregate`、`collector-domain`、`collector-provider`（ureq/rustls 出站）均无平台分支 | **已就绪** |
| **缓存根目录** | `collector-local/src/lib.rs:157-158`：`default_cache_root` 硬编码 `~/Library/Application Support/Bruce/collector-cache-v1` | **唯一硬编码残留**，Windows 需 `%LOCALAPPDATA%\Bruce\collector-cache-v1` |

**后续落地（C055 回填）**：上表结论列已成历史 —— 缓存根平台化（R1）已实施，`default_cache_root` 现按 `#[cfg(windows)]` 返回 `%LOCALAPPDATA%\Bruce\collector-cache-v1`；Windows CI job（R2）与 `verify-rust.sh`（R3）亦已落地。仅 R4（§3.4 真机实测）仍欠账。逐项状态见 §6.1。

### 3.2 Swift 侧规模（重写面）

| 模块 | 规模（2026-10-06 实测） | Windows 处置 |
|---|---|---|
| `BruceApp`（UI + 系统集成） | 30 文件 / 13,175 行；AppKit/Carbon/UserNotifications 集成面 13 文件（托盘 `MenuBarStatusItemController`、玻璃面板 `DashboardGlassPanelController`、热键 `GlobalHotkeyMonitor`/`Recorder`、通知 `QuotaAlertNotifier` 等） | 整体重写为 Tauri 前端 + Rust 系统集成 |
| `BruceAppCore`（视图模型/调度） | 34 文件 / 9,493 行；仅 `RefreshScheduler.swift:1` 一处 AppKit 导入（NSWorkspace 唤醒监听），其余纯 Foundation | **Rust 重实现 + fixture 对拍**（本设计 §6.2） |
| `BruceOnboardingCore`（凭证引导/门控） | 30 文件 / 8,248 行（含 Keychain 写入 `OnboardingConfiguration`） | Rust/前端重实现，凭证落盘改 Windows 等价方案（§4.3） |
| `BruceGlassSurfaceCore` | 1 文件 / 396 行 | 不移植（液态玻璃非目标） |

### 3.3 CI 与脚本

- `.github/workflows/ci.yml`：3 job 全 `macos-26`（:15, :29, :47），无 Windows 覆盖；
- `scripts/*.sh` 全部 zsh/bash 且假设 mac 工具链（codesign/plutil/swift run），Windows 需独立 PowerShell 产物线；
- `verify-local.sh` 中 Rust 平台无关部分（fmt/test/clippy + fixture 扫描）需抽取为双平台可复用入口。

### 3.4 Windows 真机待实测清单（P0 回填本表）

| 项 | 待确认内容 |
|---|---|
| Claude Code | `%USERPROFILE%\.claude\projects` 会话布局；CLI 凭证实际位置（预期 `~/.claude/.credentials.json` 或 Credential Manager） |
| Codex | `%USERPROFILE%\.codex\sessions` 布局 |
| Grok / Pi / ZCode / CodeBuddy | `~/.grok`、`~/.pi/agent/sessions`、`~/.zcode/cli/db/db.sqlite`、`~/.codebuddy/projects` 在 Windows 的真实布局 |
| OpenCode | `%LOCALAPPDATA%\opencode\opencode.db` vs `%APPDATA%` 实际落点（`paths.rs:59-96` 已覆盖双候选） |
| 增量缓存 | Windows 目录元数据在长驻写句柄未关闭时可能报告陈旧文件大小：实测各 Agent 会话文件的写入模式（追加即关 vs 长驻句柄），确认增量追加检测在真实采集节奏下可靠（CI 已见测试级复现，见 T01） |
| WebView2 | Windows 10 目标版本上 Evergreen Runtime 可用性 |
| 任务栏四方向停靠（C035） | Win10 真机把任务栏分别停靠左/右/上/下，核验：托盘左键弹出面板均贴任务栏内侧且沿轴对齐托盘、面板完整落在工作区内不越界；热键唤出（无托盘坐标）同样贴对应侧；任务栏自动隐藏时面板位置合理。几何已由 `tests/fixtures/geometry-parity` 与 Demo 四向截图锁定，真机只需核验系统 `work_area` 与 Tauri 上报值的一致性 |

---

## 4. 功能设计 (Functional Design)

### 4.1 系统集成能力映射

| 能力 | mac 实现 | Windows 实现 |
|---|---|---|
| 托盘常驻 | `NSStatusItem` + `NSPanel` | Tauri tray（`Shell_NotifyIcon`）+ 置顶无边框 WebView 面板 |
| 弹出看板 | `DashboardGlassPanelController`（NSGlassEffectView） | Tauri WebviewWindow（skip taskbar、失焦自动隐藏） |
| 液态玻璃 | `GlassTheme` macOS 26 门控 | **不移植**，恒走 Fluent/Mica 观感分支 |
| 全局热键 | Carbon `RegisterEventHotKey`（`GlobalHotkeyMonitor`） | Tauri global-shortcut 插件（`RegisterHotKey`） |
| 配额通知 | `UNUserNotificationCenter`（`QuotaAlertNotifier`） | Tauri notification 插件（Windows Toast） |
| 唤醒补采 | `NSWorkspace.didWake`（`RefreshScheduler.swift:174`） | 可选 `WM_POWERBROADCAST` 监听；首版可由退避调度兜底 |
| 自启 | mac 侧未实现 | 可选：Run 注册表键 / 启动文件夹（Tauri autostart 插件） |
| 凭证存储 | `OnboardingConfiguration` SecItemAdd → Keychain + `credentials.json` 0600 | `%APPDATA%\Bruce\credentials.json` + Windows ACL 限定当前用户（等价 0600），temp + rename 原子写 |
| 外部 CLI 凭证探测 | `kSecUseAuthenticationUISkip` 静默回退 | 文件读取 + 失败静默跳过原则照搬，禁止交互式弹窗 |

### 4.2 看板功能区（首版全量）

对齐 mac `MenuBarViews`/`Views/` 能力矩阵，WebView 前端实现：今日总量 Hero 卡、Agent 用量卡（模型用量区块、月卡联动、三档语义配色）、逐小时折线、热力图、订阅额度卡（10 Provider，含 StepFun 与 Cline）、Nothing 风格控制台主题（Windows 侧以 CSS/点阵等价实现，保真边界为简化 CSS 覆写而非完整 Nothing token 体系）。菜单栏圆环指示器由托盘图标渲染等价承载（刷新中/告警态图标切换）。Provider 品牌色板（徽章与余额胶囊圆点）以 mac `ProviderLogoBadge.brandColor` 为唯一事实源，双端逐家对齐（C012）。

**Provider 注册表四处事实源（增删 provider 必须同步，遗漏任一处即静默缺失）**：

| 事实源 | 位置 | 作用 |
|---|---|---|
| 设置页可见清单 | `apps/win/src-tauri/src/settings.rs` `PROVIDERS` | `enabledProviders` 默认值 + `validate_settings` 白名单；不在表内的 provider 会被 `runtime_core::panel_json` 的 `retain` 过滤掉（凭证可存但看板不显示） |
| 视图模型归一化与展示名 | `apps/win/viewmodel/src/subscription.rs` `PROVIDER_IDS` + `group_display_name` | service ID 前缀归一（如 `cline_<account>` → `cline`）与冻结展示名表 |
| 设置页表单清单 | `apps/win/src/settings.js` `providers` | 启用开关/顺序列表与添加账号下拉，显示名须等于 mac `SubscriptionProviderID.displayName` |
| 出站凭证注入表（C068） | `apps/win/src-tauri/src/collector.rs` `quota_credential_field` | provider → BridgeRequest 凭证字段（mac `ProviderRegistry` injectionKind 同表）；缺表即该家额度永不查询（C068 实测 Cline 曾因此在 Windows 从未被查询）。`scoped_refresh_coverage.rs` 断言它覆盖 `PROVIDERS` 全部条目且字段在 Bridge 白名单内 |

看板前端不另维护 provider 清单或 ID 前缀规则：`runtime_core::panel_json` 在映射完成后为已知 provider 的订阅 section 附加 `provider` 键（经 `provider_of_id` 单点归一，未知不附加），定向刷新按钮与品牌徽章只读该键；该键只在运行时层追加，不进入 mac 对拍的视图模型契约（C068）。

屏蔽规则：mac `SubscriptionPresentationPolicy.isProviderTemporarilyDisabled` 把 `jev`（官方未开放查额 API）整组丢弃，Windows 视图模型同样实现该分支，两处均**不产出诊断**。

**渲染层对标清单（C027）**：视图模型契约层由 `tests/fixtures/viewmodel-parity/*.panel.json`（mac `PanelParityHarness` 产出的 golden）逐字段对拍锁定；**契约之后的绘制为双端两套独立实现，必须按下列清单逐条对齐 mac**，且每条都应有 `apps/win/tests/frontend.test.mjs` 的真实 fixture 断言兜底（合成 section 会绕过真实结构，不可作为唯一防线）：

| 规则 | mac 语义 | Windows 渲染层 |
|---|---|---|
| 订阅段分支 | `accounts >= 2` 走多账号（默认折叠，折叠态渲染 `collapsedWindow` 单行，展开渲染账号子卡）；其余单账号段渲染 `windows`；`windows` 空且非多账号且 `balance` 非空为纯余额型，渲染「可用余额 / 订阅状态」双槽 | 同语义（`isMultiAccount` / `isBalanceBased`）；单账号段**不得**读取 `section.accounts`（Rust 对单账号同样下发单条 accounts，误读会重复渲染额度行） |
| `section.note` | 仅 `status ∈ {error, empty}` 渲染 | 同 |
| `account.note` | 仅 `account.status == "error"` 渲染 | 同 |
| `extraText` | 随头部行渲染（9pt secondary），不占正文、不用告警色 | 同 |
| 账号状态 | 卡内无 status→中文 标签行，仅经 note 与 `lastSuccessText` 呈现 | 同 |
| 余额胶囊 | 纯余额型抑制头部胶囊（改走双槽） | 同 |
| 收起态迷你摘要 | `collapsedPeakWindow` = `windows ∪ accounts[].windows` 中 `usedPercent` 最大者；纯余额型（无窗口）不出迷你条 | 渲染层按同语义推导（不改契约字段，避免 golden 漂移） |
| 折叠态可见性 | 折叠时 status 槽（`LIVE` / 最后更新时间）被 mini 摘要取代 | 同（C067 起标题行结构为 `[.drag-handle] [.card-title] [.card-status] [.collapsed-summary] [.chev]`：状态件经 `margin-left:auto` 推到行尾，折叠态隐藏 `.card-status`、迷你摘要嵌入标题行铺满中间区，而非另起一行） |
| Hero 数字渐变 | 按 `usageTier` 取五档色对（sage/moss/fern/pine/forest，`heroGradient` 基色 30% → 浅色 100%） | 同（不得写死单档；档位由契约字段 `usageTier` 下发）。**实现约束（C029）**：档位色必须以 CSS 自定义属性（`--hero-grad-start` / `--hero-grad-end`）下发，由 `.hero-num` / `.mini-num` 消费，**严禁用内联 style 直接写 background/前景** —— 内联 `background-image` 会压过 `.theme-nothing .hero-num` 的纯色覆写（C027 实测回归时该类尚带 4px 点阵遮罩，叠加成平铺条纹；C067 起 Nothing hero 改为 Doto 字体自身点阵 + 纯色 accent，不再叠加遮罩） |
| 模型/项目分布 | 渲染视图模型给出的全部行（Top3 + 「其他」聚合） | 同（前端不得再截断） |
| Nothing 主题覆写 | 新增任何卡片内组件时，除 Fluent 形态外必须同时给出 `.theme-nothing` 覆写（圆角 3 / `#1A1A1A` 底 / `#222222` 描边；阈值红 `#D71921` 只用于 ≥80 档，当月/选中等强调色一律取 hero accent `#4A9E5C`；C067 起 Nothing 块不再覆写 `--accent`） | 同（C029 起：账号子卡、余额双槽、tag 胶囊、成本数字均有 Nothing 覆写与断言） |
| Nothing 形态（C034/C066） | 订阅量条 = 24 段方角（高 10 / 段间 2 / 填充段数 = `round(clamp(fraction,0,1)×24)` / 阈值档纯色 `#4A9E5C`·`#D4A843`·`#D71921`）；14 日柱 = 3×8 点阵（6×6 格 / 段间 2 / 填充区自底向上增长 / 填充数 = `max(1, round(total/maxDayTotal×24))` / 格子自上而下编号、从第 `24 - filled` 格起按段序落槽，故首段在填充区顶部，非末段至少 1 格且末段吃剩余直至末格（mac `nothingCellSlots`，C067 校正段序）/ 退化时统一 accent 单色 / 日总量 hover 显示）；24 点走势线 = heroGreen `#30D158`（C067 校正，原 `#4A9E5C`）；agent 配色取 5 档绿阶（已知 agent 固定档位、未知 agent FNV-1a 落档）；**C066 深度对齐**：捆绑分发开源 OFL 许可官方 Doto / Space Grotesk / Space Mono 字体族（`apps/win/src/fonts/`），Hero 数字拆分 4×4px 实心小方块小数点并带呼吸微光晕；面板锁定 10px 紧凑圆角、`#000000` OLED 纯黑底座、无毛玻璃透明；卡内 LIVE 指示灯为 5×5px 纯色方块（顶部 Header 状态灯仍为圆点）；订阅卡底部渲染 `<50` / `50–79` / `≥80` 三档方块阈值图例；Agent 展开区渲染 P4 斜点阵堆叠条与 Dot-Leader 控制台（`PRJ.CONSOLE` + 6-Tick 进度块）。~~设置中心 T07 工作台全量 Nothing 纯黑单色化~~（C067 撤销：mac 设置窗口恒用 `SettingsDemoTokens` Fluent 平面 token，不随界面风格切换） | 同（Windows 恒深色，只实现 dark 侧色序）。 |

**Windows 侧验证纪律（C029，因维护者无 Windows 机器）**：

1. **真实内核渲染自检**：`apps/win/tests/dom.mjs` 是无 CSS 引擎的 DOM 桩，**不足以**验证渲染层。任何触及 `app.js` / `styles.css` / `*.html` 的改动，必须用 `apps/win/tests/render-harness/`（载入同字节产物 + 注入 `window.__TAURI__` mock）在真实浏览器内核里渲染核对（含两种主题、折叠态、满数据面板与设置窗口各分类），并确认无横向溢出与破图。该 harness 供人工/Agent 驱动，不作为 CI 门禁（CI 无浏览器依赖）。
2. **Windows 专有链路要有端到端用例**：provider 可见性/排序（`enabled_providers` retain + provider 归一化 + `provider_order`）这类只在 `runtime_core::panel_json` 才暴露的链路，回归用例必须打在该层，不能只覆盖视图模型分组。
3. **契约边界**：可在渲染层推导的展示态（如收起态峰值窗口）不进视图模型契约，避免触发 mac golden 快照重刷；确需改序列化字段时，先 `swift run --package-path apps/macos PanelParityHarness <repoRoot> --update` 刷新 golden 并同步 mac 侧。
4. **Demo 与实现必须可证明同构**（C035）：`apps/win/demo/win-taskbar-interaction-demo.html` 是人眼核验面板几何与任务栏交互的载体，其内联几何镜像（`// @geometry-parity:begin/end` 区段）与 `runtime_core::compute_dashboard_geometry` 由同一份 fixture（`tests/fixtures/geometry-parity/cases.json`）双向对拍（Rust `runtime_coverage.rs` + Node `apps/win/tests/geometry-parity.test.mjs`，后者随 `scripts/check-win-frontend.mjs` 进 CI）。**几何改动后必须重新生成 fixture**（见 `apps/win/src-tauri/examples/dump_geometry.rs` 头部命令），否则双侧测试红。

### 4.3 凭证与安全红线

- 订阅凭据统一落盘 `%APPDATA%\Bruce\credentials.json`，目录与文件 ACL 限定当前用户（等价 mac POSIX 0600 语义），temp + rename 原子替换；
- 外部应用 SQLite（opencode/zcode/cc-switch）强制 `mode=ro` 只读连接；
- **Claude 本机登录态跟随（C075）**：Windows 无 Keychain，Claude 凭据按 `%USERPROFILE%\.claude\.credentials.json` → `%USERPROFILE%\.claude.json` 只读跟随（对齐 mac `SystemExternalCredentialReader` 的读取序去掉 Keychain 段），规范化后注入 `claudeQuotaAccounts`；文件缺失/非 UTF-8/JSON 非法/无 `accessToken` 一律静默回落，**仅只读、不回写外部文件**，手工粘贴路径始终保留作多账号兜底；
- 严禁向 `core/collector` 引入任何 Windows 专有出站行为。

### 4.4 设置中心对标（C031）

六个分类与 mac 同名同序（通用 / Agent 用量 / 模型计费 / 订阅额度 / 授权与隐私 / 维护），窗口尺寸一致（1040×680，最小 980×620）。已对齐的语义（每项均有 `apps/win/tests/frontend.test.mjs` 断言 + 真实内核渲染自检）：

| 区域 | 规则 |
|---|---|
| 订阅额度行 | 每行 = 品牌图形徽章（26px，与看板同一套生成产物）+ 显示名 + 凭证形态副标题（`Web 令牌`/`API Key`/`OAuth 设备码`/`CLI 登录态`/`Step Plan Token`，多账号追加 `N 个账号`）+ 套餐标签（取自 artifact `service.plan`，C024 起只在设置页呈现）+ 状态尾件（`未配置`/`已配置`/`需要重新授权`）+ 行内启用开关 + 上移/下移 |
| Claude 本机登录态（C075） | 「Claude 本机登录态」卡：状态文案（已跟随 / 未发现 / 已过期，对齐 mac `ClaudeProviderSettingsSection`）+ `立即检测`（`claude_local_status`）+ `读取本机登录态`（`import_claude_from_local`，持久化为 `claude-cli` 账号）；启用 Claude 后自动只读跟随，粘贴入口保留作多账号兜底（见规则 17） |
| 授权与隐私 | mac 语义：单一 `Agent 用量` 开关 + 四条动态说明（含刷新间隔与已启用 provider 名单）+ `当前授权有效` 状态 + `确认授权` / `撤销全部授权` 两个**即时生效**按钮（不走全局保存）；采集与云端额度查询同属一次授权 |
| 通用 | 首卡行序对齐 mac：界面风格（经典 / Nothing）→ 刷新间隔（5/15/30/60 分钟；历史遗留的非集合值追加为选项，禁止静默改写）→ 系统通知 → 版本（来自 `get_runtime_info.version`）；界面风格与刷新间隔为 mac `FluentSegmentedPicker` 等价分段按钮（隐藏的原生 `<select>` 仍是值载体）；热键独立为「全局快捷键」分组卡（`录制`/`清除`）（C067） |
| 窗口观感（C067） | 设置窗口恒用 Fluent 平面 token（mac `SettingsDemoTokens` dark 侧），界面风格只作用于看板，**设置窗口不得套用 `.theme-nothing`**；侧栏 216 宽、项 12.5pt / 内边距 10·7 / 圆角 5、选中左缘 3pt accent 条，底部为版本号（无 Windows 自创标题）；内容区内边距 24·18，crumb · 标题 · 内容间距 14；分组标题（11pt 半粗 tertiary）位于卡片上方而非卡内；行标题 13pt 常规；按钮 12pt / 12·5 / 圆角 5，主按钮 `#4C9CFF`。设置即时生效、无全局保存栏（C069，见规则 15） |
| 维护 | `清理用量缓存`（后端 `clear_snapshot_cache`：仅删快照文件，不动配置/凭证，幂等）+ `诊断预览`（客户端拼装**脱敏** JSON：版本、模块阶段、诊断码、目录**末段名**，不含路径分隔符/凭证/账号/业务数据） |
| 品牌图形产物 | `apps/win/src/provider-brand.js` 为生成产物第三目标（与 Swift 数据、app.js 内联块同源），由 `scripts/gen-provider-glyphs.mjs --check` 锁定；设置窗口须在 `settings.js` 之前加载它 |

**后续落地（C055 回填）**：原「尚未对齐」清单已全部落地，不再留待后续卡 —— 模型计费页（今日费用总览 / 搜索 / 三态筛选 / 8 列表格 / 逐模型校准 / `settings.json` 预览，见 `pane-modelPricing-content`）与导出类能力（导出账单 CSV、导出诊断包）均已实现，导出优先调用系统文件保存对话框（`tauri-plugin-dialog` 已纳入 `desktop` feature），插件不可用时回落 `%APPDATA%\Bruce\exports\` 并回显完整路径；相应行为由 `frontend.test.mjs` 的 `model pricing pane` / `exports use the native save dialog` / `maintenance pane` 等用例守护。

**DOM id 唯一性（C031 实测）**：同页重复 id 会让 `getElementById` 命中较早元素并把结果写错位置（实测：诊断预览内容被写进同名按钮标签，预览框保持空）。两页的 id 唯一性已由 `frontend.test.mjs` 逐页遍历断言守护。

---

## 5. 总体设计 (High-Level Architecture)

### 5.1 仓库拓扑

```text
apps/
├── macos/          # 现有 SwiftUI 应用（mac 事实源，不动）
├── widget/         # Daimon 小组件（不迁移）
└── win/           # 新增 Tauri 2 应用
    ├── src-tauri/  # Rust 后端
    │   └── src/    # collector/scheduler/runtime_core/settings/credentials/ledger
    ├── viewmodel/  # 独立纯 Rust 视图模型层（§6.2）
    ├── tests/      # 生产 HTML/JS + 控制 DOM/IPC 的行为回归
    └── src/        # JS + HTML/CSS 看板前端
core/collector/     # 共享采集引擎（唯一真理源）
```

### 5.2 数据流

```text
Windows Tauri 后端 (Rust)
  → collector-application (进程内调度, RuntimeLimits/取消原语复用)
  → collector-local / collector-provider (本地扫描 + 出站额度)
  → artifact (agent-usage-v1, 与 mac 同 schema)
  → viewmodel 层 (Rust, artifact → 看板视图模型)
  → Tauri IPC → WebView 前端渲染
```

与 mac 的唯一结构差异：mac 经 stdio Bridge 拉起 `Bruce-collector` 子进程，Windows 端进程内直调（免子进程，`bin/Bruce-collector` CLI 仍保留用于 P1 阶段独立验收）。

### 5.3 一致性保障机制（对拍）

- mac `BruceAppCore` 与 Windows Rust `viewmodel` 消费**同一组 artifact fixture**（`tests/fixtures/` 既有资产）；
- 对拍协议（golden 快照模式，已落地）：mac 侧 `PanelParityHarness` 将 Swift 视图模型序列化为与 Rust serde 同构的 camelCase JSON，`--update` 刷新 golden 快照（`tests/fixtures/viewmodel-parity/`），默认模式比对；Windows 侧 `mac_parity_golden_matches` 测试消费同一快照，数值按 f64 归一后逐字段断言；
- 双向门禁：mac 端行为变更 → `--update` 刷新 golden 并审视 Windows 侧同步；Windows 侧漂移 → Rust 测试直接红。verify-local.sh 与 verify-windows CI 双侧执行；
- C009 对拍覆盖 valid、partial、empty 三个共享 artifact；这些固定输入仅证明映射结果一致，不证明 Windows 原生运行或全部凭据恢复场景。
- 已知实现约束：serde_json 需开启 `float_roundtrip`（mac JSONEncoder 输出 17 位浮点表示）；数值并列排序以稳定键序破并列，对拍 fixture 避免构造并列场景。

---

## 6. 详细设计 (Detailed Technical Design)

### 6.0 核心业务规则 (Core Rules)
<!-- @topic: WindowsCompat -->

#### 变更演进索引
| 变更编号 | 类型 | 简介 | 规则演进 |
|---|---|---|---|
| C007 | 缺陷修复 | 面板隐藏暂停采集偏离 mac 常驻语义，告警随面板关闭停摆 | 采集周期不随面板可见性门控（对齐 mac 通知常驻采集）；隐藏态开销控制仅作用于渲染层；设置加载侧钳制刷新间隔区间 |
| C009 | 缺陷修复 | 仪表盘、设置与运行生命周期对齐 | 缓存只读 IPC、单通道合并刷新、显式状态与旧快照、凭据安全与轮换恢复、配置门控及真实前端行为回归 |
| C014 | 界面对齐 | 仪表盘物理移除内嵌 Tab，设置窗口重构为 Fluent 侧栏导航 | 仪表盘 1:1 对齐 macOS MenuBarDashboardView（纯净卡片栈 + 顶底栏，彻底删除 `<nav id="tabs">` 与内嵌容器，设置仅由底栏齿轮与托盘呼出）；设置窗口 1:1 对齐 macOS SettingsView / demo L2 方案（WinUI NavigationView 侧栏 6 大分类导航） |
| C015 | 缺陷修复 | 修复设置窗口打开白屏缺陷并恢复静态预建生命周期 | 设置窗口在 tauri.conf.json 静态预声明，消灭 STA 跨线程死锁；主看板剥离探针诊断噪音并对齐 Esc 快捷收起与托盘防抖 |
| C016 | 缺陷修复 | 修复任务栏弹出位置偏离与多分辨率/DPI 仪表盘尺寸溢出 | 移除 panel_x/y 历史坐标死锁，托盘点击基于 monitor.work_area 与托盘 Rect 动态挂靠；根据可用高度动态自适应窗口高度，CSS flex 修复 min-height: 0 截断，底栏常驻可见 |
| C070 | 缺陷修复 | Agent 用量工作台真实数据 | 移除 ×¥15.2 / ×¥16.5 / 写死 21.0% 与前端模型别名; 工作台数值由 viewmodel `analytics` (mac `WorkbenchAnalytics` 逐条镜像, golden 对拍) 计算, 经 `get_usage_analytics` 下发, 前端只做呈现; 卡片按 mac 重做（见规则 16） |
| C069 | 缺陷修复 | 设置窗口即时生效 | 移除全局「保存设置」, 每个控件变更串行合并保存、失败回滚; 仅采集输入变化才触发全量采集（见规则 15） |
| C068 | 缺陷修复 | 订阅卡 Provider 定向刷新与 Cline 凭证注入 | 新增 `refresh_subscription` 定向刷新 (只查目标 Provider 额度、合并回快照、与全量串行); 补齐漏表的 Cline 凭证注入; 运行时层为 section 附 `provider` 键（见规则 14） |
| C067 | 缺陷修复 | 看板与设置窗口按 mac 源码逐项对齐 | 以 mac SwiftUI 卡片离屏渲染与 Windows 真实内核渲染并排比对定位偏差：修复无效 `font: … inherit` 简写、14 日柱零高、热力图例无色、标题行状态件与迷你摘要位置；Rust `token_count` 补 B 档；Nothing 字体行高取自身度量、描边改 overlay 等价；设置窗口不再套用 Nothing（见规则 13） |
| C075 | 缺陷修复 | Claude 凭据零配置跟随本机 CLI 登录态 | 新增本机登录态只读探测（`%USERPROFILE%\.claude\.credentials.json` → `.claude.json`），采集前自动注入 `claude-cli` 账号；设置页新增「读取本机登录态」入口与状态文案（见规则 17） |
| C076 | 缺陷修复 | 刷新调度接入网络可达性闸门 | 自动刷新前置可达性探测，离线不发起/不重试、联网后单次补偿；手动刷新语义不变（见规则 18） |
| C077 | 缺陷修复 | 订阅额度 per-provider 门禁与 429 冷却 | 按 `quotaAttemptedAt` 新鲜度 + `rateLimitedAt` 30 分钟 partial 冷却独立门控各 provider；跳过者回填旧值，手动刷新绕过冷却（见规则 19） |
| 暂无增量变更 | - | 初始基线定稿 | Windows 适配初始设计（Tauri 2 / 首版全量 / Rust 视图模型+对拍） |

#### 现行设计规则
1. **领域模型与数据结构**：视图模型层输入输出均为纯数据结构，序列化即对拍协议；
2. **核心算法与处理流程**：调度/合并/告警判定为纯函数，与 mac `BruceAppCore` 逐模块对齐；
3. **边界与约束**：所有外部探测（凭证/路径/出站额度）失败一律静默降级，禁止交互式 UI 阻塞；
4. **调度纪律**（C007）：采集周期不随面板可见性门控（对齐 mac `RefreshScheduler` 常驻语义，配额告警依赖后台周期采集）；面板打开即时手动刷新，隐藏态开销控制由前端渲染层自然暂停承载；刷新间隔在设置加载侧钳制到 `[60, 86400]` 秒。**窗口边界唤醒（C037，双端同构）**：定时唤醒不得跨过未来的额度窗口重置时刻 —— 下次唤醒 = min(间隔剩余, 最近未来 `services[].windows[].resetsAt` + slack 20s)，只在采集成功时参与调度；防风暴三道防线（只认未来边界 / 同一边界单次消费 / 未命中回落间隔）见 design/02 规则 9。

5. **刷新与发布**（C009）：`get_dashboard` 只读最近快照；所有采集经单一调度器执行。手动请求合并，失败后等待退避而不叠加正常周期；手动刷新不弹额度预警。失败和坏 artifact 保留上一有效快照，过期服务必须明确 stale，不得伪装成功。
6. **凭据生命周期**（C009）：落盘前保证目录/临时文件仅当前 SID 可访问，收权失败拒绝写入；轮换结果先安全持久化再发布，Codex accessRejected 仅允许一次刷新令牌恢复和一次重试，失败保留诊断；开发版使用隔离目录，不覆盖 mac 凭据。
7. **配置闭环**（C009）：主题、卡片顺序、价格覆盖、Provider 启用/排序与出站同意必须消费到渲染/采集；账户与 stale/extra 信息必须可见。热键保存失败不能宣称成功；设置窗口失焦不隐藏、关闭后可重开。
8. **证据边界**（C009）：真实 JS 渲染/事件回归、Rust 纯逻辑测试和 mac fixture 对拍不能替代 Win10/11 WebView2、系统热键、Toast 与 SID ACL 的真机验收。C009 与 T02/T03 在人工确认前保持 in_progress。
9. **界面与窗口形态对齐**（C014）：主面板（HUD 面板）恒为纯净看板，严禁在主面板内以 Tab 或折叠方式内嵌设置/凭证表单；主面板只加载 `app.js`，不挂载 `settings.js`；设置窗口恒为独立窗口（1040×680），内部采用 Fluent L2 侧边栏结构导航 6 大分类面板（通用、Agent 用量、模型计费、订阅额度、授权与隐私、维护），右侧展示面包屑与 FluentCard 卡片组，彻底解耦主面板与配置中心。
10. **设置窗口生命周期底线**（C015）：设置窗口必须在 `tauri.conf.json` 的 `windows` 列表中显式预声明（`visible: false`），由 Tauri 在启动阶段的 STA 主线程完成 WebView2 初始化并隐藏预备。严禁在 Tauri IPC 工作线程中通过 `WebviewWindowBuilder::build()` 动态懒建（在 Win32 下会因跨线程 COM STA 调度死锁/失败而出现全白屏无内容），呼出命令优先呈现既有窗口，关闭操作拦截并置为隐藏。
11. **诊断与探针归属边界与托盘交互**（C015）：主看板（HUD 面板）仅保留严重服务级故障（如需重新授权）；所有 Agent 探针元数据（包括'未发现会话记录'、未安装等）一律收归独立设置中心的「Agent 用量 -> 会话来源」，严禁在主看板上展示。看板贴靠任务栏所在边的内侧（四方向自适应见规则 12），支持 300ms 失去焦点防抖（杜绝托盘反弹）及 `Escape` 键即时收起，体验 1:1 对齐 macOS 菜单栏。
12. **任务栏四方向自适应定位与多分辨率自适应高度**（C016，四边统一模型由 C035 落地）：主面板必须彻底杜绝历史坐标死锁，每次唤出时以系统真实 `monitor.work_area()` 与托盘 `rect` 重新求解几何。定位为统一的四边模型 ——
    - **判边**：由工作区相对显示器四边的内缩量定位任务栏所在边，托盘 `rect` 落于哪条候选条带内即判该边（第三方 appbar/dock 与真任务栏共存时唯一可靠的消歧信号）；四边均无内缩（任务栏自动隐藏）时按托盘贴边方向推断，仍无结论则按 Windows 默认停靠顺序（底 > 右 > 上 > 左）兜底；
    - **贴边**：面板恒贴任务栏内侧（水平 12 / 垂直 10 逻辑px），完整落在工作区内，与任务栏条带永不相交；
    - **对齐**：沿任务栏轴向居中于托盘图标；托盘坐标缺失或与判定出的任务栏边不一致（陈旧 rect）时丢弃并贴托盘所在角落兜底；
    - 窗口高度按可用工作区高度动态自适应（逻辑高度上限 760px），前端 `#scroll` 必须使用 `flex: 1 1 0; min-height: 0;` 配合半透明 4px 细滚动条，底栏 `#footer` 绝对锁定 `flex: 0 0 auto`，确保在 1080p 150%、1366x768 等任意笔记本分辨率下，窗口永不出界、底栏设置与退出按钮永久完整可见。
13. **渲染层以 mac 源码为唯一数值来源**（C067）：看板与设置窗口的尺寸、字号、字重、颜色、圆角一律取自 mac `MenuBarViews.swift` / `Views/*.swift` / `SettingsView.swift` / `FluentSettingsChrome.swift` 及 `GlassSurfacePlan` token（Fluent = mac classic 分支 dark 侧，Nothing = isNothing 分支 dark 侧），不得自创形态。落地约束：
    - **字体与行高**：系统字体行高固定 1.2（Segoe / 雅黑自身度量高于 SF，`normal` 会把每行撑高约 20%）；Nothing 字体（Doto / Space Grotesk / Space Mono）双端为同一字体文件，行高一律 `normal`（取字体自身度量，与 SwiftUI 一致）。mac 只在显式指定的元素上换 Nothing 字体，Windows 不得在容器级改 `font-family`；
    - **描边**：mac 描边为 overlay `strokeBorder`（不增加尺寸），CSS `border` 会把盒子撑大 2px —— 带边框组件的 padding 必须扣除边框宽度，或改用 `box-shadow: inset 0 0 0 1px`；
    - **CSS 简写**：`font` 简写中不得混写 `inherit`（整条声明会被丢弃），由 `frontend.test.mjs` 断言锁定；
    - **折线**：看板走势线为 mac `LineMark` 默认线性插值（只有设置页时序图用 catmullRom），不得平滑；
    - **不再保留差异**：C067 首轮暂留的三项均已消除 —— 热力图不设列宽上限（与 mac 同样列等宽撑满整卡，数据仅数周时格子随之变大）；订阅段定向刷新按钮由 C068 补齐（规则 14）；设置窗口由 C069 改为即时生效（规则 15）。今后若确需偏离 mac，须在本规则内逐条登记原因；
    - **核验方法**：改动渲染层后，除 render-harness 自检外，可用 mac 卡片视图的 `ImageRenderer` 离屏渲染与 harness 截图在同一 artifact 上并排比对（C067 做法，脚本留存于 `local/win-mac-parity/`，不入库）。
14. **订阅 Provider 定向刷新**（C068，mac `RefreshScheduler.refreshSubscription` 同契约）：
    - **入口**：Tauri 命令 `refresh_subscription(section_id)`；后端经 `provider_of_id` 归一并校验——未知 provider、未授权（`consentVersion != 1`）、未启用、全量刷新进行中、同一 provider 已在刷新，一律拒绝（fail-closed），不启动采集；
    - **请求**：`collector::build_scoped_request` 只装配目标 provider 的凭证（Claude/Grok 同步装配 OAuth 与 `providerMeta`），capabilities 仅 `externalQuotas`，标记 `subscriptionQuotaOnly` / `subscriptionProviders`，不带 `days` / `pricingOverrides`——定向刷新不重扫本机会话、不重算成本；Codex 目标沿用一次刷新令牌恢复 + 一次 retry；
    - **合并**：`merge_scoped_snapshot`（mac `ScopedQuotaSnapshotMerger` 同语义）保留上一份快照的 agents / totalCostUsd 与非目标 provider 的 services；目标只取本轮返回（已断开账号不复活），成功 fresh、失败借合格旧窗口 stale、无历史 unavailable。全局 phase / lastSuccessAt / 诊断码沿用最近一次全量采集（定向刷新不代表本机会话已更新）；Bridge 整体失败只把目标降级 stale；
    - **并发**：`SchedulerControl.collection` 互斥锁令全量周期与定向刷新串行，快照写入不交错；进行中的 provider 集合经 `panel.runtime.refreshingProviders` 下发，`panel.runtime.quotaRefreshAllowed` 下发授权态；
    - **呈现**：订阅 section 头部行尾 `arrow.clockwise` 按钮（14×14，secondary）；目标刷新中为进度环并禁用（「正在刷新 X 订阅额度」），全量刷新中 / 未授权 / 未启用禁用（45% 透明）；与多账号展开开关为兄弟控件；被后端拒绝时在状态行给出可读提示，不把整体运行态标为失败；定向刷新属手动操作，不投递配额预警。
15. **设置窗口即时生效**（C069，mac `SettingsView` 同语义）：无全局「保存设置」；每个控件变更即保存——`settings.js` `persist(patch)` 串行排队，每次基于后端最新设置合并本次改动再保存，连续操作不互相覆盖；保存失败（价格覆盖非法、热键被占用等）回滚该控件，并在内容区顶部状态行以告警色提示原因，成功不打扰。后端 `settings::requires_collection` 门控：只有授权、本机会话开关、启用的 provider 集合、价格覆盖或刷新间隔变化才请求全量采集（刷新间隔即「变更后立即重新计时」），主题 / 卡片与 provider 顺序 / 通知 / 热键 / 面板位置只重新发布看板，避免即时保存引发采集风暴。授权页「Agent 用量」开关切换即等价确认 / 撤销授权。
16. **设置页 Agent 用量工作台**（C070，mac `AgentUsageWorkbenchView` 同契约，计算口径见 design 06 §4.2）：
    - **数据**：Tauri 命令 `get_usage_analytics(range)`（`today` / `7d` / `30d` / `month` / `all`）返回 `bruce_win_viewmodel::analytics::make` 的快照；与看板共用「本机会话」开关与快照，关闭或无快照时为空快照。**前端不得做任何汇总、换算或估算**（含模型名归一），只渲染快照字段；
    - **对拍**：`apps/win/viewmodel/tests/analytics_parity.rs` 对 mac `PanelParityHarness` 产出的 `*.analytics.json` 逐字段（含浮点位）比对；前端测试与 render-harness 直接渲染同一 golden；
    - **呈现**：分段时间范围（默认近 7 天）+ 导出 CSV 账单 / JSON 明细（系统保存对话框，默认文件名同 mac）→ 4 格 KPI → 时序（折线 / 面积 × Agent / 模型 / Token 构成 / 费用，分带 x 轴、≤14 点画点、悬停选点）→ 模型分布（合并 / 原始渠道，多渠道可展开）→ Agent 表现（构成比例条，今日范围才有工程分布，展开状态跨范围保留）→ Token 构成四象限与今日 24 小时密度；其下为「会话来源与采集探针」及 Windows 独有的「Agent 会话采集」开关卡；
    - **悬停文案**：`token_count` 的 JS 镜像对恰为平局的二进制值取偶（JS `toFixed` 平局进位，Rust / C 取偶），与 mac 逐字符一致。
17. **Claude 本机登录态零配置跟随**（C075，mac `SystemExternalCredentialReader` + `ClaudePasteParser` 同语义）：
    - **读取序**：`%USERPROFILE%\.claude\.credentials.json` → `%USERPROFILE%\.claude.json`（mac 读取序去掉 Keychain 段，Windows 无 Keychain）；命中即返回原文，非 UTF-8 视为不可读并继续回退；
    - **规范化**：接受包装键 `claudeAiOauth` / `claude.ai_oauth`、OAuth 条目本体或纯 token（`token [refreshToken]`），输出 `{"claudeAiOauth":{…}}`；无 `accessToken` 视为无登录态；
    - **注入**：采集前（全量与定向刷新同路径）经 `credentials::with_local_claude` 注入 `claudeQuotaAccounts["claude-cli"]`，**不落盘**；用户已存自有账号时手工配置优先，已存 `claude-cli` 时仅当本机 `expiresAt` 更大才替换；
    - **设置页**：新增「Claude 本机登录态」卡（`claude_local_status` / `import_claude_from_local` 两个命令），状态文案为已跟随 / 未发现 / 已过期（对齐 mac `ClaudeProviderSettingsSection`）；「读取本机登录态」把本机登录态显式持久化为 `claude-cli` 账号，粘贴入口保留作多账号兜底；
    - **红线**：仅只读，绝不回写外部文件；文件缺失/非法一律静默回落，不报错、不弹窗。
18. **网络可达性闸门**（C076，mac `NetworkReachability` + `RefreshScheduler.offlinePaused` 同语义）：
    - **探测**：`reachability::SystemNetworkProbe` 在 Windows 走 `InternetGetConnectedState`（返回 0 判离线），其它平台恒在线（fail-open，不误挡 mac 开发/CI）；探针以 `NetworkProbe` trait 注入，与调度逻辑解耦；
    - **闸门**：`ReachabilityGate` 初始视为在线（首个真实观测前 fail-open）；离线时跳过本轮自动刷新，**不累加 retries、不进入退避**，只按 30s 固定周期重探（`OFFLINE_PROBE_INTERVAL_SECS`），并把快照标为 `NETWORK_UNAVAILABLE`；
    - **补偿**：离线→在线跃迁给出 `Compensate`，本轮刷新即离线期间唯一一次补偿（不补发积压的多轮）；持续在线为 `Online`，语义与既有退避/边界唤醒不变；
    - **手动不变**：`should_skip_refresh` 只在「离线且非手动」时跳过 —— 手动刷新（含定向刷新）离线仍执行一次，不重试。
19. **订阅额度 per-provider 门禁与 429 冷却**（C077，mac `QuotaRefreshPolicy` + `QuotaCarryOverMerger` 同语义）：
    - **新鲜度门禁**：`quota_policy::plan` 逐 provider 判定 —— `quotaAttemptedAt`（回退 `capturedAt`，失败回退 `rateLimitedAt`）距今不足刷新间隔则跳过（多账号需全部新鲜才跳过）；无历史 service 的 provider 必须首查；上次快照后有窗口 `resetsAt` 已过则强制重查（C037 兼容）；
    - **429 冷却**：service 带 `rateLimitedAt` 且距今不足 30 分钟（`RATE_LIMIT_COOLDOWN_SECS`）时该 provider 进入冷却（partial，仅该 provider；其余照常查询）；命中判定用 service `note` 的限流文案（429 / 限流 / RATE_LIMIT）；
    - **Codex 例外**：Codex 永不因新鲜度或冷却进入 `skip_providers`（四源合并/重试链路需要完整首轮结果）；全部 provider 仍新鲜时整轮退化为本地专用 run 并回填全部旧 service；
    - **记账与回填**：本轮真实查询过的 service 写 `quotaAttemptedAt`，命中限流写 `rateLimitedAt`、成功则清除（跨重启保留节流状态）；被跳过的 provider 用上一份 service 原样回填，冷却/失败/过期标 `stale`，不丢旧值也不误标 `fresh`；
    - **手动绕过**：手动刷新 `forceRefresh + bypassCooldown` 直接查询全部 provider，不受新鲜度与冷却约束；定向刷新属手动操作，只写回目标 provider 的时间戳。
    - **范围说明（C065 联动）**：mac 侧额度查询周期已由 C065 与用户配置刷新间隔联动，Windows 侧同步以 `refresh_interval_secs` 作新鲜度间隔；不再存在「本地采集与额度查询周期绑定的双端差异」。

### 6.1 Rust 端改动清单（收敛后）

| # | 改动 | 位置 | 内容 | 实施状态 |
|---|---|---|---|---|
| R1 | 缓存根平台化 | `collector-local/src/lib.rs`（`default_cache_root` / `windows_cache_root`） | `#[cfg(windows)]` 返回 `%LOCALAPPDATA%\Bruce\collector-cache-v1`（env 优先，回退 `~/AppData/Local`），mac/Linux 行为不变；补单元测试 | **已实施**：`default_cache_root` 现按 `#[cfg(windows)]` 分派，`LOCALAPPDATA` 空白值按未设置处理以保留 home 相对回退；mac/Linux 分支行为不变 |
| R2 | Windows CI job | `.github/workflows/ci.yml` | 新增 `windows-latest` job：`cargo fmt --check` / `cargo test --workspace` / `cargo clippy` | **已实施**：`verify-windows` job 在 `windows-latest` 上执行前端结构冒烟、发布脚本 AST 语法门禁与三个 manifest（`core/collector`、`apps/win/viewmodel`、`apps/win/src-tauri`）的 fmt / test / clippy |
| R3 | 验证脚本抽取 | `scripts/` | Rust 平台无关部分抽为 `verify-rust.sh`（Windows 侧 PowerShell 等价或 PowerShell 驱动） | **已实施**：`scripts/verify-rust.sh` 已抽取并被 `verify-local.sh` 与 CI 双侧复用（Windows 侧由 CI 直接执行等价 cargo 命令，zsh 依赖不适用于 Windows） |
| R4 | 真机路径实测 | 本文档 §3.4 | P0 实测后回填；如有布局差异改 `paths.rs` 对应 resolver 并补测试 | **未实施（真机欠账）**：§3.4 仍为待实测表 |
| R5 | Claude CLI Windows 凭证 | `collector-credential` | 视实测结论：文件回退已覆盖则仅登记；否则实现 Windows `CredentialSource`（文件探测优先，禁止交互） | **已闭合（另一路线，C075 落地）**：未向 `collector-credential` 引入 Windows 侧 `CredentialSource`；Windows 壳在 `src-tauri/src/credentials/claude_local.rs` 只读跟随本机 `~/.claude/.credentials.json` → `.claude.json`，注入 `claudeQuotaAccounts`（见规则 17），并保留 `claudeOAuth` 粘贴注入 |

### 6.2 Windows 视图模型层（`apps/win/viewmodel/`，独立纯 Rust crate）

对齐 `BruceAppCore` 的职责与实际落点如下。纯映射保留在 `viewmodel`；文件持久化、调度与系统集成位于 `src-tauri`，不混入纯视图模型：

| Rust 模块 | 对齐 mac 源 | 职责 |
|---|---|---|
| `viewmodel/src/usage.rs` | `UsageMapping.swift` / `PanelViewModelMapper` | artifact → 今日总量/Agent 明细/逐小时/热力图/模型用量视图模型 |
| `viewmodel/src/subscription.rs` | `SubscriptionMapping.swift` / `SubscriptionPresentationPolicy` | Provider 额度快照 → 订阅卡展示模型（窗口语义、进度、告警态） |
| `src-tauri/src/alerts.rs` | `QuotaAlertEvaluator.swift` / `SystemNotificationDeliveryPolicy` | 配额告警判定与通知去重 |
| `src-tauri/src/scheduler.rs`、`runtime_core.rs` | `RefreshScheduler.swift` / `RefreshBackoffPolicy` / `RefreshExecutionPipeline` | 刷新调度、指数退避与可独立测试的策略 |
| `src-tauri/src/reachability.rs` | `NetworkReachability.swift` | 网络可达性闸门状态机与可注入探针（C076，见规则 18） |
| `src-tauri/src/quota_policy.rs` | `QuotaRefreshPolicy.swift` / `QuotaCarryOverMerger.swift` | per-provider 额度新鲜度门禁、429 冷却与旧值回填（C077，见规则 19） |
| `src-tauri/src/credentials/claude_local.rs` | `SystemExternalCredentialReader.swift` / `ClaudePasteParser.swift` | 本机 Claude CLI 登录态只读跟随与规范化（C075，见规则 17） |
| `src-tauri/src/runtime_core.rs` | `CodexQuotaSnapshotMerger` 等 | 快照持久化与 stale 合并（DeepSeek 月度账本已于 C020 双端移除） |
| `src-tauri/src/settings.rs`、`src/settings.js` | 设置中心相关 | 价格校准、卡片排序、主题偏好的加载与持久化 |

对拍测试位于 `apps/win/viewmodel/tests/`（`cargo test`，无需 Tauri/WebView 依赖，双平台 CI 均可执行），fixture 直接引用 `tests/fixtures/` 共享资产；mac 侧在 `verify-local.sh` 中增加对拍 invocation（Swift Harness 输出与 Rust 输出比对）。

### 6.3 Windows 系统集成壳（`apps/win/src-tauri/src/`）

- **托盘**：Tauri tray icon + 左键弹面板/右键菜单（刷新/设置/退出），图标态（就绪/刷新中/告警）与 mac 圆环语义对齐；
- **面板**：置顶、无任务栏项、失焦隐藏的 WebviewWindow；位置记忆对齐 mac `DashboardPanelPlacement`；
- **热键/通知**：Tauri 官方插件（global-shortcut / notification）；自启仍为可选后续项；
- **凭证壳**：`credentials.json` 的 ACL 写入器与 Onboarding 引导流程（Tauri 深链/本地页）。

### 6.4 打包与发布线

- `tauri.conf.json`：产品名 Bruce、identifier 沿用 `com.bruce.dashboard` 系命名；
- **应用版本号单一事实源（C056 新增）**：仓库根 `VERSION` 是唯一权威值，`apps/win/src-tauri/tauri.conf.json` 的 `version` 是它的**镜像**（Tauri 的安装包命名与 `get_runtime_info` 的 `package_info().version` 都取自该字段，故它直接决定安装包文件名与应用内「版本」行）。两端必须相等，由 `scripts/check-win-frontend.mjs` 在**每次 push 与本地 verify-local** 断言；不等即门禁红灯，禁止带漂移发版。
- 打包：Tauri bundler → NSIS 安装包（+ 可选 MSIX）；`signtool` 签名（测试期可不签）；
- CI：release 阶段增加 Windows 构建矩阵 job，产物 `Bruce_x.y.z_x64-setup.exe` + SHA256；
- 文档：README/`docs/guide/` 补 Windows 数据位置（`%APPDATA%\Bruce`、`%LOCALAPPDATA%\Bruce\collector-cache-v1`）。

**发布流水线纪律（C036）**：

1. **release 列表必须分页且展平**：草稿 release 不在 `/releases/tags/{tag}` 端点返回，Windows 作业改走列表端点取 `upload_url`；该端点默认 30 条/页，release 总数超过 30 后目标草稿不在首页，查找落空会让上传直接失败。取数固定为 `gh api --paginate --slurp "…/releases?per_page=100"`，并**必须逐页展平** —— `--slurp` 的输出是「外层数组套各页数组」（单页时亦然），直接当 release 列表用会把 `upload_url` / `assets` 取成数组、拼出损坏的上传 URL。
2. **CLI 钉版**：`cargo install tauri-cli --locked` 只钉 CLI 自身依赖树，不钉 CLI 版本本身；不钉会在 tauri-cli 3.x 稳定后跨大版本升级并冲掉已验证的 NSIS 打包链路。CI（release-windows）与 `scripts/build-win-app.ps1` 必须钉**同一精确版本**（当前 `=2.12.2`，即 v0.11.5 发布实测通过版本），升版须两端同步并随一次 tag 发布验证。
3. **重跑幂等**：同名资产已存在时上传返回 422 `already_exists`；仅重试「发布 Windows 安装包」作业（不重跑 release 作业）时草稿里往往已有上一轮资产，上传前必须清理同名残留。
4. **发布脚本可验证**：发布/打包逻辑落在 `scripts/*.ps1`，由 `verify-windows` 作业的 AST 解析步骤（`[Parser]::ParseFile`，不执行）在**每次 push** 做语法门禁 —— 这些脚本只在 tag 场景真正执行，语法错误若留到发版才暴露代价最高。
5. **验证边界**：以上四条的端到端验证只在 tag 发布时发生（`release` / `release-windows` 作业与打包脚本均 tag 触发）。push 级可验证部分是结构契约测试 `scripts/check-release-pipeline.mjs`（分页+展平 / 两端钉版 / 重跑幂等 / 脚本归属与门禁，随 `verify-windows` 执行）与 AST 语法门禁；**发版后需将一次真实 run 的结论回填到对应 C 卡**（C036 待回填）。
6. **版本漂移必须在 push 级暴露（C056）**：v0.12.0 发布实测发现 `tauri.conf.json` 的 `version` 自 v0.11.5 起未再提升，而该字段只在 tag 场景被消费 —— 结果 `Bruce_0.11.5_x64-setup.exe` 被当作 v0.12.0 的产物上传、应用内版本行亦显示 0.11.5，缺陷直到发布后才可见。现把一致性断言前移到 `check-win-frontend.mjs`（随每次 push 执行），与上述「tag 才验证」项互补：**凡 tag 场景才消费的字段，必须在 push 级至少校验其与权威源的相等性。**

---

## 7. 扩展设计 (Additional Technical Design)

### 7.1 实施阶段与任务卡映射

| 阶段 | 内容 | 任务卡 | 验收口径 |
|---|---|---|---|
| P0 | Windows CI + 真机路径实测 | T01 | windows-latest 全绿；§3.4 实测表回填 |
| P1 | 缓存根平台化 + CLI Windows 采集跑通 | T01 | Windows 本机 artifact 与 mac 同 schema 且数值合理 |
| P2 | Tauri 骨架 + 视图模型 + fixture 对拍 + 最小看板 | T02 | 双端 fixture 对拍逐字段一致 |
| P3 | 全功能对齐（订阅额度/通知/热键/设置/Onboarding） | T03 | 功能矩阵逐项勾选 |
| P4 | 打包发布线 | T04 | 安装/升级冒烟 + SHA256 |

### 7.2 风险与预案

| 风险 | 预案 |
|---|---|
| 各 Agent Windows 布局与预期不符 | P0 实测先行，`paths.rs` resolver 按实测回填，env 覆盖机制兜底 |
| WebView2 Runtime 缺失（老 Win10） | 安装包内置 WebView2 Bootstrapper（Tauri 默认行为） |
| 对拍长期维护成本 | fixture 即 mac Harness 既有资产，对拍失败即 CI 红，漂移无处藏身 |
| Claude CLI Windows 凭证形态未知 | R5 按实测结论落地，文件探测优先、静默回退，绝无交互弹窗 |
| ureq/rustls 在企业代理环境行为 | 出站探测失败静默降级为本地扫描口径（与 mac 一致） |

### 7.3 后续演进

- 更新通道：Tauri updater（P4 后可选）；
- Linux：路径表已天然大部分覆盖，视需求另行立项；
- PDH 磁盘度量：`metrics.rs` Windows 分支（可选，非目标）。

---

## 8. 参考资料 (References)

- `core/collector/crates/collector-application/src/paths.rs`：跨平台路径解析（Windows 候选分支实测锚点）
- `core/collector/crates/collector-local/src/lib.rs` 的 `default_cache_root` / `windows_cache_root`：缓存根解析（平台化已实施，见 §6.1 R1）
- `core/collector/crates/collector-credential/src/lib.rs` 的 `CredentialSource` trait 与其 `read_keychain` 默认实现：平台无关凭证读取契约
- `apps/macos/Sources/BruceAppCore/`：视图模型/调度的 mac 事实源（Rust 对齐基准）
- `docs/devel/design/00-系统总体设计.md`：Monorepo 分层与 `apps/` + `core/` 拓扑依据
- [变更总账 (WindowsCompat)](../change/index.json#WindowsCompat)

> 📌 本节引用一律采用 `文件 (符号)` 形式而非 `文件:行号`：行号会随文件增长漂移，符号不会。§3.1 的行号是其自称的时间点存档，不在此约定内。
