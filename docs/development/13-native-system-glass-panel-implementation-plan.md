# 菜单栏仪表盘系统级玻璃承载层施工计划

> 关联设计: [`12-native-system-glass-panel-design.md`](./12-native-system-glass-panel-design.md)
> 日期: 2026-08-13
> 方案: B - 窗口级原生材质混合方案
> 状态: 已实施并完成验证
> 施工规则: 只改视觉承载, 不改布局、统计和刷新流程

## 1. 施工目标

将当前“SwiftUI 每张卡片独立玻璃”改为“AppKit 窗口级系统材质 + SwiftUI 内容层”:

```text
DashboardPanel (现有无边框 NSPanel)
└── DashboardGlassPanelController (新增)
    ├── macOS 26+: NSGlassEffectView / NSGlassEffectContainerView
    ├── macOS 14-25: NSVisualEffectView
    └── NSHostingView<MenuBarDashboardView>
```

施工完成后必须同时满足:

- 当前菜单栏面板仍为无边框 `NSPanel`.
- 面板宽度仍为 440pt.
- 内容不足时高度自适应, 内容超出屏幕时卡片区域滚动, 底栏固定.
- 卡片顺序、内容、文字、数据输入和交互不变.
- 订阅、Agent 用量、额度刷新、Collector、Bridge、artifact 和凭证流程零改动.
- macOS 26 使用系统原生 Liquid Glass; macOS 14-25 使用 `NSVisualEffectView` 或现有 material 回退.

本计划只供施工确认, 本文生成过程不实施代码、不打包、不执行实时采集.

## 2. 当前工作树基线

已有的第一轮 B 方案视觉改动属于施工前基线, 包括:

- `GlassTheme.swift` 中的 dashboard surface token.
- `MenuBarViews.swift` 的面板玻璃背景入口.
- `PanelCardContainer.swift` 的卡片边框、高光和阴影 token.

本次施工在此基础上补齐真正的 AppKit 窗口级材质, 不重复扩展各卡片内部的视觉常量.

施工前必须执行只读检查:

```bash
git status --short
git diff --name-only
```

若发现 Collector、Bridge、`MdddAppCore`、订阅或统计文件已有未说明改动, 先记录并停止, 不覆盖用户现有修改.

## 3. 文件边界

### 3.1 允许新增或修改

| 文件 | 施工内容 |
|---|---|
| `macos/MdddApp/Sources/MdddApp/DashboardGlassPanelController.swift` | AppKit 宿主、Native surface、主题更新和尺寸透传 |
| `macos/MdddApp/Sources/MdddApp/GlassTheme.swift` | surface plan、视觉 token、SwiftUI modifier 和回退映射 |
| `macos/MdddApp/Sources/MdddApp/MenuBarStatusItemController.swift` | 将 hosting view 接入新宿主, 保留窗口行为 |
| `macos/MdddApp/Sources/MdddApp/MenuBarViews.swift` | 根背景透明、macOS 26 卡片容器接入, 保留全部几何逻辑 |
| `macos/MdddApp/Sources/MdddApp/Views/PanelCardContainer.swift` | 卡片背景、边框、高光和阴影接入 token |
| `macos/MdddApp/Package.swift` | 仅在确需新增视觉 Harness 时增加测试目标 |
| `macos/MdddApp/Tests/Harnesses/DashboardGlassSurfaceHarness/**` | 仅测试纯视觉 plan 映射, 不读取本机数据 |
| `docs/development/12-native-system-glass-panel-design.md` | 设计文档, 不在施工中改动 |
| `docs/development/13-native-system-glass-panel-implementation-plan.md` | 本施工计划 |

### 3.2 禁止触碰

```text
agent-usage/collector/**
bridge/**
macos/MdddApp/Sources/MdddAppCore/**
macos/MdddApp/Sources/MdddOnboardingCore/**
```

