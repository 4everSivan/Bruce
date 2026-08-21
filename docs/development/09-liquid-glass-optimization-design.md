# 仪表盘液态玻璃视觉优化设计

> 版本: 1.0
> 日期: 2026-08-13
> 方案: B - 苹果层级材质
> 状态: 已实施并完成自动化验证

## 1. 设计目标

在不改变当前仪表盘布局、内容、统计数据和交互的前提下, 提升 macOS 原生液态玻璃的接近度:

- 让系统玻璃成为主视觉, 而不是静态半透明卡片.
- 建立“外层面板 -> 内容卡片 -> 操作控件”的材质层级.
- 减少固定白色填充、重复边框和人工高光造成的塑料感.
- 保持浅色、深色和低版本系统的可读性与稳定回退.
- 让实际 macOS 26 渲染比当前浏览器视觉预览更接近系统效果.

## 2. 严格范围冻结

### 2.1 允许修改

- 仪表盘面板背景材质.
- 卡片容器背景、边框、高光和阴影.
- 底栏按钮的玻璃层级.
- 组件内部纯视觉装饰的透明度和颜色 token.
- 主题解析后的视觉 token 映射.

### 2.2 禁止修改

- 订阅额度采集、解析、刷新、合并和状态判断.
- Agent 用量扫描、聚合、成本计算和统计时间窗口.
- Collector、Bridge、artifact schema、AppModel 数据结构.
- 卡片顺序、卡片内容、文字、统计字段和条件显示逻辑.
- 自动刷新、授权、Keychain、账号排序和失败恢复流程.

当前仪表盘结构必须保持:

```text
固定宽度面板
  -> Token 用量卡
  -> 订阅用量卡
  -> Agent 用量卡
  -> 固定底栏操作区
```

## 3. 目标视觉模型

### 3.1 三层材质层级

```text
Level 1: Dashboard Panel
  标准系统玻璃, 负责整体背景和环境融合

Level 2: Panel Card
  通透玻璃, 只提供内容分组和轻微分离

Level 3: Controls
  系统玻璃按钮或低对比度控件, 只在交互位置提供高亮
```

不再让每一层都使用相同的不透明度、边框和阴影.

### 3.2 面板层

- 保持现有 440pt 宽度、动态高度和滚动行为.
- 保持 `NSPanel` 的透明、非 opaque 和阴影设置.
- 液态玻璃模式使用标准系统玻璃作为唯一主背景.
- 不再叠加额外的大面积纯色背景.
- 圆角继续保持当前 22pt, 不改变外部几何布局.

### 3.3 卡片层

- 保持当前卡片圆角、内边距和卡片间距.
- 卡片背景改为低填充通透玻璃, 让面板背景保持可见.
- 边框从固定白色改为随明暗模式变化的低对比度边缘色.
- 顶部高光从固定白线改为非常弱的材质边缘强调, 避免“描边卡片”效果.
- 浅色模式保留轻微深度, 深色模式使用更低对比度, 不产生黑色投影块.

### 3.4 内容层

所有统计内容保持原样. 只允许调整以下纯视觉属性:

- 月份块、标签和轨道的背景透明度.
- 分隔线的对比度.
- 进度条轨道和填充色的透明度.
- 内容区域与玻璃背景的对比度.

不得修改任何 ViewModel 字段、数据计算、排序或条件分支.

### 3.5 底栏层

- 保持底栏位置、操作顺序和按钮文字.
- 液态玻璃模式使用与面板外观绑定的低对比度自适应控件面, 避免通透背景下白色高亮覆盖图标.
- 经典模式继续使用原有默认按钮风格.
- 底栏顶部发线降低存在感, 只作为结构分隔.

## 4. 代码组织方案

### 4.1 新增统一视觉 token

建议在 `GlassTheme.swift` 中增加内部视觉 token, 不写入用户配置文件:

```text
GlassSurfaceTokens
  panelShape
  cardShape
  panelMaterial
  cardMaterial
  borderColor
  highlightColor
  shadowStyle
  controlMaterial
```

token 由以下状态决定:

- `ResolvedTheme.interfaceStyle`.
- `ResolvedTheme.glassStyle`.
- `colorScheme`.
- 系统能力是否支持 macOS 26 玻璃 API.

视图只使用 token 和统一 modifier, 不再在多个文件中重复透明度常量.

### 4.2 统一面板和卡片 modifier

建议提供两个内部 modifier:

```text
dashboardGlassPanel()
dashboardGlassCard()
```

