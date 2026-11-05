# Bruce menu-bar panel — exact visual + interaction spec

Extracted from Swift source (read-only). Citations are `File.swift:line`, paths relative to
`apps/macos/Sources/`. No value below is invented; anything absent from code is marked **not specified**.

Source files: `BruceApp/Views/UsageHeroCard.swift` (U), `BruceApp/Views/HourlyLineCard.swift` (H),
`BruceApp/Views/SubscriptionCard.swift` (S), `BruceApp/Views/PanelCardContainer.swift` (P),
`BruceApp/MenuBarViews.swift` (M, panel frame — the only file that owns panel width/footer),
`BruceAppCore/PanelModels.swift` (PM), `BruceAppCore/UsageMapping.swift` (UM),
`BruceAppCore/DashboardPanelSizing.swift` (DPS), `BruceGlassSurfaceCore/GlassSurfacePlan.swift` (GSP),
`BruceApp/GlassTheme.swift` (GT), `BruceApp/NothingFont.swift` (NF).

---

## 1. Panel frame

| Property | Value | Source |
|---|---|---|
| Total width | **440 pt** (fixed, both layout modes) | M:204, M:276 |
| Panel corner radius | **14 pt**, `.continuous` | M:248–250 |
| Panel border | 1 pt inside stroke. Classic/Liquid: black 10% (light) / white 14% (dark). Nothing: `#E8E8E8` light / `#222222` dark | M:206, M:255–265 |
| Panel padding / card gaps | horizontal **12** (Nothing 10), top **10** (Nothing 8), bottom **10**, inter-card gap **10** (Nothing **8**) | M:665, M:682–684 |
| Height | content-driven = header + card stack + footer; clamped by `DashboardPanelSizingPolicy` with screen `edgeInset = 8` | M:273–279, DPS:13 |
| Panel window | NSPanel `.borderless`, level `.statusBar`, `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = true` (`false` for Nothing) | MenuBarStatusItemController.swift:23, :209–213, :675–679 |

### Background material (3 themes: `classic` | `liquidGlass` | `nothing`, ThemeResolution.swift:8–10)

| Theme / glass style | Backend | Panel | Card |
|---|---|---|---|
| liquidGlass + `.regular` | `nativeLiquidGlass` (NSGlassEffectView / `.glassEffect`) | glass, tint white 46% / black 30% | filled token white 36% (light) / 9% (dark) |
| liquidGlass + `.clear` | `nativeLiquidGlass` | glass clear, tint white 34% / black 42% | white 19% / 5.5% |
| liquidGlass + `.material` | `appKitMaterial` (NSVisualEffectView) | matte, white 20% / black 16% | white 62% / 7.5% |
| classic (default fallback) | `appKitMaterial` | `.popover` (light) / `.hudWindow` (dark), tint `#F6F8FC` 92% / black 42% | white 96% / white 6.5% |
| nothing | `flatMonochrome` | flat `#F5F5F5` / `#000000` | flat `#FFFFFF` / `#111111`, 1 px border |

GSP:64–133 (routing), GSP:240–397 (all token values), DashboardGlassPanelController.swift:150–256 (NSGlassEffectView / NSVisualEffectView material mapping).

### Card shadow
`.shadow(color: cardShadow, radius: 5, y: 1)`; Nothing → radius **0** (P:46–50).
Card shadow tokens: classic light `#0F172A` @5%, classic dark black @15%; regular light `#2C3A52` @8%, dark black @14%; clear light `#2C3A52` @4%, dark black @8%; matte light `#2C3A52` @9%, dark black @20%; nothing @0 (GSP:246–381).

### Top header (not in the brief, but part of the frame)
- Row: status dot (12 pt halo + 6 pt dot) + `Bruce` 11.5 pt bold monospaced; right side = 3-icon tab switcher (tabbed mode) or `● N AGENTS ACTIVE` / `STANDBY` 9.5 pt medium monospaced (M:292–324).
- Padding horizontal **14**, vertical **9** (M:322–323); 1 px hairline under it (M:482–486).
- Tab pill: icon 11 pt semibold in 27×22 box (Nothing 10.5 pt in 24×20), radius 2, selected fill primary 10–16% (Nothing: primary solid) (M:337–355).
- Refresh-in-progress dot pulses `easeInOut 0.9s` autoreverse; 12 pt halo 0.35↔0.12, 6 pt core 1.0↔0.42 (M:65–87).

### Footer bar
- 1 px hairline: light `white 0.5`, dark `primary 0.15`; Nothing `#E8E8E8`/`#222222` (M:809–824).
- Row: `HStack(spacing: 8)`, padding horizontal **12**, vertical **9** (M:840, M:886–887).
- Buttons: **icon-only** (`.labelStyle(.iconOnly)`, M:884), padding h **9** / v **6**, radius **6**, 1 px border, shadow r3 y1 (P:152–171).
  - Refresh `arrow.clockwise` — spins `linear 1s` repeatForever while refreshing (M:51–58, M:846–857); ⌘R shortcut (M:858).
  - Appearance `circle.lefthalf.filled` → `sun.max` → `moon` (M:20–28, M:864–872). *This 4th button exists in code; brief listed only 3.*
  - Settings `gearshape` (M:877–879).
  - Quit `power` (M:880–882).
- Order: refresh, appearance, `Spacer()`, settings, quit (M:840–883).
- Nothing button variant: Space Mono 11 pt uppercase, tracking 0.66, radius **6** (comment says 5, code uses 6), pads h9/v6, 1 px `#CCCCCC`/`#333333` (P:116–141).

