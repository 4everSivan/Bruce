# Onboarding 与最小授权闭环修复设计

状态: 已经用户逐节确认

日期: 2026-07-28

范围: OpenSpec 任务组 8 修复, 以及保证 Collector 安全启用所需的最小任务组 9 能力

## 1. 背景

当前 Onboarding 实现存在以下验收阻塞:

- Python 标准版本输出无法被解析, 导致所有模块被错误阻止.
- 本机进程、SQLite 和网络扫描运行在 `MainActor`, 可能冻结界面, 且进程没有可靠超时.
- SQLite 只执行 `PRAGMA schema_version`, 没有验证 Collector 实际依赖的表和字段.
- 应用没有传入 GitLab base URL, 也没有 GitLab 授权方式和 PAT 配置闭环.
- 模块状态无法区分缺依赖、待授权和授权过期.
- 设置页没有安装、登录、配置或重新检查入口.
- 扫描结果为 ready 后会直接启用 Scheduler, 绕过用户授权确认.
- GitLab Collector 在没有受控凭证输入时仍会回退读取旧 token 文件.
- Onboarding harness 未接入稳定构建, 部分测试读取真实用户环境, 无法作为确定性证据.

本设计将本机扫描、外部连接验证、授权存储、状态计算和 Collector 启用拆分为独立边界. 首次启动和自动本机扫描期间不发出外部请求; 统一授权前只有用户主动点击登录或验证才能发出对应的单次外部请求.

## 2. 目标

- 修复 OpenSpec 任务 8.1 至 8.6 的真实实现和测试缺口.
- 首次启动自动执行的扫描仅限本机只读操作.
- 用户主动登录、验证或确认统一授权后, 才允许访问真实账号.
- 只有被用户选择、依赖满足、授权有效且授权版本仍兼容的模块才能启动 Collector.
- GitHub 继续复用 `gh` 官方登录态, mddd 不复制 GitHub token.
- 私有 GitLab 首版使用 HTTPS base URL 和 PAT, PAT 只保存到 macOS Keychain.
- Agent 模块首阶段只运行本机会话 token 分析, 未完成应用授权的云端额度 Provider 明确显示为部分可用.
- 扫描失败不清空最后成功快照, 单模块失败不影响其他模块.

## 3. 非目标

- 不在本变更中实现私有 GitLab OAuth Client 注册和回调.
- 不实现所有 Agent Provider 的 OAuth 自动续期、轮换和远端撤销.
- 不自动安装 Python、GitHub CLI 或其他系统软件.
- 不执行 CC Switch 或 Antigravity 数据库迁移、修复或写入.
- 不修改任务组 7 的 Widget 视觉、WKWebView 隔离或签名打包方案.
- 不引入通用 Provider 插件框架.

## 4. 架构

```text
首次启动/设置页
      |
      v
OnboardingCoordinator (@MainActor)
      |-- LocalDependencyScanner
      |     `-- Python, gh, 会话目录, SQLite, 仅本机只读
      |-- ProviderConnectionVerifier
      |     `-- 仅在用户操作或既有授权允许后访问 GitHub/GitLab
      |-- ReadinessEvaluator
      |     `-- 根据扫描、授权和网络状态计算模块就绪度
      |-- AuthorizationStore
      |     |-- GitLab PAT -> Keychain
      |     `-- 非敏感配置 -> Application Support/mddd/config
      `-- CollectorActivationGate
            `-- 决定 RefreshScheduler 是否可以启用模块
```

### 4.1 OnboardingCoordinator

`OnboardingCoordinator` 只负责协调 UI 操作和状态发布, 保持在 `MainActor`. 它不得直接执行同步进程、SQLite 或网络 I/O.

主要职责:

- 启动本机扫描并发布进度.
- 响应选择 Python、GitHub 登录、GitLab 配置和重新检查操作.
- 展示统一授权摘要并记录用户确认.
- 将 `CollectorActivationGate` 的决策应用到 Scheduler.
- 断开模块时停止对应 Scheduler, 并按凭证所有权执行清理.

### 4.2 LocalDependencyScanner

`LocalDependencyScanner` 是异步、无 UI 依赖的本机扫描服务. 它依赖可替换的进程、文件和 SQLite 协议, 不使用 `@MainActor`.

扫描内容:

- Python 候选绝对路径、版本和最低版本兼容性.
- `gh` 候选绝对路径和版本. 登录态不属于首次本机扫描.
- Kimi Work、Kimi Code、Claude Code、Codex 和其他已支持会话位置.
- CC Switch 和 Antigravity 数据库存在性、只读可打开性和所需 schema.