禁止修改订阅额度、Agent 用量、Codex 刷新、DeepSeek 账本、CollectorRunner、RefreshScheduler、ArtifactStore、PanelViewModel、Keychain、OAuth 和网络请求逻辑. 若编译问题要求触碰以上目录, 停止施工并重新确认范围.

## 4. Task 0: 冻结布局和业务基线

施工前记录以下不变量, 后续每个任务都必须保持:

- `MenuBarDashboardView` 的 `frame(width: 440)`.
- `ScrollView` 及其 `cardStackHeight`、`footerHeight`、`maxCardStackHeight`.
- `onGeometryChange` 和 `onContentSizeChange`.
- `MenuBarStatusItemController.resizePanel(to:)` 的顶边锚定.
- `cardStack` 的卡片顺序和 `PanelCardContainer` 的圆角、padding.
- 底栏按钮的 action、文字、disabled 条件和快捷键.

静态基线检查:

```bash
rg -n "frame\(width: 440\)|cardStackHeight|footerHeight|maxCardStackHeight|resizePanel|onContentSizeChange" \
  macos/MdddApp/Sources/MdddApp/MenuBarViews.swift \
  macos/MdddApp/Sources/MdddApp/MenuBarStatusItemController.swift
```

不保存或提交真实账号、artifact、Keychain 内容或实时采集结果作为视觉 fixture.

## 5. Task 1: 建立纯视觉 Surface Plan

### 5.1 目标

在 `GlassTheme.swift` 或同一视觉模块内建立单一映射入口, 让 AppKit 宿主和 SwiftUI 卡片使用同一套主题决策. 不修改 `ResolvedTheme`、`ThemeResolution` 或配置 schema.

### 5.2 内部类型

建议建立以下内部类型:

```text
DashboardGlassBackend
  nativeLiquidGlass
  appKitMaterial
  swiftUIFallback

DashboardGlassMaterial
  standard
  clear
  matte
  classic

DashboardGlassSurfacePlan
  backend
  panelMaterial
  cardMaterial
  usesInteractiveGlass
  reduceTransparencyFallback
```

`DashboardGlassSurfacePlan.resolve(theme:capabilities:)` 必须是纯函数. 输入只能是:

- `ResolvedTheme`.
- macOS 26 能力布尔值.
- `reduceTransparency` / 高对比度能力值.

不得读取模型、文件、网络、Keychain、当前账号或刷新状态.

### 5.3 映射规则

| 条件 | backend | 面板 | 卡片 | 控件 |
|---|---|---|---|---|
| macOS 26 + liquidGlass + regular | nativeLiquidGlass | standard | mergedClear | 系统 glass |
| macOS 26 + liquidGlass + clear | nativeLiquidGlass | clear | transparent/clear | 系统 glass |
| macOS 26 + liquidGlass + material | appKitMaterial | matte | transparent | 普通按钮 |
| classic | appKitMaterial 或 fallback | classic | classic | 普通按钮 |
| macOS 14-25 | appKitMaterial 或 fallback | classic-compatible | transparent/material | 普通按钮 |

`classic`、`material` 和 macOS 26 以下路径不得调用 `NSGlassEffectView`、`GlassEffectContainer` 或 `.glass`.

### 5.4 验收

- 旧配置和 `ResolvedTheme` 行为不变.
- 映射结果可在无 UI 环境下重复测试.
- plan 只影响视觉 backend, 不携带任何业务字段.

## 6. Task 2: 新增 AppKit 面板宿主

### 6.1 宿主结构

新增 `DashboardGlassPanelController.swift`:

```text
DashboardGlassPanelController: NSViewController
└── DashboardGlassRootView: NSView
    ├── nativeSurfaceView: NSView
    └── hostingView: NSHostingView<MenuBarDashboardView>
```

两个子视图使用 Auto Layout 或等价的边缘约束铺满根视图. `hostingView` 保持透明, 不设置独立固定高度.

### 6.2 Native surface 选择

使用单一 `updateSurface(plan:)` 入口:

```text
plan.backend == nativeLiquidGlass
    → #available(macOS 26, *) 创建/更新 NSGlassEffectView
plan.backend == appKitMaterial
    → 创建/更新 NSVisualEffectView
plan.backend == swiftUIFallback
    → 透明 surface, 交给现有 SwiftUI material
```

macOS 26 分支必须完全包在 `#available(macOS 26, *)` 中. 具体 API 属性以当前 Xcode SDK 的签名为准, 只使用公开 API; 不使用私有 KVC、未文档化 selector 或运行时字符串反射.

### 6.3 `NSVisualEffectView` 回退

兼容路径的固定规则:

- `blendingMode = .behindWindow`.
- `state` 根据面板可见和 active 状态更新.
- `regular` 语义初始映射 `.hudWindow`.
- `clear` 语义初始映射 `.underWindowBackground`.
- `classic/material` 语义映射 `.windowBackground` 或 `.contentBackground`.

如果材质初始化或渲染失败, 不抛出影响面板显示的错误, 直接切换 `swiftUIFallback`.

### 6.4 尺寸透传

宿主必须提供现有尺寸回调:

```text
SwiftUI onContentSizeChange
    → DashboardGlassPanelController.onContentSizeChange
    → MenuBarStatusItemController.resizePanel(to:)
```

Native surface 不参与高度计算, 不添加 padding, 不设置额外最小高度, 不改变面板顶边锚定.

### 6.5 生命周期

- `viewDidAppear` / 面板显示时设置 active surface state.
- 面板隐藏或关闭时释放临时材质资源, 但保留 controller 和 hosting state.
- 主题更新只替换 surface 或更新其属性, 不重建 `NSPanel`.
- 不创建独立计时器、刷新任务、网络请求或后台线程.

## 7. Task 3: 接入 `MenuBarStatusItemController`

将当前直接赋值的 `NSHostingController` 替换为 `DashboardGlassPanelController`.

保留原有 root view 构建内容:

- `openSettings`.
- `terminateApplication`.
- `onContentSizeChange`.
- `.environmentObject(model)`.
- `.environmentObject(coordinator)`.

主题更新采用显式 surface 回调:

```text
MenuBarDashboardView
    → resolvedTheme 变化回调
    → DashboardGlassPanelController.updateSurfaceConfiguration
```

回调只传 `DashboardSurfaceConfiguration` 或 `ResolvedTheme`, 不传 `AppModel`、PanelViewModel、artifact 或账号数据.

保留 `panel.backgroundColor = .clear`、`panel.isOpaque = false`、`panel.hasShadow = true`、`.statusBar` level 和 `.borderless` style mask.

## 8. Task 4: 调整 SwiftUI 面板、卡片与控件层

### 8.1 `MenuBarViews.swift`

只做以下视觉调整:

- 面板根视图使用透明背景, 让 Native surface 成为主材质.
- macOS 26 + `nativeLiquidGlass` 时, 将卡片内容放入 `GlassEffectContainer`.
- classic、material、低版本路径不挂载 Liquid Glass 容器.

绝不修改:

- `cardStack` 的 if 顺序和内容.
- `ScrollView` 的 frame、高度测量和滚动指标策略.
- `.frame(width: 440)`、`.fixedSize` 和底栏布局.
- 刷新、设置、退出按钮的 action 和可访问性.

### 8.2 `PanelCardContainer.swift`

保留圆角 16pt、padding 和内容尺寸. 背景改为 plan 提供的透明/低透明度 card layer:

- macOS 26 浅色: clear glass; macOS 26 深色: AppKit 外观驱动的低对比度半透明卡片表面与边界, 不在原生面板玻璃上叠加第二重白色 glass sheet.
- macOS 14-25: 低透明度材质或透明填充.
- classic: 现有可读性优先材质.

边框、高光和阴影全部来自 `DashboardGlassSurfaceTokens`:

