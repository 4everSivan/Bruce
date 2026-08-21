# 菜单栏仪表盘系统级玻璃承载层设计

> 日期: 2026-08-13
> 方案: B - 窗口级原生材质混合方案
> 状态: 已实施并完成验证
> 范围: macOS 菜单栏仪表盘视觉承载层

## 1. 设计结论

当前仪表盘可以直接使用系统级材质, 但需要把材质从“SwiftUI 卡片装饰”提升为“AppKit 面板承载层”. 本方案保留当前无边框菜单栏 `NSPanel`、状态栏定位、动态高度、滚动区域、底栏、卡片布局和全部数据流程, 只替换视觉承载方式:

```text
DashboardPanel (现有无边框 NSPanel)
└── DashboardGlassPanelController (新增 AppKit 宿主)
    ├── NativeSurfaceView
    │   ├── macOS 26+: NSGlassEffectView / NSGlassEffectContainerView
    │   └── macOS 14-25: NSVisualEffectView
    └── NSHostingView<MenuBarDashboardView>
```

macOS 26 使用 AppKit 原生 Liquid Glass, macOS 14-25 使用 `NSVisualEffectView` 兼容材质. SwiftUI 继续负责现有内容和布局, 只保留必要的卡片透明层和交互控件样式.

## 2. 范围冻结

### 2.1 目标

- 让系统材质成为面板的主要背景, 形成连续的环境融合和模糊效果.
- 保留当前仪表盘的窗口形态、交互和几何布局.
- 在 macOS 26 上使用系统原生 Liquid Glass, 而不是只在每张卡片上单独调用 `glassEffect`.
- 在 macOS 14-25 上安全回退, 不访问不可用的 macOS 26 API.
- 弱化重复的实体背景、固定白边、顶部高光和强阴影, 使卡片从“塑料盒”变为通透分组层.
- 主题切换只改变视觉承载和 token, 不重新创建面板或丢失 SwiftUI 状态.

### 2.2 禁止修改

本次设计不得修改:

- `agent-usage/collector/**`、Bridge、artifact schema.
- 订阅额度采集、解析、刷新、合并、账号状态和凭证处理.
- Agent 会话扫描、token 聚合、成本计算和统计窗口.
- `BruceAppCore` 中的 Collector、Scheduler、PanelViewModel、订阅和统计模型.
- 卡片顺序、卡片内容、文案、统计字段、条件渲染和可访问性语义.
- 菜单栏状态项指标、全局快捷键、刷新按钮行为和点击外部关闭行为.
- 设置页布局和设置项配置格式.
- 当前面板宽度 440pt、动态高度、最大屏幕高度、滚动区域和固定底栏策略.

## 3. 当前代码问题定位

### 3.1 面板层没有系统级材质

`MenuBarStatusItemController` 创建透明、非 opaque、无边框 `NSPanel`, 然后直接把 `NSHostingController` 设置为内容控制器. `backgroundColor = .clear` 只让背景透明, 不会自动创建窗口级模糊或 Liquid Glass.

### 3.2 系统玻璃挂在独立 SwiftUI 形状上

`GlassTheme.swift` 的 `dashboardGlassBackground` 当前在面板和每个 `PanelCardContainer` 上分别应用 SwiftUI `glassEffect`. 这些效果彼此独立, 没有 AppKit 窗口材质或 `GlassEffectContainer` 合并, 因而容易出现多块平整的半透明卡片.

### 3.3 自绘装饰覆盖动态材质

`PanelCardContainer` 同时绘制背景、边框、顶部高光和阴影. 这些层叠加在系统玻璃之上, 会遮挡背景融合、动态高光和边缘变化, 形成固定颜色的“塑料”观感.

### 3.4 参考图与产品窗口形态不同

参考图包含标准窗口的标题栏和标签栏, 当前产品是菜单栏弹出面板. 完全复制参考图需要改成标准标题栏窗口, 但这会改变当前窗口定位、点外关闭和菜单栏交互, 不在本次范围内. 本方案只追求在当前菜单栏面板形态下获得相同的系统材质层次.

## 4. 架构设计

### 4.1 组件层级

新增 `DashboardGlassPanelController`, 建议放在 `macos/BruceApp/Sources/BruceApp/` 下. 它作为 `NSPanel.contentViewController`, 内部持有原生材质视图和 SwiftUI hosting view:

```text
DashboardGlassPanelController.view
├── nativeSurfaceView (固定铺满)
└── hostingView (透明背景, 固定铺满)
```

`DashboardGlassPanelController` 负责:

- 创建并持有 `NativeSurfaceView`.
- 创建并持有 `NSHostingView<MenuBarDashboardView>`.
- 将两个视图铺满同一个透明根视图.
- 接收 `DashboardSurfaceConfiguration` 并更新材质.
- 将 `hostingView.fittingSize` 透传给当前面板尺寸回调.
- 在面板显示、隐藏、激活和失活时更新材质 state.

它不负责读取 `AppModel`、启动刷新、解析 artifact、读取凭证或计算统计.

### 4.2 `MenuBarStatusItemController.swift`

保留以下现有行为:

- `DashboardPanel` 的 `.borderless` style mask.
- `.statusBar` window level.
- 状态栏按钮定位和窄屏边界处理.
- `makeKeyAndOrderFront`、`orderOut`、前台应用恢复.
- `applicationDidResignActive` 点外关闭.
- `resizePanel(to:)` 顶边锚定.

唯一承载变化:

```text
NSHostingController(rootView: ...)  (当前)
        ↓
DashboardGlassPanelController(rootView: ..., surfaceConfiguration: ...)  (设计后)
```

`DashboardPanel` 仍然是同一个窗口对象, 主题切换时不销毁重建.

### 4.3 `MenuBarViews.swift`

保留 `frame(width: 440)`、卡片栈顺序、`ScrollView`、`onGeometryChange`、高度上限、滚动指示器、固定底栏、`fixedSize` 和 `onContentSizeChange`.

调整范围仅包括:

- 根视图不再绘制大面积实体面板背景.
- macOS 26 时, 卡片栈可由 `GlassEffectContainer` 包裹, 使相邻玻璃组件由系统统一融合.
- 低版本不挂载 `GlassEffectContainer`, 由 AppKit 面板材质提供主要背景.

### 4.4 `PanelCardContainer.swift`

保留圆角 16pt、当前 padding、卡片间距、传入 `Content` 的类型、数据和可访问性. 调整背景为低填充通透层, 统一边框、高光和阴影 token. 深色液态玻璃默认不使用明显黑色投影.

### 4.5 `GlassTheme.swift`

职责收敛为:

- `DashboardGlassSurfacePlan` 的纯函数解析.
- panel/card/control 的视觉 token.
- SwiftUI 卡片和按钮 modifier.
- `NSVisualEffectView` 与系统材质的兼容映射常量.

调用点不再自行组合系统玻璃、背景、边框和回退逻辑.

## 5. 主题与系统能力模型

现有 `ResolvedTheme` 和配置 schema 保持不变:

```json
{
  "appearanceMode": "system",
  "interfaceStyle": "liquidGlass",
  "glassStyle": "regular"
}
```

新增内部展示计划, 不写入配置文件:

```text
DashboardGlassSurfacePlan
├── backend: nativeLiquidGlass | appKitMaterial | swiftUIFallback
├── panelMaterial: standard | clear | matte | classic
├── cardMaterial: mergedClear | transparent | classic
├── usesInteractiveGlass: Bool
└── reduceTransparencyFallback: Bool
```

映射规则:

| 系统/主题 | backend | 面板 | 卡片 | 控件 |
|---|---|---|---|---|
| macOS 26 + liquidGlass + regular | nativeLiquidGlass | 标准玻璃 | 容器内透明/clear | 自适应控件面 |
| macOS 26 + liquidGlass + clear | nativeLiquidGlass | 透明玻璃 | 更低对比度 clear | 自适应控件面 |
| macOS 26 + liquidGlass + material | appKitMaterial | 哑光材质 | 透明材质层 | 普通按钮 |
| classic | appKitMaterial 或 fallback | 传统系统材质 | 传统卡片材质 | 普通按钮 |
| macOS 14-25 | appKitMaterial 或 fallback | `NSVisualEffectView` | 透明/低透明度材质 | 普通按钮 |

现有主题契约继续有效:

- `classic` 不调用 Liquid Glass API.
- `material` 不调用 Liquid Glass API.
- macOS 26 以下解析为 classic 语义, 不访问不可用 API.
- 旧配置缺少主题字段时沿用现有默认值.

## 6. AppKit 材质实现

### 6.1 macOS 26 原生路径

在 `#available(macOS 26, *)` 分支中使用:

- `NSGlassEffectView` 作为面板主背景.
- `NSGlassEffectContainerView` 或 SwiftUI `GlassEffectContainer` 合并需要融合的卡片玻璃.
- `NSGlassEffectView` 的 style、tint 和圆角由 `DashboardGlassSurfacePlan` 提供.

AppKit 宿主将 `NSHostingView` 放在玻璃视图之上, SwiftUI 根背景保持透明. 底栏按钮使用与面板外观自适应的低对比度控件面; 其他确需系统交互反馈的按钮才使用 `.glass` 或 `.glassProminent`, 不给所有内容块重复加厚玻璃.

### 6.2 macOS 14-25 兼容路径