Python 路径按以下顺序解析:

1. 用户保存的绝对路径.
2. `/usr/bin/python3`.
3. `/opt/homebrew/bin/python3`.
4. `/usr/local/bin/python3`.
5. 未来新增的显式候选, 不依赖 GUI 进程的 `PATH`.

用户可以通过文件选择器选择其他可执行文件. 选择结果属于非敏感配置.

### 4.3 AsyncProcessProbe

所有外部进程通过 `AsyncProcessProbe` 运行:

- 普通版本和状态检查默认超时 5 至 10 秒.
- 超时后先请求终止, 2 秒后仍未退出则强制终止.
- 支持调用方取消.
- 捕获输出有固定长度上限.
- 原始 stdout 和 stderr 不进入日志或 Artifact.
- 返回结构化的退出状态、超时状态和经过允许的解析结果.

Python 版本解析接受标准形式 `Python 3.9.6`, 允许前后空白, 并拒绝 Python 2 或 Python 3.8 及更低版本.

### 4.4 SQLiteSchemaProbe

SQLite 始终使用 URI `mode=ro`, 不执行 DDL、迁移或修复. 兼容性必须基于 Collector 的真实查询契约, 不能使用 `PRAGMA schema_version` 代替.

最低验证范围:

- CC Switch `providers`: `id`, `name`, `app_type`, `settings_config`, `meta`, `is_current`.
- CC Switch `model_pricing`: `model_id`, `input_cost_per_million`, `output_cost_per_million`, `cache_read_cost_per_million`, `cache_creation_cost_per_million`.
- Antigravity `conversation_summaries`: `step_count`, `last_modified_time`.

探测使用零数据查询或等价表信息检查, 不读取凭证值或活动明细. 结果区分:

- 文件不存在.
- 可读且兼容.
- 数据库锁定或繁忙.
- schema 缺表或缺字段.
- 文件损坏.
- 探测超时.

UI 和诊断只显示数据源名称, 不显示完整用户路径.

### 4.5 ProviderConnectionVerifier

外部连接验证与本机扫描分离.

GitHub:

- 状态检查使用 `gh auth status --active --hostname github.com`.
- 禁止使用 `--show-token`.
- 从未成功连接时检查失败映射为 `pendingAuthorization`.
- 曾经成功连接后检查失败映射为 `authorizationExpired`.
- 登录使用 `gh auth login --web` 官方流程.
- 登录允许取消并使用独立的交互超时.
- 一次性设备码和 CLI 原始输出只存在于当前登录会话, 不写日志.

GitLab:

- base URL 必须使用 HTTPS.
- URL 不得包含用户名、密码、query 或 fragment.
- PAT 通过 HTTP header 发送到同一受信任 host 的 `/api/v4/user`.
- 禁止携带 PAT 跟随跨 host 重定向.
- `401` 或 `403` 映射为授权失效.
- DNS、VPN、TLS 和超时映射为网络不可达, 并保留可重试语义.
- 响应正文和 header 不写日志.

首次授权前, `ProviderConnectionVerifier` 不得由应用启动流程自动调用. 用户点击登录或验证属于对该次请求的明确授权. 用户完成统一授权后, 后续启动才允许为已选模块自动验证.

### 4.6 AuthorizationStore

敏感和非敏感配置分开存储:

- GitLab PAT 保存到 Keychain.
- Keychain service 固定为 `com.mddd.dashboard.credentials`.
- Keychain account 至少按 `gitlab:<normalized-host>` 区分.
- GitLab base URL、用户选择的 Python 路径、模块选择和授权版本为非敏感配置.
- 非敏感配置固定写入 `~/Library/Application Support/mddd/config/onboarding-v1.json`, 使用临时文件、同步和原子替换, 文件权限为 `0600`.
- 配置存储带 schema version, 未知新版本必须安全拒绝自动启用.

GitHub token 继续由 `gh` 管理. mddd 不调用 `gh auth token`, 不复制 token, 也不把 `gh` 凭证迁移到自己的 Keychain.

### 4.7 ReadinessEvaluator

状态分为三层:

```text
LocalDependencyStatus
  available | missing | incompatible | locked | timedOut

ConnectionStatus
  notRequired | notChecked | pendingAuthorization
  verifying | connected | expired | unreachable | unsupported

ModuleReadiness
  ready | partial | missingDependency | pendingAuthorization
  authorizationExpired | networkUnreachable | unsupported
```