### Drag handle
- 2×3 dot grid, dot **2.2 pt** circle (Nothing: 2×2 square), H gap 3 / V gap 2.5, pad h3 v4, hover bg radius 2 (P:342–385).
- Only rendered when the card is **collapsed**: slot width **26** (Nothing 24) collapsed, **0** expanded, animates with the collapse (P:319).
- Hover reveals the chevron in the header; drag reorders cards with `easeOut 0.15` (P:411).

---

## 2. Cards, top to bottom

Stack order is user-reorderable; default `usage → subscription → hourly` (PM:846–860, M:666).

### 2.0 Shared card container (`PanelCardContainer`)
- Radius **8 pt** `.continuous` (P:23–28). *Header comment says 16 and Nothing "5" — stale; the single shape is 8.*
- Padding horizontal **15**, vertical **13** (P:39–40); 1 px inside border (P:43).
- Background per theme table in §1; Nothing = opaque flat + 1 px border, no highlight, no shadow.

### 2.1 Collapsible header (all three cards)
- Row: [drag slot] [title (fixed **92** wide, Nothing **84**) · 15 gap (Nothing 8) · status/mini · chevron].
- Title **12.5 pt semibold**, `Color.primary` (Nothing `#666666`/`#999999` 11.5 pt semibold) (P:236–258).
- Chevron `chevron.right` **9 pt semibold**, `.secondary`, hidden until row hover (`easeInOut 0.15s`), rotates 90° when expanded (P:272–280).
- Whole row is the toggle; height animation `easeInOut 0.30s` (P:248, P:181–183); body cross-fade **0.22 s easeOut** (U:72).
- Collapsed body height = **0** (DPS:70).

### 2.2 Token card — `UsageHeroCard`

| # | Row | Detail | Source |
|---|---|---|---|
| 1 | Header | title `Token 用量` + `LIVE` (6 pt dot, 12 pt halo 18%, text 9.5 pt semibold `#0a7d3b`/`#30d158`) | U:54–62, U:1118–1152 |
| 2 | Hero row | top pad **8**; `HStack(spacing: 8)`, baseline aligned | U:97–98, U:177 |
| 3 | Divider | top pad **12**, 1 px `hairline` | U:99–100, U:276–280 |
| 4 | 4-cell breakdown | top pad **10** | U:101–102 |
| 5 | Monthly section | top pad **12** | U:103–106 |
| 6 | Model usage (optional) | top pad **12** | U:107–110 |
| 7 | Heatmap block | title top **12**, grid top **4**, date axis top **5**, legend top **5** | U:111–120 |

**Hero number:** 40 pt bold, tracking **−1.2**, monospaced digits, 135° gradient `tierColor` at stop 0.3 → light tier at 1.0 (U:208–212, U:816–826).
Formatting = `PanelFormat.tokenCount`: `<1000` raw · `<1e6` `%.1f`+`K` · `<1e9` `%.1f`+`M` · else `%.2f`+`B`, trailing zeros trimmed (PM:176–189). `586_600_000 → "586.6M"`.
Unit label `tokens` 13 pt medium, `primary 0.5` (U:179–183).
Cost string right-aligned: 15 pt semibold monospaced, accent color (U:185–190). Format `"≈ ¥" + %.3f` with trailing zeros trimmed but never below 2 decimals (PM:191–203); `46.4092 USD × 7.2 = ¥334.146 → "≈ ¥334.146"` — **space after ≈, before ¥**.
Tier thresholds (drives gradient + background tint): `<100M` sage, `<200M` moss, `<300M` fern, `<400M` pine, `≥400M` forest (PM:500–512).

**4-cell breakdown** — `HStack(spacing: 0)`, 1 px dividers, 13 pt inner padding each side (U:284–308):

| CN label | English | Value font |
|---|---|---|
| 输入 | Input | 13.5 pt semibold |
| 输出 | Output | 13.5 pt semibold |
| 缓存读取 | Cache read | 13.5 pt semibold |
| 缓存命中率 | Cache hit rate | 13.5 pt semibold, string `%.0f%%` |

Label = **8.5 pt**, tracking **0.85**, `primary 0.55`; value `primary 0.85` (U:293–301).
Hit-rate formula: `cacheRead / (input + cacheRead + cacheCreation)`, `—` when denominator 0 (UM:74–78).

**Monthly aggregation row:** section title `按月 · 近 6 个月` (10 pt semibold, tracking 0.4, `primary 0.55`); right side `近半年 {total} · 月均 {avg}` at 10 pt, value in 10 pt bold (U:314–332, U:349–355).
`avg = windowTotal / number of month keys` (UM:133–136). Labels `"7月"` — month number, no year, no leading zero (UM:141–146).

**Monthly 3-column strip:** `LazyVGrid` 3 flexible columns, spacing **6**, cell spacing **6**; 6 chips = 2 rows (U:333–343). Chip: label 8.5 pt (current month semibold + accent), value 13 pt semibold; pad h **9** / v **6**; radius **6**; current-month fill white 82% (light) / white 14% (dark); non-current white 45% / 8%; border black 6.5% / white 10% (U:374–418).