使用 `NSVisualEffectView`:

- `blendingMode = .behindWindow`.
- `state` 随面板显示/隐藏和 active 状态更新.
- 初始材质映射:
  - `regular` -> `.hudWindow`.
  - `clear` -> `.underWindowBackground`.
  - `material/classic` -> `.windowBackground` 或 `.contentBackground`.

实际色调依赖系统版本、桌面背景和外观模式, 必须在 macOS 14、15 和 26 实机校准. 如果系统材质在当前窗口层级不可见, 允许回退到现有 SwiftUI material, 但不得添加高成本自绘 blur.

### 6.3 透明度与窗口设置

继续保持 `panel.backgroundColor = .clear`、`panel.isOpaque = false` 和 `panel.hasShadow = true`. Native surface 负责圆角裁剪和材质, 不改变面板的定位、层级和关闭策略. 面板高度变化时 surface 与 hosting view 一起调整, 不使用独立固定高度.

## 7. 视觉 token

token 仅依赖 `DashboardGlassSurfacePlan`、`ColorScheme` 和系统可访问性状态:

```text
DashboardGlassSurfaceTokens
├── panelCornerRadius = 22
├── cardCornerRadius = 16
├── borderColor
├── highlightColor
├── shadowColor
├── shadowOpacity
├── cardFillOpacity
└── dividerOpacity
```

参数边界:

- 面板圆角 22pt、卡片圆角 16pt 不变.
- 液态玻璃卡片不使用大面积固定实体填充.
- 顶部高光最多保留 1px 结构提示, 不作为主要光泽来源.
- 深色液态玻璃阴影默认关闭或极低对比度.
- 浅色模式保留轻微深度, 防止卡片与背景完全融合.
- `Reduce Transparency` 或高对比度时切换到可读性优先的实体/半透明背景.

## 8. 数据与布局隔离

允许的依赖方向:

```text
ResolvedTheme / Appearance
        ↓
DashboardGlassSurfacePlan / Tokens
        ↓
NativeSurfaceView + SwiftUI visual modifiers
        ↓
MenuBarDashboardView layout
```

禁止反向依赖:

```text
NativeSurfaceView -X-> AppModel
NativeSurfaceView -X-> CollectorRunner
NativeSurfaceView -X-> ArtifactStore
NativeSurfaceView -X-> SubscriptionService
```

以下数据入口和布局入口保持不变:

- `model.makePanelViewModel()`.
- `UsageHeroCard(viewModel:)`、`SubscriptionCard(viewModel:)`、`HourlyLineCard(viewModel:)`.
- `coordinator.refresh(module)`.
- `cardStackHeight`、`footerHeight`、`Self.maxCardStackHeight`.
- `onContentSizeChange` 和 `resizePanel(to:)`.

## 9. 主题更新流程

```text
设置保存 / 系统外观变化
    ↓
OnboardingCoordinator.resolvedTheme
    ↓
DashboardSurfaceConfiguration
    ├── SwiftUI 环境主题更新
    └── DashboardGlassPanelController.updateSurface(...)
        ↓
NativeSurfaceView 更新材质
```

要求:

- 主题变化只更新现有面板的 surface, 不重新创建 `NSPanel`.
- SwiftUI 内容状态和滚动位置不因主题变化丢失.
- 面板隐藏时可延迟材质更新, 再次显示前必须使用最新主题.
- surface 更新不得触发刷新、重新扫描或网络请求.

## 10. 实施顺序

实施时按以下顺序拆分, 每一步都可以独立回滚:

1. 建立 `DashboardGlassSurfacePlan` 和 token, 不改变画面结构.
2. 新增 AppKit `DashboardGlassPanelController` 和 Native surface, 保持 SwiftUI 内容透明.
3. 将 `MenuBarStatusItemController` 的 hosting 承载切换到新宿主, 保留所有窗口行为.
4. 在 macOS 26 路径接入 `NSGlassEffectView` / `GlassEffectContainer`.
5. 在 macOS 14-25 路径接入 `NSVisualEffectView` 回退.
6. 调整 `PanelCardContainer` 的背景、边框、高光和阴影 token.
7. 仅在实机截图显示内部实体块破坏材质时, 调整统计卡片内部装饰透明度; 默认不改三个内容卡片文件.
8. 完成自动化、实机视觉矩阵和正式版打包前回归.

若视觉改动需要触碰 Collector、Bridge、BruceAppCore 或统计模型, 必须停止并重新确认范围.

## 10.1 实施记录