每个模块结果携带:

- 阻塞原因.
- 非阻塞 warning.
- 非敏感诊断代码.
- 可执行 `SetupAction`.

允许的 `SetupAction`:

```text
choosePython
installPython
installGitHubCLI
loginGitHub
configureGitLab
replaceGitLabPAT
retryLocalScan
retryConnection
reviewAuthorization
```

### 4.8 CollectorActivationGate

`CollectorActivationGate` 是 Scheduler 启用模块的唯一入口. 允许条件:

```text
moduleSelected
AND consentVersionIsCurrent
AND localDependenciesPermitRun
AND connectionStatePermitsRun
AND appIsAcceptingNewTasks
```

规则:

- Agent `ready` 或具有至少一个有效本机会话源的 `partial` 可以运行本地分析.
- GitHub 和 GitLab 只有 `ready` 可以运行.
- `pendingAuthorization`, `authorizationExpired`, `networkUnreachable` 和 `unsupported` 不允许启动对应 Collector.
- 状态失效时立即取消该模块的后续调度, 不影响其他模块.
- `MdddApp.performOnboardingScan()` 只更新状态, 不直接启用模块.
- 无缓存模块在首次授权前不得利用 Scheduler 的零延迟路径运行.
- Gate 同时产生 `CollectorExecutionPolicy`. Agent 首阶段只授予 `localSessions` 和 `localPricing` 能力, 不授予 `externalQuotas`.
- Bridge 和 Agent Collector 对未知或缺失的能力采用 deny, 不得通过默认分支发起外部请求.

## 5. 模块就绪规则

### 5.1 Agent 用量

必要条件:

- Python 3.9 或更高版本.
- 至少一个能提供 token 用量的受支持本机会话源可读.

状态:

- 所有已发现来源兼容: `ready`.
- 至少一个来源可用, 其他来源缺失、锁定或不兼容: `partial`.
- 没有任何有效来源: `missingDependency`.
- 当前版本不支持已发现来源: `unsupported`.

CC Switch 和 Antigravity 数据库属于可选增强来源, 单独存在时不能满足 token 会话源的必要条件. 本修复阶段允许只读使用 CC Switch `model_pricing` 进行本地成本估算, 但禁止 CC Switch 云端额度查询和其他 Agent Provider 外部请求. 未授权云端来源显示为明确 warning, 不得静默联网.

### 5.2 GitHub

必要条件:

- Python 3.9 或更高版本.
- `gh` CLI 已安装且版本检查成功.
- `gh` 当前账号登录态有效.
- 用户选择 GitHub 模块并确认统一授权.

应用只复用 `gh` 登录态, 不持有 GitHub token.

### 5.3 GitLab

必要条件:

- Python 3.9 或更高版本.
- 合法 HTTPS base URL.
- 对应 host 的 PAT 已存在于 mddd Keychain.
- `/api/v4/user` 验证成功.
- 用户选择 GitLab 模块并确认统一授权.

GitLab Collector 必须从 Bridge 的受控凭证输入读取 PAT. App 模式不得回退读取旧项目 token 文件.

## 6. 数据流

### 6.1 首次启动

1. 加载最后成功快照并立即展示.
2. 加载非敏感配置、已选模块和授权版本.
3. 后台运行本机依赖扫描.
4. 计算模块状态和可执行操作.
5. 外部请求计数保持为 0.
6. 所有 Collector 保持禁用.
7. 显示可关闭的"连接数据源"窗口.

### 6.2 用户连接 GitHub

1. 用户点击"登录 GitHub".
2. 应用显示官方流程说明和取消入口.
3. 启动 `gh auth login --web`.
4. 登录进程完成后执行一次 `gh auth status`.
5. 只保存非敏感的连接状态和验证时间.
6. 未确认统一授权前仍不启用 Collector.

### 6.3 用户配置 GitLab

1. 用户输入 HTTPS base URL 和 PAT.
2. 应用验证 URL 结构.
3. PAT 写入对应 host 的 Keychain 项.
4. 用户点击保存并验证后调用 `/api/v4/user`.
5. 只发布 connected、expired 或 unreachable 状态.
6. 未确认统一授权前仍不启用 Collector.

验证失败时 PAT 仍只保留在 Keychain, 状态标记为未验证或失效, 且 Activation Gate 拒绝使用. 用户可以更换 PAT 或断开并删除该项.

### 6.4 统一授权