**26-week heatmap:** grid of week columns × 7 rows (Mon→Sun), **no weekday labels** (U:575–579, UM:227–280).
- Geometry: width fills card; `cellSide = (width − 3×(cols−1)) / cols`; height `= side×7 + 3×6`; gap **3** (U:873–881, U:905, U:984).
- Radius: **2** classic (Nothing 0) (U:728).
- 5 filled steps + empty slot, colors in §3 (`heatmapLevelColor`, U:734–760). Level thresholds: 0 = no usage, 1 `<100M`, 2 `<200M`, 3 `<300M`, 4 `<400M`, 5 `≥400M` (UM:264–275).
- Date axis: left = `yy/MM/dd` of first cell, right = last cell, 9 pt, `primary 0.55` (U:582–603).
- Legend right-aligned: `少` + swatches 0…5 (9×9, radius 2) + `多`, spacing 3 (U:606–626).
- Number of weeks is **data-driven** (all daily rows), not fixed at 26 (UM:227–280).
- Cell breathing (Nothing only): CA opacity `base×0.42 ↔ 1.0`, one-way **1.6 s** `easeInEaseOut`, autoreverse infinite, phase `col×0.12 + row×0.05` mod 3.2 s (HeatmapBreathingPolicy.swift:12–41).

**Card background decoration:** classic/liquid = static char-stream Canvas (`.:+*#`, 16 pt grid, 9 pt mono, opacity 0.05–0.14, ×0.35 in light) masked to fade 0.45→0.95 (U:1052–1112); Nothing = 16 pt dot grid, 2 pt dots, opacity 0.13, mask fade 0.42→0.88 (U:1009–1045).

### 2.3 Hourly card — `HourlyLineCard`

Mode names in code: the branch is `theme.interfaceStyle` → `nothing` vs. classic/liquid (H:164–168). Variant IDs used in comments: classic line (`dailyChartClassic`, H:215), **Nothing dot-matrix console** (`nothingDailyChart` / `nothingProjectConsoleSection`, H:270, H:768), and **方案 P4** = the detail-area treatment inside Nothing (`方案 P4: Top 1 主模型高亮翡翠绿, 次段采用点阵斜纹`, H:665, H:711) adding the 6-tick micro-LCD blocks (H:825–834). P4 is not a top-level theme; it is the Nothing detail variant.

Order:
1. Header `Agent 用量` (no status view — `EmptyView`, H:66).
2. 14-day daily section: chart, then date axis (top 3), then agent legend (top 4); whole block omitted if `dailyDays` empty (H:93–98, H:184–189).
3. 1 px divider (top 10 / bottom 8) (H:95–97).
4. `逐小时` title row + right `0 – 23 时` (10 pt) (H:437–452).
5. One row per agent, 1 px divider between rows (H:103–108).

**14-day stacked bars (classic):** `Chart` `BarMark` per agent segment, `cornerRadius 1.5`, **height 68 pt**, Y domain `0…maxDayTotal`, X/Y axes hidden, total label 7.5 pt `.secondary` on the top segment only (H:215–258, H:365–370). Bar grow: per-column stagger **30 ms**, `easeOut 0.5 s`, from 0 → value (H:372–392).
**14-day stacked bars (Nothing):** 14 columns, each 3 cols × 8 rows = 24 cells of **6×6 pt**, gap **2**, radius 0, column height `8×6 + 7×2 = 62`; filled = `round(v/maxV×24)` min 1, bottom-up; segment colors = Nothing green ramp; hover shows day total at 7 pt offset y −11 (H:262–363).
**Date axis:** `14 天前` / `7 天前` / `今天`, 9 pt (H:396–406).
**Legend:** agent badge 14 pt (Nothing 9) + name, spacing 10 / inner 4, font 9.5 pt (H:410–431).

**Per-agent row:** vertical padding **7**, inner spacing 4 (H:486–493). Head: badge 14 pt + name 11 pt semibold + chevron 9 pt (rotates 90°) + right total 11 pt bold (H:499–545).
**24-h line:** height **26 pt**, stroke **1.5**, area gradient `agentColor 0.18 → 0.02`, Y domain `0…max×1.1`, axes hidden (H:549–600). Nothing uses emerald `#1C8C3D`/`#30D158` line + area `0.12–0.16` (H:552–574).
Expand/collapse detail: `easeInOut 0.15` (H:605).

**Detail block** (only for expandable rows): left pad **14**, top 3 (H:638–639).
- Group title 9 pt semibold (Nothing mono 9 + tracking 0.8) (H:651–655).
- 100 % stacked bar: height **6**, radius **3**, 1 pt gaps (Nothing 2 pt, radius 1, no track), track `black 0.07`/`white 0.12`; min segment 2 pt (H:666–708).
- Legend row: 5 pt dot (Nothing 6 pt swatch / diagonal pattern), name 9.5, right `pct · total` (pct 9.5 semibold) (H:712–755).
- `其他` (Other) segment appended when the Top-3 doesn’t cover the total (UM:316–330).
- Nothing P4 console: `[P1]` 8.5 bold, name 9.5, dotted leader `dash [1.5, 3]`, token value mono 9, percent badge (pad h4 v0.5, radius 2), **6 ticks** 2.5×6 radius 0.5 gap 1.5, active ticks `round(share×6)` (H:788–838).
- Nothing project shade colors: P1 emerald, P2 mid-green, P3 dark-green (H:857–893); row pads v1.5.

### 2.4 Subscription card — `SubscriptionCard`

Order: header `订阅用量` (EmptyView status) → provider sections separated by 1 px dividers → footer (1 px divider + Nothing legend + `最后更新 HH:mm`) (S:94–159).

**Provider section paddings:** top **10** for the first section, else **8**; bottom **8**; header bottom **3** (`10` when egress-blocked) (S:265–267, S:245–246).