- 已新增 `DashboardGlassPanelController`, 将 AppKit 系统材质放到面板窗口层, SwiftUI 保持为透明内容层.
- macOS 26 使用 `NSGlassEffectView`; 旧系统、经典主题、哑光主题和辅助功能保护路径使用 `NSVisualEffectView` 或实体回退.
- 主题切换通过 `ResolvedTheme` 回调更新材质, 不重建 `NSPanel`, 不触发刷新和数据状态重置.
- 视觉验证发现把整个卡片栈放入 `GlassEffectContainer` 会使文字和图表产生重影, 因此最终实现采用“单一 AppKit 面板材质 + 独立卡片边界”的稳定组合, 未牺牲布局和内容清晰度.
- 原生材质增加轻量动态 tint, 用于避免浅色语义内容在深色桌面背景上出现不可读的黑字; 不改变用户配置 schema.
- 复测后, 原生 AppKit 面板路径统一关闭卡片层的第二重 SwiftUI glassEffect, 改为由 AppKit 外观动态决定的低对比度半透明卡片表面与边界; 底栏按钮使用低对比度自适应控件面, 避免白色玻璃覆盖内容. 该规则不依赖 SwiftUI `ColorScheme`, 兼容系统外观与窗口背景不一致的情况.

## 11. 测试与验收

### 11.1 纯逻辑测试

覆盖 `DashboardGlassSurfacePlan`:

- macOS 26 + regular -> native Liquid Glass.
- macOS 26 + clear -> native clear glass.
- liquidGlass + material -> AppKit material, 不调用 Liquid Glass.
- classic -> classic material, 不调用 Liquid Glass.
- macOS 14-25 -> AppKit material/fallback.
- 旧配置缺少 `interfaceStyle` -> 现有默认行为.

### 11.2 AppKit 宿主测试

验证:

- 面板内容控制器是 `DashboardGlassPanelController`.
- Native surface 始终铺满 hosting view 的内容区域.
- `fittingSize` 仍能触发面板高度调整.
- 主题切换不创建新面板、不清空 SwiftUI 内容状态.
- 面板隐藏后不保留独立后台刷新或计时器.

### 11.3 现有业务回归

```bash
swift build --package-path macos/BruceApp
zsh scripts/verify-local.sh
zsh scripts/build-test-app.sh
```

至少确认 `PanelViewModelHarness`、`RefreshSchedulerHarness`、`CollectorRunnerHarness`、`ArtifactStoreHarness` 和 `SubscriptionCredentialsHarness` 不受影响. 视觉验证不以实时采集为前置条件.

### 11.4 实机视觉矩阵

| 系统 | 主题 | 检查点 |
|---|---|---|
| macOS 26 | liquidGlass + regular | 原生玻璃、背景融合、卡片连续性 |
| macOS 26 | liquidGlass + clear | 透出程度、文字对比度 |
| macOS 26 | liquidGlass + material | 不调用 Liquid Glass, 使用材质回退 |
| macOS 26 | classic | 传统材质和可读性 |
| macOS 14/15 | classic/material | `NSVisualEffectView` 回退稳定 |
| 任意版本 | 深色/浅色 | 外观同步、边缘对比度 |
| 任意版本 | 多卡片/超高内容 | 充满可用高度、卡片区域滚动、底栏固定 |

验收必须同时满足:

1. 面板成为连续的系统材质面, 不再是固定灰色矩形.
2. 后方桌面或窗口变化时, 面板亮度和模糊有自然变化.
3. 卡片仍可区分, 但不再像多个厚重塑料盒.
4. 面板宽度、卡片顺序、内容、间距和底栏位置不变.
5. 内容不足时继续自适应, 内容过高时仅卡片区域滚动.
6. 订阅、Agent 用量、Bridge、artifact 和刷新流程逐项回归一致.

## 12. 回退与回滚

运行时回退顺序:

```text
macOS 26 原生 NSGlassEffectView
    ↓ API/材质不可用
macOS 14-25 NSVisualEffectView
    ↓ 初始化或渲染失败
现有 SwiftUI material/透明填充
```

回滚只涉及视觉宿主和 token 文件, 不回滚或修改 Collector、Bridge、artifact、订阅和统计文件. 如果实机发现内容尺寸变化, 立即撤销 surface 对布局的影响, 保留原有 `MenuBarDashboardView` 高度链路.

## 13. 实施前检查清单

- [ ] 用户配置 schema 不增加字段.
- [ ] 面板仍为无边框 `NSPanel`.
- [ ] `MenuBarDashboardView` 的宽度、高度、滚动和底栏代码不被重写.
- [ ] Native surface 不依赖业务模型和刷新服务.
- [ ] macOS 26 API 全部处于 `#available` 分支.
- [ ] classic/material 路径不调用 Liquid Glass API.
- [ ] 现有自动化 Harness 保持可执行.
- [ ] macOS 26 和 macOS 14/15 实机截图验证方案已准备.
