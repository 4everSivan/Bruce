## 1. 模型与解析

- [x] 1.1 新增 `InterfaceStylePreference` (`classic` / `liquidGlass`) 与 `LiquidGlassCapability` (可注入 `isSupported`)
- [x] 1.2 新增纯函数 `ThemeResolution.resolve(interface:glass:isSupported:)` 返回 resolved 界面风格 + 模糊风格
- [x] 1.3 `OnboardingConfiguration` 增加可选 `interfaceStyle`; 解码兼容缺键; `resolvedInterfaceStyle` / 更新 `resolvedGlassStyle` 语义
- [x] 1.4 OnboardingCore harness: 旧仅 `glassStyle`、不支持系统回落 classic、往返 classic/liquidGlass、注入 capability 矩阵

## 2. 协调与设置 UI

- [x] 2.1 `OnboardingCoordinator` 暴露 `interfaceStyle` 与 `setInterfaceStyle`; 不支持系统 fail-closed 拒绝 liquidGlass
- [x] 2.2 `SettingsView` 通用区: 「界面风格」经典 | 液态玻璃; 液态玻璃在 `!isSupported` 时 disabled + 旁注「需要 macOS 26」
- [x] 2.3 仅当 resolved 为液态玻璃且支持时显示「模糊风格」标准 | 通透 | 哑光 (绑定现有 `GlassStylePreference`)
- [x] 2.4 隐藏/移除旧的单层「液态玻璃」三分段作为唯一入口; 无障碍文案更新

## 3. 渲染隔离

- [x] 3.1 `GlassTheme`: classic 路径禁用 `glassEffect` / `.buttonStyle(.glass)`; liquid 路径保留 `#available(macOS 26, *)`
- [x] 3.2 `MenuBarViews` 面板背景与 `PanelCardContainer` 按 resolved 界面风格分支
- [x] 3.3 环境注入同时提供 interface + glass (或单一 `ResolvedTheme` 环境键), 避免子视图各自猜测
- [x] 3.4 全仓检索 `glassEffect` / `Glass` / `.glass` 按钮, 确保无裸调用

## 4. 部署目标与编译

- [x] 4.1 `Package.swift` platforms 下调至 macOS 14
- [x] 4.2 修复因降平台暴露的主题外最小编译错误 (仅阻断链接的 26-only API; 大改另开任务)
- [x] 4.3 `swift build` + `swift run` 相关 harness 全绿

## 5. 验证与文档

- [x] 5.1 手动验收矩阵: 模拟 isSupported false/true × classic/liquid × 三模糊风格 (纯函数 harness 覆盖)
- [x] 5.2 `swift build` 全绿; 打包脚本 `LSMinimumSystemVersion` 改为 14.0
- [x] 5.3 更新 README / AGENTS 中「macOS 26」硬性表述为最低版本 + 液态玻璃需 26
- [x] 5.4 确认旧配置文件在 26 与低版本上的解析行为符合 spec 场景 (harness)
