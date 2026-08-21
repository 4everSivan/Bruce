<div align="center">
  <img src="docs/app-icon-rounded.png" width="120" height="120" alt="Bruce" />
  <h1>Bruce</h1>
  <p><strong>macOS 菜单栏里的 AI Agent 用量与订阅额度看板</strong></p>
  <p>一条帮你看住每个 token 的本地小狗 🐶</p>
</div>

Bruce 把本机 AI Agent 的 token 用量、成本估算和订阅额度集中到一个原生 macOS 菜单栏应用中。原生层负责依赖扫描、登录授权、凭证管理、定时刷新、缓存与故障恢复; Rust Collector 负责采集; 弹出面板以原生 SwiftUI 渲染 (macOS 26+ 可选液态玻璃主题, 更低系统自动使用经典材质风格)。项目本地优先运行, 无自有服务端。

> 当前版本 v0.3.0。最低支持 macOS 14, 液态玻璃主题需 macOS 26。测试版由 `scripts/build-test-app.sh` 本地打包; 正式版 (Developer ID 签名 + 公证) 由 `scripts/build-release-app.sh` 按 Git tag 构建, 推送 `v*` tag 后 CI 自动产出草稿 Release。

## 核心特性

- **看板**: 菜单栏常驻 (LSUIElement), 原生状态项 + SwiftUI 弹出面板, 面板高度随内容自适应, 无滚动条。
- **用量卡**: hero 总量、四格细分、14 日堆叠趋势、26 周用量热力图、月度聚合分解与用量档位指示。
- **订阅用量卡**: 多 Provider 窗口量条、Codex 账号子卡、DeepSeek 月度消费与余额, 按数据可用性条件渲染。
- **逐小时卡**: 24 点折线与模型/项目明细展开。
- **主题**: 经典 / 液态玻璃两档; 液态玻璃仅 macOS 26+ 可选, 其下可调标准/通透/哑光模糊风格, 低系统强制经典材质。
- **设置窗口**: 通用 (配色模式、界面风格、模糊风格、刷新间隔、菜单栏指标拖拽排序、全局快捷键)、Agent 用量依赖卡、订阅额度 (Provider 标签式管理与拖拽排序, 凭证只进 Keychain)、统一授权与诊断。
- **授权门控**: 首次启动 Onboarding、本机只读依赖扫描、统一授权摘要与 Activation Gate — 未确认授权不启动任何 Collector。
- **调度与可靠性**: 默认每 30 分钟自动刷新, 支持手动刷新、防重入、超时、退避和系统唤醒补采; 最后成功快照优先展示, 单模块失败不阻塞其他模块, 损坏快照自动回退 previous。
- **配额预警**: 临界线计算、预警去重、通知中心提示与自动恢复判定。
- **可访问性**: 键盘导航、VoiceOver 状态语义、macOS 减少动态效果偏好。
- **隐私**: 设置页提供脱敏诊断预览与最小 ZIP 导出, 不包含 Artifact 或账号活动数据。

## 支持的数据源

| 类别 | 覆盖 |
|---|---|
| 本机会话扫描 | Kimi Work / Kimi Code、Claude Code、Codex、Grok、OpenCode、Orca、Pi、ZCode |
| 订阅额度 | Kimi、DeepSeek、火山引擎、Codex OAuth、Antigravity、Claude、Grok、OpenCode Go |

> 仓库根 `*/widget/` 单文件 Widget 继续保留, 仅服务 Daimon / Kimi Work Blueprint 场景, 不属于 App 的组成部分。

## 界面预览

原生面板截图待补充。运行 App (`dist/Bruce.app`, 由 `scripts/build-test-app.sh` 生成) 后, 对菜单栏面板和设置窗口截图, 替换下表占位即可:

| 场景 | 截图 |
|---|---|
| 菜单栏面板 (用量 / 订阅用量 / 逐小时卡片) | _待补充_ |
| 设置窗口 (通用 / 订阅额度 / 统一授权 / 诊断) | _待补充_ |

Widget 场景的视觉基线见 `tests/visual/baselines/agent-usage-valid.jpg`, 由 `tests/visual/` 的确定性测试维护。

## 快速开始

### 环境要求

- macOS 14 或更高 (`LSMinimumSystemVersion` 14.0); 液态玻璃主题需 macOS 26 或更高。
- Swift 6 工具链, 当前验证版本 Apple Swift 6.2.1; 只有 Command Line Tools 即可完成 SwiftPM 构建。
- Rust toolchain (rustc/cargo); Collector 编译为 macOS 原生 Rust 二进制。
- Agent 用量模块需要至少一个受支持的本机会话数据源。

签名、归档和公证需要完整 Xcode 与 Developer ID 证书。

