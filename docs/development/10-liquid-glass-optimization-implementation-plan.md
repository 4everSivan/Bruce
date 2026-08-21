# 仪表盘液态玻璃视觉优化施工计划

> 关联设计: `docs/development/09-liquid-glass-optimization-design.md`
> 方案: B - 苹果层级材质
> 日期: 2026-08-13
> 状态: 已实施并完成自动化验证

## 1. 施工目标

仅优化 macOS 原生仪表盘的视觉材质, 保持当前布局、内容、交互和统计流程完全不变.

施工完成后应形成以下层级:

```text
NSPanel 透明承载层
  -> Dashboard 外层标准玻璃
      -> Token 用量 / 订阅用量 / Agent 用量卡片通透玻璃
          -> 原有统计内容和控件
      -> 原有底栏操作按钮玻璃样式
```

## 2. 绝对禁止变更范围

施工提交不得修改以下区域:

- `agent-usage/collector/**`
- `bridge/**`
- `MdddAppCore` 中的 Collector、artifact、PanelViewModel、订阅和统计模型.
- 订阅额度采集、刷新、合并、账号状态和凭证处理.
- Agent 会话扫描、token 聚合、成本计算和统计窗口.
- `RefreshScheduler`、`CollectorRunner`、`SubscriptionService` 的业务逻辑.

若视觉改动需要触碰以上文件, 必须停止施工并重新确认范围.

## 3. 允许修改文件

首轮只允许修改以下 SwiftUI 视觉文件:

| 文件 | 允许内容 |
|---|---|
| `macos/MdddApp/Sources/MdddApp/GlassTheme.swift` | 视觉 token、主题 modifier、材质映射 |
| `macos/MdddApp/Sources/MdddApp/MenuBarViews.swift` | 外层面板背景的视觉实现, 不改卡片装配和几何逻辑 |
| `macos/MdddApp/Sources/MdddApp/Views/PanelCardContainer.swift` | 卡片背景、边框、高光和阴影 |
| `macos/MdddApp/Sources/MdddApp/Views/UsageHeroCard.swift` | 仅允许调整内部装饰色和透明度, 默认不改 |
| `macos/MdddApp/Sources/MdddApp/Views/SubscriptionCard.swift` | 仅允许调整内部装饰色和透明度, 默认不改 |
| `macos/MdddApp/Sources/MdddApp/Views/HourlyLineCard.swift` | 仅允许调整内部装饰色和透明度, 默认不改 |

首轮不得修改 `SettingsView`、`SettingsCard` 和设置页布局. 设置页统一视觉另立计划.

## 4. 施工任务

### Task 1: 建立视觉 token

文件: `GlassTheme.swift`

实现内容:

- 增加内部 `GlassSurfaceTokens`.
- 将 panel、card、control 的背景、边框、高光、阴影统一收口.
- token 输入只依赖 `ResolvedTheme` 和 `colorScheme`.
- 不增加 `onboarding-v1.json` 字段.
- 保留 `classic`、`liquidGlass`、`material` 三条现有路径.

验收:

- 低于 macOS 26 时不会访问不可用的玻璃 API.
- `material` 不调用系统玻璃 API.
- 缺省主题行为与当前一致.

### Task 2: 优化外层面板

文件: `MenuBarViews.swift`

只调整 `panelGlassBackground`:

- 保持宽度 440pt.
- 保持 `ScrollView`、高度测量、屏幕最大高度和底栏逻辑.
- 保持圆角 22.
- 液态玻璃模式使用标准系统玻璃作为唯一主要背景.
- 移除或降低额外纯色叠加.

禁止:

- 修改 `cardStack` 的卡片顺序.
- 修改 `.frame(height:)`、`.fixedSize`、`onGeometryChange` 和滚动行为.
- 修改面板内容或刷新按钮行为.

### Task 3: 优化卡片容器

文件: `PanelCardContainer.swift`

- 保持现有圆角 16、内边距和卡片间距.
- 使用通透玻璃层级, 让外层背景可见.
- 边框改为低对比度动态边缘色.
- 弱化固定顶部白色高光.
- 浅色保留轻微深度, 深色避免厚重黑影.
- 所有视觉参数来自 Task 1 token.

禁止:

- 直接改写传入 `Content`.
- 改变卡片高度或内容布局.
- 增加新的卡片包装层.

### Task 4: 优化底栏按钮

文件: `PanelCardContainer.swift` 或 `GlassTheme.swift`

- 保持刷新、设置、退出按钮顺序、文字和可访问性.
- 液态玻璃模式使用与面板外观自适应的低对比度控件面, 不使用会生成白色高亮块的系统 `.glass` 按钮.
- 经典模式保持默认按钮样式.
- 只调整材质和视觉层级, 不改 action 和 disabled 条件.

### Task 5: 收敛内部装饰

文件: `UsageHeroCard.swift`、`SubscriptionCard.swift`、`HourlyLineCard.swift`

默认策略是零改动. 只有在截图验证发现内部固定背景明显破坏玻璃层级时, 才允许:

- 降低小块背景透明度.
- 降低分隔线对比度.
- 调整进度条轨道透明度.
- 复用 `GlassSurfaceTokens` 的颜色.

不得修改:

- ViewModel 类型.
- ForEach 数据源.
- 文案和字段.
- 统计数字、计算、排序和条件渲染.

### Task 6: 主题能力矩阵验证

不改配置 schema, 仅验证以下组合:

| 系统能力 | interfaceStyle | glassStyle | 预期 |
|---|---|---|---|
| false | classic | regular | 经典材质 |
| false | liquidGlass | clear | 强制经典材质 |
| true | classic | clear | 经典材质 |
| true | liquidGlass | regular | 标准系统玻璃 |
| true | liquidGlass | clear | 通透系统玻璃 |
| true | liquidGlass | material | 材质回退 |
| true | 缺省 | 缺省 | 默认标准系统玻璃 |

## 5. 实施顺序与提交拆分

每个阶段独立提交, 便于回滚:

1. `glass-theme-tokens`: 增加 token 和 modifier, 不改变画面.
2. `dashboard-panel-surface`: 只切换外层面板材质.
3. `dashboard-card-surface`: 只切换卡片背景、边缘和阴影.
4. `dashboard-control-surface`: 只调整底栏按钮材质.
5. `dashboard-detail-polish`: 如有必要, 调整内部装饰透明度.
6. `dashboard-visual-validation`: 只补测试、截图说明和验收记录.

每次提交前检查:

```text
git diff --name-only
```

若出现 Collector、Bridge、MdddAppCore、订阅或统计相关文件, 立即停止.

## 6. 验证计划

### 6.1 静态验证

- `git diff --check`.
- 确认没有新增配置字段.
- 确认没有修改 artifact、ViewModel 和统计相关文件.
- 确认没有新增网络、文件或 Keychain 调用.

### 6.2 构建和 Harness

```bash
swift build --package-path macos/MdddApp
swift run --package-path macos/MdddApp MdddOnboardingCoreHarness
swift run --package-path macos/MdddApp PanelViewModelHarness
swift run --package-path macos/MdddApp RefreshSchedulerHarness
zsh scripts/verify-local.sh
```

其中:

- `MdddOnboardingCoreHarness` 验证主题配置兼容和回退.
- `PanelViewModelHarness` 验证内容映射不变.
- `RefreshSchedulerHarness` 验证刷新和统计流程没有被触碰.
- `verify-local.sh` 作为最终构建基线.

### 6.3 视觉验证

至少验证:

- macOS 26 浅色 + regular.
- macOS 26 深色 + regular.
- macOS 26 + clear.
- macOS 26 + material.
- 低版本 macOS 经典回退.
- 多屏、不同壁纸和面板接近屏幕边缘的情况.
- 内容不足时的自然高度.
- 内容超出屏幕时的最大高度和滚动行为.

视觉比较只检查:

- 材质融合.
- 透明度.
- 边缘高光.
- 卡片层级.
- 文本可读性.

不得以“调整布局”为视觉优化手段.

## 7. 验收标准

### 7.1 内容和布局

- 面板仍为 440pt.
- 三张现有卡片顺序不变.
- 文字、数字、统计区块和按钮不变.
- 底栏位置和高度行为不变.
- 滚动和自动高度行为不变.

### 7.2 业务流程

- 订阅统计流程无代码和测试变化.
- Agent 用量统计流程无代码和测试变化.
- Collector、Bridge、artifact 和 ViewModel 无变化.
- 授权、刷新、凭证和错误处理无变化.

### 7.3 视觉

- 外层面板具有明显的系统玻璃环境融合.
- 卡片不再是多个高不透明度白色矩形.
- 卡片边缘不再依赖明显白色描边.
- 深色模式不出现厚重黑色阴影.
- 按钮、卡片、面板属于同一材质体系.
- 视觉接近苹果系统, 但不牺牲数据可读性.

## 8. 回滚方案

出现以下任一情况时回滚最近一个视觉提交:

- 卡片内容或顺序改变.
- 面板高度、滚动或底栏行为改变.
- 统计测试失败.
- 低版本系统构建失败.
- 文本对比度不足.
- 玻璃效果在深色模式下出现明显发黑或闪烁.

回滚只允许撤销视觉相关提交, 不得使用全仓库重置命令覆盖其他工作区修改.

## 9. 完成定义

- 设计文档和施工计划通过审阅.
- 视觉 token 和 modifier 已完成收口.
- 面板、卡片和按钮完成 B 方案材质层级.
- 统计、订阅、artifact 和刷新流程保持不变.
- 构建、Harness 和全量验证通过.
- macOS 26 与低版本回退均完成视觉验收.

## 10. 已完成施工记录

已完成的代码改动仅涉及:

- `GlassTheme.swift`: 增加统一 surface token、面板/卡片背景共享实现和卡片通透层级.
- `MenuBarViews.swift`: 面板背景改为调用统一玻璃背景实现.
- `PanelCardContainer.swift`: 使用统一 token 调整卡片边缘、高光、阴影和背景层级.

未修改:

- `UsageHeroCard.swift`、`SubscriptionCard.swift`、`HourlyLineCard.swift` 的内容和布局.
- 订阅统计、Agent 用量统计、Collector、Bridge、artifact、ViewModel 和刷新逻辑.

验证结果:

- `swift build --package-path macos/MdddApp` 通过.
- `zsh scripts/verify-local.sh` 通过.
- Python 测试: 以当前 `pytest` 收集结果为准.
- Onboarding Core Harness: 175 项通过.
- PanelViewModel Harness: 41 项通过.
- RefreshScheduler Harness: 62 项通过.
- 其余 Artifact、CollectorRunner、NativeLifecycle、Diagnostics、LocalIntegration、DeepSeekUsageLedger、SubscriptionCredentials、GlobalHotkey 和 AppModel 缓存 Harness 全部通过.
