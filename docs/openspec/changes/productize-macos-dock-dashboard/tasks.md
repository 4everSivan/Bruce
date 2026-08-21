## 1. 契约基线与工程决策

- [x] 1.1 记录 macOS 13 最低版本、Xcode/Swift 工具链和应用 bundle identifier, 并创建原生应用工程
- [x] 1.2 盘点各 Agent provider、GitHub 和私有 GitLab 的 OAuth、设备授权、CLI 登录及 PAT 支持矩阵
- [x] 1.3 根据现有 Collector 语法和测试结果确定 Python 3 最低小版本, 在启动检查和开发文档中使用同一范围
- [x] 1.4 为 Agent、GitHub 和 GitLab 当前 Artifact 各保存一组已脱敏的有效、部分失败和无数据 fixture
- [x] 1.5 为三个现有 Widget 生成固定窗口尺寸、亮度设置和测试数据下的视觉基线截图
- [x] 1.6 将 `data/`、Application Support 快照、诊断导出和 Xcode 本机产物纳入版本控制排除检查

## 2. Collector 可测试边界与兼容性

- [x] 2.1 为 Agent Collector 抽取可注入的文件系统、当前时间、时区、HTTP 和凭证读取边界
- [x] 2.2 为 GitHub Collector 抽取可注入的 `gh` 执行器、GraphQL 客户端、当前时间和时区边界
- [x] 2.3 为 GitLab Collector 抽取可注入的 HTTP 客户端、base URL、当前时间和时区边界
- [x] 2.4 将 CC Switch 和 Antigravity SQLite 访问统一为 `mode=ro`, 并为 schema 不兼容返回可诊断状态
- [x] 2.5 为 token 聚合、成本估算、streak、贡献日期映射和时区边界补充 Python 单元测试
- [x] 2.6 为三个 Collector 增加 CLI 回归测试, 证明 `run(ctx)` 和 `--out` 继续输出兼容的 `{"artifact": ...}`
- [x] 2.7 移除 App 模式下对第三方认证文件的直接写回, 将令牌候选更新转换为显式返回值

## 3. 版本化 Python Bridge

- [x] 3.1 定义 Bridge v1 请求 schema, 包含 `schemaVersion`、`runId`、模块、超时和最小凭证上下文
- [x] 3.2 定义 Bridge v1 响应 schema, 包含 `status`、`artifact`、`credentialUpdates` 和 `diagnostics`
- [x] 3.3 实现单一 Bridge 入口, 按模块调用现有采集函数并保证 stdout 只输出一个 JSON envelope
- [x] 3.4 为凭证输入、敏感字段检查和 Python 诊断脱敏实现共享工具
- [x] 3.5 为 Bridge 成功、部分成功、协议缺字段、未知版本、污染 stdout 和异常退出增加契约测试
- [x] 3.6 使用 fake HOME、mock HTTP、临时只读 SQLite 和伪造凭证运行全部 Bridge 测试

## 4. macOS 应用骨架与生命周期

- [x] 4.1 创建 SwiftUI `BruceApp`、AppKit application delegate bridge 和单一主窗口场景
- [x] 4.2 实现 Dock 图标点击重新打开窗口, 并验证关闭窗口不会创建第二个调度器
- [x] 4.3 实现 Agent、GitHub、GitLab 和设置的侧边栏导航及模块状态模型
- [x] 4.4 实现应用退出协调, 包括停止新调度、取消运行任务和超时后终止子进程
- [x] 4.5 实现不包含账号或仓库标识的通用 Dock badge 状态
- [x] 4.6 为窗口关闭、重新打开、重复激活和退出路径增加原生生命周期测试

## 5. CollectorRunner 与运行隔离

- [x] 5.1 实现使用绝对 Python 路径启动 Bridge 的 `CollectorRunner`, 并通过 stdin 传入请求
- [x] 5.2 实现 stdout 单 envelope 解析、stderr 脱敏收集和 `runId` 匹配校验
- [x] 5.3 实现本地扫描 30 秒、外部请求 10 秒和模块运行 90 秒的默认超时配置
- [x] 5.4 实现进程取消、宽限期和强制终止, 且不发布被取消任务的不完整输出
- [x] 5.5 实现同模块互斥和全局最多两个 Collector 并发的资源限制
- [x] 5.6 为超时、取消、子进程崩溃、重复请求和跨模块隔离增加 Swift 测试