### 构建并运行

```bash
swift build --package-path macos/BruceApp
swift run --package-path macos/BruceApp BruceApp
```

首次运行流程:

1. 在设置页检查 Rust Collector、本机会话和可选 SQLite 数据源。
2. 选择需要启用的 Agent 用量模块。
3. 在「订阅额度」分区按需配置或导入订阅凭证; 未配置任何 Provider 时订阅卡片不渲染。
4. 阅读统一授权摘要并确认后, 应用才会启动对应 Collector 和自动刷新。

真实账号访问和外部请求只应在个人 Mac 上、由用户明确授权后执行。

### 打包与发布

```bash
zsh scripts/build-test-app.sh    # 测试版: dist/Bruce.app + dist/Bruce.zip (不入库)
zsh scripts/build-release-app.sh # 正式版: Developer ID 签名 + Hardened Runtime + 公证 (需 Git tag 与证书)
zsh scripts/release-notes.sh     # 从 CHANGELOG 提取当前版本生成 Release 说明
```

正式打包前置条件: Git tag `v<major>.<minor>.<patch>`、Developer ID Application 证书和 App Store Connect API Key; 未配置时脚本在对应阶段清晰失败, 不产出半成品。

## 应用架构

```text
macOS 菜单栏应用 (LSUIElement, 最低 14)
  ├─ Onboarding + Settings
  │    ├─ 本机只读依赖扫描
  │    └─ 订阅额度凭证 (Keychain, 可一次性只读导入)
  ├─ RefreshScheduler
  │    └─ CollectorRunner
  │         └─ Rust Bridge/Collector (stdin/stdout JSON)
  │              └─ Agent Usage modules
  └─ ArtifactStore
       └─ AppModel + PanelViewModelMapper
            └─ 原生状态项 + AppKit/SwiftUI 看板 (经典 / 液态玻璃)
                 (用量 / 订阅用量 / 逐小时卡片)
```

可测试业务逻辑位于 `BruceAppCore` library target (AppModel、调度、PanelViewModel 映射); `BruceApp` executable target 只保留应用入口、SwiftUI 界面装配和 `Sources/BruceApp/Views/` 原生看板卡片组件。所有 Swift Harness 直接依赖 Core target。

运行链路:

1. 原生层根据 Onboarding 结果和用户授权决定允许启动的模块。
2. Scheduler 为每个模块创建受控运行任务, 并通过 Rust Bridge 的 stdin 传入最小 context 和 credentials。
3. Rust Collector 返回 `{"artifact": ...}`; Bridge 验证 schema、错误语义和凭证更新。
4. ArtifactStore 原子保存最后成功快照。
5. 同一 Artifact 两路消费: App 内由 AppModel + PanelViewModelMapper 映射为面板 view model, 交给原生 SwiftUI 卡片渲染; Daimon 场景映射为 `DaimonWidget.data.main`, 由仓库根单文件 Widget 渲染。

Collector 保留独立 CLI 入口, 用于开发、测试和故障排查, 但不再是产品的主要使用方式。

## 安全与隐私

- 本地优先, 无项目自有服务端, 不默认同步活动数据。
- 订阅额度凭证 (Kimi、DeepSeek、火山引擎、Codex、Antigravity、OpenCode Go) 保存在 macOS Keychain。
- 凭证通过 Bridge stdin 的单次请求传递, 不进入命令行参数、Artifact 或日志。
- Rust Collector 不直接写 Keychain, 也不写回第三方认证文件; 订阅令牌轮换经 `credentialUpdates` 只写回 Keychain, 不回写 CC Switch 或 CLI 认证文件。
- 菜单栏面板为纯 SwiftUI 渲染, 不接触凭证。仓库根 `*/widget/` 单文件 Widget 仅由 Daimon host 以受 CSP 限制的 WebView 加载, 其 JSON fixture 和 JavaScript 语法可独立验证。
- 配置和快照写入用户级 Application Support; 真实凭证、账号活动和 `data/*.json` 不得进入仓库。
- 诊断包采用白名单字段, 生成后解压复核文件清单并再次扫描敏感形态。
- 菜单栏指标仅显示通用状态和聚合数字, 不显示账号或 token 明细。

## 项目结构

