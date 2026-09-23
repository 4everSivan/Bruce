# 变更日志 (CHANGELOG)

所有对本项目的显著变更均记录于此文件。
格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号严格遵循 [语义化版本 (SemVer)](https://semver.org/lang/zh-CN/)。

---

## [Unreleased] - 待发布

### Added
- **现行系统设计基线体系**: 依据 `ad-flow` 治理规范与标准化 8 节大纲，提炼并定稿 5 篇现行设计基线文档（`docs/devel/design/00~04`），覆盖系统宏观架构、多模型计费引擎、POSIX 0600 安全凭据存储、赛博环形菜单栏渲染及价格校准交互。

### Changed
- **工程目录 Monorepo 分层重构**: 根目录历史碎片与平台目录全面重组为 `apps/`（`apps/macos`, `apps/widget`）应用层与 `core/`（`core/collector`）核心引擎层；更新全部构建验证脚本与运行时探测；清理 4.4GB 本地 Rust 构建调试缓存。双向回链变更卡 `[C001](docs/devel/change/C001.json)`。
- **历史文档归档与设计真理源纯化**: 将历史过程文档目录 `docs/development/` 与旧版原型目录 `docs/design/` 完整隔离迁移至 `_adflow_backup/original_docs/`，消除历史多头维护；同步修订现行微设计文档 `00~04.md` 与设计中枢索引，杜绝悬空死链。双向回链变更卡 `[C002](docs/devel/change/C002.json)`。

---

## [0.9.0] - 2026-09-23

### Added

- **模型计费与价格校准引擎**:
  - Rust Collector 内置 26 款主流大模型官方基准定价表（覆盖 OpenAI、Anthropic、DeepSeek、火山引擎、Google、Moonshot 等），支持模型名称前缀智能匹配与模糊解析；
  - 恢复全局与单模型/单 Agent 维度的 Token 成本（`costUsd`）精确核算；
  - 设置窗口新增「模型计费」专区，支持全模型定价一览、关键字实时搜索、单模型一键弹窗校准与输入/输出价格自定义覆盖，配置与 `config.json` 实时双向映射联动。
- **菜单栏纯图标模式与赛博环形精密仪表**:
  - 新增“仅显示图标”紧凑模式开关，隐藏冗长文字指标，满足极简桌面偏好；
  - 状态栏图标深度集成 Style 01 绿阶雷达扫描动态与 Precision Cyber Ring Gauge 环形仪表，实时呈现订阅额度健康度与剩余用量比例；
  - 菜单栏指示器与刻度环原生适配浅色与深色桌面环境，根据 `effectiveAppearance` 动态调整高对比度色阶，杜绝辨识度不足。
- **菜单栏指标动态自适应与实时交互配置**:
  - 设置窗口提供高保真 macOS 菜单栏实时模拟预览条，调整指标启停与顺序时所见即所得；
  - 引入点阵抓手卡片式拖拽排序与指标备选池交互，自由定制菜单栏指示器；
  - 菜单栏状态项控制器支持多指标宽度动态测量排版，彻底解决右侧文本截断问题。
- **Nothing 风格 Agent 项目看板视觉升级**:
  - 引入 Dot-Leader Console 点阵导引线控制台，项目列表支持虚线点阵对齐与阶梯式 Glyph 翠绿标签；
  - 进度条应用 P4 风格 6 格 LCD 迷你仪表，由实心 Hero 翠绿主段与 45° 斜向点阵纹理构成；
  - 逐小时折线图全面升级为 Emerald Glow 极光绿微光趋势线，搭配平滑渐变衰减，大幅提升暗色背景下的辨识度与工业美感。
- **本地权限保护文件凭据存储**:
  - 实现 `ProtectedFileCredentialStore`，凭证统一落盘至 `~/Library/Application Support/Bruce/credentials.json`，采用严格的 Unix `0600` POSIX 权限与临时文件原子替换；
  - 彻底摆脱本地 Ad-hoc 签名哈希改变导致频繁弹出 macOS Keychain 授权输入密码对话框的困扰；
  - 内置无感向下兼容迁移机制，初次启动自动读取旧版 Keychain 凭证并静默迁移；
  - 外部 CLI 探测（如 Claude Code）引入 `kSecUseAuthenticationUISkip` 强制静默，遇到未授权直接平滑降级至本地文件，0 弹窗打扰。
- **Universal 2 通用二进制与跨平台路径基底**:
  - `scripts/build-test-app.sh` 增加 `--universal` 选项，一键编译产出原生适配 Apple Silicon（arm64）与 Intel Mac（x86_64）的通用应用；
  - Rust Collector 抽象跨平台统一路径解析器 `paths.rs`，原生适配 macOS、Windows（`%APPDATA%`）与 Linux（XDG）路径规范；
  - 会话扫描器引入规范路径集合排重与 16 层深度限制，防止软链接死循环与深层目录卡死。

### Changed

- **看板卡片头部视觉纯化**: 移除各卡片顶部冗余的等宽印章字符，界面更具呼吸感与精致感。
- **设置窗口尺寸优化**: 默认视口调整为 1040x680（最小 980x620），确保新增的模型计费与实时预览在不同分辨率下舒展呈现。

---

## [0.8.0] - 2026-09-21

### Added

- **阶跃星辰（StepFun）订阅用量支持**: 新增 StepFun Provider 适配器，支持国内站（`stepfun.com`）与海外站（`stepchat.com`）双站点用量与额度查询；支持 API Key 与基于内置 WebKit 的网页登录授权流（自动拦截提取 session cookie、防循环重定向与安全清理历史登录态）。
- **仪表盘全局 HUD 状态栏**: 顶部新增终端点阵状态栏，展示系统运行状态（`SYS.OK`）与全局活跃 Agent 统计（`X AGENTS ACTIVE` / `STANDBY`），适配 Nothing、经典及液态玻璃全视觉风格。
- **多账号站点差异化标识**: 同一 Provider 存在多账号时，在仪表盘海外站点账号旁呈现专属标记，保持单账号场景的视觉克制。

### Changed

- **仪表盘 Fluent 微光边框与原生圆角**: 面板引入 Fluent 双层微光边框体系与顶部渐隐高光线；保持窗口底色全透明并由 GPU 硬件加速图层裁剪，彻底消除直角死角，呈现精致平滑的原生圆角（Nothing 10pt / 经典 22pt）。
- **折叠态卡片专属手柄与拖拽解耦**: 仅在卡片缩小/折叠态允许拖动排序，展开态卡片禁止拖拽以杜绝手势干扰；缩小态左侧提供物理隔离的专属 6 点拖拽手柄（Nothing 方点阵 / 经典圆点阵），彻底解耦拖拽排序与点击展开。
- **设置窗口生命周期规范**: 强化设置窗口单例控制与事件调度，防止重复触发打开或意外影响主菜单栏状态。

---

## [0.7.0] - 2026-09-17

### Added

- 新增统一的 Bruce 钥匙串访问配置和首次启动引导, 让用户明确授权后再读取凭证、迁移账号和刷新状态。
- 新增系统通知的应用层开关, 支持在设置中关闭 Bruce 自有的额度预警投递。
- 新增可收起的仪表盘卡片和折叠态迷你摘要, 并持久化每张卡片的收起状态。
- 新增稳定的 macOS 原生菜单栏状态项内容, 在菜单栏显示 Bruce 图标、今日用量和状态摘要。

### Changed

- macOS 27 下改用固定尺寸的原生状态项图像和确定性的仪表盘切换状态, 提升菜单栏重排、Pelmet 管理和首次/二次点击行为的稳定性。
- 设置窗口始终保持菜单栏应用的 accessory activation policy, 不再因为打开或关闭配置页残留 Dock 或 `⌘Tab` 图标。
- 启动时优先恢复本地缓存和今日用量, 避免钥匙串授权弹窗阻塞菜单栏指标显示。
- macOS 14–25 继续使用兼容的经典面板路径, macOS 26+ 才启用液态玻璃主题。
- 隐藏或遮挡仪表盘时卸载装饰性动画, 并缓存 Codex 会话树扫描, 降低后台 CPU、IO 和内存开销。
- 发布流水线继续生成未签名 Preview 草稿包, 正式签名与公证从 CI/CD 自动流程中延后处理。

### Fixed

- 修复 CodeBuddy reasoning token 重复计数、缓存详情丢失和 cache-inclusive prompt cost 计算错误。
- 修复原子 JSON 存储的备份不更新、IO 读取错误被误判为损坏, 以及回滚路径未校验 schema 版本的问题。
- 修复 macOS 27 菜单栏图标偶发消失、今日用量不显示、仪表盘位置异常和点击后无法正确关闭的问题。

### Removed

- 移除没有 Rust 额度消费者的 Antigravity 凭证、注入、设置和 SQLite 探测链路, 同步收缩 Bridge schema 与测试。

## [0.6.0] - 2026-09-04

### Added

- **Nothing 风格主题**: 新增定制字体、卡片外观、Hero 强调色、热力图呼吸效果和绿色阶系列色, 形成独立的 Nothing 视觉主题。
- **模型用量多窗口明细**: Hero 卡新增模型用量分解, 支持多个时间窗口展示和对应的模型占比。
- **CodeBuddy CLI 会话采集**: 新增 CodeBuddy CLI 会话扫描, 支持原始 usage 解析、快照去重和与其他 Agent 统一聚合。
- **设置页配置体验**: 新增 Fluent 卡片式设置外观、模态 API Key 配置和更集中的 Provider 配置流程。

### Changed

- **会话用量归因**: Codex token 用量按 turn context model 归因, OpenCode 与 ZCode 在行数上限场景保留最新消息和模型记录。
- **持久化可靠性**: 提取 `AtomicJSONStore`, 统一 JSON 配置的原子读写与恢复边界。
- **订阅配置结构**: 收敛订阅 Provider 配置和 CodeBuddy 会话源接入, 保持凭证配置与运行时注入职责分离。
- **界面可读性**: 调整模型用量列表和 Nothing 主题的文本、颜色与间距表现, 避免 token 数值在卡片中意外换行。

### Fixed

- **CodeBuddy usage 解析与去重**: 兼容 raw usage 和 camelCase cache breakdown, 按 session/message identity 去重重复快照。
- **Codex 快照重复计数**: 使用文件头尾 fingerprint 替代完整文件 digest, 在重复 rollout 副本和大文件场景保持稳定去重。
- **Rust CI Clippy 门禁**: 兼容新版 Clippy 对 cache writer、JSONL source reader 循环和 `io::Error` 构造的 lint 要求, 恢复 `verify-local.sh` 发布门禁。

---

## [0.5] - 2026-08-25

### Added

- **Rust Collector 完整迁移**: 完成从 Python Collector 到 Rust workspace 的运行时切换, 统一 Bridge artifact、额度 Provider 和本地会话采集边界。
- **Rust 运行时验证与发布门禁**: 增加 Collector fixture、进程边界、资源指标、安装/升级/回滚与缓存重建验证, 并接入 macOS App 打包和 GitHub Release 草稿流程。

### Changed

- **刷新与资源占用优化**: 本地采集、缓存和 Bridge 运行时采用有界读取、增量处理与资源指标, 降低刷新期间的 CPU、IO 和内存峰值。
- **订阅额度兼容性增强**: Provider 解析和 App 注入契约统一, 支持多账号额度查询、定向刷新与可诊断失败状态。
- **仓库与工程文档清理**: 清理过期迁移说明、OpenSpec/本地工作流残留和未打包参考契约, 同步更新治理、CI、工具链和正式发布文档。

### Fixed

- **智谱 GLM Coding Plan 额度不显示**: 兼容新版 `CREDIT_LIMIT` 与 `data` 数组响应, 在缺少百分比字段时从当前用量和剩余额度推导窗口进度。
- **火山引擎额度查询凭证键名错配**: 修正 App 注入字段与 Rust Provider 契约不一致导致的查询失败。
- **Codex 用量重复统计**: 去重重复 rollout 文件和重复会话副本, 避免 token 用量被重复累计。
- **Provider 错误诊断不准确**: 保留 HTTP 状态并区分非 JSON 响应、业务拒绝和 HTTP 错误, 避免把不同故障都显示成同一错误。

### Removed

- **旧 Python Collector 与桥接实现**: 移除遗留 Python 采集器、旧 Bridge 运行时和对应契约测试, 项目运行时完全由 Rust Collector 提供。
- **冗余死代码与本地产物**: 清理无调用方的 Rust/Swift/Widget 路径、过期图标和本地工作流产物, 不再进入仓库或 App 包。

---

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

