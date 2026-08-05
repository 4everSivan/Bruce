## Why

当前 `Package.swift` 将部署目标固定为 `macOS(.v26)`, 主题设置把「标准 / 通透 / 哑光」直接当作液态玻璃变体, 未区分「是否支持液态玻璃」与「玻璃模糊强度」. 要在 macOS 26 以下运行, 必须先把主题模型改成「经典 vs 液态玻璃」两层选择: 低版本只能用经典, 液态玻璃灰显不可用; 仅启用液态玻璃后才展示模糊风格子选项. 这是向下兼容的第一刀, 也避免低版本编译或误用 `glassEffect` API.

## What Changes

- 引入**界面风格**两档: **经典** (classic) 与 **液态玻璃** (liquidGlass).
- **macOS 26 以下**: 液态玻璃选项灰显、不可选; 强制解析为经典; 渲染全部走材质/实体填充, 不调用液态玻璃 API.
- **macOS 26+**: 可选液态玻璃; **仅当选择液态玻璃时**展示模糊子风格 (标准 / 通透 / 哑光, 对应现有 `GlassStylePreference`).
- 设置页 UI 重组: 一级为经典/液态玻璃; 二级为模糊风格 (条件显示).
- 配置持久化: 新增界面风格字段; 兼容旧 `glassStyle` 键 (旧配置在 26+ 默认视为液态玻璃 + 原模糊风格, 在低版本回落经典).
- 渲染层: `GlassTheme` / 面板 / 设置行背景按「能力 + 风格」分支; 使用 `#available(macOS 26, *)` 隔离 API.
- 部署目标: 将 `Package.swift` 最低系统版本下调到本 change 确定的兼容基线 (见 design; 建议至少 macOS 14 或 15, 以实现阶段确认).
- **非本 change**: 不改采集/凭证/Bridge 契约; 不改配色模式 (浅色/深色/跟随系统); 不引入非 AppKit/SwiftUI 主题引擎.

## Capabilities

### New Capabilities

- `theme-presentation`: 界面风格 (经典 / 液态玻璃) 与模糊子风格的能力探测、配置解析、设置页交互与运行时渲染契约.

### Modified Capabilities

- (无既有 main specs 目录条目; 本仓库 `openspec/specs/` 为空, 以新能力为主.)

## Impact

- **配置**: `OnboardingConfiguration` 字段与 `resolved*` 语义; 可能小幅 schema 演进 (保持向后兼容解码).
- **UI**: `SettingsView` 通用区; `GlassTheme.swift`; `MenuBarViews` / `PanelCardContainer` 背景.
- **协调层**: `OnboardingCoordinator` 读写新偏好并在不支持系统上回落.
- **构建**: `Package.swift` platforms; 测试 harness 增加能力矩阵用例.
- **打包**: `build-test-app.sh` / `build-release-app.sh` 在新最低系统上验证可链接.
- **用户**: 从 26-only 升级到兼容版本后, 低系统看到经典主题; 26 用户可继续用液态玻璃.