```text
Bruce/
├── macos/BruceApp/          # macOS 菜单栏应用 (最低 14)、Scheduler、缓存和原生看板
│   ├── Sources/BruceApp/       # 应用入口、原生状态项、设置窗口和 Views/ 卡片组件
│   ├── Sources/BruceAppCore/   # AppModel、调度、PanelViewModel 映射
│   ├── Sources/BruceOnboardingCore/  # 扫描、授权、Gate、订阅凭证、主题解析纯逻辑
│   ├── Assets/                # AppIcon.icns 应用图标
│   └── Tests/                 # 独立 Harness target
├── bridge/                 # Bridge v1 JSON schema
├── rust/Bruce-collector/   # Rust Agent 用量 Collector workspace
├── agent-usage/            # Daimon Widget
├── tests/                  # JSON fixture 与 Widget 视觉基线
├── scripts/                # 本地验证、测试版/正式版打包与发布说明脚本
└── docs/                   # 设计、工具链和授权说明文档
```

关键入口:

- macOS App: `macos/BruceApp/Sources/BruceApp/BruceApp.swift`
- 面板卡片组件: `macos/BruceApp/Sources/BruceApp/Views/`
- Rust Bridge/Collector: `rust/Bruce-collector/bin/Bruce-collector/src/main.rs`
- Widget 源文件 (Daimon 场景): `agent-usage/widget/index.html`
- Artifact schemas: `bridge/schemas/`

## 数据位置、清理与回滚

应用自有数据位于:

- `~/Library/Application Support/Bruce/config/onboarding-v1.json`: 非敏感配置和授权版本。
- `~/Library/Application Support/Bruce/snapshots/`: 当前和 previous Artifact 快照。
- `~/Library/Application Support/Bruce/metadata/modules.json`: 最近成功、尝试时间和错误分类。
- macOS Keychain service `com.bruce.dashboard.credentials`: 应用持有的订阅额度凭证。

清理前先退出应用。在设置页使用「撤销全部授权」停止全部调度; 需要完全重置时, 再通过 Finder 删除 `~/Library/Application Support/Bruce/`, 并在「钥匙串访问」中删除上述 service 的项目。删除快照和 Keychain 项不可由应用自动恢复, 操作前应确认不再需要最后成功数据和现有授权。

出现回归时可先撤销受影响模块并继续使用其他模块; 回退到兼容 Bridge v1 / Artifact v1 的旧构建不会改写第三方数据库。若新快照损坏, 应用优先回退 previous; 不要通过修改 CC Switch 或 Antigravity 数据库来修复 Bruce。

## 故障排查

- 设置页「重新检查」用于复核 Rust Collector、本机会话位置和只读 SQLite 状态。
- 有旧快照时, 刷新失败不会清空主视图; 状态文案会区分过期、离线、授权失效和部分成功。
- 导出支持信息前先使用设置页「预览诊断」, 确认其中只有状态和校验元数据。

## 开发与验证

默认离线验证入口:

```bash
./scripts/verify-local.sh
```

该脚本运行 Rust workspace 测试、格式检查、Clippy、fixture 脱敏扫描、Swift 构建和全部 Swift Harness。隔离集成只在随机临时 HOME 中运行 Rust Collector, 关闭外部额度能力, 不访问真实账号、Keychain 或第三方数据库。

按需运行子集:

```bash
cargo test --manifest-path rust/Bruce-collector/Cargo.toml --workspace
zsh scripts/check-collector-fixtures.sh
swift run --package-path macos/BruceApp BruceOnboardingCoreHarness
swift run --package-path macos/BruceApp PanelViewModelHarness
swift run --package-path macos/BruceApp RefreshSchedulerHarness "$PWD"
```

CI (`.github/workflows/ci.yml`) 在 push/PR 时执行 Rust/Swift verify-local.sh 和测试版 App 构建; tag `v*` 触发正式构建与草稿 Release。

Widget JavaScript 语法和安全隔离继续面向 Daimon 场景维护。真实 Collector、OAuth、签名和 `.app` 发布验证不属于默认测试流程, 需要单独授权和对应环境。

## 当前限制

- 正式签名与公证发布链路需要 Developer ID 证书和 App Store Connect API Key; 未配置时 CI Release 保持草稿状态。
- 真实 Agent Provider 登录验收需要用户在个人 Mac 上明确授权。
- 30 分钟自动刷新、系统睡眠补偿、凭证续期和撤销仍需真实环境持续验收。
- VoiceOver、增加对比度和全键盘流程仍需在签名发布构建上完成人工验收。

## 更多文档

- [Bruce 设计文档](docs/development/01-bruce-design.md)
- [CI/CD 设计](docs/development/02-ci-cd.md)
- [工具链基线](docs/development/03-toolchain.md)
- [Provider 授权矩阵](docs/development/04-provider-auth-matrix.md)
- [发布人工验收清单](docs/development/05-release-acceptance.md)
- [正式打包与发布](docs/development/08-production-packaging-and-release.md)
- [1.0 Rust Collector 构建目标](docs/development/14-rust-collector-v1-build-target.md)

## License

[MIT](LICENSE)
