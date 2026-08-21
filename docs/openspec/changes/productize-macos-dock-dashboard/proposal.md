## Why

现有项目已经具备 Agent token、额度和仓库热力图的采集与展示能力, 但仍是由独立脚本和宿主 Widget 组成的本机工具集合, 缺少统一的 macOS 应用生命周期、登录授权、定时刷新、故障隔离和安全凭证边界.

本变更把现有 Collector 和视觉设计产品化为个人电脑使用的独立 macOS Dock 应用, 在最大限度复用 Python 与 HTML/CSS 资产的前提下, 建立可验证、可恢复且不泄露凭证的运行架构.

## What Changes

- 新增独立 macOS Dock 应用壳, 提供主窗口、模块导航、Dock badge、后台驻留和手动刷新.
- 保留现有 Agent、GitHub 和 GitLab Widget 的视觉与风格, 通过 `WKWebView` 托管, 不进行原生 UI 重绘.
- 新增首次启动扫描与配置流程, 检测 Python 3、`gh` CLI、VPN/服务可达性、本机会话和已有登录态.
- 新增应用内官方登录窗口和统一授权流程; OAuth token 存入 macOS Keychain, PAT/API Key 通过安全配置表单录入.
- 新增统一 Python Bridge, 通过 stdin 接收临时凭证与运行参数, 调用现有 `run(ctx)` Collector, 输出版本化结果 envelope.
- 新增默认每 30 分钟自动刷新、手动刷新、防重入、超时、有限退避和系统唤醒补采.
- 新增 artifact schema 校验、原子快照、最后成功结果回退和过期状态提示.
- 调整 Collector 的凭证刷新边界: Python 返回 `credentialUpdates`, 由 Swift 写入 Keychain; App 模式下 Python 不直接修改认证文件.
- 保持现有 Collector CLI 与 `--out` 行为兼容.
- 新增隔离测试、契约测试、Swift 调度测试和 Widget 视觉回归测试; CI 不访问真实账号.

## Capabilities

### New Capabilities

- `macos-dock-app`: 独立 Dock 应用的窗口、导航、生命周期、Dock badge 和状态展示.
- `provider-onboarding-auth`: 本机依赖扫描、服务配置、应用内登录、统一授权、Keychain 存储和重新授权.
- `scheduled-collector-runtime`: Python Bridge、30 分钟调度、手动刷新、防重入、超时、取消、失败退避与模块隔离.
- `artifact-cache-contract`: 版本化运行 envelope、artifact schema、credential update 隔离、原子快照和最后成功结果.
- `widget-visual-hosting`: 使用 `WKWebView` 原样托管现有 Agent/GitHub/GitLab Widget, 并保持既有视觉基线.

### Modified Capabilities

无. 当前 `openspec/specs/` 不存在已归档能力规范.

## Impact

- 新增 SwiftUI/AppKit macOS 应用工程、Keychain 访问、`WKWebView` 宿主、调度器和本地缓存.
- 新增 Python Bridge 与 JSON Schema; 现有 Collector 将逐步使用 `ctx` 获取时间、路径、凭证和 HTTP 依赖.
- 修改 `agent-usage`, `github`, `gitlab` Collector 的 App 模式接口, 同时保持现有 CLI 兼容.
- 复用并测试三个现有 `widget/index.html`; 动态字段必须安全注入或转义.
- 个人电脑 MVP 允许依赖本机 Python 3、`gh` CLI、VPN 和现有服务账号, 不引入远端后端.
- 凭证迁移到 macOS Keychain; 真实凭证、账号活动数据和运行快照不得进入仓库或测试 fixture.