## 6. Artifact schema 与原子缓存

- [x] 6.1 为 Agent、GitHub 和 GitLab 定义版本化 Artifact schema 及 Swift 解码模型
- [x] 6.2 实现字段类型、日期、模块标识和敏感字段的发布前校验
- [x] 6.3 实现 `~/Library/Application Support/Bruce/` 当前用户专属目录和文件权限
- [x] 6.4 实现临时写入、同步、重新读取校验和原子替换的模块快照流程
- [x] 6.5 实现 `lastSuccessAt`、`lastAttemptAt`、`isStale`、错误类别和 schema 版本元数据
- [x] 6.6 实现旧 schema 可回滚迁移和未知新 schema 的安全拒绝路径
- [x] 6.7 为写入中断、磁盘失败、损坏快照、迁移失败和最后成功回退增加测试

## 7. WidgetHost 与视觉保真

- [x] 7.1 将三个现有 `widget/index.html` 及其本机资源纳入签名应用包
- [x] 7.2 实现 WKWebView `WidgetHost`, 将已验证 Artifact 映射为 `DaimonWidget.data.main`
- [x] 7.3 禁止非白名单网络请求, 并将脚本消息接口限制为显式结构化操作
- [x] 7.4 审计三个 Widget 的动态字符串渲染, 将不安全 `innerHTML` 路径改为文本节点或等价转义
- [x] 7.5 在保留现有颜色、字体、卡片和热力图布局的前提下增加加载、刷新中、过期和授权失效状态
- [x] 7.6 为三个模块运行截图对比, 将非预期视觉差异修复到评审接受范围 (差异源为 widget 全宽流式布局预期演进, 经确认后以 deterministic 模式重建基线: 同机两次截图像素差异 0%, 新截图对基线差异 <3%, RMSE <6)
- [x] 7.7 验证 Widget 无法访问 Keychain、文件系统、进程通道或直接调用外部服务

## 8. Onboarding 与依赖扫描

- [x] 8.1 实现 Python 3 与 `gh` CLI 的绝对路径、版本和登录状态只读扫描
- [x] 8.2 实现 Agent 会话位置、CC Switch 和 Antigravity 数据库的存在性及只读兼容性扫描
- [x] 8.3 实现私有 GitLab base URL、VPN或网络可达性和授权方式检查
- [x] 8.4 为每个模块呈现可用、缺依赖、待授权、授权过期、网络不可达和不支持状态
- [x] 8.5 为缺失依赖提供安装、登录或配置入口, 且在条件未满足时阻止启动 Collector
- [x] 8.6 为扫描超时、路径不存在、数据库锁定和 schema 不兼容增加不含敏感内容的测试 (BruceOnboardingCoreHarness: 74 tests passed, `swift run` 可执行)

## 9. 授权、Keychain 与自动续期

- [x] 9.1 实现统一授权摘要, 列出扫描位置、外部服务、30 分钟刷新、令牌续期和撤销方式 (SettingsView 统一授权区: 模块 Toggle + 摘要 + 确认/撤销按钮 -> OnboardingCoordinator.confirmConsent)
- [ ] 9.2 为支持 OAuth 的 provider 实现官方 `ASWebAuthenticationSession` 或设备授权适配器
- [x] 9.3 为不支持应用 OAuth 的 provider 实现官方 CLI 登录引导或安全 PAT/API key 输入 (GitHub: gh auth login --web 官方流程; GitLab: PAT SecureField 不回显 + 保存并验证, PAT 只入 Keychain)
- [x] 9.4 实现按服务和账号范围保存、读取、更新及删除 Keychain 项 (CredentialStore 协议 + KeychainCredentialStore + InMemoryCredentialStore, BruceOnboardingCoreHarness 74 tests 覆盖)
- [x] 9.5 实现从 Keychain 到 CollectorRunner 的单次最小凭证传递, 确保命令行和日志不包含凭证 (OnboardingRunInputProvider 按模块生成最小 context/credentials, 仅经 Bridge stdin JSON 传递; 输入缺失不启动进程)
- [x] 9.6 实现 `credentialUpdates` 验证和 Keychain 原子更新, 并拒绝 Python 直接写回第三方认证文件 (Bridge validate_credential_updates + KeychainCredentialStore SecItemUpdate 优先原子写 + Agent 能力门禁拒绝未授权 OAuth 读写, 2.7 已移除 App 模式写回)
- [ ] 9.7 实现访问令牌安全续期窗口、临时故障有限重试和永久认证错误暂停
- [ ] 9.8 实现按服务撤销授权和删除应用持有凭证, 并确保其他服务不受影响
- [ ] 9.9 为登录成功、用户取消、回调校验失败、续期轮换、刷新令牌失效和撤销增加测试

