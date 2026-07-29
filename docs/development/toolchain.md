# macOS 应用工具链基线

## 平台与标识

- 最低系统版本: macOS 13 Ventura.
- 应用形态: 独立 Dock 应用.
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
  agent-usage/collector/collect_usage.py \
  github/collector/collect_github.py \
  gitlab/collector/collect_gitlab.py
```

## 构建边界

- SwiftPM 验证只证明源码可以编译, 不证明应用签名、沙盒权限、Keychain entitlement 或 Dock 生命周期已经完成.
- `.app` 打包、签名、公证和真实授权窗口验收必须在完整 Xcode 可用后执行.
- 真实 Collector、OAuth 和 PAT 验收不属于静态工具链检查, 必须另行获得用户明确授权.

## 测试

### MdddOnboardingCore library target (已接入构建)

- `MdddOnboardingCore` 是不含 SwiftUI/AppKit 的纯 library target, 可以被测试 harness 通过 `@testable import` 正常链接和运行.
- `MdddOnboardingCoreHarness` 是依赖 Core library 的 `@main` 可执行 harness, 已接入 `Package.swift` 构建目标.
- 运行: `swift run --package-path macos/MdddApp MdddOnboardingCoreHarness`
- 当前包含 49 个测试, 覆盖 Python 版本解析, 路径解析, ActivationGate, ReadinessEvaluator, 配置存储, Keychain 抽象和 schema profile.

### 旧 harness (依赖 executable target, 未接入构建)

- `macos/MdddApp/Tests/Harnesses/` 下有五个 `@main` 可执行测试 harness: `ArtifactStoreHarness`, `CollectorRunnerHarness`, `NativeLifecycleHarness`, `OnboardingScannerHarness` 和 `RefreshSchedulerHarness`.
- 这些 harness 依赖 `MdddApp` executable target, 当前在 Command Line Tools 下因 executable 符号无法被外部 target 链接而未接入构建.
- 每个 harness 接受仓库根路径作为唯一参数, 在完整 Xcode 可用后可通过添加 `executableTarget` 依赖来编译和运行.
- 后续可将这些 harness 迁移到依赖 `MdddOnboardingCore` 或新建的 library target, 以复用已验证的 library target 测试模式.