**Provider header** (`HStack(spacing: 6)`): brand badge → name 11 pt semibold (+ `chevron.down` 8 pt when multi-account, rotates 180°) → balance chip (non-balance-mode) → account count 10.5 pt secondary → egress flag/badge 12 pt → extra text 9 pt secondary → `Spacer(minLength: 8)` → refresh button (S:368–439).
- Brand badge: **15 pt** square, radius `max(3, size×0.2)` = **3**, brand color fill, white glyph; monogram fallback `size×0.6` bold; Nothing = brand color @12–16% + brand glyph (ProviderBrandBadge.swift:20–31, :63–83).
- **Plan tag: NOT rendered on the dashboard** since C024 — plan only shows in Settings (S:215, S:598). Do not draw it.
- Account count text: e.g. `2 个账号` (S:1342).
- Refresh button: 14×14 frame, `arrow.clockwise` 10 pt semibold, `.secondary`, opacity **0.45** when disabled; spinner while refreshing (S:472–504).

**Window row** (`HStack(spacing: 8)`, vertical pad **2.5**): label fixed **62** wide (10 pt secondary) → meter (flex) → percent fixed **46** right (10 pt semibold; Nothing 12 pt bold) → reset fixed **48** right (9 pt secondary) (S:637–718).
- Meter: classic **5 pt** tall, radius 3, track `black 0.07`/`white 0.12`, fill = 2-stop horizontal gradient, opacity crossfade 0.34 s (S:880–937).
- Meter: Nothing **10 pt** tall, **24** square segments, gap **2**, empty `#E0E0E0`/`#222222`, filled = flat threshold color, frontier segment +white 35–45% (S:940–986).
- Reset text: `HH:mm` today, `N 天后`, `刷新中` when past (PM:246–262).

**Utilization thresholds (single source, all themes):**

| Used % | Level | Classic fill gradient | Nothing fill |
|---|---|---|---|
| `< 50` | normal | `#30d158 → #66d4a3` | `#4A9E5C` |
| `50 – 79` | warning | `#ff9f0a → #ffd60a` | `#D4A843` |
| `≥ 80` | critical | `#ff453a → #ff6961` | `#D71921` |

S:778–797 (levels), S:926–937 (gradients), S:47–64 (Nothing threshold colors). Nothing legend footer: `<50` · `50–79` · `≥80` (S:1232–1236).

**Multi-account (Codex) sub-cards:** collapsed by default; collapsed state shows the single most-stressed window row (`collapsedWindow`), expanded shows account cards stacked with spacing **4**, top 4 / bottom 2 (S:323–351).
Account card: radius **6**, pad h **9** / v **6**, fill white 35% (light) / 10% (dark) (Nothing `#F0F0F0`/`#1A1A1A`), 1 px border black 6.5% / white 18% (S:1063–1089). Content: account name 10.5 semibold + optional tag chip; window rows; error note `#ff9f0a` 10 pt; last-success line 9 pt secondary (S:1032–1062).
Tag chip: 8.5 pt medium `#0a84ff`, bg `#0a84ff` @12%/22%, radius 3.5, pad h5 v1 (S:1187–1201).

**Balance-mode provider (DeepSeek — no windows, single account, has balance):** two equal slots, gap 8, top 4 / bottom 2 (S:512–531).
- Left `可用余额`: label 10 pt secondary; value 14 pt bold digit, `primary 0.9`; slot pad h9/v7, radius 6, fill black 3.5% / white 6%, border 0.5 px black 6.5% / white 10% (S:535–584).
- Right `订阅状态`: 5 pt success dot + status text 12 pt (`ok` → `正常`) (S:588–630).
- Header metadata chip (when not balance-mode): 4 pt brand dot + amount 9.5 semibold, capsule, pad h6 v1, fill white 55%/12%, border 0.5 px white 60%/18% (S:1128–1148).

**Divider rules:** 1 px `black 0.05` / `white 0.10` (Nothing `#E8E8E8`/`#222222`) between provider sections (S:132–141); footer divider top **8** (Nothing **11**), footer content top **8** (Nothing **10**) (S:1218–1252).

**Footer:** Nothing legend left + `最后更新 HH:mm` right, 10.5 pt secondary (Nothing mono 9 disabled) (S:1239–1250).

---

## 3. Design tokens

### 3.1 Hardcoded colors (adaptive = light / dark; literal `Color(hex:)` already hex)

