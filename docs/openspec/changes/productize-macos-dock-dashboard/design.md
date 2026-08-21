## Context

当前仓库已经包含三套可运行的 Collector-Artifact-Widget 管道:

- `agent-usage`: 扫描本机 Agent 会话, 聚合 token、成本和额度.
- `github`: 通过本机 `gh` 登录态和 GitHub GraphQL 获取贡献日历.
- `gitlab`: 通过私有 GitLab Events API 聚合活动.

Collector 以 Python 3 标准库实现, 对外维持 `run(ctx) -> {"artifact": ...}` 与 `--out` 文件输出. Widget 是原生 HTML/CSS/JavaScript 单文件页面, 通过 `DaimonWidget.data.main` 读取 Artifact. 这些 Widget 已经形成明确的暗色卡片、用量层级和热力图视觉语言, 必须保留.

产品目标是把现有脚本集合升级为个人 Mac 上长期运行的独立 Dock 应用. 应用需要提供依赖扫描、应用内登录、Keychain 凭证管理、默认 30 分钟刷新、缓存优先展示和故障恢复. 当前项目没有服务端、远程账号系统、CI 或自有数据库, 因此首版继续采用本地优先架构.

现有 Collector 会读取真实会话、第三方认证文件和 SQLite 数据库, 部分 OAuth 流程可能产生令牌轮换. 产品化必须把读取、刷新、保存和展示拆成清晰的安全边界, 避免 Python 采集代码直接修改第三方应用维护的数据.

## Goals / Non-Goals

### Goals

- 提供在 Dock 中驻留、可重新打开主窗口的独立 macOS 应用.
- 在单一应用中呈现 Agent 用量、GitHub 和 GitLab 三个模块.
- 完整保留现有 Widget 的视觉、交互层级和数据表达.
- 复用现有 Python Collector 和聚合算法, 保留 CLI 兼容性.
- 首次启动扫描 Python 3、`gh`、本机会话、私有 GitLab 和网络条件.
- 通过应用发起官方登录窗口或提供安全的 PAT/API key 配置.
- 用户统一授权后允许自动续期令牌和默认每 30 分钟刷新.
- 使用 Keychain 保存凭证, 使用 Application Support 保存原子快照.
- 在部分服务失败、离线、睡眠恢复和应用重启时继续提供最后成功数据.
- 建立可自动验证的 Bridge、Artifact schema 和视觉回归边界.

### Non-Goals

- 首版不提供跨设备同步、云端账号、团队共享或远程后端.
- 首版不移除个人 Mac 对 Python 3、`gh` CLI、VPN 和既有服务账号的依赖.
- 不在 Widget 中直接访问第三方 API、文件系统或 Keychain.
- 不迁移、修改或修复 CC Switch、Antigravity 等第三方 SQLite 数据库.
- 不在本次变更中重写全部 Collector 为 Swift.
- 不以产品化为由重新设计现有 Widget 的核心视觉语言.
- 不保证 Mac 睡眠期间按墙钟精确执行刷新; 唤醒后只做合并补偿.

## Decisions

### 1. 使用 SwiftUI 主应用, 通过 AppKit 补齐 Dock 生命周期

主窗口、导航、设置、状态和生命周期使用 SwiftUI. Dock 图标、重新打开窗口、badge、退出协调以及需要的窗口行为通过 AppKit bridge 实现. 首版最低系统版本设为 macOS 13, 以使用成熟的 Swift concurrency、NavigationSplitView 和 WKWebView 集成能力.

主窗口包含:

- 侧边栏: Agent 用量、GitHub、GitLab、设置.
- 内容区: 对应模块的 WKWebView.
- 原生状态层: 刷新、过期、授权和错误操作.
- Dock badge: 默认只显示通用风险或刷新失败提醒, 不显示账号或仓库信息. 具体汇总数字在可用性测试后再决定, 不作为首版阻塞项.

选择该方案是因为 macOS 生命周期、Keychain、授权会话和 WKWebView 都需要原生能力, 同时 SwiftUI 能以较小代码量承载设置和状态. 备选方案包括:

- 纯 AppKit: 生命周期控制更直接, 但界面开发和状态绑定成本更高.
- Electron/Tauri: Web 复用程度高, 但增加运行时体积和新的安全边界.
- 继续依赖 Daimon host: 无法形成用户要求的独立 Dock 应用和完整授权体验.

### 2. 复用 Python Collector, 每次刷新启动受控短生命周期子进程

