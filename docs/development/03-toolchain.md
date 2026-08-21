# macOS 应用工具链基线

| 项目 | 定义 |
|---|---|
| 文档版本 | 1.0 |
| 文档路径 | `docs/development/03-toolchain.md` |
| 适用平台 | macOS 26 及以上 (Liquid Glass 与菜单栏面板依赖) |

## 平台与标识

- 最低系统版本: macOS 26 (Liquid Glass 与菜单栏面板依赖).
- 应用形态: 菜单栏常驻应用 (LSUIElement), 原生状态项 + AppKit/SwiftUI 弹出面板 + 独立设置窗口.
- 开发 bundle identifier: `com.mddd.dashboard`.
- 发布前必须根据最终签名团队确认 bundle identifier; 数据目录和 Keychain service 名称不得在发布后随意变化.

## Swift 工具链

- 工程格式: Swift Package Manager executable, 后续可由 Xcode 直接打开 `macos/MdddApp/Package.swift`.
- Swift tools version: 6.0.
- 当前已验证编译器: Apple Swift 6.2.1.
- 当前机器只有 Apple Command Line Tools, 未安装或未选择完整 Xcode, 因此暂不能执行 `xcodebuild archive`、签名和 `.app` 发布验证.
- 无完整 Xcode 时使用:

```bash
swift build --package-path macos/MdddApp
```

## Python 工具链

- 最低支持版本: Python 3.9.
- 当前已验证解释器: Python 3.9.13.
- Collector 仅使用标准库; 当前使用的最晚基础 API 是 Python 3.7 已提供的 `datetime.fromisoformat`.
- 首次启动扫描必须拒绝 Python 2 和 Python 3.8 及更低版本, 并显示安装或重新选择解释器的建议.

静态验证:

```bash
python3 -m py_compile \
  agent-usage/collector/collect_usage.py
```

## 构建边界

- SwiftPM 验证只证明源码可以编译, 不证明应用签名、沙盒权限、Keychain entitlement 或菜单栏生命周期已经完成.
- `.app` 打包、签名、公证和真实授权窗口验收必须在完整 Xcode 可用后执行.
- 真实 Collector、OAuth 和 PAT 验收不属于静态工具链检查, 必须另行获得用户明确授权.

## 测试

### Core targets

- `MdddOnboardingCore` 是不含 SwiftUI/AppKit 的纯 library target, 可以被测试 harness 通过 `@testable import` 正常链接和运行.
- `MdddAppCore` 承载 AppModel, CollectorRunner, RefreshScheduler, ArtifactStore, Widget 状态, 生命周期协调和诊断服务.
- `MdddApp` executable target 只保留 `@main`, SwiftUI/AppKit 界面, AppDelegate 装配和 Widget 资源.
- 包内跨 target API 使用 Swift `package` 访问级别, 不扩大为对包外公开的接口.

### 已接入 SwiftPM 的 Harness

| Harness | 当前用例数 | 覆盖 |
|---|---:|---|
| `MdddOnboardingCoreHarness` | 以 Harness 实际输出为准 | 路径、版本、扫描、readiness、授权 Gate、配置、Keychain 抽象、订阅凭证、设备码登录、令牌轮换合并 |
| `PanelViewModelHarness` | 以 Harness 实际输出为准 | 措辞、分组、条件渲染 |
| `ArtifactStoreHarness` | 以 Harness 实际输出为准 | schema、私有权限、原子发布、previous 回退和迁移 |
| `CollectorRunnerHarness` | 以 Harness 实际输出为准 | stdin 凭证、协议、并发、超时、取消和隔离 Bridge |
| `RefreshSchedulerHarness` | 以 Harness 实际输出为准 | 30 分钟定时、合并、退避、授权失败、唤醒、容量和停止 |
| `NativeLifecycleHarness` | 以 Harness 实际输出为准 | 调度启动、退出回收、原生到 Widget 状态映射和菜单栏指标/摘要 |
| `DiagnosticsHarness` | 以 Harness 实际输出为准 | 白名单报告、敏感扫描、最小 ZIP、权限和命名 |
| `LocalIntegrationHarness` | 以 Harness 实际输出为准 | 临时 HOME/Application Support、真实本地 Bridge、缓存重启、诊断和清理 |

全部 Harness 可在只有 Apple Command Line Tools 的环境中构建和运行, 不依赖 executable target 链接.

## 统一验证

```bash
./scripts/verify-local.sh
```

脚本默认不访问真实账号或 Keychain. `LocalIntegrationHarness` 会在随机临时 HOME 中调用真实 Agent Bridge/Collector 代码, 但只授权本地会话和本地计价能力, 不启用外部额度采集.
