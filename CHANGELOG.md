# 变更日志 (CHANGELOG)

所有对本项目的显著变更均记录于此文件。
格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号严格遵循 [语义化版本 (SemVer)](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Fixed
- **ZCode 万行截断被误报为故障致菜单栏红圈修复 (C041)**：修复菜单栏配额环误变红（警告三角）的缺陷。排查确认配额余量最低 40%（智谱周窗）不满足红圈阈值（<15%），红圈来自采集 envelope `partial`。根因：ZCode DB `model_usage` 在 182 天窗口内已有 10,986 行，超过 `MAX_SOURCE_ROWS = 10,000`，扫描按计划内语义「保留最新、丢最旧」降级并附诊断，但该降级被两处按故障处理 —— `collect_local_usage` 把任意源诊断统一挂 `LOCAL_SOURCE_SCHEMA_INCOMPATIBLE`（名不符实，并非 schema 问题）并计入 `response_status` 诊断计数，`finalize_local_agent` 见诊断即置 `agent.status=error`。按当前用量（约 500 行/天）上限将长期触发：红圈不可自愈，半年视图静默只保留最近约 3 周，且截断后缓存 `append_safe=false` 每轮全量重扫 1 万行。现将上限提至 `MAX_SOURCE_ROWS = 30,000`（覆盖 ZCode 自身修剪天花板约 1.1 万行，上限休眠；opencode 同享），截断路径新增结构化 `capped` 标记贯穿缓存条目，对外改用**独立信息级诊断码 `LOCAL_SOURCE_ROWS_CAPPED`**：agent 状态保持 ok 仅记 note（诊断与降级说明仍可见，可观测性不降），`response_status` 改为按诊断列表判定、信息级不参与 Partial，`LOCAL_SOURCE_SCHEMA_INCOMPATIBLE` 仅用于真实 schema/读取故障。**实测**：Universal 包重打包安装并强制重启后，app artifact zcode 恢复 `status=ok` / note「本机会话聚合」（11K 行 < 3 万新上限，万行截断诊断消失），today.total 持续正常累计，全部订阅服务 ok → envelope Success → 菜单栏恢复绿色配额环（红圈两触发条件均排除：余量最低 40% > 15%、模块状态 fresh）。
- **SQLite 增量缓存跨窗口身份错位静默清空历史 base 修复 (C040)**：修复 ZCode 今日 token 统计大幅偏低（cline-pass/deepseek-v4.1-flash 今日真实 99.7M+ 完全不可见，今日全量 134M 只显示约 1-4.5M）的缺陷。对账锁定根因在 `scan_sqlite_cached` 追加路径：缓存身份（窗口长度/时区/今日）不匹配时不命中缓存但**仍允许增量追加**，旧条目的 days 索引在新窗口 `day_list` 下有两种败坏形态 —— 越界时 `to_domain` 返 None 被静默替换为空 base（历史清零），索引恰在界内时解码「成功」但数据整体平移到错误日期（实锤：今日桶 139M 被挪到 13 天前）；两形态均照常前推游标且无自愈（诱因是探测脚本直跑 collector 未带 `days/timezone`，默认 14 天/UTC 与 app 实际 182 天/本机时区错位，但缺陷本身潜伏：任何窗口/时区配置变更都会触发）。现**增量追加必须以缓存身份全匹配为前置**（`cache_identity_matches`），身份错位一律回退全量重建；base 解码失败不再以空 base 合并后推进游标。新增回归用例 `zcode_sqlite_cache_window_mismatch_rebuilds_instead_of_empty_append`（已做红绿验证：修复后通过、旧代码上失败）。**实测**：Universal 包重打包安装并强制重启后，app artifact today.total = ΣtodayModels = 163,747,628 逐 token 一致，cline-pass 今日 99,783,779 恢复可见。
- **Cline 三窗口改直读网页同源服务端权威端点 (C039)**：修复 Cline 三窗口与网页控制台偏差大的缺陷（面板 24.05%/12.02% vs 网页 34%/17%）。对账锁定两层根因：**(1) 台账翻页截断** —— 安装中的构建仍是 C038 之前版本（12 页 × 200 = 2400 单上限，静默截断），本机台账已达 3319 单，最旧 919 单（约周分子 30.1%）被丢弃；**(2) 客户端窗口建模与服务端口径的结构性漂移** —— 5h 实为「上一块到期后首单开块 [t, t+5h)」的服务端活动块（纳秒级实证：端点 `resetsAt` 减 5h 恰为台账开块那一单），纪元网格固定槽（5 日轮转）与之语义不同。扫描 app.cline.bot 前端 bundle 发现网页 USAGE LIMITS 的真实数据源 `GET /api/v1/users/me/plan/usage-limits`（Bearer API key 直连 200），返回三窗口整数百分比 + 纳秒级 `resetsAt`，与网页逐字一致。现三窗口**直读该权威端点**，删除台账翻页、user id 获取与全部窗口建模代码；C038 引入的 `LedgerCache` 脚手架（端口 + `FileLedgerCache` + `RunContext` 接线）因失去唯一消费者整体回收（git 历史保留，`/usages` 与 `/usages/daily` 在 design/02 备案为将来模型级明细或端点失效时的既定回退路径）；design/02 规则 5 改写为「数据源直读 + 失败语义」，红线改为**严禁在客户端复刻服务端窗口建模**。
- **Cline 逐单台账跨运行增量缓存 (C038)**：修复 Cline 长窗口（7d/30d）用量分子被单轮页数上限截断导致系统性偏低的问题。`/usages` 接口不支持时间过滤且单页硬上限 200，历史实现每轮固定深翻 12 页（约 2400 单、约 8s），30 天内单据数超过该上限的账户（本机账户实测 30 天 3464 单）其 7d/30d 分子被静默截断。现引入**跨运行台账缓存**：新增 `LedgerCache` 端口（定义于零依赖的 `collector-runtime`，实现 `FileLedgerCache` 归 `collector-local`，落 `<cache_root>/provider-ledger/`，临时文件 + rename 原子替换），provider 保持无状态、缓存缺失或损坏按空态自愈；取数分两段 —— **追新**（从首页起直到一页不再产出新单据，稳态仅 1 页）与**回溯**（未覆盖 30 天 horizon 时从上次中断游标续翻，每轮最多 8 页分次收敛，游标失效则放弃本轮并于下轮重新收敛）。单据按服务端 `id`（实测存在）去重，缺失时回退内容指纹，跨页重复单据不再被重复计入。**实测**：首次深翻 12 页即触上限（2400 单，`complete=false`，复现截断）→ 回溯收敛至 3464 单覆盖完整 30 天，7d 分子由 29.61% 修正至 35.44%、30d 由 14.8% 修正至 17.72%；稳态每轮 1 页约 1.3s（原 12 页约 5.3s）。fixture 通道保持 `NoLedgerCache`，无外部 I/O 的测试契约不变。
- **额度窗口边界唤醒与过期窗口文案 (C037)**：修复「到点不刷新」的观感缺陷 —— 订阅刷新间隔（默认 1800s）与额度窗口的重置时刻无关，槽/窗口边界过后至下次定时刷新之间（最长约 30 分钟）面板仍展示上一窗口的百分比，并把倒计时写成「已到期」。现新增**窗口边界唤醒**：下次定时唤醒 = min(间隔剩余, 最近一个**未来**窗口重置时刻 + 20s slack)，边界取自 artifact `services[].windows[].resetsAt`，只在采集成功时参与调度（退避路径语义不变）。为杜绝刷新风暴设三道防线：只认严格在未来的边界（滚动窗口的滑出时刻随刷新前移时天然不触发）、同一「边界值」只消费一次（epoch 秒精确去重）、未命中或边界比间隔更远时回落原间隔 —— 这是 C025「滚动窗口倒计时恒贴近当前时刻」教训的直接防护。同时把过期窗口（`resetsAt <= now`：窗口已重置、数据仍属上一窗口）的文案由「已到期」改为「**刷新中**」，mac 与 Windows 两端一致（`PanelModels.resetText` / `viewmodel::reset_text`），配合边界唤醒该中间态通常只持续数十秒。mac 侧新增 `SubscriptionBoundaryWakePolicy`（纯策略，与 Windows `runtime_core::boundary_wake` 同构），双端各带边界提取/防风暴回归用例。
- **Windows 发布流水线三处缺陷修复与发布脚本可验证化 (C036)**：修复 Windows 安装包上传环节的三处缺陷。**(1) release 列表分页**：上传步骤经列表端点取草稿 release 的 `upload_url`，但未传分页参数（该端点默认 30 条/页），仓库 release 总数超过 30 后目标草稿不在首页会导致查找落空、发版失败（当前 16 个 release，属潜伏缺陷；已用 `per_page=2` 模拟超页场景复现旧逻辑命中数为 0）。现改为 `gh api --paginate --slurp …?per_page=100` 取全量并逐页展平 —— 实测 `--slurp` 输出为「外层数组套各页数组」（单页亦然），不展平会把 `upload_url`/`assets` 取成数组并拼出损坏的上传 URL（该陷阱已在实现中踩到并修正）。**(2) tauri-cli 钉版**：`cargo install tauri-cli --locked` 的 `--locked` 只钉 CLI 自身依赖树，不钉 CLI 版本本身——v0.11.5 发布实测装的是当时的 latest `2.12.2`，如今已是 `2.12.3` 且 `3.0.0-alpha` 已发布，3.0 稳定后该命令会跨大版本升级并冲掉已验证的 NSIS 打包链路。CI 与 `scripts/build-win-app.ps1` 现统一钉 `=2.12.2`（v0.11.5 发布实测通过版本），消除本地与 CI 的打包链路漂移。**(3) 重跑幂等**：同名资产已存在时上传返回 422 `already_exists`，而「重试失败的 Windows 发布作业」正是最自然的恢复动作，此前必然再次失败并只能人工删资产；现上传前按 `assets[].name` 清理同名残留。**(4) 发布脚本可验证**：上传逻辑抽出为 `scripts/upload-win-release.ps1`，并由 `verify-windows` 作业新增的 AST 解析步骤在**每次 push** 对 `build-win-app.ps1` / `upload-win-release.ps1` 做语法门禁（这些脚本只在 tag 场景执行，此前任何改动都无法在 push 场景验证）。
- **看板面板任务栏四方向自适应定位 (C035)**：修复 Windows 任务栏停靠左/右侧时面板定位错乱的缺陷。原实现的定位判据只有一个「任务栏在上还是在下」的布尔量，左右停靠方向在代码中没有任何表示：**左侧任务栏 + 全局热键（或首次用托盘右键菜单「显示看板」）唤出**时，横向兜底恒取工作区右缘，面板会跑到屏幕另一端（1920×1080、48px 左栏实测 x=1468，正确值 60，距任务栏 1420px）；纵向任务栏下的沿轴对齐也只是巧合（托盘恒落在纵向栏底部，被误判为「任务栏在下方」而套用横向上方贴靠逻辑，右栏实测 y=250，统一模型下应为 y=310）。现改为**四边统一模型**：由系统真实工作区相对显示器四边的内缩量判定任务栏所在边（`detect_taskbar_edge`），托盘 `rect` 落在候选条带内时用于消歧（第三方 appbar/dock 与真任务栏共存场景），定位统一为「贴边轴恒贴任务栏内侧（水平 12 / 垂直 10 逻辑px）+ 对齐轴沿任务栏轴向居中于托盘，无可用托盘坐标时贴托盘所在角落」，两轴均按含边距区间夹紧，面板矩形恒在工作区内且与任务栏条带不相交。同时补齐两处健壮性：托盘 `rect` 与判定出的任务栏边不一致（任务栏换边/换屏后的陈旧坐标）时丢弃并走贴角兜底；任务栏自动隐藏（工作区无内缩）时按托盘贴边方向推断停靠边。顶/底任务栏与各档分辨率/DPI 的既有行为逐字符保持不变（原 7 项几何测试期望值未变）。
- **面板几何 Demo 与实现的可证明同构 (C035)**：任务栏交互 Demo 扩展为四方向停靠 + 模拟屏幕缩放框，面板位置/尺寸/DPI 内容缩放全部由与 `runtime_core::compute_dashboard_geometry` 逐行同构的内联几何镜像驱动；新增 `tests/fixtures/geometry-parity/cases.json`（50 例：5 档分辨率/DPI × 4 方向 × 有/无托盘 + 竖屏 + 自动隐藏 + 第三方 appbar 消歧 + 陈旧 rect + 负坐标副屏），由 Rust 与 Node 双侧读取对拍（`apps/win/tests/geometry-parity.test.mjs` 随 `scripts/check-win-frontend.mjs` 进 CI），消除维护者无 Windows 机器时「Demo 与实现漂移而核验失效」的风险。

### Added
- **订阅用量卡徽章升级为品牌图形 (C026)**：仪表盘订阅区各 Provider 的身份标识由「品牌色首字母字母标」升级为**品牌图形徽章**（品牌色瓷砖 + 白色品牌图形），10 家 provider（Kimi / DeepSeek / 火山引擎 / Z.ai / ChatGPT / Claude / Grok / OpenCode GO / StepFun / Cline）各取官方 mark，未收录图形的 provider（Jev）保持首字母兜底：
  - **多图标库取材**：Simple Icons（CC0，Kimi / DeepSeek / Claude / Cline / OpenCode）、theSVG（MIT，火山引擎 / 阶跃星辰）、SVG Logos（CC0，ChatGPT / Grok）；Z.ai 因图标库仅有「智谱」点阵 mark 与现显示名不符，改取其**官方 logo 的 Z 字形**；
  - **单一事实源数据管线**：源 SVG 归档于 `docs/assets/provider-icons/`（含逐图标来源与许可证登记），`scripts/gen-provider-glyphs.mjs` 归一化为绝对 M/L/C/Z 路径（圆弧与简写曲线在生成期展开为三次贝塞尔），同一份数据生成 macOS 与 Windows 两端产物，`verify-local` 校验产物与源文件一致；
  - **双端实现**：macOS 新增 `ProviderBrandGlyphData` / `SVGPathBuilder` / `ProviderBrandGlyph` / `ProviderBrandPalette` 与共享徽章视图 `ProviderBrandBadge`；Windows 端徽章改为 DOM API 构建内联 SVG；新增 `SubscriptionBrandGlyphHarness` 7 项边界测试（覆盖率 / 兜底 / 画布适配 / 命令集纪律 / 色板 / 深色集合 / 透明度保留）；
  - **品牌色板调整**：Z.ai 改用官方锁版深色 `#2D2D2D`（与其官方 logo 深色瓷砖一致，取代旧蓝 `#3859ff`），补齐此前缺失的 Cline 品牌色 `#18181b`（原先落默认灰 `#8e8e93`）；Nothing 主题深色品牌色（Grok / Z.ai / Cline）沿用 secondary 灰兜底；
  - **设置中心同步图标化**：设置中心「订阅额度」Provider 行首加入 26pt 品牌图形大图标（拖拽柄右侧），配置弹窗标题前置 20pt 品牌徽章；徽章组件尺寸参数化（15pt 仪表盘 / 26pt 设置行 / 20pt 弹窗标题），圆角与首字母字号按比例缩放；
  - **「添加服务」下拉选项带品牌图标**：选择 Provider 的下拉保持原有控件与两步（选择 → 添加…）流程不变——改用同一原生 `NSPopUpButton`（SwiftUI `Picker` 的菜单项不渲染图像），每个选项前为 16pt 品牌瓷砖 + 白色图形（`NSMenuItem.image`，非模板染色保留品牌色），图形右侧留 6pt 留白把标题右移（AppKit 菜单标题位置由图像列宽决定），闭合态由系统自动带出所选 provider 的图标。

## [0.11.5] - 2026-10-14

### Added
- **统一余额型订阅仪表盘展示规范为双槽对称流并暂时屏蔽 Jev (C018)**:
  - **仪表盘双槽对称流 (方案 B)**: 为 DeepSeek 等按量计费/余额型订阅重构正文布局，标头移出拥挤的 `BalanceChip`，正文平铺为 50/50 规整双槽（左槽为大号等宽粗体「可用余额」，右槽为「本月消费」及覆盖区间说明，若无账本则显示「订阅状态」）；Classic/LiquidGlass 适配微透明平滑圆角磨砂槽，Nothing 主题适配 3pt 方角、透明底加强边框与 Space Mono 字体。
  - **界面暂时屏蔽 Jev**: 因 TypeSafe 官方未开放免费查询剩余额度的公开 API，在 `SettingsView` 与 `SubscriptionPresentationPolicy` 中暂时隐藏 Jev 显示与配置入口，避免无官方查额接口对用户造成误导；底层 Collector 解析、凭据存储及全部 168 项安全测试 100% 完整保留。
- **TypeSafe Jev 订阅额度监控与多模型计费全链路适配 (T05 & C017)**:
  - **Core Collector**: 内置 TypeSafe Jev 模型定价（`jev-1.13.0`, `jev-1.13`, `jev-latest`, `jev-preview`），基准单价输入 $0.042/1M tokens ($42/1B)，输出免费；实现 `JevProvider` 出站探测 `GET https://api.typesafe.ai/v1/models`，自动解析活跃模型列表与速率限额（100k tok/s, 80 req/s），标准化映射 401 凭证失效与 429 限流退避。
  - **凭据白名单与安全传输**: 扩充 `ALLOWED_CREDENTIAL_FIELDS` 白名单与 `request-v1.schema.json`，支持 `jevQuotaAccounts` 安全注入与 POSIX 0600 凭据权限隔离。
  - **macOS 原生设置中心与看板卡片**: `BruceOnboardingCore` 与 `BruceApp` 接入 Jev API Key 单一凭据配置弹窗（`console.typesafe.ai` 快捷引导）、即时连通性校验（`reverify`）、品牌色 `#e551ba` 与 System One 决策模型专属配额卡片渲染；补全全量 Harness 测试（168 项用例）。

## [0.11.4] - 2026-10-14

### Fixed
- **Windows 任务栏托盘弹出位置偏离与静态坐标死锁修复 (C016)**: 修复点击托盘图标位置错位、钻入任务栏后方或多屏切换后失效的缺陷。彻底废弃历史失焦时写入 `settings.json` 并永久死锁面板坐标的旧逻辑；改为基于 Win32 操作系统底层真实的 `monitor.work_area()` 工作区（自动扣除任务栏占用）与 Tauri 2 托盘点击物理 `rect`，动态计算贴靠位置（底部任务栏上方 10px / 顶部任务栏下方 10px），并居中对齐托盘图标与安全边缘钳制；支持 Windows 10/11 任意任务栏停靠位置与多显示器负坐标环境。
- **多分辨率与高 DPI 缩放仪表盘高度自适应 (C016)**: 修复 `tauri.conf.json` 写死高度 760 导致在 1080p 150% 缩放笔记本（可用逻辑高度仅 688px）及 1366×768 屏幕下窗口超出屏幕下界、底栏设置与退出按钮不可见的严重 Bug。实现纯函数 `compute_dashboard_geometry` 动态根据工作区可用高度自适应降高（留出上下各 10px 安全边距），开启 `resizable: true` 支持程序级尺寸适配。
- **消除前端 CSS Flex 截断与细滚动条优化 (C016)**: 修复 `styles.css` 中 `#scroll` 缺少 `min-height: 0` 导致的 Flex 规范下子项拒绝收缩并挤出底栏的缺陷；为 `#scroll` 注入 `flex: 1 1 0; min-height: 0;` 并配备 4px 细致半透明滚动条；为 `#footer` 显式设置 `flex: 0 0 auto;`，底栏齿轮设置与退出按钮永久绝对锁定在可视区底端。
- **交付 Windows 任务栏高保真交互与多分辨率模拟 Demo**: 更新 `apps/win/demo/win-taskbar-interaction-demo.html`，新增 1080p 100%、1080p 150%、1366×768、2K 125%、4K 200% 分辨率切换与顶部/底部任务栏切换，并实时渲染几何 Telemetry 状态参数与挂靠对齐效果。

## [0.11.3] - 2026-10-13

### Fixed
- **Windows 设置窗口打开全白屏与生命周期修复 (C015)**: 修复 v0.11.2 中打开独立设置窗口呈现无内容全白屏的严重缺陷。原因系 C013 曾尝试「懒创建」从 `tauri.conf.json` 移除了 `settings` 窗口，在 Tauri v2 命令工作线程中动态构建 Webview 破坏了 Win32 STA 线程要求导致 WebView2 初始化死锁/失败且缺少 `show()`。现全面恢复设置窗口静态预建配置（`visible: false`），启动时由主线程完成 WebView2 预备，点击设置即开即显；补充主线程兜底创建与显式呈现逻辑；为 `settings.js` 和 `app.js` 强化 Tauri 全局 IPC 对象防御性判空，彻底消除脚本未捕获异常隐患。
- **Windows 仪表盘去噪与会话探针 1:1 对齐 macOS**: 剥离仪表盘上混杂的“未发现会话记录”与空 Agent 探测噪音，主面板恢复纯净极简 HUD（仅保留严重服务级重授权异常）；将 10 大 Agent（Claude Code, Codex, Kimi, OpenCode, Grok, 火山引擎, Orca, Pi, ZCode, CodeBuddy）与 Rust Collector 的探针就绪/未发现记录/未安装状态完整对齐收拢至「设置 -> Agent 用量 -> 会话来源」，并配备「重新检查」即时扫描能力。
- **Windows 任务栏托盘交互体验对齐 macOS 菜单栏**: 增加 300ms 失去焦点去抖动防护，彻底消除在面板激活时点击托盘收起窗口因 Win32 焦点丢失与 Tauri Click 事件竞争产生的“反弹重开”恶性 Bug；未记忆位置时默认自动贴靠当前主显示器右下角任务栏上方；新增 `Escape` 快捷键与 `hide_dashboard` 命令，按下 `Esc` 键即刻平滑收起看板。
- **交付 Windows 仪表盘与设置中心高保真 Fluent 预览 Demo**: 交付 440px Fluent 仪表盘（`apps/win/demo/win-dashboard-fluent-preview.html`）与 1040×680 WinUI 导航设置中心（`apps/win/demo/win-settings-fluent-preview.html`），支持暗黑/浅色、状态与折叠交互。

## [0.11.2] - 2026-10-13

### Fixed
- **Windows 仪表盘去 Tab 纯净化与 Fluent 侧栏设置窗口对齐 (C014)**: 修复早期原型遗留的内嵌 Tab 与内嵌表单容器破坏 440px 窄面板布局的缺陷; 物理移除 `<nav id="tabs">` 与内嵌容器, 仪表盘 1:1 对齐 macOS `MenuBarDashboardView` (纯净卡片栈 + 顶底栏); 独立设置窗口彻底重构为 Fluent L2 侧栏架构 (WinUI `NavigationView` 6 大分类导航: 通用、Agent 用量、模型计费、订阅额度、授权与隐私、维护), 彻底解耦主面板与配置中心。
- **Windows 字体栈与抗锯齿排版防折行加固**: 引入 Windows 11/10 专用字体栈 (`Segoe UI Variable Text` / `Segoe UI` / `Microsoft YaHei UI` / `Cascadia Mono`)、表单控件全局字体继承、`-webkit-font-smoothing` 平滑抗锯齿；全面加固 `white-space: nowrap` 与 `overflow: hidden; text-overflow: ellipsis;`，彻底消除单词折行（`Claud\ne`、`DeepSe\nek`）；为右侧操作按钮设置 `flex-shrink: 0`；注入 Fluent 6px 悬浮细滚动条，消除 Windows 17px 原生粗滚动条宽度挤压；全量启用 Tabular Nums 防止数据刷新数值跳动。

## [0.11.1] - 2026-10-12

### Fixed
- **Windows 应用图标缺失与常驻卡顿 (C013)**: 真机反馈修复——`icons/icon.ico|png` 此前是占位空图 (998B/104B), 现由 mac `AppIcon.icns` 生成真图标 (ico 七层 16-256 + png 512), 安装器/开始菜单/任务栏/窗口/托盘全场景显示 Bruce logo; 性能优化: 设置窗口改为首次打开时懒创建 (启动常驻 WebView 减半)、采集线程降 BELOW_NORMAL 优先级 (周期扫描与装机全量首扫不再抢占前台)、面板隐藏时跳过全量重渲染 (脏标记 + 可见补渲)。
- **Windows 品牌色板与 mac 事实源统一 (C012)**: 订阅徽章与余额胶囊圆点的 Provider 品牌色此前双端各自维护, 9 家中 7 家漂移 (如 DeepSeek `#4A9E5C`→`#4d6bfe`、Grok `#6c63ff`→`#111111`、Claude `#ff7a59`→`#d97757`), 违背 styles.css「配色 token 按 mac 源码数值」契约; 现以 mac `ProviderLogoBadge.brandColor` 为唯一事实源逐家对齐。同时回写设计基线 05: 浅色外观显式豁免 (Windows 恒深色, mac dark 侧 1:1 复刻)、订阅卡 Provider 数修正为 9 (含 StepFun)、Nothing 主题保真边界注明。

## [0.11.0] - 2026-10-10

### Changed
- **GPT Credits 改为剩余余额展示 (C010)**: Codex 的 Credits 从订阅卡头部小字升级为「Credits 余额 N.NN」结构化余额 (非货币纯数字); 余额归零或耗尽后采集侧不再产出, 下一次刷新自动消失; 不限量计划维持「Credits 不限量」文案; 双端 golden 对拍锁定渲染契约。
- **余额行升格为订阅段头部元数据胶囊 (C011)**: Credits 与「账户余额」不再占用窗口行下方的裸文本行, 改为 section 头部「品牌色圆点 + 金额」胶囊 (与套餐胶囊并排, 多账号折叠态也可见); Credits 名称去掉「余额」二字, 金额千分位两位小数 (如 2,998.12), 分隔符双端固定一致; Windows 端顺带修正单账号徽章因 id 后缀取不到品牌色而退灰的问题。

### Fixed
- **Windows 仪表盘、配置与生命周期对齐 (C009)**: 修复卡片空白、页签和月度模型切换；接通主题、卡片/Provider 排序、模型价格覆盖、用量开关及出站同意；补齐账号管理/导入、诊断和 DeepSeek 月度账本。刷新统一走有界调度，读面板不触发采集；失败保留旧快照并标记过期。凭据改用实际 SID 的受保护 ACL，收权失败拒绝写入，补充令牌轮换与 Codex 有界恢复。增加生产 HTML/JS 行为回归及 valid/partial/empty 双端对拍。Windows 真机窗口、热键、Toast、ACL 和真实路径仍待人工验收，卡片保持 `in_progress`。
- **Windows 前端三重脱节白屏 (C005)**: 0184900 前端 1:1 复刻只回写了 app.js/styles.css 而漏 index.html 与窗口配置，真机面板加载即抛 `ReferenceError` 白屏。修复：按 styles.css 契约重写 index.html (HUD/三视图/底栏)；app.js 移除 demo 模板残留 `PANEL` 数据段并接线主题选择器, 补模型用量区块 `models` 判空 (无模型月度数据时该区块隐藏而非整栈渲染崩溃, 浏览器真实数据预览已验证三卡完整渲染)；窗口 380x620 → 440x760 对齐 440px 布局, 并清除 demo 残留的 body 20px padding (此前把面板挤压到 400 宽致卡片破版)；新增 `scripts/check-win-frontend.mjs` 结构冒烟 (语法 + DOM id 交叉 + 残留哨兵) 并纳入 verify-rust.sh 与 verify-windows CI，此类缺陷此后双侧 CI 直接红灯。
- **限流退避分类双端死代码 (C006)**: 采集链路诊断 category 值域不含 `rateLimit`，Windows `classify_rate_limited` 与 mac `RefreshErrorClassifier` 按 category 匹配永远落空，「限流固定 300s 退避」从未生效。修复：双端改按 `code == PROVIDER_RATE_LIMIT` 判定 (兼容保留 category 分支)；Windows 测试改用真实形态诊断 (旧测试自造 `rateLimit` fixture 属自证清白) 并补 `compute_backoff(0)` 下溢防御；mac RefreshSchedulerHarness 增分类器用例 (82 项)。
- **面板隐藏暂停采集偏离 mac 常驻语义 (C007)**: mac 后台始终周期采集 (配额告警依赖)，Windows 侧隐藏即停采导致面板关闭后告警停摆，且 `panel_visible` 因关闭路径 (失焦/托盘切换/初始态) 行为不一。修复：删除可见性门控 (`panel_visible`/`set_panel_visible`/`visibilitychange` 上报)，采集恒周期 + 打开面板即时手动刷新；设置加载侧将刷新间隔钳制到 `[60, 86400]` 秒 (手改 `settings.json` 为 0 不再触发零间隔 busy-loop)；设计基线 05 与 T03 卡口径同步回写。
- **Windows 壳采集窗口偏离 mac 半年口径 (C008)**: 壳层把采集窗口写死 `days=14`, 而 mac 事实源为 `days=182` (半年窗口供热力图与按月聚合, 14 日柱状图由映射层截取), 导致真机热力图永远只有 2-3 周、按月聚合最多 2 个月; 测试曾把 14 锁进断言。修复: 对齐 `days=182` 并补 `home` 上下文; 前端热力图列宽设上限并右对齐, 短数据 (新用户) 时不再胀成巨型方块; `dump_panel` 支持注入当前时间, 已用本机真实 182 天数据验证 27 周热力图网格完整渲染。
- **壳层测试临时目录并行碰撞 (伴随修复)**: `temp_root()` 以 `pid-纳秒` 命名，测试线程并行启动时同纳秒碰撞共享目录导致间歇失败 (本轮实测复现)。改用进程内原子序号保证唯一。

---

## [0.10.0] - 2026-10-06

### Added
- **Windows 平台适配 (apps/win, T01-T04)**: Tauri 2 托盘常驻看板, 与 mac 共享 core/collector 单引擎 (进程内直调, 双端 artifact fixture 对拍逐字段锁定); 落地本地采集、订阅凭证存储 (白名单 + 原子写 + 最小权限)、配额 Toast 预警 (5h 窗口 >80% 跨越沿去重)、全局热键、设置中心 (主题/刷新间隔/热键/位置记忆)、NSIS 安装包与 Windows 发布矩阵。设计基线 `docs/devel/design/05-Windows平台适配.md`。
- **现行系统设计基线体系**: 依据 `ad-flow` 治理规范与标准化 8 节大纲，提炼并定稿 5 篇现行设计基线文档（`docs/devel/design/00~04`），覆盖系统宏观架构、多模型计费引擎、POSIX 0600 安全凭据存储、赛博环形菜单栏渲染及价格校准交互。

### Changed
- **精简菜单栏状态指示图标**: 保留外侧 1.5pt 底环与订阅配额比例弧线，彻底移除就绪态、刷新中及未配置状态下的 2.4pt 中心实心微点，使圆环中心完全通透轻盈，与设置窗口中的极简圆环预览条视觉规范保持 100% 对齐。双向回链变更卡 `[C004](docs/devel/change/C004.json)`。
- **工程目录 Monorepo 分层重构**: 根目录历史碎片与平台目录全面重组为 `apps/`（`apps/macos`, `apps/widget`）应用层与 `core/`（`core/collector`）核心引擎层；更新全部构建验证脚本与运行时探测；清理 4.4GB 本地 Rust 构建调试缓存。双向回链变更卡 `[C001](docs/devel/change/C001.json)`。
- **历史文档归档与设计真理源纯化**: 将历史过程文档目录 `docs/development/` 与旧版原型目录 `docs/design/` 完整隔离迁移至 `_adflow_backup/original_docs/`，消除历史多头维护；同步修订现行微设计文档 `00~04.md` 与设计中枢索引，杜绝悬空死链。双向回链变更卡 `[C002](docs/devel/change/C002.json)`。

### Fixed
- **Agent 用量卡片收起动画与过渡行为对齐**: 修复 Agent 用量卡片收起动画与其他卡片不一致的缺陷。为 `HourlyLineCard` 收起态迷你折线图附加动画事务阻断（`.transaction { $0.animation = nil }`），彻底杜绝 Swift Charts 在 0.25 秒收折期间发生线条形变与插值跳动；为展开区附加 `.clipped()` 视口裁切与 `.transition(.opacity)`，消除高度坍缩时内部柱状图与多行图表的垂直挤压；为卡片头部 `mini` 与 `status` 统一应用平滑淡出转场，消除水平位移。双向回链变更卡 `[C003](docs/devel/change/C003.json)`。

---

## [0.9.0] - 2026-09-23

### Added

- **模型计费与价格校准引擎**:
  - Rust Collector 内置 26 款主流大模型官方基准定价表（覆盖 OpenAI、Anthropic、DeepSeek、火山引擎、Google、Moonshot 等），支持模型名称前缀智能匹配与模糊解析；
  - 恢复全局与单模型/单 Agent 维度的 Token 成本（`costUsd`）精确核算；
  - 设置窗口新增「模型计费」专区，支持全模型定价一览、关键字实时搜索、单模型一键弹窗校准与输入/输出价格自定义覆盖，配置与 `config.json` 实时双向映射联动。
- **菜单栏纯图标模式与赛博环形精密仪表**:
  - 新增“仅显示图标”紧凑模式开关，隐藏冗长文字指标，满足极简桌面偏好；
  - 状态栏图标深度集成 Style 01 绿阶雷达扫描动态与 Precision Cyber Ring Gauge 环形仪表，实时呈现订阅额度健康度与剩余用量比例；
  - 菜单栏指示器与刻度环原生适配浅色与深色桌面环境，根据 `effectiveAppearance` 动态调整高对比度色阶，杜绝辨识度不足。
- **菜单栏指标动态自适应与实时交互配置**:
  - 设置窗口提供高保真 macOS 菜单栏实时模拟预览条，调整指标启停与顺序时所见即所得；
  - 引入点阵抓手卡片式拖拽排序与指标备选池交互，自由定制菜单栏指示器；
  - 菜单栏状态项控制器支持多指标宽度动态测量排版，彻底解决右侧文本截断问题。
- **Nothing 风格 Agent 项目看板视觉升级**:
  - 引入 Dot-Leader Console 点阵导引线控制台，项目列表支持虚线点阵对齐与阶梯式 Glyph 翠绿标签；
  - 进度条应用 P4 风格 6 格 LCD 迷你仪表，由实心 Hero 翠绿主段与 45° 斜向点阵纹理构成；
  - 逐小时折线图全面升级为 Emerald Glow 极光绿微光趋势线，搭配平滑渐变衰减，大幅提升暗色背景下的辨识度与工业美感。
- **本地权限保护文件凭据存储**:
  - 实现 `ProtectedFileCredentialStore`，凭证统一落盘至 `~/Library/Application Support/Bruce/credentials.json`，采用严格的 Unix `0600` POSIX 权限与临时文件原子替换；
  - 彻底摆脱本地 Ad-hoc 签名哈希改变导致频繁弹出 macOS Keychain 授权输入密码对话框的困扰；
  - 内置无感向下兼容迁移机制，初次启动自动读取旧版 Keychain 凭证并静默迁移；
  - 外部 CLI 探测（如 Claude Code）引入 `kSecUseAuthenticationUISkip` 强制静默，遇到未授权直接平滑降级至本地文件，0 弹窗打扰。
- **Universal 2 通用二进制与跨平台路径基底**:
  - `scripts/build-test-app.sh` 增加 `--universal` 选项，一键编译产出原生适配 Apple Silicon（arm64）与 Intel Mac（x86_64）的通用应用；
  - Rust Collector 抽象跨平台统一路径解析器 `paths.rs`，原生适配 macOS、Windows（`%APPDATA%`）与 Linux（XDG）路径规范；
  - 会话扫描器引入规范路径集合排重与 16 层深度限制，防止软链接死循环与深层目录卡死。

### Changed

- **看板卡片头部视觉纯化**: 移除各卡片顶部冗余的等宽印章字符，界面更具呼吸感与精致感。
- **设置窗口尺寸优化**: 默认视口调整为 1040x680（最小 980x620），确保新增的模型计费与实时预览在不同分辨率下舒展呈现。

---

## [0.8.0] - 2026-09-21

### Added

- **阶跃星辰（StepFun）订阅用量支持**: 新增 StepFun Provider 适配器，支持国内站（`stepfun.com`）与海外站（`stepchat.com`）双站点用量与额度查询；支持 API Key 与基于内置 WebKit 的网页登录授权流（自动拦截提取 session cookie、防循环重定向与安全清理历史登录态）。
- **仪表盘全局 HUD 状态栏**: 顶部新增终端点阵状态栏，展示系统运行状态（`SYS.OK`）与全局活跃 Agent 统计（`X AGENTS ACTIVE` / `STANDBY`），适配 Nothing、经典及液态玻璃全视觉风格。
- **多账号站点差异化标识**: 同一 Provider 存在多账号时，在仪表盘海外站点账号旁呈现专属标记，保持单账号场景的视觉克制。

### Changed

- **仪表盘 Fluent 微光边框与原生圆角**: 面板引入 Fluent 双层微光边框体系与顶部渐隐高光线；保持窗口底色全透明并由 GPU 硬件加速图层裁剪，彻底消除直角死角，呈现精致平滑的原生圆角（Nothing 10pt / 经典 22pt）。
- **折叠态卡片专属手柄与拖拽解耦**: 仅在卡片缩小/折叠态允许拖动排序，展开态卡片禁止拖拽以杜绝手势干扰；缩小态左侧提供物理隔离的专属 6 点拖拽手柄（Nothing 方点阵 / 经典圆点阵），彻底解耦拖拽排序与点击展开。
- **设置窗口生命周期规范**: 强化设置窗口单例控制与事件调度，防止重复触发打开或意外影响主菜单栏状态。

---

## [0.7.0] - 2026-09-17

### Added

- 新增统一的 Bruce 钥匙串访问配置和首次启动引导, 让用户明确授权后再读取凭证、迁移账号和刷新状态。
- 新增系统通知的应用层开关, 支持在设置中关闭 Bruce 自有的额度预警投递。
- 新增可收起的仪表盘卡片和折叠态迷你摘要, 并持久化每张卡片的收起状态。
- 新增稳定的 macOS 原生菜单栏状态项内容, 在菜单栏显示 Bruce 图标、今日用量和状态摘要。

### Changed

- macOS 27 下改用固定尺寸的原生状态项图像和确定性的仪表盘切换状态, 提升菜单栏重排、Pelmet 管理和首次/二次点击行为的稳定性。
- 设置窗口始终保持菜单栏应用的 accessory activation policy, 不再因为打开或关闭配置页残留 Dock 或 `⌘Tab` 图标。
- 启动时优先恢复本地缓存和今日用量, 避免钥匙串授权弹窗阻塞菜单栏指标显示。
- macOS 14–25 继续使用兼容的经典面板路径, macOS 26+ 才启用液态玻璃主题。
- 隐藏或遮挡仪表盘时卸载装饰性动画, 并缓存 Codex 会话树扫描, 降低后台 CPU、IO 和内存开销。
- 发布流水线继续生成未签名 Preview 草稿包, 正式签名与公证从 CI/CD 自动流程中延后处理。

### Fixed

- 修复 CodeBuddy reasoning token 重复计数、缓存详情丢失和 cache-inclusive prompt cost 计算错误。
- 修复原子 JSON 存储的备份不更新、IO 读取错误被误判为损坏, 以及回滚路径未校验 schema 版本的问题。
- 修复 macOS 27 菜单栏图标偶发消失、今日用量不显示、仪表盘位置异常和点击后无法正确关闭的问题。

### Removed

- 移除没有 Rust 额度消费者的 Antigravity 凭证、注入、设置和 SQLite 探测链路, 同步收缩 Bridge schema 与测试。

## [0.6.0] - 2026-09-04

### Added

- **Nothing 风格主题**: 新增定制字体、卡片外观、Hero 强调色、热力图呼吸效果和绿色阶系列色, 形成独立的 Nothing 视觉主题。
- **模型用量多窗口明细**: Hero 卡新增模型用量分解, 支持多个时间窗口展示和对应的模型占比。
- **CodeBuddy CLI 会话采集**: 新增 CodeBuddy CLI 会话扫描, 支持原始 usage 解析、快照去重和与其他 Agent 统一聚合。
- **设置页配置体验**: 新增 Fluent 卡片式设置外观、模态 API Key 配置和更集中的 Provider 配置流程。

### Changed

- **会话用量归因**: Codex token 用量按 turn context model 归因, OpenCode 与 ZCode 在行数上限场景保留最新消息和模型记录。
- **持久化可靠性**: 提取 `AtomicJSONStore`, 统一 JSON 配置的原子读写与恢复边界。
- **订阅配置结构**: 收敛订阅 Provider 配置和 CodeBuddy 会话源接入, 保持凭证配置与运行时注入职责分离。
- **界面可读性**: 调整模型用量列表和 Nothing 主题的文本、颜色与间距表现, 避免 token 数值在卡片中意外换行。

### Fixed

- **CodeBuddy usage 解析与去重**: 兼容 raw usage 和 camelCase cache breakdown, 按 session/message identity 去重重复快照。
- **Codex 快照重复计数**: 使用文件头尾 fingerprint 替代完整文件 digest, 在重复 rollout 副本和大文件场景保持稳定去重。
- **Rust CI Clippy 门禁**: 兼容新版 Clippy 对 cache writer、JSONL source reader 循环和 `io::Error` 构造的 lint 要求, 恢复 `verify-local.sh` 发布门禁。

---

## [0.5] - 2026-08-25

### Added

- **Rust Collector 完整迁移**: 完成从 Python Collector 到 Rust workspace 的运行时切换, 统一 Bridge artifact、额度 Provider 和本地会话采集边界。
- **Rust 运行时验证与发布门禁**: 增加 Collector fixture、进程边界、资源指标、安装/升级/回滚与缓存重建验证, 并接入 macOS App 打包和 GitHub Release 草稿流程。

### Changed

- **刷新与资源占用优化**: 本地采集、缓存和 Bridge 运行时采用有界读取、增量处理与资源指标, 降低刷新期间的 CPU、IO 和内存峰值。
- **订阅额度兼容性增强**: Provider 解析和 App 注入契约统一, 支持多账号额度查询、定向刷新与可诊断失败状态。
- **仓库与工程文档清理**: 清理过期迁移说明、OpenSpec/本地工作流残留和未打包参考契约, 同步更新治理、CI、工具链和正式发布文档。

### Fixed

- **智谱 GLM Coding Plan 额度不显示**: 兼容新版 `CREDIT_LIMIT` 与 `data` 数组响应, 在缺少百分比字段时从当前用量和剩余额度推导窗口进度。
- **火山引擎额度查询凭证键名错配**: 修正 App 注入字段与 Rust Provider 契约不一致导致的查询失败。
- **Codex 用量重复统计**: 去重重复 rollout 文件和重复会话副本, 避免 token 用量被重复累计。
- **Provider 错误诊断不准确**: 保留 HTTP 状态并区分非 JSON 响应、业务拒绝和 HTTP 错误, 避免把不同故障都显示成同一错误。

### Removed

- **旧 Python Collector 与桥接实现**: 移除遗留 Python 采集器、旧 Bridge 运行时和对应契约测试, 项目运行时完全由 Rust Collector 提供。
- **冗余死代码与本地产物**: 清理无调用方的 Rust/Swift/Widget 路径、过期图标和本地工作流产物, 不再进入仓库或 App 包。

---

## [0.4] - 2026-08-21

### Added

- **全局快捷键与原生状态项**: 新增可配置全局快捷键呼出看板 (设置「通用」分区录制, 组合被占用时非致命提示); `MenuBarExtra` 重构为原生状态项 + 无边框面板, 状态栏标签改用模板图片渲染, 深浅外观下尺寸与着色稳定, 面板关闭后焦点正确归还。
- **Pi agent 用量**: 新增 Pi 会话本地扫描 (会话路径经运行上下文注入), 数据源、服务拓扑与面板配色并列展示。
- **ZCode CLI 会话扫描**: 新增 ZCode CLI 会话用量统计, 与 Kimi/Claude/Codex/Grok/OpenCode 并列展示; 同步更新应用图标。
- **智谱 GLM Coding Plan 订阅额度**: 新增 Zhipu GLM Coding Plan 个人订阅额度采集与展示。
- **订阅额度 Provider 定向刷新**: Scheduler 支持按 Provider 定向刷新并联动面板刷新状态, 定向快照合并保留单 Provider 失败语义; Bridge/Collector 增加 quota-only Provider 白名单与凭证隔离。

### Changed

- **项目更名 mddd → Bruce**: 应用、构建产物 (`Bruce.app`/`Bruce.zip`)、CI 发布标题与文档统一更名为 Bruce。
- **Kimi 订阅额度切换 API Key**: Kimi 额度采集从 Web Tokens 切换为 Kimi For Coding API Key 查询。
- **用量档位与热力图刻度统一**: 用量档位与热力图等级统一为 100M 绿色刻度, OpenCode agent 使用独立绿色。
- **液态玻璃面板优化**: 统一面板玻璃表面矩阵, 提升液态玻璃对比度并打磨面板与刷新指示细节。
- **设置窗口卡片化**: 设置窗口重构为卡片化 UI 体系, 应用版本号改为动态单一真源。
- **README 重写**: 重整文档结构与发布信息, 应用图标启用圆角版本。

### Fixed

- **Claude 用量少计修复**: 重复写入的 Claude 消息按完整 usage 条目计数, 修复骨架消息导致的用量低估。
- **菜单栏缓存误失效修复**: 菜单栏摘要缓存与面板缓存版本分离, 不再相互触发重建。

---

## [0.3.0] - 2026-08-10

### Added

- **OpenCode Go 订阅额度**: 接入 opencode.ai 网页控制台的 Go 订阅用量 (滚动/每周/每月窗口), 支持多账号 Keychain 凭证管理与统一窗口语义 (每 5 小时/每周/每月, 服务端无窗口不显示)。
- **OpenCode agent 用量**: 新增 OpenCode 会话本地扫描 (只读 SQLite), 精确 token 计数与模型/项目分布, 与 Kimi/Claude/Codex/Grok 并列展示。
- **用量卡增强**: 新增 26 周用量热力图、月度聚合分解与用量档位指示 (UsageHeroCard/HourlyLineCard)。

### Changed

- **Keychain 访问免弹窗**: 显式宽松 ACL, 避免 ad-hoc 签名下每次启动刷新触发授权密码框。
- **刷新与内存优化**: 本地扫描改串行执行 (内存降约 27%, 耗时降约 35%), 跳过超长 JSONL 行避免碎片化分配; 清理 `collect_usage.py` 死代码。
- **CPU 优化**: 用量卡代码流背景与 LIVE 指示改为静态渲染, 移除窗口隐藏后仍持续驱动 SwiftUI 渲染循环的动画 (主线程 CPU 由 20-40% 降至约 0%)。
- **启动提速**: 凭证异步后台加载与快速初始菜单栏指标渲染。

---

## [0.2] - 2026-08-06

### Added

- **多账号订阅凭证管理**: 支持火山引擎 (Volcengine)、Kimi Web Tokens 以及 DeepSeek API Keys 的多账号 Keychain 持久化保存、标签管理与配额并行采集。
- **主题降级与多版本兼容**: 新增 `ThemeResolution` 解析模块，支持 macOS 14+ 经典玻璃与 macOS 26+ 液态玻璃主题自动适应与降级防护。
- **刷新调度与执行管道重构**: 引入 `RefreshIntent`、`RefreshExecutionPipeline` 与 `CredentialUpdateCoordinator`，提升并发刷新稳定性与异常恢复能力。
- **测试套件拓展**: Harness 测试扩充至 388 项 Swift 测试（涵盖多账号凭证存储、刷新调度与映射），Pytest 契约测试扩充至 162 项。

### Changed

- 优化 `SubscriptionCard` 与 `HourlyLineCard` 面板卡片字号、布局及 24 点折线图渲染表现。
- 规范化请求结构 Schema 定义 (`request-v1.schema.json`)。

---

## [0.1] - 2026-08-05

### Added

- **macOS 原生菜单栏应用 (Bruce)**: 原生 SwiftUI 液态玻璃看板，支持 Agent 用量、成本、额度监控与趋势折线图展示。
- **订阅凭证校验与管理**: 支持 Kimi Web Tokens、火山引擎 API Key、DeepSeek API Key、Codex OAuth 以及 Antigravity OAuth 凭证导入、自动生成与 Keychain 安全存储。
- **DeepSeek 月度账本**: 支持 DeepSeek 月度 Token 消费追踪、每日差分增量算法与跨日持久化账本。
- **Claude & Grok 官方额度采集**: 自动探测 CLI Keychain 与登录会话，支持 Claude Code 与 Grok 官方订阅额度只读采集。
- **配额预警与系统通知**: 支持额度临界线计算、预警去重、通知中心提示与自动恢复判定。
- **模块化 Collector 架构**: 解耦 `pricing`、`runtime`、`quota_services`、`local_usage`、`codex_compat` 与 `quota_official` 独立数据管道。
- **多账号 Codex 刷新与故障恢复**: 支持多账号合并诊断、自动 Token 轮换、401 故障重试与去重。
- **本地 Harness 测试套件**: 提供 10 个独立 Swift Harness（352 项 Swift 测试）与 Python 契约测试（155 项 Pytest 测试）。

### Changed

- 打包脚本产物重命名为 `dist/Bruce.app` 与 `dist/Bruce.zip`（去除了 `test` 后缀）。
- 应用 Icon 正式采用原生 AppIcon 资源与规范文档。