授权摘要列出:

- 用户选择的模块.
- 将扫描的本机数据源类别.
- 将访问的 GitHub/GitLab host.
- 默认每 30 分钟自动刷新.
- Agent 云端额度 Provider 当前是否被禁用.
- 暂停采集和删除应用持有凭证的方法.

用户确认后:

1. 保存授权版本和模块选择.
2. 重新计算 Activation Gate.
3. 只启用满足条件的模块.
4. 无缓存的已授权模块允许执行首次刷新.

### 6.5 后续启动

1. 先显示缓存.
2. 执行本机扫描.
3. 若授权版本仍有效, 可以自动检查已选 GitHub/GitLab 连接.
4. 连接有效后恢复 30 分钟调度.
5. 网络失败时保留缓存并显示过期或离线状态.

### 6.6 断开

GitHub:

- 停止 mddd 的 GitHub 调度.
- 清除 mddd 的模块启用许可.
- 不自动调用 `gh auth logout`, 避免影响其他工具.

GitLab:

- 停止对应模块调度.
- 删除 mddd Keychain 中对应 host 的 PAT.
- 保留最后成功快照并标记为过期或未连接.
- 远端 PAT 撤销由用户在 GitLab 完成, UI 提供说明.

## 7. 引导与设置界面

首次引导使用可关闭的原生 SwiftUI 设置窗口, 不使用强制向导. Dashboard 在配置期间仍可展示已有缓存.

三张模块状态卡:

- Agent 用量: Python 版本、有效会话源数量、来源 warning、选择 Python 和重新检查.
- GitHub: `gh` 安装状态、登录状态、查看安装说明、登录和重新检查.
- GitLab: base URL、PAT `SecureField`、网络状态、保存并验证、更换 PAT 和重新检查.

交互约束:

- 安装操作只打开官方说明或复制命令, 不静默调用包管理器.
- 每张卡片独立显示进度, 不阻塞其他模块.
- 状态同时使用图标和文字, 不只依赖颜色.
- PAT 永不回显.
- 用户取消或关闭窗口不会运行 Collector.
- 缺依赖和未授权状态提供真实按钮, 不只提供指导文本.

## 8. 错误与诊断

所有边界错误转换为:

```text
ScanIssue {
  code
  stage
  category
  retryable
  suggestedAction
}
```

允许的类别:

- `dependency`
- `auth`
- `network`
- `schema`
- `storage`
- `timeout`
- `cancelled`

禁止进入诊断的内容:

- PAT、OAuth token、设备码和 Cookie.
- `gh` 原始认证输出.
- 用户名、邮箱和账号标识.
- 完整用户路径.
- GitLab 响应正文和敏感 header.
- 带 query 的 URL.

单个来源失败只产生对应 warning 或模块状态变化. 不用空数据伪装 schema、网络或授权错误.

## 9. 测试设计

为使测试可正常导入, 将纯扫描、状态和 Gate 逻辑放入 SwiftPM library target `MdddOnboardingCore`. SwiftUI、AppKit 和应用入口保留在 executable target.

### 9.1 单元测试

- Python 版本解析: 3.9、3.12、Python 2、Python 3.8、空白和异常输出.
- Python 和 `gh` 候选路径解析.
- 三层状态模型的表驱动组合.
- Agent 至少一个来源可用时的 partial 判定.
- Activation Gate 的未授权、授权版本变化、授权失效和单模块隔离.
- `ScanIssue` 脱敏.

### 9.2 系统边界测试

- 进程成功、非零退出、超时、取消、强制终止和输出长度限制.
- 使用临时目录构造 SQLite 正常 schema、缺表、缺字段、锁定、损坏和不存在.
- 每个测试显式注入临时 home 和绝对路径.
- 禁止测试使用 `OnboardingPaths.default` 或真实用户目录.

### 9.3 授权适配器测试

GitHub:

- 已登录.
- 从未登录.
- 既有授权失效.
- 用户取消.
- 进程超时.
- 输出不进入诊断.

GitLab:

- `/api/v4/user` 成功.
- `401` 和 `403`.
- DNS、TLS 和超时.
- VPN不可达.
- 同 host 重定向.
- 跨 host 重定向被拒绝且 PAT 不转发.

Keychain:

- 单元测试使用内存 fake.
- 平台测试使用独立测试 service.
- 测试结束后清理测试项.
- 不读取或修改真实凭证.

### 9.4 集成验收

