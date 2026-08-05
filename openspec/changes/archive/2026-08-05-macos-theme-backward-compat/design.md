## Context

- 当前部署目标: `Package.swift` → `.macOS(.v26)`.
- 主题相关状态仅有 `GlassStylePreference` (`regular` / `clear` / `material`), 设置页以「液态玻璃」分段控件直接选择三者.
- 渲染: `GlassTheme` / `PanelCardContainer` / 菜单栏面板在 `usesGlass == true` 时调用 `glassEffect` 与 `.buttonStyle(.glass)`; `material` 已退化为材质填充, 但 **API 仍编译依赖 macOS 26**.
- 用户需求: 向下兼容; 主题先拆「经典 vs 液态玻璃」; 低版本液态玻璃灰显; 仅液态玻璃启用后展示模糊风格子选项.

约束:

- 配置文件向后兼容 (旧 `glassStyle` 可解码).
- 不改变采集 / 凭证 / Bridge 契约.
- 中文 UI 文案; 半角标点.
- 低版本不得链接调用仅 26+ 可用的符号路径 (用 `#available` / 分离类型隔离).

## Goals / Non-Goals

**Goals:**

1. 配置与 UI 表达两层主题: **界面风格** (经典 / 液态玻璃) + **模糊风格** (仅液态玻璃下).
2. 运行时能力门闩: `LiquidGlassCapability.isSupported` (等价于 macOS 26+).
3. 低版本强制经典渲染, 设置中液态玻璃不可用 (灰显).
4. 高版本可选液态玻璃; 子风格沿用现有 regular/clear/material 语义.
5. 下调最低部署版本到可验证基线, 使非 26 系统可安装运行 (经典主题).

**Non-Goals:**

- 不实现第三方液态玻璃仿制 (低版本不「假玻璃」).
- 不改浅色/深色/跟随系统逻辑.
- 不在本 change 全面审计所有 macOS 26-only API (仅主题相关路径 + 编译通过所需最小隔离; 其余 API 另开 change).
- 不改 Widget / Daimon 单文件主题.

## Decisions

### D1: 两层模型, 而非把 classic 塞进 GlassStylePreference

| 层 | 类型 (建议名) | 取值 |
|----|----------------|------|
| 界面风格 | `InterfaceStylePreference` | `classic`, `liquidGlass` |
| 模糊风格 | 现有 `GlassStylePreference` | `regular`, `clear`, `material` |

**理由:** 用户语义是「是否启用液态玻璃」与「玻璃变体」正交; 低版本只禁用第一层.

**替代方案 (否决):** 仅增加 `GlassStylePreference.classic` — 与「启用液态玻璃后才显示模糊」的二级 UI 不匹配, 且易与 material 混淆.

### D2: 能力探测

```text
LiquidGlassCapability.isSupported ⇔ #available(macOS 26, *)
```

纯函数 / 可注入 `() -> Bool` 便于 harness 测设置页启用态, 无需真机切系统.

### D3: 解析与回落

```text
resolvedInterfaceStyle:
  if !isSupported → always .classic
  else → stored ?? .liquidGlass   // 26+ 默认保持现网「玻璃」体验

resolvedGlassStyle (模糊):
  only meaningful when resolvedInterfaceStyle == .liquidGlass
  else ignored for rendering; still may persist last user choice for 26+ 升级后恢复
  default when liquid: glassStyle ?? .regular
```

**旧配置迁移:**

- 仅有 `glassStyle`, 无 `interfaceStyle`:
  - 支持液态玻璃: `interfaceStyle = liquidGlass`, 保留 `glassStyle`
  - 不支持: 运行时 `classic`, 磁盘可不改写 (fail-closed 读时回落)
- 用户在 26 上选 classic 后升级/降级: 持久化 classic, 低版本一致.

### D4: 设置页交互

```text
[ 界面风格 ]  经典 | 液态玻璃
              液态玻璃: 仅 isSupported 时可点; 否则灰显 + 旁注「需要 macOS 26」

[ 模糊风格 ]  标准 | 通透 | 哑光     ← 仅当 界面风格==液态玻璃 且 isSupported 时显示
```

- 灰显: `disabled` + 降低 opacity, 不隐藏选项 (用户可知存在该能力).
- 在不支持系统上若配置文件被手改成 liquidGlass: 读时回落 classic, 不崩溃.

### D5: 渲染分支

```text
if resolvedInterfaceStyle == .classic || !isSupported:
  面板/卡片/设置行: material 或实色/系统 material 填充
  按钮: 默认 Plain/Bordered, 不用 .glass
else:
  现逻辑: usesGlass ? glassEffect(style) : material 退化
```

所有 `glassEffect` / `Glass` / `.buttonStyle(.glass)` 必须包在 `#available(macOS 26, *)` 或仅在 26+ 编译的 helper 中.

### D6: 最低系统版本

| 选项 | 说明 |
|------|------|
| **推荐: macOS 15** | 平衡 API 面与覆盖; 与较新 SwiftUI Layout 等兼容 |
| 备选: macOS 14 | 覆盖更广, 可能需更多 API 替换 |
| 不推荐: 维持 26 | 无法实现本提案 |

**已确认最低系统: macOS 14** (用户 2026-08-05 指定).

`Package.swift`: `.macOS(.v14)`.

### D7: 配置 schema

- `schemaVersion` 保持 2 或 +1 到 3:
  - **推荐保持 2 + 新可选键** `interfaceStyle` (缺省 nil), 避免强制迁移工具.
  - 未知 `interfaceStyle` 字符串 → nil → 按 D3 回落.

### D8: 测试策略

- OnboardingCore: 解码/往返 `interfaceStyle` + 旧配置仅 `glassStyle`.
- 纯函数: `ThemeResolution.resolve(storedInterface, storedGlass, isSupported) -> ResolvedTheme`.
- 设置页: 可用 view model / 解析结果测「子选项是否应显示 / 液态是否 enabled」(不必 UI 截图).
- 在 26 SDK 上编译: 双路径 `#available` 分支均可链接.

## Risks / Trade-offs

| 风险 | 缓解 |
|------|------|
| 除主题外仍有 26-only API, 降 platforms 后编译失败 | 主题 change 内只修编译阻断点; 清单记入 tasks; 大块 API 另 change |
| 用户以为低版本「灰显玻璃」是 bug | 旁注「需要 macOS 26」 |
| 旧配置在低版本静默丢玻璃偏好 | 磁盘保留 glassStyle; 升级 26 后仍可读 |
| material 与 classic 视觉接近 | 文案区分: classic=「经典」; material=「哑光」(仅玻璃下) |
| 双 openspec 目录 (根 `openspec/` 与 `docs/openspec/`) | 本 change 写在 CLI 创建的 `openspec/changes/...`; 后续统一符号链接另议 |

## Migration Plan

1. 发版前: 文档说明最低系统版本变更.
2. 安装: 旧 26 用户配置自动映射为液态玻璃 + 原模糊风格.
3. 回滚: 恢复 platforms 与单层 glassStyle UI; 配置多出的 `interfaceStyle` 键可被旧版 decode 忽略 (若旧版 `decodeIfPresent` 未知键 — 标准 JSONDecoder 忽略未知键, 安全).

## Open Questions

1. ~~最低系统 15 还是 14?~~ **已确认 14**
2. 经典主题视觉: 统一 `.regularMaterial` 还是浅色半透明白底 / 深色 material (可沿用现 material 分支)? → 实现沿用现 material/半透明白底分支
3. 是否在菜单栏面板 footer 显示「经典」标识? (默认否, 减少噪音)