## 10. 30 分钟调度与恢复

- [x] 10.1 实现每模块默认 30 分钟的 `RefreshScheduler` 和自动刷新开关
- [x] 10.2 实现单模块与全部模块的手动刷新, 并在已有任务时执行合并或最多一次后续重跑
- [x] 10.3 实现 Mac 睡眠恢复和应用重新激活后的过期检查及最多一次补偿刷新
- [x] 10.4 实现临时错误的有限指数退避、抖动和服务 rate-limit 时间尊重
- [x] 10.5 实现认证错误进入 `authRequired`, 不进行无限重试, 并保留最后成功快照
- [x] 10.6 为定时器、睡眠跨多个周期、并发手动点击、失败退避和模块禁用增加确定性时钟测试 (`RefreshSchedulerHarness` 已接入 `BruceAppCore`, 9 tests passed, 含容量释放后排队启动)

## 11. 用户状态、可访问性与诊断

- [x] 11.1 实现缓存优先启动, 确保主窗口不等待扫描或网络请求即可显示 (`RefreshScheduler.start` 先读快照; `LocalIntegrationHarness` 验证重启加载)
- [x] 11.2 实现刷新中、部分成功、过期、离线、认证失效和无缓存状态的统一原生模型 (`ModuleRunState` -> `WidgetDisplayState` 全量映射, NativeLifecycleHarness 覆盖)
- [x] 11.3 实现 Agent 内单 provider 失败的 `partial` 展示, 区分真实零用量与采集失败 (Bridge partial diagnostic + Scheduler/Widget 文案 + partial fixture)
- [x] 11.4 为导航、刷新、设置和状态提示增加键盘焦点、辅助功能标签和非颜色线索 (侧栏状态、`⌘R`、设置 hints、VoiceOver announcement、热力格 aria label)
- [x] 11.5 根据 macOS 减少动态效果设置关闭或缩短非必要 Widget 动画 (三个 Widget 与 host bootstrap 均覆盖 `prefers-reduced-motion`)
- [x] 11.6 实现脱敏诊断查看与导出预览, 排除 Keychain、令牌、邮箱、完整本机路径和敏感 URL 参数 (`DiagnosticsHarness` 5 tests; ZIP 解压白名单复核)
- [x] 11.7 对正常、离线、过期、授权失效和部分成功状态执行可访问性与视觉验收 (2026-07-30 使用脱敏 fixture 和 deterministic reduced-motion 模式生成并目视检查 5 状态临时截图)

## 12. 集成验证与发布准备

- [x] 12.1 配置无真实账号的自动化测试入口, 覆盖 Python 单元、Bridge 契约、Swift 单元和 Widget fixture (`scripts/verify-local.sh`)
- [x] 12.2 增加 Python 语法检查、Swift build/test、Widget JavaScript 语法检查和 Artifact schema 校验命令 (统一脚本运行 AST、pytest/node、Swift build 与 7 个 Harness)
- [x] 12.3 在隔离 HOME 和临时 Application Support 下验证首次启动、缓存启动、刷新及数据清理 (`LocalIntegrationHarness` 使用随机目录并在结束后删除)
- [x] 12.4 验证日志、进程列表、快照、诊断包和 Widget 数据中不存在测试凭证 (stdin-only fake credential、子进程环境白名单、Artifact 敏感字段拒绝、诊断二次扫描和 Widget 隔离测试)
- [ ] 12.5 在用户明确授权的个人 Mac 上执行 GitHub、私有 GitLab 和选定 Agent provider 的真实登录验收
- [ ] 12.6 验证 30 分钟自动刷新、睡眠补偿、授权续期、撤销、退出和最后成功回退
- [x] 12.7 更新 README 和运行说明, 记录依赖、授权范围、数据位置、手动清理、故障排查和回滚方式 (另见 `docs/development/release-acceptance.md`)
- [ ] 12.8 完成 OpenSpec 逐项验收, 确认所有 capability scenario 有对应实现或自动化证据后再归档变更
