import Foundation
@testable import BruceAppCore

/// T10 软件更新 Harness: semver / 清单 / 调度 / 偏好 / 双端文案对拍 / 状态机 / 安装器.
/// 网络以 FakeUpdateTransport 替换, 安装器只在临时目录夹具上运行.
@main
@MainActor
struct SoftwareUpdateHarness {
    static func main() async throws {
        let repoRoot = resolveRepoRoot()
        var passed = 0

        func run(_ name: String, _ body: () async throws -> Void) async throws {
            print("Software update: \(name)")
            try await body()
            passed += 1
        }

        // 模型与纯函数
        try await run("semver 解析") { try SoftwareUpdateModelTests.semverParsesStrictTriples() }
        try await run("semver 比较") { try SoftwareUpdateModelTests.semverComparesNumerically() }
        try await run("生成器清单 fixture") { try SoftwareUpdateModelTests.generatorManifestFixtureParses(repoRoot: repoRoot) }
        try await run("清单拒绝非法条目") { try SoftwareUpdateModelTests.manifestRejectsUntrustedOrMalformedEntries() }
        try await run("自动检查时序") { try SoftwareUpdateModelTests.scheduleChecksThirtySecondsAfterLaunchThenDaily() }
        try await run("偏好默认值与持久化") { try SoftwareUpdateModelTests.preferencesDefaultOnAndRoundTrip() }
        try await run("网络错误分类") { try SoftwareUpdateModelTests.transportClassifiesTimeouts() }
        var parityCases = 0
        try await run("双端文案对拍 fixture") {
            parityCases = try SoftwareUpdateParityTests.sharedCopyFixture(repoRoot: repoRoot)
        }

        // 安装器
        try await run("SHA256 标准向量") { try SoftwareUpdateInstallerTests.sha256MatchesKnownVector() }
        try await run("解压与 bundle 复核") { try await SoftwareUpdateInstallerTests.prepareExtractsAndValidatesBundle() }
        try await run("SHA256 不符拒绝") { try await SoftwareUpdateInstallerTests.prepareRejectsChecksumMismatch() }
        try await run("降级与错配拒绝") { try await SoftwareUpdateInstallerTests.prepareRejectsDowngradeAndMismatchedBundles() }
        try await run("损坏压缩包拒绝") { try await SoftwareUpdateInstallerTests.prepareRejectsCorruptArchive() }
        try await run("剥离 quarantine") { try await SoftwareUpdateInstallerTests.prepareStripsQuarantine() }
        try await run("原子替换保留备份") { try SoftwareUpdateInstallerTests.replaceSwapsBundleAndKeepsBackup() }
        try await run("替换失败回滚") { try SoftwareUpdateInstallerTests.replaceRollsBackWhenSwapFails() }
        try await run("回滚失败如实报告") { try SoftwareUpdateInstallerTests.replaceReportsFailedRollback() }
        try await run("备份失败不动原位置") { try SoftwareUpdateInstallerTests.replaceFailsCleanlyWhenBackupFails() }
        try await run("自替换位置前置检查") { try SoftwareUpdateInstallerTests.selfReplaceRequiresWritableSameVolumeLocation() }
        try await run("重启等待器") { try SoftwareUpdateInstallerTests.relaunchWaitsForCurrentProcessThenOpens() }
        try await run("清理只限 updates 目录") { try SoftwareUpdateInstallerTests.removeStaleArtifactsOnlyTouchesUpdatesRoot() }

        // 服务状态机
        try await run("dev 构建降级") { try await SoftwareUpdateServiceTests.devBuildNeverTouchesNetwork() }
        try await run("手动检查发现新版本") { try await SoftwareUpdateServiceTests.manualCheckFindsNewerRelease() }
        try await run("手动检查已是最新") { try await SoftwareUpdateServiceTests.manualCheckReportsLatest() }
        try await run("手动失败告警与清除") { try await SoftwareUpdateServiceTests.manualFailureShowsWarnAndSuccessClearsIt() }
        try await run("自动检查 30 秒 + 24 小时") { try await SoftwareUpdateServiceTests.autoCheckFollowsLaunchDelayAndDailyInterval() }
        try await run("自动检查失败静默") { try await SoftwareUpdateServiceTests.autoCheckFailureIsSilent() }
        try await run("自动检查发现新版本") { try await SoftwareUpdateServiceTests.autoCheckFindsUpdateAndShowsBadge() }
        try await run("关闭自动检查") { try await SoftwareUpdateServiceTests.disabledAutoCheckDoesNotFetch() }
        try await run("下载中不自动检查") { try await SoftwareUpdateServiceTests.autoCheckDoesNotInterruptDownload() }
        try await run("迟到检查不覆盖下载") { try await SoftwareUpdateServiceTests.lateAutoCheckResultDoesNotOverrideDownload() }
        try await run("手动接管在途自动检查") { try await SoftwareUpdateServiceTests.manualCheckJoinsInFlightAutoCheck() }
        try await run("跳过版本语义") { try await SoftwareUpdateServiceTests.skipVersionSemantics() }
        try await run("本地追平跳过版本") { try await SoftwareUpdateServiceTests.skippedVersionClearsOnceLocalCatchesUp() }
        try await run("下载校验就绪") { try await SoftwareUpdateServiceTests.downloadVerifiesAndBecomesReady() }
        try await run("下载包校验失败") { try await SoftwareUpdateServiceTests.downloadRejectsChecksumMismatch() }
        try await run("下载失败") { try await SoftwareUpdateServiceTests.downloadFailureReturnsToAvailable() }
        try await run("取消下载") { try await SoftwareUpdateServiceTests.cancelDownloadReturnsImmediately() }
        try await run("稍后与再次就绪") { try await SoftwareUpdateServiceTests.postponeThenRecheckReturnsToReady() }
        try await run("安装并重启") { try await SoftwareUpdateServiceTests.installReplacesAndRelaunches() }
        try await run("安装失败回滚") { try await SoftwareUpdateServiceTests.installFailureRollsBackAndWarns() }
        try await run("重启失败不退出") { try await SoftwareUpdateServiceTests.relaunchFailureKeepsProcessAlive() }
        try await run("位置不可写降级") { try await SoftwareUpdateServiceTests.manualInstallOnlyWhenLocationNotReplaceable() }
        try await run("启动清理残留") { try SoftwareUpdateServiceTests.startCleansPreviousUpgradeArtifacts() }

        print("SoftwareUpdate tests passed: \(passed) (parity assertions: \(parityCases))")
    }

    private static func resolveRepoRoot() -> URL {
        if CommandLine.arguments.count > 1 {
            return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SoftwareUpdateHarness.swift -> SoftwareUpdateHarness/
            .deletingLastPathComponent() // -> Harnesses/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> macos/
            .deletingLastPathComponent() // -> apps/
            .deletingLastPathComponent() // -> repoRoot
    }
}