| Token | Light | Dark | Source |
|---|---|---|---|
| accent (usage) | `#0284C7` | `#0a84ff` | U:764–767 |
| hairline (usage) | black 7% | white 12% | U:771–774 |
| subdued / faint | primary 50% / 55% | same | U:769–770 |
| Nothing display / primary / secondary / disabled | `#000000` `#1A1A1A` `#666666` `#999999` | `#FFFFFF` `#E8E8E8` `#999999` `#666666` | U:778–793 |
| Nothing border / border-visible / surface-raised | `#E8E8E8` `#CCCCCC` `#F0F0F0` | `#222222` `#333333` `#1A1A1A` | U:794–805 |
| Nothing hero accent | `#D4A843` | `#4A9E5C` | U:808–811 |
| tier sage (base/light) | `#047857` / `#059669` | `#7D9B76` / `#9DB597` | U:832–836 |
| tier moss | `#059669` / `#10B981` | `#63885E` / `#82A57C` | U:837–841 |
| tier fern | `#047857` / `#059669` | `#4C7249` / `#6A9064` | U:842–846 |
| tier pine | `#065F46` / `#047857` | `#385B38` / `#557B52` | U:847–851 |
| tier forest | `#064E3B` / `#065F46` | `#26452A` / `#456B42` | U:852–856 |
| LIVE green / text | `#30d158` / `#0a7d3b` | `#30d158` / `#30d158` | U:1145–1147 |
| LIVE Nothing square | `#4A9E5C` | same | U:1148 |
| emerald hero line (hourly) | `#1C8C3D` | `#30D158` | H:552, H:670, H:713 |
| emerald P2 / P3 | `#2E9E4F` / `#185E2B` | `#4A9E5C` / `#2B7A42` | H:875, H:884 |
| project bar shades | `#30b0c7` `#55c2d4` `#7ad4e1` `#9fe5ed` | same | H:902–907 |
| Nothing ramp (5 steps) dark | `#8CCB98` `#5FAF6E` `#4A9E5C` `#35854A` `#2A6B3C` | (light reversed) | PM:100–104 |
| Nothing success / warning / critical | `#4A9E5C` `#D4A843` `#D71921` | same | S:47–50 |
| meter normal / warn / crit | `#30d158→#66d4a3` `#ff9f0a→#ffd60a` `#ff453a→#ff6961` | same | S:926–937 |
| note / egress warning | `#ff9f0a` | same | S:261, S:1052 |
| account tag chip | `#0a84ff` | same | S:1190 |
| Nothing empty segment | `#E0E0E0` | `#222222` | S:43–45 |
| panel footer bg (Nothing) | `#F5F5F5` | `#000000` | M:827–831 |
| header ok dot | `#0A7D3B` | `#30D158` | M:460–478 |
| warn / error / neutral dot | `#B25000` `#C62828` `#8E8E93` | `#D4A843` `#E5534B` `#8A8A8A` | M:460–478 |
| agent series | kimi-code `#0a84ff`, claude `#ff7a59`, codex `#bf5af2`, kimi-work `#5ac8fa`, grok `#6c63ff`, zcode `#40c8e0`, opencode `#30d158`, codebuddy `#ff9f0a`, dsh `#4d6bfe`, pi `#ff6482` | same | PM:44–72 |
| provider brand | kimi `#0a84ff`, codex/openai `#10a37f`, volcengine `#ff6a00`, deepseek `#4d6bfe`, claude `#d97757` | same | ProviderBrandPalette.swift:12–39 |

All hex literals above are literal `Color(hex:)`; alpha values are recorded as percentages. No `Color(red:green:blue:)` literals appear in these four view files (all color math is `Color(hex:)` or `Color.adaptive(light:dark:)`).

### 3.2 System semantic colors (no hex in code)

| Use | Resolved ≈ light |
|---|---|
| `Color.primary` | `#000000` (labelColor) |
| `.secondary` | `#808080` (secondaryLabelColor, ~50 % black) |
| `Color.primary.opacity(0.5 / 0.55 / 0.75 / 0.85 / 0.9)` | `#808080` / `#737373` / `#404040` / `#262626` / `#1A1A1A` over white |
| `Color.orange` (egress) | system orange ≈ `#FF9500` |

`.tertiary` is not used in these files. The table above is the resolved system value, not a literal in source.

### 3.3 Typography

| Role | Font | Source |
|---|---|---|
| Panel brand `Bruce` | system 11.5 bold **monospaced** | M:306 |
| Card title | system 12.5 semibold | P:254–256 |
| Section title | system 10 semibold, tracking 0.4 | U:349–355 |
| Hero number | system 40 bold, tracking −1.2, monospaced digit | U:208–212 |
| Hero unit `tokens` | system 13 medium | U:180 |
| Cost | system 15 semibold, monospaced digit | U:187 |
| Breakdown label / value | 8.5 (tracking 0.85) / 13.5 semibold | U:294–299 |
| Month chip label / value | 8.5 / 13 semibold | U:378–387 |
| Heatmap axis, legend | 9 | U:588, U:616 |
| Agent name / total | 11 semibold / 11 bold | H:518, H:541 |
| Distribution legend | 9.5 (pct semibold) | H:744–752 |
| Provider name | 11 semibold | S:378–388 |
| Window label / pct / reset | 10 / 10 semibold / 9 | S:653, S:693, S:682 |
| Balance value | 14 bold digit | S:543 |
| Footer updated | 10.5 | S:1247 |
| Nothing equivalents | Doto display (17/52), Space Grotesk ui (10/11/11.5/12/13), Space Mono (7/8.5/9/9.5/10/11/12/13/17) | NF:11–24 |

### 3.4 Radii

| Element | Radius | Source |
|---|---|---|
| Panel | 14 | M:249 |
| Card | 8 | P:25 |
| Footer button / account card / balance slot / month chip | 6 | P:160, S:1074, S:570, U:400 |
| Distribution bar track | 3 | H:700 |
| Meter (classic) | 3 | S:884 |
| Heatmap cell / swatch | 2 | U:728, U:623 |
| Tab pill / Nothing control | 2 / 6 | M:347, P:133 |
| Nothing segmented meter | 0 | S:962 |

### 3.5 Spacing constants
Card padding 15/13 · card gap 10 · stack inset 12/10/10 · header 14/9 · footer 12/9 · footer button 9/6 · breakdown cell 13 · month chip 9/6 · month grid gap 6 · heatmap gap 3 · window row label 62 / pct 46 / reset 48 · account card 9/6 · provider section 10(or 8)/8/3 · detail indent 14.

### 3.6 Motion (duration / curve)