应用不常驻 Python daemon. `CollectorRunner` 为每个模块按需启动一个受控子进程, 通过标准输入发送版本化 JSON 请求, 通过标准输出读取单个版本化 JSON 响应. 标准错误仅用于脱敏诊断.

同一模块运行互斥, 不同模块可以在最多两个并发任务的资源限制下运行. 应用退出时先请求取消, 超过短暂宽限期后终止进程. 默认边界为:

- 本机依赖和会话扫描: 30 秒.
- 单次外部 HTTP 请求: 10 秒.
- 单模块 Collector: 90 秒.

选择短生命周期进程可以隔离 Python 崩溃、泄漏和环境差异, 也避免设计进程间常驻服务协议. 备选方案:

- 完整 Swift 重写: 能减少运行依赖, 但会复制成熟聚合逻辑并扩大首版风险.
- 常驻 Python daemon: 启动更快, 但增加升级、进程恢复和凭证驻留复杂度.
- Shell 直接执行现有 `--out`: 易实现, 但无法可靠分离 Artifact、凭证更新和诊断.

### 3. 建立版本化 Bridge, 保留现有 CLI 契约

Collector 核心被整理为可注入文件系统、时间、HTTP 和凭证上下文的纯采集函数. 现有入口继续支持:

```text
run(ctx) -> {"artifact": ...}
python3 <collector>.py --out <path>
```

App 模式在其外部增加 Bridge adapter. 响应 envelope:

```json
{
  "schemaVersion": 1,
  "runId": "UUID",
  "generatedAt": "RFC3339",
  "status": "success|partial|error",
  "artifact": {},
  "credentialUpdates": [],
  "diagnostics": []
}
```

约束:

- stdout 只能包含一个完整 JSON envelope.
- `runId` 必须与请求一致.
- `artifact` 只包含可展示数据.
- `credentialUpdates` 只包含由 Swift 处理的候选变更.
- `diagnostics` 必须为结构化且已脱敏的数据.
- 未知 `schemaVersion`、污染 stdout 或缺字段一律拒绝发布.

这允许应用增加安全和运行元数据, 又不破坏当前脚本与 Daimon Widget 的使用方式.

### 4. Swift 是凭证和授权状态的唯一所有者

`AuthCoordinator` 负责:

- 使用 `ASWebAuthenticationSession` 或服务支持的设备授权流程打开官方登录.
- 对不支持应用 OAuth 的服务提供 PAT/API key 安全输入或官方 CLI 登录引导.
- 在统一授权摘要中列出本机扫描位置、外部服务、30 分钟刷新和令牌续期.
- 将应用持有的凭证按服务和账号范围写入 macOS Keychain.
- 在访问令牌进入安全续期窗口时自动续期.
- 在不可恢复的授权错误后暂停服务并提示重新登录.

Python App 模式只接收单次运行的最小必要凭证. 新令牌只能作为 `credentialUpdates` 返回, 由 Swift 验证后原子写入 Keychain. Python 不直接写 Keychain, 不写回第三方认证文件, 不迁移外部 SQLite.

采用该边界是为了把系统凭证能力和副作用集中在原生层. 备选方案是延续 Collector 直接读取和刷新所有本机认证文件, 但这会让授权范围、撤销和并发写回难以审计.

### 5. 依赖扫描与登录配置属于显式 Onboarding

`OnboardingScanner` 在首次启动和设置页中执行只读检查:

- Python 3 可执行文件与版本.
- `gh` CLI 是否安装及登录状态.
- 支持的 Agent 会话位置是否存在.
- CC Switch 与 Antigravity 数据库是否可只读打开.
- 私有 GitLab base URL、VPN或网络可达性.
- 各服务已连接、待授权、授权过期或不支持状态.

扫描结果使用状态模型, 不显示凭证值. 用户选择启用哪些模块后, 统一授权页才允许自动采集. 被禁用或缺依赖模块保持可诊断状态, 不运行 Collector.

### 6. 每模块调度状态机, 默认 30 分钟

`RefreshScheduler` 为每个模块维护:

```text
disabled
  -> ready
  -> queued
  -> running
  -> fresh
  -> stale
  -> authRequired
  -> backoff
```

规则:

- 所有已启用、已授权模块默认每 30 分钟刷新.
- 用户可关闭自动刷新, 手动刷新仍可用.
- 以最近一次已完成尝试为基础防止高频失败循环, 以最近成功时间判断数据是否过期.
- 睡眠恢复后, 过期模块最多补跑一次.
- 定时、唤醒和重复点击会被合并; 同模块不并发.
- 临时错误采用有限指数退避并加入少量抖动, 最大不超过下一个正常周期.
- 认证撤销、无效刷新令牌或明确权限不足不自动循环, 直接进入 `authRequired`.
- 手动刷新会复用正在运行的任务; 如果用户在运行中再次请求, 最多登记一次后续重跑.

选择统一 30 分钟默认值符合用户确认的使用节奏, 也能控制第三方 API 压力. 首版保留内部配置接口, 但 UI 只提供开关和默认值, 避免过早增加复杂频率选项.

### 7. ArtifactStore 使用校验后原子发布和最后成功回退

数据目录:

```text
~/Library/Application Support/mddd/
  snapshots/
    agent-usage.json
    github.json
    gitlab.json
  metadata/
    modules.json
  diagnostics/
```

每个模块都有独立 Artifact schema. 发布流程:

1. 校验 Bridge envelope 和 `runId`.
2. 对 `artifact` 执行模块 schema、日期、字段类型和敏感字段检查.
3. 写入同目录临时文件并同步.
4. 重新读取校验.
5. 原子替换当前快照.
6. 更新最近成功时间和非敏感运行元数据.

刷新失败时不替换快照. UI 同时获得 `lastSuccessAt`、`lastAttemptAt`、`isStale` 和脱敏错误类别, 因而能明确显示旧数据而不伪装为最新数据. 未知新 schema 保留原文件并拒绝展示; 受支持旧 schema 只通过保留原始文件的可回滚迁移读取.

选择文件快照而不是首版引入 SQLite, 是因为三个模块每次发布单个 JSON, 原子文件已经满足一致性和恢复要求. 如果未来需要长期时序查询, 再以 ADR 引入项目自有数据库和迁移策略.

### 8. WKWebView 保留视觉, 原生层只承载状态和能力

`WidgetHost` 将现有三个 `widget/index.html` 作为应用资源加载到隔离 WKWebView, 并提供兼容的 `DaimonWidget.data.main`. 改造重点是 host adapter 和状态槽位, 不重写核心布局.

安全约束:

- 只加载签名应用包内的页面和静态资源.
- 禁止 Widget 直接联网.
- 只注册明确白名单的脚本消息.
- 不向 JavaScript 暴露文件系统、进程或 Keychain.
- 动态用户名、仓库名和错误文本使用 `textContent` 或等价安全方式.
- 注入前必须通过 Artifact schema 和敏感字段检查.

视觉约束:

- 保留现有颜色、字体层级、卡片、热力格、强度和主要动效.
- 新增加载、过期、授权失效和刷新中状态时复用现有视觉 token.
- 有旧快照时, 状态层不清空主内容.
- 支持键盘焦点、辅助功能标签、非颜色提示和减少动态效果.

SwiftUI 原生重绘全部 Widget 是备选方案, 但会导致视觉偏移和重复实现, 因此不采用.

### 9. 错误隔离和可诊断性

错误按阶段分类:

- `dependency`: 缺少 Python、`gh`、本机文件或 VPN.
- `auth`: 登录取消、授权撤销、令牌失效或权限不足.
- `network`: DNS、超时、服务暂时不可用.
- `schema`: 外部响应或 Bridge/Artifact 不兼容.
- `collector`: Python 异常、进程退出或总超时.
- `storage`: Keychain 或快照写入失败.

诊断只保留模块、阶段、错误代码、耗时、重试次数和可执行建议. 令牌、授权码、Cookie、账号邮箱、完整本机路径和带敏感参数的 URL 在 Python 与 Swift 两层都执行脱敏.

一个 provider 或模块失败只改变其状态. Agent 模块内部 provider 可返回 `partial`, 但必须区分真实零用量和采集失败. UI 对 `partial` 明确标注缺失来源.

## Risks / Trade-offs

### Python 与本机环境差异

个人 Mac 可能存在多个 Python、PATH 不同或脚本依赖行为差异. 缓解措施是启动时记录选中的可执行文件和版本, 运行时使用绝对路径, 首版只支持 Python 3 的已验证版本范围, 并提供重新扫描.

### OAuth 回调与私有 GitLab 差异

