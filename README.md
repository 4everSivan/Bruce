<div align="center">
  <img src="docs/app-icon.png" width="120" height="120" alt="mddd" />
  <h1>mddd</h1>
  <p>本地优先的 macOS 26 菜单栏研发活动看板</p>
</div>

`mddd` 将本机 AI Agent 的 token 用量、成本估算和额度状态集中到一个原生 macOS 菜单栏应用中。应用负责依赖扫描、登录授权、凭证管理、定时刷新、缓存和故障恢复；Python Collector 负责采集；菜单栏弹出面板以原生 SwiftUI 液态玻璃看板渲染。仓库根 `*/widget/` 单文件 Widget 保留，仅服务 Daimon/Kimi Work Blueprint 场景。

> **v0.1 Release**
>
> 支持从源码构建运行或生成可下载的 `.app` 发布包（位于 `dist/mddd.app`），最低支持 macOS 26。

## 核心能力

| 模块 | 能力 | 数据边界 |
|---|---|---|
| Agent 用量 | 汇总 Kimi Work、Kimi Code、Claude Code、Codex、Grok 和 Orca 会话的 token、成本、趋势及可用额度状态 | 以本机会话和用户授权的 Provider 为来源 |

应用还提供:

- 菜单栏常驻形态 (LSUIElement)、MenuBarExtra 弹出式液态玻璃面板、可配置的菜单栏指标 (1 至 3 项) 和自动刷新指示。
- 原生 SwiftUI 玻璃卡片看板: 用量卡 (hero 总量、四格细分、14 日堆叠趋势)、订阅用量卡 (多 Provider 窗口量条、Codex 账号子卡、DeepSeek 月度消费与余额) 和逐小时卡 (24 点折线、模型/项目明细展开)，按数据可用性条件渲染，面板高度随内容自适应，无滚动条。
- 设置窗口分区: 通用 (配色模式、液态玻璃强度、刷新间隔、菜单栏指标拖拽排序)、Agent 用量依赖卡、订阅额度 (Provider 标签式管理，拖拽排序，凭证只进 Keychain)、统一授权和诊断。
- 首次启动 Onboarding、本机依赖扫描、统一授权摘要和 Activation Gate (未确认授权不启动任何 Collector)。
- 默认每 30 分钟自动刷新，以及手动刷新、防重入、超时、退避和系统唤醒补采。
- 最后成功快照优先展示；单模块失败不会阻止其他模块更新。
- 设置页提供脱敏诊断预览和最小 ZIP 导出，不包含 Artifact 或账号活动数据。
- 支持键盘导航、VoiceOver 状态语义和 macOS 减少动态效果偏好。

## 界面预览

原生菜单栏面板截图待补充。运行 App (`dist/mddd.app`，由 `scripts/build-test-app.sh` 生成) 后，对菜单栏面板和设置窗口截图，替换到本节的占位即可:

| 场景 | 截图 |
|---|---|
| 菜单栏面板 (用量 / 订阅用量 / 逐小时卡片) | _待补充_ |
| 设置窗口 (通用 / 订阅额度 / 统一授权 / 诊断) | _待补充_ |

> Widget 场景 (Daimon/Kimi Work Blueprint) 的视觉基线见 `tests/visual/baselines/agent-usage-valid.jpg`，由 `tests/visual/` 的确定性测试维护。

## 快速开始

### 环境要求

- macOS 26 或更高版本 (部署目标 `LSMinimumSystemVersion` 26.0)。
- Swift 6 工具链；当前验证版本为 Apple Swift 6.2.1。
- Python 3.9 或更高版本；Collector 仅依赖 Python 标准库。
- Agent 用量模块需要至少一个受支持的本机会话数据源。

只有 Apple Command Line Tools 时即可完成 SwiftPM 构建。签名、归档和公证需要完整 Xcode。

### 构建并运行

```bash
swift build --package-path macos/MdddApp
swift run --package-path macos/MdddApp MdddApp
```

首次运行后:

1. 在设置页扫描 Python、本机会话和可选 SQLite 数据源。
2. 选择需要启用的 Agent 用量模块。
3. 在「订阅额度」分区按需配置或导入订阅凭证；未配置任何 Provider 时订阅卡片不渲染。
4. 阅读统一授权摘要并确认后，应用才会启动对应 Collector 和自动刷新。

真实账号访问和外部请求只应在个人 Mac 上、由用户明确授权后执行。

### 构建测试版 App

```bash
zsh scripts/build-test-app.sh
```

生成 `dist/mddd-test.app` 和 `dist/mddd-test.zip`（测试用，不入库）。

## 应用架构

```text
macOS 26 菜单栏应用 (LSUIElement)
  ├─ Onboarding + Settings
  │    ├─ 本机只读依赖扫描
  │    └─ 订阅额度凭证 (Keychain, 可一次性只读导入)
  ├─ RefreshScheduler
  │    └─ CollectorRunner
  │         └─ Python Bridge (stdin/stdout JSON)
  │              └─ Agent Usage Collector
  └─ ArtifactStore
       └─ AppModel + PanelViewModelMapper
            └─ MenuBarExtra 原生液态玻璃看板
                 (用量 / 订阅用量 / 逐小时玻璃卡)
```

可测试业务逻辑位于 `MdddAppCore` library target (AppModel、调度、PanelViewModel 映射)；`MdddApp` executable target 只保留应用入口、SwiftUI 界面装配和 `Sources/MdddApp/Views/` 原生看板卡片组件。所有 Swift Harness 直接依赖 Core target。

运行链路:

1. 原生层根据 Onboarding 结果和用户授权决定允许启动的模块。
2. Scheduler 为每个模块创建受控运行任务，并通过 Bridge 的 stdin 传入最小 context 和 credentials。
3. Collector 返回 `{"artifact": ...}`；Bridge 验证 schema、错误语义和凭证更新。
4. ArtifactStore 原子保存最后成功快照。
5. 同一 Artifact 两路消费: App 内由 AppModel + PanelViewModelMapper 映射为面板 view model，交给原生 SwiftUI 卡片渲染；Daimon 场景映射为 `DaimonWidget.data.main`，由仓库根单文件 Widget 渲染。

Collector 仍保留独立 CLI 入口，用于开发、测试和故障排查，但不再是产品的主要使用方式。

## 安全与隐私

- 本地优先，无项目自有服务端，也不默认同步活动数据。
- 订阅额度凭证 (Kimi、DeepSeek、火山引擎、Codex、Antigravity) 保存在 macOS Keychain。
- 凭证通过 Bridge stdin 的单次请求传递，不进入命令行参数、Artifact 或日志。
- App 模式下 Python 不直接写 Keychain，也不写回第三方认证文件；订阅令牌轮换经 `credentialUpdates` 只写回 Keychain，不回写 CC Switch 或 CLI 认证文件。
- 菜单栏面板为纯 SwiftUI 渲染，不接触凭证。仓库根 `*/widget/` 单文件 Widget 仅由 Daimon host 以受 CSP 限制的 WebView 加载，其安全契约由 Python 测试继续覆盖。
- 配置和快照写入用户级 Application Support；真实凭证、账号活动和 `data/*.json` 不得进入仓库。
- 诊断包采用白名单字段，生成后会解压复核文件清单并再次扫描敏感形态。
- 菜单栏指标仅显示通用状态和聚合数字，不显示账号或 token 明细。

## 项目结构

```text
mddd/
├── macos/MdddApp/          # macOS 26 菜单栏应用、Scheduler、缓存和原生液态玻璃看板
│   ├── Sources/MdddApp/       # 应用入口、MenuBarExtra、设置窗口和 Views/ 卡片组件
│   ├── Sources/MdddAppCore/
│   ├── Sources/MdddOnboardingCore/
│   ├── Assets/                # AppIcon.icns 应用图标
│   └── Tests/                 # 独立 Harness target
├── bridge/                 # Swift 与 Python 之间的版本化 JSON 协议和安全校验
├── agent-usage/            # Agent 用量 Collector 与 Daimon Widget
├── tests/                  # Python 契约、Collector、Widget 安全和视觉基线测试
├── scripts/                # 本地验证与测试版 App 打包脚本
└── docs/                   # 设计、工具链和授权说明文档
```