| Interaction | Value | Source |
|---|---|---|
| Refresh icon spin | `linear 1 s`, repeatForever | M:56 |
| Status dot pulse | `easeInOut 0.9 s` autoreverse | M:83 |
| Card collapse / expand | `easeInOut 0.30 s` | P:181–183 |
| Card body fade | `easeOut 0.22 s` | U:72 |
| Mini ⇄ status cross-fade | `easeOut 0.12 s` delay 0.06 (in) / `0.07 s` (out) | P:293–306 |
| Chevron hover | `easeInOut 0.15 s` | P:278 |
| Drag reorder | `easeOut 0.15 s` | P:411 |
| Tab switch + card height | `easeOut 0.24 s` | M:535, M:654 |
| Hourly bar grow | 30 ms per column, `easeOut 0.5 s` | H:384–388 |
| Hourly row expand | `easeInOut 0.15 s` | H:605 |
| Meter fill / percent | `spring(duration 0.85, bounce 0)` | MeterMotionPolicy.swift:66–67 |
| Meter balance | `spring(0.6, bounce 0)` | :68–69 |
| Level crossfade | `easeOut 0.34 s` | :70–71 |
| Threshold color | `easeOut 0.25 s` | :72–73 |
| Highlight | `easeOut 0.2 s`, hold **0.95 s** | :74–75, :57 |
| Sheen sweep | `timingCurve(0.33,0,0.2,1) 0.85 s` | :76–77 |
| Meter entrance | `easeOut 0.45 s` | S:838 |
| Nothing hero breathing | `easeInOut 1.3 s` autoreverse | U:269 |
| Heatmap breathing | `1.6 s` one-way, autoreverse infinite, easeInEaseOut | HeatmapBreathingPolicy:12–41 |
| LIVE indicator | **static**, no animation in code (comment mentions 2.4 s — stale) | U:1118–1143 |

Count-up: no numeric count-up exists; numbers roll via `.contentTransition(.numericText)` (S:545, S:695, S:1118). Reduced-motion / hidden panel disables every loop above (C044/C145 gates).

---

## 4. Measured geometry (from frames/padding math)

| Item | Value | Derivation |
|---|---|---|
| Panel width | 440 | M:204 |
| Card outer width | **416** | 440 − 12×2 |
| Card content width | **386** | 416 − 15×2 |
| Heatmap cell / footprint | **≈11.96 pt** side, 26 cols → **386 × 102** pt | `(386 − 3×25)/26`; height `11.96×7 + 3×6` (U:879–880, U:905) |
| Heatmap at 25 weeks | cell 12.56, height 105.9 | same formula |
| Month chip width | **124.67** | `(386 − 6×2)/3` |
| 14-day chart height | **68** (classic) / **62** columns (Nothing) | H:250, H:280 |
| Hourly line height | **26** | H:599 |
| Collapsed mini line | **12** | H:147 |
| Meter height | **5** classic / **10** Nothing | S:833, S:829 |
| Stacked share bar | **6** | H:706 |
| Model usage bar | **4** | U:552 |
| Provider badge | **15×15** | ProviderBrandBadge.swift:21 |
| Agent badge | **14** (Nothing 9) | H:418, H:505 |
| Footer button height | **≈25–26** (11–12 pt icon + 6+6 pad + 2 border) | P:153–171 |
| Footer bar height | 1 + 9 + ≈26 + 9 = **≈45** | M:809–889 |
| Header height | 1 + 9 + 12 + 9 = **31** (12 pt dot row) | M:322–323, M:482 |

---

## 5. Sample dataset (JSON)

Levels use the real 0–5 scale (`UM:264–275`); every cell is 0–4 except **today = 5** (586.6M ≥ 400M) — the requested 0–4 range is otherwise satisfied. Window is 26 weeks, Mon 2026-05-11 → Wed 2026-11-04 (178 data days + 4 future cells).

