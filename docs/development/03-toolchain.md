# macOS 应用工具链基线

| 项目 | 定义 |
|---|---|
| 文档版本 | 1.0 |
| 文档路径 | `docs/development/03-toolchain.md` |
| 适用平台 | macOS 14 及以上 (液态玻璃主题需 macOS 26) |

## 平台与标识

- 最低系统版本: macOS 14 (`Package.swift` platforms `.macOS(.v14)`, 与 `LSMinimumSystemVersion 14.0` 一致); 液态玻璃主题仅 macOS 26 及以上启用.
- 应用形态: 菜单栏常驻应用 (LSUIElement), 原生状态项 + AppKit/SwiftUI 弹出面板 + 独立设置窗口.
- 开发 bundle identifier: `com.bruce.dashboard`.
- 发布前必须根据最终签名团队确认 bundle identifier; 数据目录和 Keychain service 名称不得在发布后随意变化.

## Swift 工具链

- 工程格式: Swift Package Manager executable, 后续可由 Xcode 直接打开 `macos/BruceApp/Package.swift`.
- Swift tools version: 6.2 (`// swift-tools-version: 6.2`).
- 当前已验证编译器: Apple Swift 6.2.1.
- 本机开发环境只有 Apple Command Line Tools, 无法在本机执行 `xcodebuild archive`; `scripts/build-release-app.sh` 仅作为未来正式版手工预留, 当前未接入 CI/CD.
- 无完整 Xcode 时使用:

```bash
swift build --package-path macos/BruceApp
```

## Rust 工具链

- Collector 使用 Rust Cargo workspace 构建.
- Rust 二进制入口: `rust/Bruce-collector/bin/Bruce-collector/src/main.rs`.
- App 只发现并启动随包提供的 Rust Collector, 不扫描或依赖用户本机解释器.

静态验证:

```bash
cargo fmt --manifest-path rust/Bruce-collector/Cargo.toml --all -- --check
cargo clippy --manifest-path rust/Bruce-collector/Cargo.toml --workspace --all-targets -- -D warnings
```

## 构建边界

- SwiftPM 验证只证明源码可以编译, 不证明应用签名、沙盒权限、Keychain entitlement 或菜单栏生命周期已经完成.
- `.app` 打包、签名、公证和真实授权窗口验收必须在完整 Xcode 可用后执行.
- 真实 Collector、OAuth 和 PAT 验收不属于静态工具链检查, 必须另行获得用户明确授权.

## 测试

### Core targets

- `BruceOnboardingCore` 是不含 SwiftUI/AppKit 的纯 library target, 可以被测试 harness 通过 `@testable import` 正常链接和运行.
- `BruceAppCore` 承载 AppModel, CollectorRunner, RefreshScheduler, ArtifactStore, Widget 状态, 生命周期协调和诊断服务.
- `BruceApp` executable target 只保留 `@main`, SwiftUI/AppKit 界面, AppDelegate 装配和 Widget 资源.
- 包内跨 target API 使用 Swift `package` 访问级别, 不扩大为对包外公开的接口.

### 已接入 SwiftPM 的 Harness

Package.swift 共声明 14 个 Harness executable target (3 个 library target: `BruceOnboardingCore`, `BruceAppCore`, `BruceGlassSurfaceCore`; 1 个 App executable target: `BruceApp`):

| Harness | 覆盖 |
|---|---|
| `BruceOnboardingCoreHarness` | 路径、版本、扫描、readiness、授权 Gate、配置、Keychain 抽象、订阅凭证、设备码登录、令牌轮换合并 |
| `ArtifactStoreHarness` | schema、私有权限、原子发布、previous 回退和迁移 |
| `CollectorRunnerHarness` | stdin 凭证、协议、并发、超时、取消和隔离 Bridge |
| `RefreshSchedulerHarness` | 30 分钟定时、合并、退避、授权失败、唤醒、容量和停止 |
| `NativeLifecycleHarness` | 调度启动、退出回收、原生到 Widget 状态映射和菜单栏指标/摘要 |
| `DiagnosticsHarness` | 白名单报告、敏感扫描、最小 ZIP、权限和命名 |
| `LocalIntegrationHarness` | 临时 HOME/Application Support、真实本地 Bridge、缓存重启、诊断和清理 |
| `PanelViewModelHarness` | 措辞、分组、条件渲染、用量档位与热力图、按月聚合映射 |
| `DeepSeekUsageLedgerHarness` | DeepSeek 月度账本领域差分、时区跨日、持久化与损坏恢复 |
| `SubscriptionCredentialsHarness` | 订阅凭证注入与 Keychain 边界 |
| `GlobalHotkeyHarness` | 全局快捷键录制与冲突处理 |
| `AppModelCacheHarness` | AppModel 缓存失效与菜单栏摘要缓存分离 |
| `DashboardGlassSurfaceHarness` | 面板玻璃表面矩阵与液态玻璃对比度 |
| `SubscriptionRefreshControlHarness` | Provider 定向刷新控件与刷新状态联动 |

各 Harness 的当前用例数以 Harness 实际输出为准。全部 Harness 可在只有 Apple Command Line Tools 的环境中构建和运行, 不依赖 executable target 链接。

## 统一验证

```bash
./scripts/verify-local.sh
```

脚本默认不访问真实账号或 Keychain. `LocalIntegrationHarness` 会在随机临时 HOME 中调用 Rust Agent Collector, 但只授权本地会话和本地计价能力, 不启用外部额度采集.
