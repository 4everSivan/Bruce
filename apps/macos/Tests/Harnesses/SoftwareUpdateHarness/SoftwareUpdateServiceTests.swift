import Foundation
@testable import BruceAppCore

// MARK: - 状态机 / 自动检查 / 跳过 / 下载安装 (假网络 + 临时目录, 不访问任何真实端点)

@MainActor
final class ServiceFixture {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let transport = FakeUpdateTransport()
    let commands = RecordingCommandRunner()
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let model: AppModel
    let installedApp: URL
    let installer: UpdateInstaller
    var terminated = 0
    private(set) var service: SoftwareUpdateService!

    init(
        localVersion: String? = "0.12.2",
        withInstaller: Bool = true,
        moveItem: UpdateInstaller.MoveItem? = nil
    ) throws {
        root = try TemporaryDirectories.make("service")
        suiteName = "test.bruce.softwareUpdate.service.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw UpdateHarnessFailure.expectation("无法创建隔离 UserDefaults")
        }
        self.defaults = defaults
        model = AppModel(collapsedDefaults: defaults)
        installedApp = try FixtureBundle.makeApp(
            in: root.appendingPathComponent("Applications"),
            version: localVersion ?? "0.0.0"
        )
        let updatesRoot = root.appendingPathComponent("Application Support/Bruce/updates")
        if let moveItem {
            installer = UpdateInstaller(updatesRoot: updatesRoot, commands: commands, moveItem: moveItem)
        } else {
            installer = UpdateInstaller(updatesRoot: updatesRoot, commands: commands)
        }
        let clock = self.clock
        service = SoftwareUpdateService(
            localVersion: localVersion.flatMap(SemanticVersion.init),
            installedApp: installedApp,
            bundleIdentifier: FixtureBundle.bundleIdentifier,
            preferences: UpdatePreferences(defaults: defaults),
            transport: transport,
            installer: withInstaller ? installer : nil,
            model: model,
            now: { clock.now },
            terminate: { [weak self] in self?.terminated += 1 }
        )
    }

    func tearDown() {
        service.stop()
        defaults.removePersistentDomain(forName: suiteName)
        TemporaryDirectories.remove(root)
    }

    /// 准备一份真实可安装的 0.13.0 夹具包, 清单 sha 与之匹配.
    func serveInstallableRelease(version: String = "0.13.0") throws {
        let source = root.appendingPathComponent("release-\(version)", isDirectory: true)
        let app = try FixtureBundle.makeApp(in: source, version: version)
        let archive = root.appendingPathComponent("served-\(version).zip")
        try FixtureBundle.zip(app: app, to: archive)
        transport.downloadSource = archive
        transport.manifest = .success(manifestData(
            version: version,
            sha256: try UpdateInstaller.sha256Hex(of: archive)
        ))
        transport.contentLength = 7_100_000
    }

    var preferences: UpdatePreferences { UpdatePreferences(defaults: defaults) }
}

@MainActor
enum SoftwareUpdateServiceTests {
    static func devBuildNeverTouchesNetwork() async throws {
        let fixture = try ServiceFixture(localVersion: nil)
        defer { fixture.tearDown() }
        let service = fixture.service!
        try expect(service.isDevelopmentBuild, "无合法版本即 dev 构建")
        try expect(!service.canSelfInstall, "dev 构建不可自替换")
        service.start()
        fixture.clock.advance(31)
        await service.autoCheckTick()
        await service.checkNow()
        try expectEqual(fixture.transport.fetchCount, 0, "dev 构建不发起任何网络请求")
        try expectEqual(service.phase, .idle, "dev 构建保持空闲")
    }