```json
{
  "meta": { "today": "2026-11-04", "generatedAt": "2026-11-04T15:52:00+08:00", "cnyPerUsd": 7.2 },
  "tokenCard": {
    "totalTokens": 586600000, "totalTokensText": "586.6M",
    "costUsd": 46.4092, "costText": "≈ ¥334.146",
    "breakdown": [
      { "cn": "输入", "en": "Input", "tokens": 18400000, "text": "18.4M" },
      { "cn": "输出", "en": "Output", "tokens": 1700000, "text": "1.7M" },
      { "cn": "缓存读取", "en": "Cache read", "tokens": 566500000, "text": "566.5M" },
      { "cn": "缓存命中率", "en": "Cache hit rate", "valueText": "97%" }
    ],
    "cacheCreation": 0, "isLive": true, "tier": "forest",
    "halfYear": { "totalText": "44.33B", "averageText": "7.39B" }
  },
  "monthly": [
    { "key": "2026-06", "label": "6月", "total": 7378700000, "totalText": "7.38B", "isCurrent": false },
    { "key": "2026-07", "label": "7月", "total": 7347900000, "totalText": "7.35B", "isCurrent": false },
    { "key": "2026-08", "label": "8月", "total": 7099800000, "totalText": "7.1B", "isCurrent": false },
    { "key": "2026-09", "label": "9月", "total": 7711700000, "totalText": "7.71B", "isCurrent": false },
    { "key": "2026-10", "label": "10月", "total": 7968600000, "totalText": "7.97B", "isCurrent": false },
    { "key": "2026-11", "label": "11月", "total": 1420400000, "totalText": "1.42B", "isCurrent": true }
  ],
  "heatmap": {
    "firstDate": "2026-05-11", "lastDate": "2026-11-04", "gap": 3, "radius": 2,
    "weeks": [
      [4,4,3,2,4,2,2], [4,3,4,3,4,2,2], [3,4,3,3,4,2,2], [3,4,4,3,3,2,1],
      [2,3,4,3,3,2,2], [2,4,4,4,4,2,2], [2,3,4,3,3,1,2], [3,4,3,4,4,1,2],
      [4,4,3,3,4,1,2], [4,4,3,3,4,0,0], [0,3,3,4,4,2,1], [3,3,2,4,2,2,2],
      [3,4,3,3,3,2,1], [3,2,3,4,4,1,2], [3,4,4,4,2,2,1], [3,4,4,2,4,2,2],
      [3,3,4,3,4,1,0], [3,2,4,3,4,2,2], [4,4,4,3,3,2,2], [4,3,4,3,3,2,2],
      [4,4,4,4,3,1,2], [4,2,3,4,3,2,1], [3,4,4,4,3,1,2], [3,4,4,4,4,2,2],
      [4,3,4,4,4,2,2], [4,3,5,null,null,null,null]
    ]
  },
  "agents": [
    { "id": "kimi-code-cli", "name": "Kimi Code", "colorHex": "#0a84ff" },
    { "id": "claude-code", "name": "Claude Code", "colorHex": "#ff7a59" },
    { "id": "codex", "name": "Codex", "colorHex": "#bf5af2" },
    { "id": "kimi-work", "name": "Kimi Work", "colorHex": "#5ac8fa" }
  ],
  "daily14": [
    { "date": "2026-10-22", "total": 376200000, "segments": [["kimi-code-cli",172100000],["claude-code",98000000],["codex",63300000],["kimi-work",42800000]] },
    { "date": "2026-10-23", "total": 346600000, "segments": [["kimi-code-cli",158600000],["claude-code",90300000],["codex",58300000],["kimi-work",39400000]] },
    { "date": "2026-10-24", "total": 177500000, "segments": [["kimi-code-cli",81100000],["claude-code",46300000],["codex",29900000],["kimi-work",20200000]] },
    { "date": "2026-10-25", "total": 182400000, "segments": [["kimi-code-cli",83500000],["claude-code",47500000],["codex",30700000],["kimi-work",20700000]] },
    { "date": "2026-10-26", "total": 326000000, "segments": [["kimi-code-cli",149100000],["claude-code",85000000],["codex",54800000],["kimi-work",37100000]] },
    { "date": "2026-10-27", "total": 245800000, "segments": [["kimi-code-cli",112500000],["claude-code",64100000],["codex",41300000],["kimi-work",27900000]] },
    { "date": "2026-10-28", "total": 303200000, "segments": [["kimi-code-cli",138700000],["claude-code",79000000],["codex",51000000],["kimi-work",34500000]] },
    { "date": "2026-10-29", "total": 383100000, "segments": [["kimi-code-cli",175300000],["claude-code",99800000],["codex",64400000],["kimi-work",43600000]] },
    { "date": "2026-10-30", "total": 355700000, "segments": [["kimi-code-cli",162800000],["claude-code",92700000],["codex",59800000],["kimi-work",40400000]] },
    { "date": "2026-10-31", "total": 112500000, "segments": [["kimi-code-cli",51500000],["claude-code",29300000],["codex",18900000],["kimi-work",12800000]] },
    { "date": "2026-11-01", "total": 163800000, "segments": [["kimi-code-cli",74900000],["claude-code",42700000],["codex",27600000],["kimi-work",18600000]] },
    { "date": "2026-11-02", "total": 392600000, "segments": [["kimi-code-cli",179700000],["claude-code",102300000],["codex",66000000],["kimi-work",44600000]] },
    { "date": "2026-11-03", "total": 277400000, "segments": [["kimi-code-cli",126900000],["claude-code",72300000],["codex",46700000],["kimi-work",31500000]] },
    { "date": "2026-11-04", "total": 586600000, "segments": [["kimi-code-cli",268400000],["claude-code",152900000],["codex",98700000],["kimi-work",66600000]] }
  ],
  "hourly": [
    { "agentID": "kimi-code-cli", "todayTotal": 268400000, "points": [4200000,2600000,1400000,800000,600000,900000,2100000,5400000,9800000,14600000,18200000,16800000,11400000,12600000,18400000,20800000,21600000,19400000,15200000,13800000,16600000,18200000,14400000,8600000] },
    { "agentID": "claude-code", "todayTotal": 152900000, "points": [400000,200000,100000,0,0,100000,600000,1800000,4200000,7600000,12400000,9200000,5800000,6400000,9600000,13800000,15400000,13400000,10100000,7200000,9400000,12600000,8200000,4400000] },
    { "agentID": "codex", "todayTotal": 98700000, "points": [100000,0,0,0,0,0,300000,1200000,2800000,5200000,7400000,7200000,3800000,4200000,6800000,8400000,10500000,8200000,5400000,4600000,6200000,7800000,5400000,3200000] },
    { "agentID": "kimi-work", "todayTotal": 66600000, "points": [200000,100000,0,0,0,100000,400000,1400000,3200000,4800000,5600000,5200000,3400000,3600000,4800000,5400000,6200000,5800000,3500000,2800000,3200000,3000000,2000000,1900000] }
  ],
  "subscriptions": {
    "updatedText": "最后更新 15:52",
    "sections": [
      {
        "id": "kimi", "name": "Kimi", "badgeHex": "#0a84ff", "status": "ok",
        "windows": [
          { "label": "每 5 小时", "en": "Every 5 hours", "usedPercent": 68, "percentText": "68%", "resetText": "15:00", "level": "warning" },
          { "label": "每周", "en": "Weekly", "usedPercent": 39, "percentText": "39%", "resetText": "3 天后", "level": "normal" },
          { "label": "每月", "en": "Monthly", "usedPercent": 52, "percentText": "52%", "resetText": "18 天后", "level": "warning" },
          { "label": "赠送额度", "en": "Bonus quota", "usedPercent": 81, "percentText": "81%", "resetText": "", "ownRow": true, "level": "critical" }
        ]
      },
      {
        "id": "codex", "name": "ChatGPT", "badgeHex": "#10a37f", "status": "ok",
        "isMultiAccount": true, "accountCountText": "2 个账号",
        "collapsedWindow": { "label": "每 5 小时", "en": "Every 5 hours", "usedPercent": 92, "percentText": "92%", "resetText": "13:30", "level": "critical" },
        "accounts": [
          { "id": "codex-personal", "name": "sivan…", "tag": "国际", "status": "ok",
            "windows": [
              { "label": "每 5 小时", "en": "Every 5 hours", "usedPercent": 57, "percentText": "57%", "resetText": "16:00", "level": "warning" },
              { "label": "每周", "en": "Weekly", "usedPercent": 96, "percentText": "96%", "resetText": "2 天后", "level": "critical" }
            ] },
          { "id": "codex-work", "name": "work…", "status": "ok",
            "windows": [
              { "label": "每 5 小时", "en": "Every 5 hours", "usedPercent": 92, "percentText": "92%", "resetText": "13:30", "level": "critical" },
              { "label": "每周", "en": "Weekly", "usedPercent": 36, "percentText": "36%", "resetText": "4 天后", "level": "normal" }
            ] }
        ]
      },
      {
        "id": "volcengine", "name": "Volcengine", "badgeHex": "#ff6a00", "status": "ok",
        "windows": [
          { "label": "每 5 小时", "en": "Every 5 hours", "usedPercent": 74, "percentText": "74%", "resetText": "14:00", "level": "warning" },
          { "label": "每周", "en": "Weekly", "usedPercent": 46, "percentText": "46%", "resetText": "5 天后", "level": "normal" },
          { "label": "每月", "en": "Monthly", "usedPercent": 63, "percentText": "63%", "resetText": "21 天后", "level": "warning" }
        ]
      },
      {
        "id": "deepseek", "name": "DeepSeek", "badgeHex": "#4d6bfe", "status": "ok",
        "isBalanceBased": true, "accountCountText": "按量付费",
        "balance": { "label": "账户余额", "en": "Account balance", "amountText": "¥ 38.21", "amount": 38.21 },
        "statusText": "正常"
      }
    ]
  }
}
```