它们只负责背景、边框、高光和阴影, 不负责内容布局.

使用位置:

- `MenuBarDashboardView.panelGlassBackground`.
- `PanelCardContainer`.
- 底栏按钮样式.

`UsageHeroCard`、`SubscriptionCard`、`HourlyLineCard` 保持内容结构不变, 默认不直接重写.

### 4.3 设置页处理边界

本次重点是仪表盘. 设置页不进行布局重构, 只保留后续可选的 token 接入点.

如果后续统一设置页视觉, 只能替换 `SettingsCard` 的背景实现, 不改变设置项顺序、控件类型和配置读写逻辑.

## 5. 配置兼容策略

不增加新的用户配置字段, 继续使用:

```json
{
  "appearanceMode": "system",
  "interfaceStyle": "liquidGlass",
  "glassStyle": "regular"
}
```

规则保持不变:

- `classic`: 不调用液态玻璃 API.
- `liquidGlass + regular`: 标准系统玻璃.
- `liquidGlass + clear`: 通透系统玻璃.
- `liquidGlass + material`: 使用材质回退, 不调用玻璃 API.
- macOS 低于 26: 强制经典回退.
- 旧配置缺少主题字段: 按现有默认规则解析.

视觉 token 属于代码内设计规范, 不暴露为用户可调参数, 避免配置文件变成不稳定的 CSS 参数集合.

## 6. 施工阶段

### 阶段 A: 视觉基线冻结

- 保存当前仪表盘浅色、深色和不同背景下的截图.
- 记录当前卡片尺寸、间距、顺序和文字快照.
- 确认 `PanelViewModel` 和 artifact 输出在改造前后完全一致.

### 阶段 B: 统一视觉 token

- 在 `GlassTheme.swift` 建立 token 和 modifier.
- 迁移面板和卡片的重复透明度、边框和阴影常量.
- 不改变任何内容 View 的数据输入.

### 阶段 C: 应用 B 方案层级

- 外层面板使用标准玻璃.
- 卡片使用通透玻璃.
- 底栏使用与明暗外观自适应的低对比度控件面.
- 减少卡片顶部高光和固定白色边框.
- 调整内部小块的透明度, 保留现有结构.

### 阶段 D: 可读性与系统回退

- 验证浅色/深色模式.
- 验证 macOS 26 玻璃路径.
- 验证 macOS 14-25 经典回退.
- 验证 `material` 选项的材质回退.
- 验证动态背景下的文本对比度.

### 阶段 E: 视觉验收

- 使用与当前浏览器预览相同的面板结构进行截图对比.
- 只比较材质、边缘、高光、透明度和层级.
- 若卡片尺寸、文字或内容顺序发生变化, 视为失败并回滚.

## 7. 验收标准

### 7.1 结构不变

- 面板宽度仍为 440pt.
- 卡片顺序和底栏位置不变.
- 卡片内容和文字不变.
- 卡片高度变化只允许来自系统材质渲染误差, 不允许来自布局重写.

### 7.2 数据流程不变

- 订阅模块输出与改造前逐字段一致.
- Agent 用量输出与改造前逐字段一致.
- artifact、ViewModel 和统计测试不需要修改.
- 不新增网络请求、刷新请求或凭证读取.

### 7.3 视觉效果改善

- 背景能够透过面板和卡片形成层次.
- 卡片不再呈现大面积固定白色或灰色块.
- 边缘高光自然且不形成明显描边.
- 深色模式不出现厚重黑色阴影.
- 按钮与卡片属于同一材质体系.
- 整体观感更接近 macOS 原生玻璃, 而不是普通半透明卡片.

## 8. 验证与回滚

验证命令:

```text
swift build --package-path macos/BruceApp
zsh scripts/verify-local.sh
swift run --package-path macos/BruceApp PanelViewModelHarness
swift run --package-path macos/BruceApp RefreshSchedulerHarness
```

视觉改造提交必须满足:

- Collector 和 Bridge 文件无变更.
- 订阅和 Agent 统计相关测试无需改动.
- artifact fixture 无变化.
- 失败时只回滚 `GlassTheme.swift`、面板容器和视觉 modifier 相关改动.

## 9. 当前结论

B 方案是本项目的推荐方向: 保持当前仪表盘的内容和布局, 只把玻璃渲染从“多层静态卡片”调整为“系统面板玻璃 + 通透内容卡片 + 自适应控件面”的层级体系.

本设计确认后才进入实施计划阶段. 当前文档不代表代码已经修改.