    static func manualCheckFindsNewerRelease() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        let service = fixture.service!
        try expect(service.canSelfInstall, "临时目录夹具可自替换")
        await service.checkNow()
        guard case .available(let release) = service.phase else {
            throw UpdateHarnessFailure.expectation("应进入 available, 实得 \(service.phase)")
        }
        try expectEqual(release.version, SemanticVersion("0.13.0"), "远端版本")
        try expectEqual(release.sizeBytes, 7_100_000, "包体尺寸经 HEAD 补齐")
        try expectEqual(fixture.transport.headCount, 1, "发现新版本才发 HEAD")
        try expectEqual(service.lastCheckAt, fixture.clock.now, "上次检查时间")
        try expectEqual(fixture.preferences.lastCheckAt, fixture.clock.now, "上次检查时间持久化")
        try expect(service.phase.showsNavigationBadge, "导航角标出现")
    }

    static func manualCheckReportsLatest() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        fixture.transport.manifest = .success(manifestData(version: "0.12.2"))
        let service = fixture.service!
        await service.checkNow()
        try expectEqual(service.phase, .latest(checkedAt: fixture.clock.now), "本地 = 远端判已是最新")
        try expectEqual(fixture.transport.headCount, 0, "已是最新不发 HEAD")
        fixture.transport.manifest = .success(manifestData(version: "0.12.1"))
        await service.checkNow()
        guard case .latest = service.phase else {
            throw UpdateHarnessFailure.expectation("本地 > 远端也判已是最新, 实得 \(service.phase)")
        }
    }

    static func manualFailureShowsWarnAndSuccessClearsIt() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        let service = fixture.service!
        fixture.transport.manifest = .failure(.timedOut)
        await service.checkNow()
        try expectEqual(service.phase, .failed(.timedOut), "手动检查失败进入 failed")
        try expectEqual(fixture.model.settingsErrorMessage, "检查更新失败：网络超时", "状态行 warn")
        try expectEqual(service.lastCheckAt, nil, "失败不记上次检查")
        try expect(service.phase.allowsManualCheck, "失败后可重试")

        fixture.transport.manifest = .success(manifestData(version: "0.12.2"))
        await service.checkNow()
        try expectEqual(fixture.model.settingsErrorMessage, nil, "重试成功清除本服务告警")

        // 只清除自己写的告警, 不抹掉其他设置错误.
        fixture.transport.manifest = .failure(.httpStatus(404))
        await service.checkNow()
        try expectEqual(fixture.model.settingsErrorMessage, "检查更新失败：HTTP 404", "HTTP 失败告警")
        fixture.model.setSettingsError("诊断包导出失败, 未写入业务数据")
        fixture.transport.manifest = .success(manifestData(version: "0.12.2"))
        await service.checkNow()
        try expectEqual(
            fixture.model.settingsErrorMessage,
            "诊断包导出失败, 未写入业务数据",
            "其他来源的设置错误保留"
        )
    }

    static func autoCheckFollowsLaunchDelayAndDailyInterval() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        fixture.transport.manifest = .success(manifestData(version: "0.12.2"))
        let service = fixture.service!
        service.start()
        service.stop() // 由测试手动驱动 tick, 不依赖真实休眠.
        fixture.clock.advance(29)
        await service.autoCheckTick()
        try expectEqual(fixture.transport.fetchCount, 0, "启动 30 秒内不检查")
        fixture.clock.advance(1)
        await service.autoCheckTick()
        try expectEqual(fixture.transport.fetchCount, 1, "启动 30 秒后首查")
        fixture.clock.advance(24 * 60 * 60 - 1)
        await service.autoCheckTick()
        try expectEqual(fixture.transport.fetchCount, 1, "24 小时内不重复检查")
        fixture.clock.advance(1)
        await service.autoCheckTick()
        try expectEqual(fixture.transport.fetchCount, 2, "满 24 小时再查")
    }

    static func autoCheckFailureIsSilent() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        let service = fixture.service!
        service.start()
        service.stop()
        fixture.transport.manifest = .failure(.offline)
        fixture.clock.advance(30)
        await service.autoCheckTick()
        try expectEqual(fixture.transport.fetchCount, 1, "自动检查已执行")
        try expectEqual(service.phase, .idle, "自动检查失败不改主态")
        try expectEqual(fixture.model.settingsErrorMessage, nil, "自动检查失败不写状态行")
        try expectEqual(service.lastCheckAt, nil, "失败不记上次检查")

        // 已发现的新版本不被后续静默失败抹掉.
        try fixture.serveInstallableRelease()
        await service.checkNow()
        guard case .available = service.phase else {
            throw UpdateHarnessFailure.expectation("应为 available")
        }
        fixture.transport.manifest = .failure(.timedOut)
        fixture.clock.advance(24 * 60 * 60)
        await service.autoCheckTick()
        guard case .available = service.phase else {
            throw UpdateHarnessFailure.expectation("静默失败后仍为 available, 实得 \(service.phase)")
        }
        try expectEqual(fixture.model.settingsErrorMessage, nil, "仍不写状态行")
    }

    static func autoCheckFindsUpdateAndShowsBadge() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        let service = fixture.service!
        service.start()
        service.stop()
        fixture.clock.advance(30)
        await service.autoCheckTick()
        guard case .available = service.phase else {
            throw UpdateHarnessFailure.expectation("自动检查发现新版本进入 available, 实得 \(service.phase)")
        }
        try expect(service.phase.showsNavigationBadge, "仅以导航角标静默提示")
    }

    static func disabledAutoCheckDoesNotFetch() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        fixture.transport.manifest = .success(manifestData(version: "0.12.2"))
        let service = fixture.service!
        service.setAutoCheckEnabled(false)
        try expect(!fixture.preferences.autoCheckEnabled, "开关即时持久化")
        service.start()
        service.stop()
        fixture.clock.advance(30)
        await service.autoCheckTick()
        try expectEqual(fixture.transport.fetchCount, 0, "关闭后不自动检查")
        await service.checkNow()
        try expectEqual(fixture.transport.fetchCount, 1, "手动检查不受开关影响")
    }

    static func autoCheckDoesNotInterruptDownload() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        let service = fixture.service!
        service.start()
        service.stop()
        await service.checkNow()
        fixture.transport.holdDownload = true
        service.startDownload()
        try await waitUntil("下载开始") { fixture.transport.downloadCount == 1 }
        // 手动检查也重置 24 小时节奏; 拨满一天让自动检查确实到期, 验证是下载态挡住了它.
        fixture.clock.advance(24 * 60 * 60)
        await service.autoCheckTick()
        try expectEqual(fixture.transport.fetchCount, 1, "下载中不自动检查")
        guard case .downloading = service.phase else {
            throw UpdateHarnessFailure.expectation("仍在下载, 实得 \(service.phase)")
        }
        try expect(!service.phase.allowsManualCheck, "下载中禁用检查按钮")
        service.cancelDownload()
    }

    static func lateAutoCheckResultDoesNotOverrideDownload() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        let service = fixture.service!
        service.start()
        service.stop()
        await service.checkNow()
        fixture.clock.advance(24 * 60 * 60)
        fixture.transport.holdFetch = true
        let auto = Task { await service.autoCheckTick() }
        try await waitUntil("自动检查在途") { fixture.transport.fetchCount == 2 }
        // 静默检查在途时用户点了「下载并安装」.
        fixture.transport.holdDownload = true
        service.startDownload()
        try await waitUntil("下载开始") { fixture.transport.downloadCount == 1 }
        fixture.transport.holdFetch = false
        await auto.value
        guard case .downloading = service.phase else {
            throw UpdateHarnessFailure.expectation("迟到的检查结果不得覆盖下载态, 实得 \(service.phase)")
        }
        service.cancelDownload()
    }

    static func manualCheckJoinsInFlightAutoCheck() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        let service = fixture.service!
        service.start()
        service.stop()
        fixture.transport.manifest = .failure(.timedOut)
        fixture.transport.holdFetch = true
        fixture.clock.advance(30)
        let auto = Task { await service.autoCheckTick() }
        try await waitUntil("自动检查在途") { fixture.transport.fetchCount == 1 }
        try expectEqual(service.phase, .idle, "静默检查不显示 spinner")
        let manual = Task { await service.checkNow() }
        try await waitUntil("手动检查接管") { service.phase == .checking }
        fixture.transport.holdFetch = false
        await auto.value
        await manual.value
        try expectEqual(fixture.transport.fetchCount, 1, "复用在途请求, 不重复拉取")
        try expectEqual(service.phase, .failed(.timedOut), "用户在场时失败须呈现")
        try expectEqual(fixture.model.settingsErrorMessage, "检查更新失败：网络超时", "状态行告警")
    }

    static func skipVersionSemantics() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        let service = fixture.service!
        await service.checkNow()
        service.skipCurrentVersion()
        guard case .skipped(let skipped) = service.phase else {
            throw UpdateHarnessFailure.expectation("跳过后进入 skipped, 实得 \(service.phase)")
        }
        try expectEqual(skipped.version, SemanticVersion("0.13.0"), "跳过的版本")
        try expectEqual(fixture.preferences.skippedVersion, SemanticVersion("0.13.0"), "跳过版本持久化")
        try expect(!service.phase.showsNavigationBadge, "跳过后角标消失")

        await service.checkNow()
        guard case .skipped = service.phase else {
            throw UpdateHarnessFailure.expectation("同版本再查仍为 skipped, 实得 \(service.phase)")
        }

        service.resumeSkippedVersion()
        guard case .available = service.phase else {
            throw UpdateHarnessFailure.expectation("恢复检查回到 available, 实得 \(service.phase)")
        }
        try expectEqual(fixture.preferences.skippedVersion, nil, "恢复检查解除跳过")

        service.skipCurrentVersion()
        try fixture.serveInstallableRelease(version: "0.13.1")
        await service.checkNow()
        guard case .available(let newer) = service.phase else {
            throw UpdateHarnessFailure.expectation("远端出现更新版本自动恢复提醒, 实得 \(service.phase)")
        }
        try expectEqual(newer.version, SemanticVersion("0.13.1"), "新版本")
        try expectEqual(fixture.preferences.skippedVersion, nil, "跳过记录自动解除")
    }

    static func skippedVersionClearsOnceLocalCatchesUp() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        fixture.preferences.skippedVersion = SemanticVersion("0.12.2")
        fixture.transport.manifest = .success(manifestData(version: "0.12.2"))
        await fixture.service.checkNow()
        try expectEqual(fixture.preferences.skippedVersion, nil, "本地已达跳过版本即清除记录")
    }

    static func downloadVerifiesAndBecomesReady() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        let service = fixture.service!
        await service.checkNow()
        service.startDownload()
        guard case .downloading(_, let initial) = service.phase else {
            throw UpdateHarnessFailure.expectation("进入 downloading, 实得 \(service.phase)")
        }
        try expectEqual(initial.receivedBytes, 0, "初始进度 0")
        try expectEqual(initial.totalBytes, 7_100_000, "初始总量取自 HEAD 尺寸")
        try await waitUntil("下载完成就绪") {
            if case .ready = service.phase { return true }
            return false
        }
        try expectEqual(fixture.transport.downloadCount, 1, "下载一次")
        try expect(fixture.transport.progressEvents > 0, "有进度回调")
        try expect(service.phase.showsNavigationBadge, "就绪态保留角标")
        try expectEqual(fixture.model.settingsErrorMessage, nil, "成功不打扰")
    }

    static func downloadRejectsChecksumMismatch() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        fixture.transport.manifest = .success(manifestData(version: "0.13.0", sha256: String(repeating: "0", count: 64)))
        let service = fixture.service!
        await service.checkNow()
        service.startDownload()
        try await waitUntil("校验失败回到 available") {
            if case .available = service.phase { return true }
            return false
        }
        try expectEqual(
            fixture.model.settingsErrorMessage,
            "更新包校验失败：SHA256 不一致, 已拒绝安装",
            "校验失败告警"
        )
        try expect(
            !FileManager.default.fileExists(atPath: fixture.installer.updatesRoot.path),
            "校验失败清理下载残留"
        )
        try expectEqual(FixtureBundle.version(of: fixture.installedApp), "0.12.2", "未校验包绝不安装")
    }

    static func downloadFailureReturnsToAvailable() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        fixture.transport.downloadError = .downloadFailed
        let service = fixture.service!
        await service.checkNow()
        service.startDownload()
        try await waitUntil("下载失败回到 available") {
            if case .available = service.phase { return true }
            return false
        }
        try expectEqual(fixture.model.settingsErrorMessage, "下载更新失败：网络错误, 可稍后重试", "下载失败告警")
    }

    static func cancelDownloadReturnsImmediately() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        fixture.transport.holdDownload = true
        let service = fixture.service!
        await service.checkNow()
        service.startDownload()
        try await waitUntil("下载开始") { fixture.transport.downloadCount == 1 }
        service.cancelDownload()
        guard case .available = service.phase else {
            throw UpdateHarnessFailure.expectation("取消立即回到 available, 实得 \(service.phase)")
        }
        // 在途任务随后收尾, 不得改写状态或告警.
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .available = service.phase else {
            throw UpdateHarnessFailure.expectation("取消后保持 available, 实得 \(service.phase)")
        }
        try expectEqual(fixture.model.settingsErrorMessage, nil, "取消不告警")
    }

    static func postponeThenRecheckReturnsToReady() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        let service = fixture.service!
        await service.checkNow()
        service.startDownload()
        try await waitUntil("就绪") {
            if case .ready = service.phase { return true }
            return false
        }
        service.postponeInstall()
        guard case .available = service.phase else {
            throw UpdateHarnessFailure.expectation("稍后回到 available, 实得 \(service.phase)")
        }
        await service.checkNow()
        guard case .ready = service.phase else {
            throw UpdateHarnessFailure.expectation("已暂存同版本再查直接就绪, 实得 \(service.phase)")
        }
        try expectEqual(fixture.transport.downloadCount, 1, "不重复下载")
    }

    static func installReplacesAndRelaunches() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        let service = fixture.service!
        await service.checkNow()
        service.startDownload()
        try await waitUntil("就绪") {
            if case .ready = service.phase { return true }
            return false
        }
        service.installAndRelaunch()
        guard case .relaunching = service.phase else {
            throw UpdateHarnessFailure.expectation("进入 relaunching, 实得 \(service.phase)")
        }
        try expectEqual(FixtureBundle.version(of: fixture.installedApp), "0.13.0", "原位置已替换为新版本")
        try expectEqual(
            FixtureBundle.version(of: fixture.installer.backupDirectory.appendingPathComponent("Bruce.app")),
            "0.12.2",
            "旧版本留在 backup"
        )
        try expectEqual(fixture.commands.detached.count, 1, "启动重启等待器")
        try expectEqual(fixture.commands.detached.first?.1.last, fixture.installedApp.path, "重启目标为原安装位置")
        try expectEqual(
            fixture.commands.detached.first?.1[3],
            String(ProcessInfo.processInfo.processIdentifier),
            "等待当前进程退出"
        )
        try expectEqual(fixture.terminated, 1, "当前进程退出")
    }

    static func installFailureRollsBackAndWarns() async throws {
        let calls = Counter()
        let fixture = try ServiceFixture(moveItem: { from, to in
            // 第 2 次 move 为新 app → 原位置, 注入失败触发回滚.
            if calls.increment() == 2 {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.moveItem(at: from, to: to)
        })
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        let service = fixture.service!
        await service.checkNow()
        service.startDownload()
        try await waitUntil("就绪") {
            if case .ready = service.phase { return true }
            return false
        }
        service.installAndRelaunch()
        guard case .available = service.phase else {
            throw UpdateHarnessFailure.expectation("替换失败回到 available, 实得 \(service.phase)")
        }
        try expectEqual(fixture.model.settingsErrorMessage, "安装更新失败：已恢复原版本", "回滚告警")
        try expectEqual(FixtureBundle.version(of: fixture.installedApp), "0.12.2", "原 app 完好")
        try expectEqual(fixture.terminated, 0, "失败不退出")
        try expectEqual(fixture.commands.detached.count, 0, "失败不重启")
    }

    static func relaunchFailureKeepsProcessAlive() async throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        fixture.commands.detachedFails = true
        let service = fixture.service!
        await service.checkNow()
        service.startDownload()
        try await waitUntil("就绪") {
            if case .ready = service.phase { return true }
            return false
        }
        service.installAndRelaunch()
        try expectEqual(
            fixture.model.settingsErrorMessage,
            "新版本已安装, 自动重启失败, 请手动重新打开 Bruce",
            "重启失败告警"
        )
        try expectEqual(FixtureBundle.version(of: fixture.installedApp), "0.13.0", "新版本已就位")
        try expectEqual(fixture.terminated, 0, "等待器未启动时不退出")
    }

    static func manualInstallOnlyWhenLocationNotReplaceable() async throws {
        let fixture = try ServiceFixture(withInstaller: false)
        defer { fixture.tearDown() }
        try fixture.serveInstallableRelease()
        let service = fixture.service!
        try expect(!service.canSelfInstall, "无可用安装器即降级")
        await service.checkNow()
        service.startDownload()
        try expectEqual(fixture.transport.downloadCount, 0, "降级时不下载")
        guard case .available(let release) = service.phase else {
            throw UpdateHarnessFailure.expectation("仍提示新版本, 实得 \(service.phase)")
        }
        let banner = UpdatePresentation.banner(
            release: release,
            localVersion: service.localVersion,
            canSelfInstall: service.canSelfInstall
        )
        try expectEqual(banner.actions, [.skipVersion, .openReleasePage], "横幅降级为引导手动更新")
    }

    static func startCleansPreviousUpgradeArtifacts() throws {
        let fixture = try ServiceFixture()
        defer { fixture.tearDown() }
        let leftover = fixture.installer.backupDirectory.appendingPathComponent("Bruce.app")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        fixture.service.start()
        fixture.service.stop()
        try expect(
            !FileManager.default.fileExists(atPath: fixture.installer.updatesRoot.path),
            "新版本启动清理上一轮下载与备份"
        )
    }
}