Consistency: `18.4 + 1.7 + 566.5 = 586.6M`; hit rate `566.5 / (18.4 + 566.5 + 0) = 96.85 % → "97%"`; cost `46.4092 × 7.2 = 334.146`; each agent’s 24 `points` sum exactly to its `todayTotal`; each `daily14` total equals its segment sum; `heatmap` last column `[4,3,5]` matches Nov 2/3/4 totals (392.6M / 277.4M / 586.6M); monthly 6 keys sum 38.93B while `halfYear.totalText` 44.33B includes the partial May window (exactly how `UM:133–136` behaves).

---

## 6. Chinese UI strings → English (site is English-only)

| CN | EN | Source |
|---|---|---|
| 刷新 / 外观 / 设置 / 退出 | Refresh / Appearance / Settings / Quit | M:848, 868, 878, 881 |
| Token 用量 | Token usage | U:55 |
| tokens | tokens (keep) | U:179 |
| 输入 / 输出 / 缓存读取 / 缓存命中率 | Input / Output / Cache read / Cache hit rate | UM:90–95 |
| 热力图 · 近半年 | Heatmap · last 6 months | U:112 |
| 按月 · 近 6 个月 | By month · last 6 months | U:317 |
| 近半年 / 月均 | Last 6 months / Monthly avg | U:321–325 |
| 少 / 多 | Less / More | U:609–614 |
| 模型用量 / 本月 / 3 月 / 6 月 | Model usage / This month / 3 months / 6 months | U:449, UM:209–211 |
| 暂无模型数据 | No model data | U:460 |
| 展开全部模型 / 收起全部模型 | Expand all models / Collapse all models | U:480 |
| Agent 用量 | Agent usage | H:61 |
| 逐小时 / 0 – 23 时 | Hourly / 0–23 h | H:439, H:442 |
| 14 天前 / 7 天前 / 今天 | 14 days ago / 7 days ago / Today | H:398–402 |
| 模型占比 / 项目分布 | Model share / Project share | H:619, H:630 |
| 项目统计 // PRJ.CONSOLE | Project stats // PRJ.CONSOLE | H:771 |
| N WORKSPACES | N workspaces | H:776 |
| 其他 | Other | UM:323 |
| 订阅用量 | Subscription usage | S:97 |
| 最后更新 HH:mm | Updated HH:mm | SubscriptionMapping.swift:214 |
| 可用余额 / 订阅状态 / 正常 | Available balance / Subscription status / Active | S:537, S:590, S:599 |
| 每 5 小时 / 每周 / 每月 | Every 5 hours / Weekly / Monthly | PM:240–251 |
| 赠送额度 / 加量包 | Bonus quota / Top-up pack | S:1287–1288 |
| 刷新中 / N 天后 | Refreshing / in N days | PM:257–262 |
| 个账号 / 按量付费 | N accounts / Pay-as-you-go | S:1342, S:1368 |
| 已拦截查额以保护账号 | Quota check blocked to protect this account | S:285 |
| 去设置 / 重测 | Open settings / Retest | S:307, S:313 |
| 拖拽调整卡片顺序 | Drag to reorder cards | P:370 |
| 收起卡片 / 展开卡片 | Collapse card / Expand card | P:287 |
| 未配置模块, 前往设置 / 打开设置 | No modules configured — open settings / Open settings | M:751, M:755 |
| 已收起 / 已展开 | Collapsed / Expanded | P:288 |
| 月 (suffix, e.g. 6月) | Jun (render as short month name) | UM:145 |
| 时 / 天 (axis units) | h / d | H:556, PM:262 |