关键入口:

- macOS App: `macos/MdddApp/Sources/MdddApp/MdddApp.swift`
- 面板卡片组件: `macos/MdddApp/Sources/MdddApp/Views/`
- Python Bridge: `bridge/run_bridge.py`
- Collector: `agent-usage/collector/collect_usage.py`
- Widget 源文件 (Daimon 场景): `agent-usage/widget/index.html`
- Artifact schemas: `bridge/schemas/`

## 数据位置、清理与回滚

应用自有数据位于:

- `~/Library/Application Support/mddd/config/onboarding-v1.json`: 非敏感配置和授权版本。
- `~/Library/Application Support/mddd/snapshots/`: 当前和 previous Artifact 快照。
- `~/Library/Application Support/mddd/metadata/modules.json`: 最近成功、尝试时间和错误分类。
- macOS Keychain service `com.mddd.dashboard.credentials`: 应用持有的订阅额度凭证。

清理前先退出应用。在设置页使用“撤销全部授权”停止全部调度；需要完全重置时，再通过 Finder 删除 `~/Library/Application Support/mddd/`，并在“钥匙串访问”中删除上述 service 的项目。删除快照和 Keychain 项不可由应用自动恢复，操作前应确认不再需要最后成功数据和现有授权。

出现回归时可先撤销受影响模块并继续使用其他模块；回退到兼容 Bridge v1 / Artifact v1 的旧构建不会改写第三方数据库。若新快照损坏，应用优先回退 previous；不要通过修改 CC Switch 或 Antigravity 数据库来修复 mddd。

## 故障排查

- 设置页“重新检查”用于复核 Python、会话位置和只读 SQLite 状态。
- 有旧快照时，刷新失败不会清空主视图；状态文案会区分过期、离线、授权失效和部分成功。
- 导出支持信息前先使用设置页“预览诊断”，确认其中只有状态和校验元数据。

## 开发与验证

默认离线验证入口:

```bash
./scripts/verify-local.sh
```

该脚本检查 Python 语法，运行全部 Python/Bridge/schema/Widget 测试，构建 Swift 包，并依次执行 Onboarding (162 项)、面板映射 (35 项)、DeepSeek 月度账本 (17 项)、缓存、Runner、调度、生命周期、诊断、订阅凭证和隔离集成 Harness。隔离集成只在随机临时 HOME 中运行 Agent Collector，关闭外部额度能力，不访问真实账号、Keychain 或第三方数据库。

Python 语法和测试:

```bash
python3 -m py_compile \
  agent-usage/collector/collect_usage.py \
  bridge/*.py

python3 -m pytest -q
```

Swift 构建和单个 Core Harness:

```bash
swift build --package-path macos/MdddApp
swift run --package-path macos/MdddApp MdddOnboardingCoreHarness
swift run --package-path macos/MdddApp PanelViewModelHarness
swift run --package-path macos/MdddApp RefreshSchedulerHarness "$PWD"
```

Widget JavaScript 语法和安全隔离由 Python 测试继续覆盖 (面向 Daimon 场景)。真实 Collector、OAuth、签名和 `.app` 发布验证不属于默认测试流程，需要单独授权和对应环境。

更多资料:

- [mddd 设计文档](docs/development/01-mddd-design.md)
- [CI/CD 设计](docs/development/02-ci-cd.md)
- [工具链基线](docs/development/03-toolchain.md)
- [Provider 授权矩阵](docs/development/04-provider-auth-matrix.md)
- [发布人工验收清单](docs/development/05-release-acceptance.md)

## 当前限制

- 尚未提供签名、公证和可下载的 `.app` 发布包。
- 完整 Xcode 下的 archive、entitlement、Keychain 和菜单栏生命周期发布验证尚未完成。
- 真实 Agent Provider 登录验收需要用户在个人 Mac 上明确授权。
- 30 分钟自动刷新、系统睡眠补偿、凭证续期和撤销仍需真实环境验收。
- VoiceOver、增加对比度和全键盘流程仍需在签名发布构建上完成人工验收。

## License

[MIT](LICENSE)
