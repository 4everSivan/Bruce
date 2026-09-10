# 设置页状态与控件调整设计

- 日期: 2026-09-10
- 范围: macOS 设置窗口的 Agent 用量状态展示与通用页访问控件布局
- 用户选择: Agent 用量采用 A; 通用设置采用 B
- 不涉及: Collector 采集逻辑、依赖扫描规则、Keychain 访问策略、配置数据格式和刷新行为

## 背景

当前 Agent 用量页把缺失的 OpenCode/Pi 会话源显示为黄色“未授权”, 同时在卡片底部追加“暂不可用”警告。对明确缺失的本机目录而言, 该表达与实际原因不一致, 也造成重复信息。

通用页的系统通知、钥匙串访问和外部 CLI 来源控件虽然功能正确, 但右侧控件层级不统一: 钥匙串动作使用普通按钮, 外部来源使用纵向系统开关, 与当前 Fluent 平面行的单行控制区不一致。

## 目标

1. 缺失的 Agent 会话源在原状态位置直接显示灰色“未安装”。
2. 删除由“未安装”状态重复产生的底部“暂不可用”提示, 不改变其他诊断信息。
3. 通用页的关键动作使用现有 Fluent 按钮体系, 保持行高、间距、边框和颜色 token 一致。
4. 外部 CLI 来源改为“管理”入口, 在独立的 Fluent 风格管理面板中保留 Claude/Grok 开关。
5. 不改变现有配置写入、Keychain 读取、通知开关和外部来源白名单语义。

## 设计

### 1. Agent 用量不可用状态 (方案 A)

`SettingsView.agentUsagePane` 根据 `DependencyProbe.status` 映射尾部状态:

| 状态 | 视觉 | 文案 | 底部提示 |
|------|------|------|----------|
| `available` | 绿色状态点 + 次级文字 | `就绪` | 不变 |
| `missing` | 无状态点, `text3` 灰色文字 | `未安装` | 隐藏同一会话源的 `暂不可用` 警告 |
| 其他不可用状态 | 黄色状态点 + warning 文字 | 保留现有 `未授权` | 保留现有诊断/阻塞信息 |

这里仅改变展示层, 不把 `missing` 改写成其他 `LocalDependencyStatus`, 也不改变 `ReadinessEvaluator` 的 warnings 和 module readiness。为避免误删诊断, 底部 warning 过滤只针对对应的 `missing` 会话源, Kimi Work 现有过滤规则继续保留。

### 2. 通用页访问控件 (方案 B)

#### 2.1 系统通知

保留现有系统开关和“已开启/已关闭”文本, 只统一右侧控制区间距。开关仍调用 `setSystemNotificationsEnabled`, 不改变“应用层关闭而不撤销 macOS 权限”的语义。

#### 2.2 钥匙串访问

保留状态文本:

- `已配置`: 绿色次级状态文字。
- `未配置` / `访问被阻断`: 现有状态文字。

把右侧动作按钮统一为 `FluentButtonStyle(.primary)`, 使“重新配置/配置/修复”成为明确的主操作。按钮仍调用 `configureKeychainAccess`, 不新增凭证读取入口。

#### 2.3 外部 CLI 来源

主行右侧只显示 `管理` 普通 Fluent 按钮, 点击后打开一个小型管理 sheet。sheet 使用现有 `FluentCard` / `FluentRow` 和 Fluent token, 在两行中展示:

- `Claude CLI` 开关。
- `Grok CLI` 开关。

开关的读写绑定继续使用 `externalKeychainSources` 和 `setExternalKeychainSource`; 打开或关闭来源时不立即读取 CLI 凭证。sheet 关闭后不改变外部来源之外的任何设置。

#### 2.4 首次配置引导

钥匙串首次配置引导的 `现在配置` 按钮也改用 `FluentButtonStyle(.primary)`, 使设置页内的主操作样式一致; 行为保持不变。

## 组件边界

- `SettingsView`: 负责状态文案、行内布局、管理 sheet 的展示状态和 SwiftUI binding。
- `FluentSettingsChrome.swift`: 复用现有 `FluentButtonStyle`, `FluentCard`, `FluentRow` 和 `SettingsDemoTokens`; 本次不新增视觉 token。
- `AppModel` / `OnboardingCoordinator`: 不新增业务状态, 继续作为现有数据和动作入口。

## 错误与降级

- 缺失会话源只显示灰色“未安装”, 不再以警告色模拟授权问题。
- 被锁定、损坏、超时或不兼容的会话源继续保留黄色状态和已有诊断, 避免把真实故障误报为未安装。
- 管理 sheet 无需额外权限; 保存失败仍由现有 `settingsErrorMessage` 显示。
- sheet 关闭或窗口复用不清空来源配置。

## 验证

1. `swift build --package-path macos/BruceApp`。
2. 运行现有 `BruceOnboardingCoreHarness` 和 `PanelViewModelHarness`, 确认核心状态和面板映射未受影响。
3. 构建 `dist/Bruce.app`, 手工检查:
   - OpenCode/Pi 为 missing 时右侧仅显示灰色“未安装”, 不显示重复底部警告。
   - 其他异常状态仍保留黄色诊断。
   - 钥匙串主动作变为 Fluent 主按钮。
   - 外部 CLI 行显示“管理”, sheet 内开关可正常持久化。
   - 系统通知行为和现有配置值不变。
4. `git diff --check`。

## 不做的事

- 不修改 Agent 探测路径、扫描状态或就绪度计算。
- 不删除或迁移任何外部 CLI 凭证。
- 不将外部 CLI 开关改为默认开启或关闭。
- 不引入新的设计系统、颜色 token 或第三方 UI 组件。
