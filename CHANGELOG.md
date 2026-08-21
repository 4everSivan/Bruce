# Changelog

All notable changes to this project will be documented in this file.

## [0.4] - 2026-08-21

### Added

- **全局快捷键与原生状态项**: 新增可配置全局快捷键呼出看板 (设置「通用」分区录制, 组合被占用时非致命提示); `MenuBarExtra` 重构为原生状态项 + 无边框面板, 状态栏标签改用模板图片渲染, 深浅外观下尺寸与着色稳定, 面板关闭后焦点正确归还。
- **Pi agent 用量**: 新增 Pi 会话本地扫描 (会话路径经运行上下文注入), 数据源、服务拓扑与面板配色并列展示。
- **ZCode CLI 会话扫描**: 新增 ZCode CLI 会话用量统计, 与 Kimi/Claude/Codex/Grok/OpenCode 并列展示; 同步更新应用图标。
- **智谱 GLM Coding Plan 订阅额度**: 新增 Zhipu GLM Coding Plan 个人订阅额度采集与展示。
- **订阅额度 Provider 定向刷新**: Scheduler 支持按 Provider 定向刷新并联动面板刷新状态, 定向快照合并保留单 Provider 失败语义; Bridge/Collector 增加 quota-only Provider 白名单与凭证隔离。

### Changed

- **项目更名 mddd → Bruce**: 应用、构建产物 (`Bruce.app`/`Bruce.zip`)、CI 发布标题与文档统一更名为 Bruce。
- **Kimi 订阅额度切换 API Key**: Kimi 额度采集从 Web Tokens 切换为 Kimi For Coding API Key 查询。
- **用量档位与热力图刻度统一**: 用量档位与热力图等级统一为 100M 绿色刻度, OpenCode agent 使用独立绿色。
- **液态玻璃面板优化**: 统一面板玻璃表面矩阵, 提升液态玻璃对比度并打磨面板与刷新指示细节。
- **设置窗口卡片化**: 设置窗口重构为卡片化 UI 体系, 应用版本号改为动态单一真源。
- **README 重写**: 重整文档结构与发布信息, 应用图标启用圆角版本。

### Fixed

- **Claude 用量少计修复**: 重复写入的 Claude 消息按完整 usage 条目计数, 修复骨架消息导致的用量低估。
- **菜单栏缓存误失效修复**: 菜单栏摘要缓存与面板缓存版本分离, 不再相互触发重建。

---

## [0.3.0] - 2026-08-10

### Added

- **OpenCode Go 订阅额度**: 接入 opencode.ai 网页控制台的 Go 订阅用量 (滚动/每周/每月窗口), 支持多账号 Keychain 凭证管理与统一窗口语义 (每 5 小时/每周/每月, 服务端无窗口不显示)。
- **OpenCode agent 用量**: 新增 OpenCode 会话本地扫描 (只读 SQLite), 精确 token 计数与模型/项目分布, 与 Kimi/Claude/Codex/Grok 并列展示。
- **用量卡增强**: 新增 26 周用量热力图、月度聚合分解与用量档位指示 (UsageHeroCard/HourlyLineCard)。

### Changed

- **Keychain 访问免弹窗**: 显式宽松 ACL, 避免 ad-hoc 签名下每次启动刷新触发授权密码框。
- **刷新与内存优化**: 本地扫描改串行执行 (内存降约 27%, 耗时降约 35%), 跳过超长 JSONL 行避免碎片化分配; 清理 `collect_usage.py` 死代码。
- **CPU 优化**: 用量卡代码流背景与 LIVE 指示改为静态渲染, 移除窗口隐藏后仍持续驱动 SwiftUI 渲染循环的动画 (主线程 CPU 由 20-40% 降至约 0%)。
- **启动提速**: 凭证异步后台加载与快速初始菜单栏指标渲染。

---

## [0.2] - 2026-08-06

### Added

- **多账号订阅凭证管理**: 支持火山引擎 (Volcengine)、Kimi Web Tokens 以及 DeepSeek API Keys 的多账号 Keychain 持久化保存、标签管理与配额并行采集。
- **主题降级与多版本兼容**: 新增 `ThemeResolution` 解析模块，支持 macOS 14+ 经典玻璃与 macOS 26+ 液态玻璃主题自动适应与降级防护。
- **刷新调度与执行管道重构**: 引入 `RefreshIntent`、`RefreshExecutionPipeline` 与 `CredentialUpdateCoordinator`，提升并发刷新稳定性与异常恢复能力。
- **测试套件拓展**: Harness 测试扩充至 388 项 Swift 测试（涵盖多账号凭证存储、刷新调度与映射），Pytest 契约测试扩充至 162 项。

### Changed

- 优化 `SubscriptionCard` 与 `HourlyLineCard` 面板卡片字号、布局及 24 点折线图渲染表现。
- 规范化请求结构 Schema 定义 (`request-v1.schema.json`)。

---

## [0.1] - 2026-08-05

### Added

- **macOS 原生菜单栏应用 (Bruce)**: 原生 SwiftUI 液态玻璃看板，支持 Agent 用量、成本、额度监控与趋势折线图展示。
- **订阅凭证校验与管理**: 支持 Kimi Web Tokens、火山引擎 API Key、DeepSeek API Key、Codex OAuth 以及 Antigravity OAuth 凭证导入、自动生成与 Keychain 安全存储。
- **DeepSeek 月度账本**: 支持 DeepSeek 月度 Token 消费追踪、每日差分增量算法与跨日持久化账本。
- **Claude & Grok 官方额度采集**: 自动探测 CLI Keychain 与登录会话，支持 Claude Code 与 Grok 官方订阅额度只读采集。
- **配额预警与系统通知**: 支持额度临界线计算、预警去重、通知中心提示与自动恢复判定。
- **模块化 Collector 架构**: 解耦 `pricing`、`runtime`、`quota_services`、`local_usage`、`codex_compat` 与 `quota_official` 独立数据管道。
- **多账号 Codex 刷新与故障恢复**: 支持多账号合并诊断、自动 Token 轮换、401 故障重试与去重。
- **本地 Harness 测试套件**: 提供 10 个独立 Swift Harness（352 项 Swift 测试）与 Python 契约测试（155 项 Pytest 测试）。

### Changed

- 打包脚本产物重命名为 `dist/Bruce.app` 与 `dist/Bruce.zip`（去除了 `test` 后缀）。
- 应用 Icon 正式采用原生 AppIcon 资源与规范文档。
