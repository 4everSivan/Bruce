# Bruce — Menu-Bar Chrome & Settings Spec (extracted from Swift source)

Source of truth: `apps/macos/Sources/` (read-only extraction, 2026-11-04).
Citation convention: `FileName.swift:line` — all paths relative to `apps/macos/Sources/`.
Anything not found in code is marked **not specified**; nothing here is invented.

Class-name shorthand used below:
`MBMetrics` = `BruceAppCore/MenuBarMetrics.swift`, `MBContent` = `BruceAppCore/MenuBarStatusItemContent.swift`,
`MBController` = `BruceApp/MenuBarStatusItemController.swift`, `MBViews` = `BruceApp/MenuBarViews.swift`,
`Settings` = `BruceApp/SettingsView.swift`.

---

## 1. Menu bar status item
### 1.1 What is actually drawn

The status item is one rasterized NSImage, **22pt** tall — `button.title = ""`, `.imageOnly`, `.scaleProportionallyDown` (`MBController.swift:318-324,389`). The drawn "icon" is not an SF Symbol but a hand-drawn single-orbit quota gauge (Bauhaus "The Orbit & Satellite", C183, `:378-383`); `content.iconName` only selects the drawing branch and the AX text (`:436-438`).
### 1.2 Indicator modes / contents

| Mode | Trigger | What renders |
|---|---|---|
| **Icon only** ("仅显示双环图标") | `menuBarIconOnly` preference true → `metricText` empty (`MBController.swift:297,312`) | Orbit gauge only, centered; no text. Status item length **28pt** (`:312-313`, `:48`) |
| **Gauge + 1–3 metrics** (default) | default metrics = minimumRemainingQuota, todayTokens, todayCost (`MBMetrics.swift:45-49`) | Orbit at x=13 + text starting x=25 (`MBController.swift:391,570`) |
| **Refreshing** | any module `state == .refreshing` (`MBController.swift:585-587`) | Track drawn in track color, satellite dot spins; text unchanged; `iconName = "arrow.clockwise"` |
| **Quota arc (ready)** | ratio > 0.005 and not unconfigured | Filled arc from 12 o'clock clockwise + satellite dot at arc end |
| **Zero-quota** | ratio ≤ 0.005 | No arc; single 1.8pt warning dot at top of orbit (`MBController.swift:526-532`) |
| **Unconfigured** | `iconName == "circle.dashed"` | Dashed track `[2.2, 2.2]`, no arc, no satellite (`:459-462`, `:490`) |
| **Warning / failed** | `exclamationmark.triangle` / `xmark.circle` | Arc color forced amber / red regardless of ratio (`:436-450`) |
### 1.3 Exact ring/arc geometry (points)