GitHub、私有 GitLab 和 Agent provider 的 OAuth 能力及回调配置不同. 缓解措施是按 provider 实现适配器, 优先官方授权会话, 无法注册 OAuth client 时明确降级为官方 CLI 登录或 PAT, 不模拟账号密码登录.

### 自动续期的副作用

令牌轮换会改变应用持有的认证状态. 缓解措施是统一授权前明确告知, 由 Swift 单点更新 Keychain, 使用原子替换, 不写回第三方应用文件, 且用户可按服务撤销.

### WKWebView 攻击面

Widget 会显示来自外部服务的字符串. 缓解措施是本机资源白名单、禁网、schema 校验、敏感字段检查、文本转义和最小脚本消息接口.

### 30 分钟调度与 API 限额

三类模块固定周期可能受到 GitHub/GitLab 或 provider 限额影响. 缓解措施是模块互斥、合并唤醒补偿、有限退避、尊重服务返回的 rate-limit 时间, 并在后续版本开放高级频率设置.

### 快照包含个人活动数据

即使没有凭证, token 用量和仓库活动也属于个人数据. 缓解措施是只写 Application Support、限制当前用户权限、不默认同步、不写仓库、导出前脱敏和范围确认.

### 保留现有视觉限制原生体验

WKWebView 能最大限度保真, 但会增加原生和 Web 两套可访问性与状态协调. 缓解措施是把导航、授权和全局状态留在原生层, Widget 专注数据呈现, 并建立截图基线和键盘测试.

## Migration Plan

### Phase 1: 固化契约和测试夹具

1. 为三个现有 Artifact 建立版本化 schema 和脱敏 fixture.
2. 将 Collector 的时间、文件系统、HTTP、SQLite 和认证读取抽为可注入边界.
3. 保持 `run(ctx)` 和 `--out` 输出兼容, 增加单元与契约测试.
4. 建立现有 Widget 的桌面尺寸截图基线.

回滚边界: 此阶段只重构内部边界. 任一 CLI fixture 不兼容时停止迁移并恢复原入口适配, 不修改数据文件.

### Phase 2: Bridge 与本机存储

1. 增加 Python Bridge adapter 和版本化 envelope.
2. 实现 Swift `CollectorRunner`、schema 校验和 `ArtifactStore`.
3. 使用 fake HOME、mock HTTP 和临时 Application Support 运行测试.
4. 验证超时、污染 stdout、进程取消和原子写入恢复.

回滚边界: App Bridge 可整体关闭, 现有 CLI 与 Widget 仍可独立运行.

### Phase 3: 原生应用与 WidgetHost

1. 创建 macOS 13 SwiftUI/AppKit 应用骨架.
2. 集成三个现有 Widget 资源和 `DaimonWidget.data.main` adapter.
3. 添加导航、缓存优先启动、状态覆盖层和 Dock badge.
4. 对照截图基线验证视觉, 补充可访问性测试.

回滚边界: 每个模块可单独切回静态 fixture, 不影响 Collector 开发.

### Phase 4: Onboarding、Keychain 与授权

1. 实现只读依赖扫描和模块状态.
2. 按 provider 接入官方登录窗口、CLI 引导或安全 PAT/API key 输入.
3. 增加统一授权摘要、Keychain 存储、自动续期和撤销.
4. 确保 Python App 模式不写回第三方认证文件.

回滚边界: 每个 provider 使用独立 feature flag. 授权适配器失败时禁用该 provider, 不回退到隐式抓取或保存明文凭证.

### Phase 5: 调度、故障恢复与发布验证

1. 实现 30 分钟调度、睡眠补偿、去重、退避和手动刷新.
2. 验证离线、授权过期、部分 provider 失败和应用退出.
3. 在无真实凭证 CI 环境运行全部静态、单元、契约和视觉测试.
4. 仅在用户明确授权的本机验收中连接真实账号, 并验证撤销和数据清理.

回滚边界: 调度器可全局关闭, 用户仍可手动刷新并使用最后成功快照.

## Open Questions

以下事项不阻塞当前架构和任务拆分, 但必须在对应实现任务开始前记录最终值:

- 各 provider 是否已有可用于桌面应用的 OAuth client 与 callback 配置; 若没有, 使用已定义的官方 CLI 或 PAT 降级路径.
- Python 3 的最低受支持小版本需要根据现有 Collector 语法和首轮测试矩阵确定.
- 首版 Dock badge 除通用提醒外是否展示 token 汇总; 默认不展示数字以保护隐私.