- 顶部高光最多 1px.
- 深色液态玻璃阴影为零或极低.
- 浅色保留弱边界, 防止内容与背景混在一起.

### 8.3 内容卡片

首轮不修改 `UsageHeroCard.swift`、`SubscriptionCard.swift` 和 `HourlyLineCard.swift`. 只有实机截图证明内部固定背景明显遮挡 Native surface 时, 才允许降低其纯视觉透明度; 不得修改 ViewModel、数据源、文案、数字、排序和条件渲染.

### 8.4 底栏控件

底栏保留刷新、设置、退出三个按钮的顺序、动作、禁用条件和可访问性语义. 液态玻璃模式使用与明暗外观自适应的低对比度控件面, 避免系统 `.glass` 在白色背景下生成白色高亮块.

## 9. Task 5: 可访问性与性能保护

- 尊重 `Reduce Transparency` 和高对比度设置, 进入实体或高对比度回退.
- 不使用 SwiftUI `blur`、`drawingGroup` 或每张卡片独立高成本模糊.
- 面板最多一个主 AppKit 材质层.
- `ScrollView` 只滚动 hosting 内容, Native surface 固定在窗口层.
- 文字继续使用系统 primary/secondary 层级.
- 材质更新不得触发业务刷新或重新扫描.

## 10. Task 6: 测试实施

### 10.1 Surface plan 测试

优先增加纯逻辑 Harness, 测试以下矩阵:

```text
macOS 26 + liquidGlass + regular → nativeLiquidGlass / standard
macOS 26 + liquidGlass + clear   → nativeLiquidGlass / clear
macOS 26 + liquidGlass + material → appKitMaterial / matte
任意版本 + classic                → appKitMaterial 或 fallback / classic
macOS 14-25                       → 不访问 macOS 26 API
旧配置缺少主题字段               → 现有默认行为
```

Harness 不读取本机数据、不访问网络、不写 Keychain、不启动 AppModel.

### 10.2 编译和静态验证

```bash
git diff --check
swift build --package-path macos/MdddApp
```

确认:

- 所有 macOS 26 类型和调用位于 `#available(macOS 26, *)`.
- classic/material 路径不存在 Liquid Glass 调用.
- `git diff --name-only` 没有 Collector、Bridge、MdddAppCore、订阅和统计文件.
- 没有新增配置字段、网络调用、文件写入或 Keychain 访问.

### 10.3 现有回归

```bash
zsh scripts/verify-local.sh
swift run --package-path macos/MdddApp PanelViewModelHarness
swift run --package-path macos/MdddApp RefreshSchedulerHarness
swift run --package-path macos/MdddApp CollectorRunnerHarness
swift run --package-path macos/MdddApp ArtifactStoreHarness
swift run --package-path macos/MdddApp SubscriptionCredentialsHarness
```

视觉施工不得以实时 Collector 采集作为前置条件, 也不得把真实 artifact 写入仓库.

### 10.4 实机视觉验证

| 系统 | 主题 | 必查内容 |
|---|---|---|
| macOS 26 | liquidGlass + regular | 系统玻璃、背景融合、卡片连续性 |
| macOS 26 | liquidGlass + clear | 透明度和文字可读性 |
| macOS 26 | liquidGlass + material | 不调用 Liquid Glass, 使用材质回退 |
| macOS 26 | classic | 传统材质可读性 |
| macOS 14/15 | classic/material | `NSVisualEffectView` 稳定性 |
| 任意版本 | 深色/浅色 | 外观同步和边缘对比度 |
| 任意版本 | 多卡片/超高内容 | 高度铺满、滚动和底栏固定 |

每组截图只比较材质、边缘、高光、透明度和层级, 不允许以改变布局或删除内容换取视觉效果.

## 11. Task 7: 打包前验收

满足以下条件才能进入打包:

1. `swift build` 和 `verify-local.sh` 全部通过.
2. Surface plan 矩阵测试全部通过.
3. 现有 PanelViewModel、刷新、Collector、artifact 和凭证 Harness 全部通过.
4. 面板仍为无边框菜单栏 `NSPanel`.
5. 面板宽度 440pt, 高度和滚动策略无变化.
6. 订阅和 Agent 用量的输出逐字段与改造前一致.
7. macOS 26 原生路径和 macOS 14/15 回退路径均完成截图检查.
8. 降低透明度和高对比度模式仍可读.
9. `git diff --name-only` 只包含视觉宿主、主题、面板视图、卡片容器、必要 Harness 和文档.

## 12. 回退方案

运行时回退:

```text
NSGlassEffectView
    ↓ API 或材质不可用
NSVisualEffectView
    ↓ 初始化或渲染失败
现有 SwiftUI material / 透明填充
```

施工回滚:

- 只回滚 `DashboardGlassPanelController.swift`、`GlassTheme.swift`、`MenuBarStatusItemController.swift`、`MenuBarViews.swift`、`PanelCardContainer.swift` 及视觉 Harness.
- 不回滚、不覆盖任何业务模块或用户本地数据.
- 若 Native surface 影响 fitting size, 先移除 surface 对布局的约束, 恢复原有 hosting view 高度链路.
- 若某系统版本材质不可读, 提高回退 token 的填充和边界对比度, 不修改业务内容和布局.

## 13. 施工完成报告格式

施工完成后必须记录:

```text
修改文件:
- ...

未修改保护范围:
- Collector / Bridge / MdddAppCore / 订阅 / Agent 统计 / 刷新流程

验证:
- swift build: pass/fail
- verify-local.sh: pass/fail
- Harness: pass/fail
- macOS 26 截图: pass/fail
- macOS 14/15 回退截图: pass/fail

回退验证:
- Native surface fallback: pass/fail
- Reduce Transparency: pass/fail
```

## 14. 本次施工完成报告

修改文件:

- `macos/MdddApp/Sources/MdddApp/DashboardGlassPanelController.swift`
- `macos/MdddApp/Sources/MdddApp/GlassTheme.swift`
- `macos/MdddApp/Sources/MdddApp/MenuBarStatusItemController.swift`
- `macos/MdddApp/Sources/MdddApp/MenuBarViews.swift`
- `macos/MdddApp/Sources/MdddApp/Views/PanelCardContainer.swift`

未修改保护范围:

- Collector、Bridge、MdddAppCore、订阅额度、Agent 统计、额度刷新、凭证和网络请求流程.

验证记录:

- `swift build --package-path macos/MdddApp`: pass.
- `zsh scripts/verify-local.sh`: pass (Python 194 项, Swift 全部 Harness).
- `zsh scripts/build-test-app.sh`: pass, App Bundle 签名校验通过.
- macOS 26 原生面板截图: pass; 440pt 宽度、卡片顺序、内容和固定底栏保持不变, 文字与图表保持清晰.
- `NSGlassEffectView` 内容容器实验: rejected; 将完整 SwiftUI 内容作为 `contentView` 或套入全量 `GlassEffectContainer` 会导致重影, 已回退为 sibling surface 结构.
- 深色 + 通透复测: pass; 原生面板保持连续材质, 所有卡片层改为 AppKit 外观驱动的低对比度半透明表面, 标题、统计文字、订阅内容和图表均可读, 底栏控件不再生成白色高亮块. 卡片决策不依赖 SwiftUI `ColorScheme`, 避免窗口背景与环境外观不一致时回归.
- `Reduce Transparency` / 高对比度: 由 `DashboardGlassSurfacePlan` 进入实体材质回退, 不使用交互玻璃.

回退验证:

- macOS 26 API 不可用时: `NSVisualEffectView` 回退.
- 辅助功能降低透明度或高对比度: classic 实体回退.
- 原生 surface 初始化失败或低版本: 保留透明 SwiftUI fallback, 不影响业务和布局链路.