| Constant | Value | Source |
|---|---|---|
| Orbit radius `radiusOrbit` | **6.4** | `MBController.swift:393` |
| Orbit stroke `lineWidthOrbit` | **1.4**, `lineCapStyle = .round` on the filled arc | `:394`, `:500` |
| Satellite dot radius `radiusSatellite` | **1.8** (3.6pt diameter) | `:395` |
| Satellite highlight core radius | **0.75** (1.5pt diameter) | `:396` |
| Arc start angle | **90°** (12 o'clock), sweeps `-(ratio × 360°)` **clockwise** | `:496-498` |
| Center (with text) | x = **13**, y = **11** (22/2) | `:391-392` |
| Center (icon only) | x = width/2, y = 11 | `:391` |
| Text origin | x = **25**, width = `imageWidth − 25` | `:570-573` |
| Text vertical centering | `baselineY = round((22 − font.capHeight)/2 + font.descender)` | `:568` |
| Track dash (unconfigured) | `[2.2, 2.2]`, phase 0 | `:460-461` |

Angles are AppKit degrees (counter-clockwise positive); the UI reads as a clockwise fill from the top.
### 1.4 Status item width

- Default length constant **74pt**, icon-only **28pt** (`MBController.swift:47-48`).
- Dynamic width when text is present: `raw = 25 + textWidth + 8`, quantized to a **4pt step**
  (`ceil(raw/4)*4`), floor **64pt** (`:372-375`).
- 25 = left gauge + gutter; 8 = right comfortable padding (`:372` comment).
- Fonts: classic/glass = **12pt monospacedDigit regular**; Nothing = **12.5pt monospaced semibold**
  (`:366-367`, `:538-540`).
### 1.5 Colors (status item)

Dark (`MBController.swift:420-426`) / light (`:427-433`); comment hex is authoritative, srgb triples are what is fed to `NSColor`.

| Role | Dark | Light |
|---|---|---|
| Track | white **α0.22** | black **α0.18** |
| Green (healthy) | srgb(0.19, 0.82, 0.35) ≈ **#30D159** (comment `#30D158`) | srgb(0.08, 0.50, 0.24) ≈ **#14803D** (comment `#15803D`) |
| Amber (warning) | srgb(1.0, 0.72, 0.0) = **#FFB800** | srgb(0.85, 0.47, 0.02) ≈ **#D97706** |
| Red (critical) | srgb(1.0, 0.27, 0.23) ≈ **#FF453B** (comment `#FF453A`) | srgb(0.86, 0.15, 0.15) ≈ **#DB2626** (comment `#DC2626`) |
| Metric text | white **α0.95** | black **α0.90** |
| Separator (Nothing) | white **α0.36** | black **α0.34** |
| Satellite core | white | white α0.96 |

Image is **not** a template (`:581`) — pre-colored, so it does not auto-tint with the menu bar.
### 1.6 Tier thresholds

`MenuBarQuotaTier` (`MBContent.swift:41-52`): `critical` if ratio **< 0.20**; `warning` if **≤ 0.50**;
else `healthy`. Nil ratio → `healthy`. Priority over tier: failed icon → red, warning icon → amber
(`MBController.swift:440-450`).

Legacy note: onboarding still describes a **dual concentric ring** ("外母环/内子环", `WelcomeOnboardingPresentation.swift:44-47`, ≥30%/15–30%/<15%) while the shipped gauge is the single orbit above (`MBContent.swift:68-75` maps outer=average, inner=minimum, but only the average ratio is drawn). Use the single orbit on the site.
### 1.7 Metric catalog + label strings

| Enum case | Chinese title | SF Symbol | Value source |
|---|---|---|---|
| `minimumRemainingQuota` | **最低剩余额度** | `gauge.with.dots.needle.33percent` | `100 − usedPercent`, min over service windows (`MBMetrics.swift:12-40`, `:130-147`) |
| `averageRemainingQuota` | **平均剩余额度** | `chart.bar.xaxis` | mean of those values (`:100-103`) |
| `todayTokens` | **今日 Token** | `number` | Σ agent today totals (`:104-106`) |
| `todayCost` | **今日费用** | `dollarsign.circle` | `artifact.totalCostUsd` (`:112`) |
| `overallStatus` | **综合状态** | `waveform.path.ecg` | worst module state, excluding settings (`:160-189`) |

Max 3 metrics, drag-reorderable; empty selection falls back to defaults (`MBMetrics.swift:44-69`).
On the bar only **values** appear; Chinese titles appear in the accessibility label and in
Settings → 菜单栏指标 (`Settings.swift:579-608`).

Status icon per overall state (`MBContent.swift:107-127`): fresh/ready → `gauge`; refreshing →
`arrow.clockwise`; partial/stale/authRequired → `exclamationmark.triangle`; failed → `xmark.circle`;
notConfigured → `circle.dashed`.

Separator between metrics: two spaces `"  "` (classic/glass) or `" / "` (Nothing) (`MBContent.swift:80`).
In Nothing the slash is dimmed to the separator color (`MBController.swift:550-564`).
### 1.8 Numeric formatting (exact rules)

`MenuBarMetricFormatter` (`MBMetrics.swift:192-251`):

- Percentage: `Int(value.rounded())` + `"%"`; nil/non-finite → `"--"` (`:221-224`).
- Count (`:226-237`): `< 1000` plain; `< 1M` → /1_000 + `"k"` (**`"K"` in Nothing**); else /1_000_000 + `"M"`. Decimals (`:245-250`): ≥100 or integer → `%.0f`, else `%.1f`.
- Currency (`:239-243`): `"$%.*f"`, **3 digits when 0 < v < 0.01**, else **2**; nil → `"--"`.

Worked examples: 586_600_000 → `586.6M`; 1_200_000 → `1.2M`; 586_600 → `586.6k` (`586.6K` in Nothing); 999 → `999`; 1_000 → `1k`; 334.0 → `$334.00`; 0.0042 → `$0.004`; 42.4% → `42%`; nil → `--`.

⚠️ **Correction to the brief:** the code formats currency with **`$`**, not `¥` (`MBMetrics.swift:242`).
There is no CNY/¥ formatter anywhere in these files — a `¥334` label would be invented. Use `$334.00`.
### 1.9 Accessibility / tooltip

Button AX label fixed `"Bruce"` (`MBController.swift:272`); tooltip = `accessibilityLabel · metricText` (`:330-332`); content AX label = `"Bruce, <status title>, 剩余额度 N%, <title> <value>, …"` (`MBContent.swift:129-144`). Status titles come from `ModuleRunState.title` (out of scope).
### 1.10 Refresh animation

Timer **0.05s**, phase += **18°** per tick (≈360°/s) (`MBController.swift:340-349`); angle `= 90° − phase` (`:468`); satellite is always green here (`:478`); nothing runs when motion is suppressed (`:338`).
### 1.11 Related gauge in Settings preview

Settings preview re-draws the same orbit at **16×16pt** with the same 6.4/1.4/3.6/1.5 metrics (`Settings.swift:761-809`). Dashboard subscription meters are a different component: 5pt-high rounded bar, radius 3, three gradient tiers (`BruceApp/Views/SubscriptionCard.swift:721-777`).

---

## 2. Settings center window
### 2.1 Window

| Property | Value | Source |
|---|---|---|
| Title | **Bruce 设置** | `BruceApp/ApplicationBootstrap.swift:338` |
| Default content size | **1000 × 680** | `BruceAppCore/SettingsWindowMetrics.swift:19-20` |
| Minimum content size | **980 × 620** | `:23-24` |
| Sidebar width | **17.6%** of content width, floor **160pt** (176pt at 1000) | `:10,13,27-30` |
| Sidebar/content separator | **1pt** flat line | `:16`, `Settings.swift:81-84` |
| Structure | `HStack`: sidebar · 1px rule · scrollable pane | `Settings.swift:78-110` |
### 2.2 Sidebar categories (`BruceAppCore/SettingsCategory.swift:5-31`)

| `rawValue` | Chinese title | SF Symbol |
|---|---|---|
| `general` | **通用** | `gearshape` |
| `agentUsage` | **模型用量** | `chart.bar` |
| `modelPricing` | **模型计费** | `dollarsign.circle` |
| `subscription` | **订阅额度** | `cloud` |
| `consent` | **授权与隐私** | `checkmark.shield` |
| `maintenance` | **维护** | `wrench.and.screwdriver` |

Sidebar geometry (`Settings.swift:263-315`): row padding h10/v7, selected pill radius **5**, icon 13pt in an 18pt box, label 12.5pt (semibold when selected), accent bar **3pt** wide / radius 2 / inset 9, version 10.5pt at bottom, list top padding 14 and side padding 8. "维护" can carry an update badge (`有可用更新`, `SoftwareUpdatePresentation.swift:17`).
### 2.3 Pane layout idiom

Content `VStack(spacing: 14)`, padding h **24** / v **18**. Crumb `设置 / <分类名>` **11pt** text3 (`Settings.swift:89,338-344`); pane title **19pt semibold** (`:346-351`); group caption **11pt semibold**, tracking **0.4**, text3 (`:353-359`). `FluentCard` = surface card; `FluentRow(title, sub:, divided:)` = 13pt title + 11.5pt subtitle with trailing control, padding h14/v10, `divided` adds a 1pt rule (`:586-604`).

Fluent tokens (light / dark) — `BruceApp/Settings/FluentSettingsChrome.swift:9-38`:

| Token | Light | Dark |
|---|---|---|
| window | `#FAFAFA` | `#242424` |
| nav (sidebar) | `#F3F3F3` | `#1F1F1F` |
| surface (card) | `#FFFFFF` | `#2C2C2C` |
| surfaceHover / navSelected | `#F0F0F0` | `#333333` |
| separator | `#E2E2E2` | `#3A3A3A` |
| borderStrong | `#CFCFCF` | `#4A4A4A` |
| text / text2 / text3 | `#1B1B1B` / `#5C5C5C` / `#9A9A9A` | `#F2F2F2` / `#A8A8A8` / `#6E6E6E` |
| accent | `#0B5CBB` | `#4C9CFF` |
| ok / warn / danger | `#4A9E5C` / `#D4A843` / `#E5534B` | same |

Control idiom: `FluentSegmentedPicker` for 2–3 mutually exclusive options, `Toggle(...).toggleStyle(.switch)`
for booleans, trailing `fluentButton()` / `.fluentButton(.primary)` / `.fluentButton(.danger)`.
### 2.4 通用 pane (rows, in order) — `Settings.swift:364-612`

| Row title | Subtitle | Control |
|---|---|---|
| 配色模式 | 立即作用于菜单栏面板与设置窗口 | segmented: 跟随系统 / 浅色 / 深色 (`:372-386`) |
| 界面风格 | …经典/液态玻璃/Nothing… | segmented: 经典 / 液态玻璃 / Nothing (`:388-405`) |
| 模糊风格 (only in Liquid Glass) | 标准与通透为系统液态玻璃, 哑光退化为材质质感 | segmented: 标准 / 通透 / 哑光 (`:408-424`) |
| 界面动效 | 关闭后全应用不做过渡动画; 「始终播放」会忽略系统「减弱动态效果」 | segmented: 跟随系统 / 始终播放 / 始终关闭 (`:428-443`) |
| 仪表盘卡片布局 | 纵向级联可滚轮纵览… | segmented: 纵向级联 / 顶栏 Tab (`:446-460`) |
| 刷新间隔 | …订阅额度最短 3 分钟查询一次, 遇 429 限流时自动冷却 | presets 3 / 6 min + custom 1–1440 (`:462-468`) |
| 开机自启动 | 开机时自动启动 Bruce 并在后台常驻菜单栏 | switch + "打开系统设置" (`:502-526`) |
| 凭据存储 | 统一管理 Bruce 保存的订阅凭证访问权限 | 未配置/访问被阻断 + 配置 (`:528-554`) |
| 外部 CLI 来源 | 仅允许已明确开启的 Claude / Grok 本机来源, 不保存凭证内容 | 管理 (`:556-562`) |

> **C209 增量注记（2026-11-05）**：原「锁屏暂停订阅刷新」「额度预警气泡」两行已退役，两项行为恒开、不再有开关；本表行号引用基于 2026-11-04 源码快照，删除这两行后，其后的行号整体前移约 32 行，其余行标题与顺序不变。

Then caption **菜单栏指标** (`:579`) with: 菜单栏实时预览 strip (`:813-823`), row **仅显示图标** /
"开启后菜单栏隐藏全部文本指标, 仅保留高精度配额环规图标" + switch (`:586-602`), and a drag-reorder
metric list when the toggle is off (`:606-608`).
### 2.5 模型用量 pane — `BruceApp/Settings/AgentUsageWorkbenchView.swift:18-51`

Vertical stack: header toolbar (segmented 今日 / 近 7 天 / 近 30 天 / 本月 / 全部历史 + 导出 CSV 账单 / 导出 JSON 明细, `:59-82`); 4 KPI tiles **总 Token** (`… Tokens`), **费用** (`… /1M`), **缓存收益** (tag 已省), **活跃 Agent** (`N 个`, tag 全域) (`:97-127`); then cards 时序趋势 (`TimelineChartCard.swift:44`, sub 多维度用量走势与峰值下钻分析), 模型分布 (`CanonicalModelAnalyticsCard.swift:43`, sub 自动归并同类模型…), Agent 表现 (`AgentComparisonMatrixCard.swift:17`, sub 透视各 Agent 用量占比、Token 结构与关联工程), Token 构成与时段 (`TokenCompositionCard.swift:21`, sub Prompt Cache 专项分析; tiles Prompt Input / Model Output / Prompt Cache Read / Cache Creation, `:58-85`), and the session-probe footer (会话来源与采集探针 `:187`; note 所有会话仅在本机分析，绝不上报远程服务器 `:262`).
### 2.6 模型计费 pane — `BruceApp/Settings/ModelPricingSettingsView.swift`

Title block **今日 TOKEN 预估折算总费用** + 基于当前本机全部活跃 Agent 真实 Token 吞吐量进行折算 (`:165-168`), `/ <tokens>` suffix (`:181`). **Pricing table columns** (`:319-334`): **模型与厂商** · **今日用量** · **来源** · **输入单价** · **输出单价** · **缓存命中** · **今日折算** · **操作**; price cells append `/1M` (`:416,427,440`); 来源 = **人工校准** / **内置基线** (`:394,401`), empty = `—`; empty search state **未找到匹配的模型定价规则** (`:292`). Calibration sheet: 模型单价人工校准 (`:617`), 当前已校准 (`:626`), 备注说明 (可选) (`:658`), 实时折算公式与效果预估 (`:669`), prefix `$` (`:728`); reset confirm 此操作将清除所有人工校准与自定义模型的单价覆盖配置。 (`:156`); config hint 配置文件实时映射 (onboarding-v1.json) (`:504`) at `~/Library/Application Support/Bruce/config/onboarding-v1.json` (`:508`), `pricingOverrides` node (`:521`).
### 2.7 订阅额度 pane — `BruceApp/SettingsView+SubscriptionPane.swift:14-65`

Caption **云端额度凭证** → card of provider rows (drag handle, 26pt brand badge, name + subtitle, plan tag, status tail, 配置 button, enable switch, `SettingsView+SubscriptionPane.swift:126-150`); empty row **尚未配置任何订阅 Provider** / 从下方添加服务 (`:21`); add row **添加服务** / 只列出尚未配置的 Provider, 添加后打开配置窗口 + `ProviderPopUpPicker` (**选择 Provider**) + **添加…** (`:25-48`); footer 配置并启用后, Agent 用量将在统一授权生效时查询对应云端额度; 拖拽行调整看板展示顺序 (`:58`); then `EgressSettingsCard` (出口IP检查, `EgressSettingsCard.swift:21`). Jev is hidden from this pane (`:69`).
### 2.8 授权与隐私 pane — `Settings.swift:1109-1185`

Single card: toggle row **模型用量** / 允许按授权范围采集本机会话用量; body heading **授权后应用将:**
followed by bullet lines (`核心句式见 §5`); status **当前授权有效** + button **撤销全部授权**, or
button **确认授权**.
### 2.9 维护 pane — `Settings.swift:1190-1272` (the "维护/更新" actions)

Order: `paneCaption(UpdateCopy.caption)` → `SoftwareUpdateCard()` → `paneCaption(PricingCopy.caption)`
→ `PricingCatalogSyncCard()` → `paneCaption("数据")` → card → `paneCaption("诊断")` → card.

| Group | Row | Subtitle | Action |
|---|---|---|---|
| 软件更新 | 自动检查更新 | 启动 30 秒后静默检查一次, 之后每 24 小时一次; 检查失败不打扰 | switch (`SoftwareUpdatePresentation.swift:10-11`) |
| 软件更新 | 当前版本 | — | value; dev builds show 开发版本 (`:12-14`) |
| 软件更新 | 检查更新 | 正在检查更新… / 发现新版本 / 检查失败 | button 检查更新 (`:15-23`) |
| 模型价格表 | 自动同步价格表 | 启动 30 秒后静默同步一次, 之后每 24 小时一次; 同步失败不打扰 | switch (`PricingCatalogSyncPresentation.swift:10-11`) |
| 模型价格表 | 当前价格表 | 内置基线 · N 款模型 / GitHub 已同步 · N 款模型 | value (`:82-91`) |
| 模型价格表 | 同步价格表 | 上次同步 今天 HH:mm / M月d日 HH:mm / — | buttons **同步更新** + **恢复内置** (`:13-14`, `:92-101`) |
| 数据 | 清理用量缓存 | 仅删除本应用快照, 不影响配置, 凭证与账单统计 | 清理 (danger) (`Settings.swift:1200`) |
| 数据 | 导出账单 | token 用量与花费统计 CSV | 导出… (`:1207`) |
| 诊断 | 诊断信息 | 最近采集错误与模块状态, 脱敏 JSON | 预览 (`:1228`) |
| 诊断 | 导出诊断包 | 脱敏后 zip, 不含 Artifact 与凭证 | 导出… (`:1241`) |

Cache-clear confirm: **确认清理缓存?** / 仅删除本应用生成的快照缓存, 配置, 凭证与账单统计不受影响 / 清理 · 取消 (`Settings.swift:1254-1265`). Billing filename `Bruce-billing-yyyyMMdd-HHmm.csv` (`:1303-1307`).

---

## 3. Brand colors, badges, glyphs
### 3.1 Provider brand colors — `BruceAppCore/ProviderBrandPalette.swift:12-39`

| providerID(s) | Hex | Notes |
|---|---|---|
| `kimi` | **#0a84ff** | |
| `deepseek` | **#4d6bfe** | |
| `volcengine` | **#ff6a00** | |
| `zhipu` | **#2D2D2D** | official dark tile since C026 (was `#3859ff`) |
| `codex`, `openai` | **#10a37f** | |
| `claude` | **#d97757** | |
| `grok` | **#111111** | |
| `opencodeGo`, `opencode-go`, `opencode` | **#8a63d2** | |
| `stepfun` | **#0c5efc** | |
| `jev` | **#e551ba** | |
| `cline` | **#18181b** | |
| *(default / unknown)* | **#8e8e93** | neutral gray fallback |

`isDarkBrand` = `grok`, `zhipu`, `cline` (`:43-50`) — on dark/Nothing surfaces glyph and monogram fall back to secondary gray (brand color unreadable).
### 3.2 Agent / model brand identity — `BruceAppCore/AgentBrandPalette.swift`

Assets are `(imageName?, glyphID?, tileHex, markHex, monogram)`; order: official bitmap → glyph on brand tile → monogram (`:5-13`).

| agentID | imageName | glyphID | tile | mark | monogram |
|---|---|---|---|---|---|
| `zcode` | `agent-zcode` | `zcode` | `#0A0A0A` | `#FFFFFF` | `Z` (`:49-53`) |
| `claude-code` | — | `claude` | `#F2EEE6` | `#D97757` | `C` (`:54-58`) |
| `codex` | `agent-codex` | `codex` | `#0A0A0A` | `#FFFFFF` | `X` (`:59-63`) |
| `kimi-code-cli`, `kimi-work` | — | `kimi` | `#0B0B0B` | `#FFFFFF` | `K` (`:64-67`) |
| `opencode` | — | `opencodeGo` | `#1C1C1E` | `#CFCECD` | `O` (`:68-71`) |
| `codebuddy` | `agent-codebuddy` | — | `#5B3DF5` | `#FFFFFF` | `C` (`:72-76`) |
| `dsh` | — | `deepseek` | `#FFFFFF` | `#4D6BFE` | `D` (`:77-81`) |
| `grok` | — | `grok` | `#0B0B0B` | `#FFFFFF` | `G` (`:82-85`) |
| `pi` | — | — | `""` | `""` | `π` (`:86-88`) |
| *(unknown)* | nil | — | — | — | first character fallback (`:46`) |

Model-key matching (substring, first match wins, `:105-127`):

| Key needles | glyphID | tile | mark | monogram |
|---|---|---|---|---|
| `claude`, `sonnet`, `opus` | claude | `#F2EEE6` | `#D97757` | C |
| `deepseek` | deepseek | `#FFFFFF` | `#4D6BFE` | D |
| `glm`, `zhipu` | zhipu | `#FFFFFF` | `#1F63EC` | G |
| `gpt`, `openai`, `codex` | codex | `#FFFFFF` | `#0B0B0B` | G |
| `kimi`, `k3` | kimi | `#0B0B0B` | `#FFFFFF` | K |
| `grok`, `xai` | grok | `#0B0B0B` | `#FFFFFF` | G |
| `cline` | cline | `#0B0B0B` | `#FFFFFF` | C |
### 3.3 Badge / glyph shape rules

**Provider badge** (`BruceApp/Views/ProviderBrandBadge.swift:19-62`): sizes dashboard **15pt** / settings row **26pt** / dialog title **20pt** (`:19-21`); radius `max(3, size × 0.2)` continuous (`:29-31`) → 15pt ⇒ **3pt**, 26pt ⇒ **5.2pt**; tile = brand color, or brand color at **α0.16 dark / α0.12 light** in Nothing (`:66-71`); glyph white (or brand color in Nothing), monogram = first char uppercase **bold at `size × 0.6`** (`:54-60`); glyph fills **58%** of the tile (`glyphBoxFraction = 0.58`), aspect-fit centered, so a 15pt badge draws ≈**8.7pt** (`ProviderBrandGlyph.swift:16-37`); no glyph ⇒ monogram (fail-closed).

**Agent badge** (`BruceApp/Views/AgentBrandBadge.swift:10-30`), three tiers: sizes settings **20pt** / dashboard **14pt** / model chip **12pt** (`:25`); radius `max(1, size × 0.27)`, Nothing forces **1** (`:28,48-50`). **True-color tier** (size ≥ 14, not Nothing): bitmap else brand tile + glyph **plus a 1.2pt series-color ring** matching the chart line (`:12-14,57`); **series-color tier** (size < 14): series-color tile + white glyph; **Nothing tier**: monochrome 1pt square outline + green-ramp glyph. Monogram **bold `size × 0.54`**, `minimumScaleFactor 0.6` (`:87-90`); decorative, AX-hidden (`:44`). For HTML: provider chips = rounded tiles, white glyph at ~58% box, monogram 0.6×; agent chips at 14–20pt add the 1.2pt ring.

---

## 4. Animation & motion policy
### 4.1 The app-level `prefers-reduced-motion` equivalent

`MotionPreference` has three values — `system` / `always` / `never` — with a single decision point
(`BruceOnboardingCore/OnboardingConfiguration.swift:129-143`):

| Preference | `suppressesMotion(systemReduceMotion:)` |
|---|---|
| `system` | returns the system **Reduce Motion** value |
| `always` | `false` (ignores system setting, always plays) |
| `never` | `true` (always suppressed) |

The result is injected once per SwiftUI root through a custom writable environment key
`\.motionSuppressed` because SwiftUI's `accessibilityReduceMotion` is read-only
(`BruceAppCore/MotionPolicy.swift:3-20`). Views pass `nil` animation when suppressed; looping
animations are simply not mounted (`MenuBarViews.swift:53-59, 80-86`).
### 4.2 Durations, curves, springs

| Motion | Value | Source |
|---|---|---|
| Panel curtain **open** | **0.24s**, `cubic-bezier(0.22, 0.61, 0.36, 1.0)` | `DashboardPanelAnimationPolicy.swift:47`, `MenuBarStatusItemController.swift:742-744` |
| Panel curtain **close** | **0.14s**, `.easeIn` | `:49`, `MBController.swift:820-821` |
| Curtain collapsed height | **20pt** (top edge fixed) | `:51`, `MBController.swift:726-734` |
| Window content resize | **0.30s**, `.easeInOut` | `BruceApp/Views/PanelCardContainer.swift:179-184`, `MBController.swift:894-898` |
| Resize coalescing window | **30ms**, single animation per burst | `MBController.swift:852-865` |
| Resize animates only when | visible ∧ !suppressed ∧ Δheight > **2pt** ∧ Δx ≤ **1pt** | `MBController.swift:886-889` |
| Tab / card swap | **0.24s** `.easeOut`, horizontal slide + opacity; explicitly **no spring** (overshoot reads as bounce) | `MenuBarViews.swift:535, 648-657` |
| Card body collapse fade | **0.22s** `.easeOut` | `BruceApp/Views/HourlyLineCard.swift:76` |
| Toast dismiss | **0.20s** `.easeInOut` | `Settings.swift:111` |
| Status-item refresh spin | timer **0.05s**, **+18°**/tick | `MBController.swift:340-349` |
| Footer refresh icon spin | `linear 1s`, `repeatForever` | `MenuBarViews.swift:56` |
| Header status dot pulse | `easeInOut 0.9s`, `autoreverses` | `MenuBarViews.swift:83` |
| Freeze/resume | suppress ⇒ curtain transition skipped, panel shown/hidden instantly at α1/α0 | `MBController.swift:717-724, 799-806` |

Meter motion (subscription card), single source `BruceAppCore/MeterMotionPolicy.swift:53-77`:

| Kind | Curve |
|---|---|
| `fill`, `percent` | **spring(duration 0.85, bounce 0)** |
| `balance` | **spring(duration 0.6, bounce 0)** |
| `levelCrossfade` | `easeOut 0.34` |
| `thresholdColor` | `easeOut 0.25` |
| `highlight` | `easeOut 0.20` |
| `sheen` | `timingCurve(0.33, 0, 0.2, 1)` duration **0.85** |

Also: `minimumFractionDelta = 0.0005` (below this, no highlight/sheen), `highlightHoldSeconds = 0.95`
(`MeterMotionPolicy.swift:55-58`). All springs use **bounce 0** — no overshoot anywhere in metering.
### 4.3 Gating rules (`BruceAppCore/DashboardPanelAnimationPolicy.swift:8-56`)

| Animation | Allowed when |
|---|---|
| Hero / status pulse (`allowsHero`) | `panelVisible && !motionSuppressed` |
| Heatmap (`allowsHeatmap`) | `panelVisible && isNothing && filled && !motionSuppressed` |
| Refresh progress (`allowsRefreshProgress`) | `panelVisible` only (targeted refresh up to 90s) |
| Hourly bar growth (`allowsHourlyGrowth`) | `panelVisible && !motionSuppressed` |
| Scrollbar suppression | `panelVisible` only |
| Curtain transition | `!motionSuppressed` |

Reason: `orderOut` keeps the view hierarchy alive, so hidden panels must *remove* animation-bearing
branches, not just reset state (`:3-7`).
### 4.4 Three hourly-card style names

**Not specified.** No style enum for the hourly card exists in these files; the hourly card is a single
view (`BruceApp/Views/HourlyLineCard.swift`, title **Agent 用量**, `:61`). What does exist as a triad is the
**three dashboard cards** (`BruceAppCore/PanelModels.swift:891-907`): `usage` **Token 用量**
(`chart.bar.xaxis`), `subscription` **订阅与配额** (`creditcard`), `hourly` **Agent 活跃**
(`waveform.path.ecg`). If the site needs three hourly styles, they must be designed, not cited.

---

## 5. Copy inventory (Chinese original → English, code-verified)

All strings below exist verbatim in the cited file:line.

**Brand / product**
| Chinese | English | Source |
|---|---|---|
| Bruce | Bruce | app name, `MenuBarViews.swift:297,305` |
| LOCAL-FIRST | LOCAL-FIRST | `WelcomeOnboardingPresentation.swift:9` |
| Bruce 设置 | Bruce Settings | `ApplicationBootstrap.swift:338` |

**Onboarding headlines**
| Chinese | English | Source |
|---|---|---|
| 欢迎使用 Bruce | Welcome to Bruce | `WelcomeOnboardingPresentation.swift:8,21` |
| STEP 01 · WELCOME & LOCAL SCAN | STEP 01 · WELCOME & LOCAL SCAN | `:20` |
| Bruce 已在后台完成本机只读探测。点击下方主按钮即可一步开启本地 Token 与费用统计，无需逐项翻找设置。 | Bruce has already finished a read-only scan of this Mac in the background. One click on the primary button below turns on local token and cost tracking — no digging through settings. | `:22` |
| 本机 AI Agent 会话源（只读扫描） | Local AI-agent session sources (read-only scan) | `:23` |
| 一步启用：本地会话统计 + 本机 0600 凭据存储 | Enable in one step: local session tracking + on-device 0600 credential storage | `:25` |
| 只读扫描已发现的 Agent 目录与 CC Switch 数据库（每 30 分钟自动刷新）；订阅凭据统一保存在本机受保护文件（权限 0600），彻底告别系统钥匙串频繁弹窗。可随时在「设置 → 授权与隐私」撤销。 | Read-only scans of discovered agent directories and the CC Switch database (auto-refresh every 30 minutes); subscription credentials live in one protected local file (mode 0600), ending the constant macOS Keychain prompts. Revocable anytime in Settings → Consent & Privacy. | `:26` |
| 启用本地统计并继续 → | Enable local tracking and continue → | `:27` |
| STEP 02 · SUBSCRIPTION QUOTA | STEP 02 · SUBSCRIPTION QUOTA | `:29` |
| 可选步骤 · 可随时跳过 | Optional step · skip anytime | `:30` |
| 连接云端订阅额度 | Connect cloud subscription quotas | `:31` |
| 监控 5 小时滑动窗、周限额与 API 余额预警。若本机已登录 CLI 或 CC Switch，可直接一键只读导入；也可跳过此步，先看本地 Token 统计。 | Monitors the 5-hour rolling window, weekly limits and API balance alerts. If a CLI or CC Switch is already signed in locally you can import read-only in one click; or skip and start with local token stats. | `:32` |
| 发现本机已登录凭据（免填 Key 一键导入） | Found credentials already on this Mac (import in one click, no key entry) | `:33` |
| 一键只读导入 | Read-only import | `:34` |
| 支持的服务商（10 家）· 也可在「设置 → 订阅额度」随时添加 | Supported providers (10) · add more anytime in Settings → Subscription | `:36` |
| 稍后在设置中配置 | Configure later in Settings | `:38` |
| STEP 03 · APPEARANCE & SHORTCUT | STEP 03 · APPEARANCE & SHORTCUT | `:41` |
| 定制你的菜单栏看板 | Customize your menu-bar dashboard | `:42` |
| 完成最后一步外观与热键偏好，点击「完成并打开看板」即刻在菜单栏展开实时监控。 | Finish appearance and hotkey preferences, then hit "Finish and open dashboard" to see live monitoring in the menu bar. | `:43` |
| 完成并打开看板 ↵ | Finish and open dashboard ↵ | `:48` |
| 欢迎与使用引导 | Welcome & onboarding | `:50` |
| 重新打开欢迎向导 | Reopen the welcome wizard | `:52` |

**Privacy / consent**
| Chinese | English | Source |
|---|---|---|
| 100% 本地只读闭环 | 100% local, read-only, closed loop | `:10` |
| 不代理对话流量、不修改外部会话数据库（SQLite 强制 mode=ro），凭据以 POSIX 0600 权限保存在本机目录。 | Does not proxy conversation traffic and never writes to external session databases (SQLite forced to mode=ro); credentials are stored on this Mac with POSIX 0600 permissions. | `:11` |
| 授权后应用将: | Once authorized, the app will: | `Settings.swift:1129` |
| 扫描本机 Agent 会话目录和 CC Switch 数据库 (只读) | Scan local agent session directories and the CC Switch database (read-only) | `:1132` |
| 每 N 分钟自动刷新已授权模块 | Auto-refresh authorized modules every N minutes | `:1133` |
| 未配置启用的订阅额度 Provider, 不会访问云端额度接口 | No enabled subscription provider configured — cloud quota endpoints are never contacted | `:1137` |
| 确认授权后查询已启用订阅 Provider 的云端额度: … | After consent, query cloud quotas for enabled providers: … | `:1141` |
| 可随时在此撤销授权暂停采集 | Revoke authorization and pause collection here at any time | `:1143` |
| 当前授权有效 | Authorization currently active | `:1155` |
| 撤销全部授权 / 确认授权 | Revoke all / Confirm authorization | `:1162,1168` |
| 所有会话仅在本机分析，绝不上报远程服务器 | All sessions are analyzed on this Mac only and never uploaded to a remote server | `AgentUsageWorkbenchView.swift:262` |

**Empty states**
| Chinese | English | Source |
|---|---|---|
| 未配置模块, 前往设置 | No modules configured — go to Settings | `MenuBarViews.swift:751` |
| 打开设置 | Open Settings | `:755` |
| 尚未添加订阅 / 添加并验证账号后，显示 5 小时与每周额度。/ 添加订阅（未配置） | No subscription added yet / Add and verify an account to see 5-hour and weekly quotas. / Add subscription (`notConfigured`) | `SubscriptionEmptyState.swift:66-73` |
| 暂未获取到额度 / 这次采集没有返回订阅额度，可手动刷新重试。/ 刷新额度（无数据） | No quota retrieved yet / This collection returned no quota; refresh to retry. / Refresh quota (`noData`) | `:57-64` |
| 尚未配置任何订阅 Provider / 从下方添加服务 | No subscription provider configured yet / Add a service below | `SettingsView+SubscriptionPane.swift:21` |
| 暂无活跃 Agent 消耗数据 | No active agent usage data | `AgentComparisonMatrixCard.swift:254` |
| 暂无模型消耗数据 | No model usage data | `CanonicalModelAnalyticsCard.swift:299` |
| 当前时间跨度暂无活跃用量点 | No active usage points in this range | `TimelineChartCard.swift:284` |
| 未找到匹配的模型定价规则 | No matching model pricing rule found | `ModelPricingSettingsView.swift:292` |
| STANDBY / N AGENTS ACTIVE / N AGENTS RUNNING | STANDBY / N AGENTS ACTIVE / N AGENTS RUNNING | `MenuBarViews.swift:395,402,411` |

**Quota warnings**
- Tier ladder `[50%, 80%, 95%]` on the 5-hour window (`BruceAppCore/QuotaAlertEvaluator.swift:37-57`).
- **No headline sentence exists** for the quota bubble: the alert shows service name + window label +
  `percent%` + meter + seconds countdown; the string is assembled, not a fixed sentence
  (`BruceApp/Views/QuotaAlertBubbleView.swift:151-254, 375-412`). Website copy must be written fresh.
- Meter tier semantics (used %, all themes): `<50` normal green, `50–79` warning orange, `≥80` critical red
  (`BruceApp/Views/SubscriptionCard.swift:781-793`). Note this is **used**, the inverse of the menu-bar
  gauge which shows **remaining**.

**Pricing / update status lines**
| Chinese | English | Source |
|---|---|---|
| 模型价格表 | Model price list | `PricingCatalogSyncPresentation.swift:8` |
| 自动同步价格表 | Auto-sync price list | `:9` |
| 同步更新 / 恢复内置 | Sync now / Restore built-in | `:13-14` |
| 正在从 GitHub 同步模型价格表… | Syncing the model price list from GitHub… | `:15` |
| 同步失败 / 重试 | Sync failed / Retry | `:16`, `:20` |
| 内置基线 · N 款模型 / GitHub 已同步 · N 款模型 | Built-in baseline · N models / Synced from GitHub · N models | `:86-90` |
| 已是最新价格表 · … | Already up to date · … | `:120` |
| 软件更新 / 检查更新 | Software update / Check for updates | `SoftwareUpdatePresentation.swift:9,16` |
| 发现新版本 / 检查失败 | New version available / Check failed | `:20,23` |
| 当前安装位置不支持自动更新, 请从发布页下载新版本 | This install location doesn't support auto-update — download the new version from the release page | `:26` |

No standalone tagline exists beyond **LOCAL-FIRST** (`:9`); a marketing tagline would be new copy.

---

## 6. Factual product summary (from code)

Bruce is a native macOS menu-bar companion that monitors **local AI-agent token usage, estimated cost,
and cloud subscription quotas** entirely on the user's machine: it read-only scans discovered agent
session directories and the CC Switch SQLite database (forced `mode=ro`), aggregates tokens and cost
against a built-in/synced per-model price list, and optionally queries the cloud quota endpoints of
about ten subscription providers (Kimi, DeepSeek, Volcengine, Zhipu, Codex/OpenAI, Claude, Grok,
OpenCode Go, StepFun, Jev, Cline) for 5-hour and weekly windows. Its status item is a compact
single-orbit quota gauge plus up to three live metrics (minimum/average remaining quota, today's
tokens, today's cost) rendered at 22pt with tiered green/amber/red coloring; clicking it drops a
440pt-wide borderless glass panel (`MenuBarViews.swift:204`) with Token 用量, 订阅与配额 and Agent 活跃 cards, switchable between a
stacked and a tabbed layout, with refresh, appearance, settings and quit in the footer. A Fluent-styled
six-pane settings window (通用 / 模型用量 / 模型计费 / 订阅额度 / 授权与隐私 / 维护) handles appearance and
motion policy, the deep analytics workbench, per-model price calibration, provider credentials and egress
routes, consent, plus updates, price-list sync, cache clearing, CSV billing export and redacted
diagnostics. Credentials are kept in `~/Library/Application Support/Bruce/credentials.json` at mode 0600,
and every animation funnels through one motion policy that honors Reduce Motion (or an explicit
always-on/always-off override).

---

### Gaps / "not specified"

- ¥/CNY currency formatting: **does not exist** (only `$`, `MenuBarMetrics.swift:242`).
- Three hourly-card style names: **do not exist** (see §4.4).
- App marketing tagline beyond `LOCAL-FIRST`: **does not exist**.
- Fixed quota-warning headline sentence: **does not exist** (bubble is data-composed).
- Menu-bar metric Chinese labels are not drawn on the bar; only in AX/settings.
