# Changelog

All notable changes to this project will be documented in this file.

## [0.1] - 2026-08-05

### Added

- **macOS 原生菜单栏应用 (mddd)**: 原生 SwiftUI 液态玻璃看板，支持 Agent 用量、成本、额度监控与趋势折线图展示。
- **订阅凭证校验与管理**: 支持 Kimi Web Tokens、火山引擎 API Key、DeepSeek API Key、Codex OAuth 以及 Antigravity OAuth 凭证导入、自动生成与 Keychain 安全存储。
- **DeepSeek 月度账本**: 支持 DeepSeek 月度 Token 消费追踪、每日差分增量算法与跨日持久化账本。
- **Claude & Grok 官方额度采集**: 自动探测 CLI Keychain 与登录会话，支持 Claude Code 与 Grok 官方订阅额度只读采集。
- **配额预警与系统通知**: 支持额度临界线计算、预警去重、通知中心提示与自动恢复判定。
- **模块化 Collector 架构**: 解耦 `pricing`、`runtime`、`quota_services`、`local_usage`、`codex_compat` 与 `quota_official` 独立数据管道。
- **多账号 Codex 刷新与故障恢复**: 支持多账号合并诊断、自动 Token 轮换、401 故障重试与去重。
- **本地 Harness 测试套件**: 提供 10 个独立 Swift Harness（352 项 Swift 测试）与 Python 契约测试（155 项 Pytest 测试）。

### Changed

- 打包脚本产物重命名为 `dist/mddd.app` 与 `dist/mddd.zip`（去除了 `test` 后缀）。
- 应用 Icon 正式采用原生 AppIcon 资源与规范文档。