- 首次启动和未触发用户操作的本机扫描期间外部请求次数为 0.
- 未确认统一授权时 Collector 执行次数为 0.
- 确认后只启用被选择且就绪的模块.
- 一个模块授权失效不影响其他模块.
- GitLab 断开后 Keychain 项删除且调度停止.
- 扫描或授权失败不会清空最后成功快照.
- Agent 本地分析不会触发未授权的云端额度请求.

标准命令:

```bash
swift build --package-path macos/MdddApp
swift test --package-path macos/MdddApp
python3 -m unittest discover -s tests
```

## 10. OpenSpec 验收映射

### 8.1

- Python 和 `gh` 使用绝对路径.
- Python 标准版本输出测试通过.
- 所有进程具有超时、取消和脱敏边界.
- GitHub 登录状态与缺少 CLI 分开表示.

### 8.2

- 会话目录存在性扫描只读.
- SQLite 使用 `mode=ro`.
- 使用真实表和字段契约验证兼容性.
- 锁定、损坏、缺表和缺字段均有明确状态.

### 8.3

- GitLab base URL 可配置且必须为 HTTPS.
- VPN、网络、TLS 与授权错误分开表示.
- 授权方式明确为首版 PAT.
- PAT 只存 Keychain, Collector 不读取旧 token 文件.

### 8.4

- UI 呈现 ready、partial、missingDependency、pendingAuthorization、authorizationExpired、networkUnreachable 和 unsupported.
- 状态带图标、文字和对应操作.

### 8.5

- 提供选择 Python、安装说明、GitHub 登录、GitLab 配置和重新检查入口.
- Activation Gate 阻止条件不满足或未经授权的 Collector.
- 不再由扫描结果直接启用 Scheduler.

### 8.6

- Harness 或 Swift test 接入正常构建.
- 超时、路径不存在、数据库锁定和 schema 不兼容测试均为确定性测试.
- 测试不读取真实用户目录、账号或凭证.

只有映射中的行为测试全部通过后, 才允许重新勾选 8.1 至 8.6.

## 11. 实施顺序

1. 抽取 `MdddOnboardingCore` 和共享模型.
2. 实现 `AsyncProcessProbe`、版本解析和确定性测试.
3. 实现 SQLite schema profile 和 fixture 测试.
4. 实现三层状态模型和 `ReadinessEvaluator`.
5. 实现 GitHub/GitLab verifier 与 Keychain 抽象.
6. 实现 `CollectorActivationGate`, 移除扫描后直接启用逻辑.
7. 实现引导和设置操作.
8. 限制 Agent App 模式为已授权能力, 移除 GitLab token 文件回退.
9. 完成集成、安全和脱敏测试.
10. 根据证据更新 OpenSpec 任务状态.

## 12. 风险与回滚

### SwiftPM target 调整

风险: 抽取 library target 可能暴露当前应用内部类型耦合.

缓解: 只移动 Onboarding 纯逻辑和必要共享枚举, 不同时重构 Widget、ArtifactStore 或 Scheduler 内部实现.

回滚: executable target 可以暂时继续使用旧 UI, 但 Activation Gate 的默认值必须保持 deny, 不得回滚到扫描后自动启用.

### GitHub CLI 登录交互

风险: CLI 版本、系统 credential store 或浏览器行为可能不同.

缓解: 只使用官方 `--web` 流程, 检查最低支持版本, 提供取消和重新检查, 不解析或保存 token.

回滚: 登录入口可降级为官方命令说明, GitHub 模块保持禁用, 不绕过授权.

### 私有 GitLab 网络差异

风险: VPN、内部 CA、代理或 SSO 策略可能造成验证失败.

缓解: 保留 TLS 验证, 区分网络和授权错误, 不将 TLS 错误降级为可用.

回滚: 保留 PAT 和 base URL 的安全配置, 模块保持离线, 不启动 Collector.

### Agent 云端额度暂时受限

风险: 修复阶段只显示本地 token 分析, 部分现有云端额度暂不可用.

缓解: 明确显示 partial 和未授权来源, 后续按 Provider 完成任务组 9 授权能力.

回滚: 不允许恢复未经应用授权的隐式凭证读取和外部请求.

## 13. 参考

- GitHub CLI `gh auth login`: https://cli.github.com/manual/gh_auth_login
- GitHub CLI `gh auth status`: https://cli.github.com/manual/gh_auth_status
- 项目 OpenSpec: `docs/openspec/changes/productize-macos-dock-dashboard/`
- 项目安全治理: `constitution.md`
