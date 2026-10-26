import Combine
import Foundation

// MARK: - 软件更新服务 (07-软件更新 §4.1 状态机 / §4.2 R2 / R4 / R5 / R6)

/// 设置页「软件更新」卡的唯一状态源: 拉取清单、semver 比较、自动检查调度、跳过版本、
/// 下载校验与自替换安装. dev 构建 (无合法 bundle 版本) 不发起任何网络请求.
@MainActor
package final class SoftwareUpdateService: ObservableObject {
    @Published package private(set) var phase: UpdatePhase = .idle
    @Published package private(set) var autoCheckEnabled: Bool
    /// 上次成功检查时间 (持久化).
    @Published package private(set) var lastCheckAt: Date?

    /// 本地版本; nil 即 dev 构建降级 (07 §4.2 R2).
    package let localVersion: SemanticVersion?
    /// 当前应用能否原地自替换; 否则横幅降级为引导手动更新 (R6.4).
    package let canSelfInstall: Bool

    private let preferences: UpdatePreferences
    private let transport: any UpdateTransport
    private let installer: UpdateInstaller?
    private let manifestURL: URL
    private let installedApp: URL
    private let bundleIdentifier: String?
    private let now: () -> Date
    private let terminate: () -> Void
    private weak var model: AppModel?

    private var launchedAt: Date?
    private var lastAttemptAt: Date?
    private var checkTask: Task<Void, Never>?
    private var checkIsManual = false
    private var downloadTask: Task<Void, Never>?
    /// 下载代次: 取消或重新下载后, 旧任务的迟到回调不得改写状态.
    private var downloadGeneration = 0
    private var stagedApp: (version: SemanticVersion, url: URL)?
    private var scheduleTask: Task<Void, Never>?
    /// 本服务写入状态行的最后一条文案; 只清除自己写的, 不抹掉其他设置错误.
    private var postedStatusLine: String?

    package init(
        localVersion: SemanticVersion?,
        installedApp: URL,
        bundleIdentifier: String?,
        preferences: UpdatePreferences,
        transport: any UpdateTransport,
        installer: UpdateInstaller?,
        manifestURL: URL = UpdateRepository.manifestURL,
        model: AppModel?,
        now: @escaping () -> Date = Date.init,
        terminate: @escaping () -> Void = {}
    ) {
        self.localVersion = localVersion
        self.installedApp = installedApp
        self.bundleIdentifier = bundleIdentifier
        self.preferences = preferences
        self.transport = transport
        self.installer = installer
        self.manifestURL = manifestURL
        self.model = model
        self.now = now
        self.terminate = terminate
        autoCheckEnabled = preferences.autoCheckEnabled
        lastCheckAt = preferences.lastCheckAt
        canSelfInstall = localVersion != nil
            && installer?.canSelfReplace(installedApp: installedApp) == true
    }

    /// 生产装配: 版本取 Bundle 短版本串, 安装位置取运行中的 bundle.
    package convenience init(
        bundle: Bundle = .main,
        model: AppModel?,
        terminate: @escaping () -> Void
    ) {
        let rawVersion = AppVersion.current(bundle: bundle)
        // 裸 swift run 没有 .app 包装, bundleURL 指向可执行文件目录, 同样按 dev 处理.
        let isAppBundle = bundle.bundleURL.pathExtension == "app"
        self.init(
            localVersion: isAppBundle ? SemanticVersion(rawVersion) : nil,
            installedApp: bundle.bundleURL,
            bundleIdentifier: bundle.bundleIdentifier,
            preferences: UpdatePreferences(),
            transport: URLSessionUpdateTransport(),
            installer: UpdateInstaller.defaultUpdatesRoot().map { UpdateInstaller(updatesRoot: $0) },
            model: model,
            terminate: terminate
        )
    }

    package var isDevelopmentBuild: Bool { localVersion == nil }

    // MARK: 启动与自动检查

    /// 应用启动时调用: 清理上一轮升级残留与已追平跳过版本, 并开始自动检查调度 (启动 30 秒后首查).
    package func start() {
        guard let localVersion, launchedAt == nil else { return }
        launchedAt = now()
        installer?.removeStaleArtifacts()
        cleanupStaleSkippedVersion(localVersion: localVersion)
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.secondsUntilNextAutoCheck()
                if wait > 0 {
                    let slice = min(wait, UpdateCheckSchedule.pollSlice)
                    try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                    continue
                }
                await self.autoCheckTick()
            }
        }
    }

    /// 启动时即时比对当前版本; 本地版本追平或超过跳过版本时清除记录 (07 §4.2 R4).
    private func cleanupStaleSkippedVersion(localVersion: SemanticVersion) {
        if let skipped = preferences.skippedVersion, skipped <= localVersion {
            preferences.skippedVersion = nil
        }
    }

    package func stop() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    /// 自动检查到期判定 + 执行; 调度循环与测试共用. 关闭开关、检查进行中或用户正在下载/安装时不打扰.
    package func autoCheckTick() async {
        guard let launchedAt, localVersion != nil else { return }
        let current = now()
        guard current >= UpdateCheckSchedule.nextCheck(
            launchedAt: launchedAt,
            lastAttemptAt: lastAttemptAt
        ) else { return }
        guard autoCheckEnabled else {
            // 关闭期间顺延, 重新开启后按 24 小时节奏继续.
            lastAttemptAt = current
            return
        }
        switch phase {
        case .checking, .downloading, .ready, .relaunching:
            lastAttemptAt = current
            return
        case .idle, .latest, .available, .failed, .skipped:
            break
        }
        await runCheck(manual: false)
    }

    private func secondsUntilNextAutoCheck() -> TimeInterval {
        guard let launchedAt else { return UpdateCheckSchedule.pollSlice }
        return UpdateCheckSchedule.nextCheck(
            launchedAt: launchedAt,
            lastAttemptAt: lastAttemptAt
        ).timeIntervalSince(now())
    }

    package func setAutoCheckEnabled(_ enabled: Bool) {
        autoCheckEnabled = enabled
        preferences.autoCheckEnabled = enabled
    }

    // MARK: 检查

    /// 手动检查: 不受间隔限制; 自动检查在途时升级为手动语义 (失败也要呈现).
    package func checkNow() async {
        guard localVersion != nil, phase.allowsManualCheck else { return }
        await runCheck(manual: true)
    }

    private func runCheck(manual: Bool) async {
        if manual {
            checkIsManual = true
            phase = .checking
            clearStatusLine()
        }
        if let checkTask {
            await checkTask.value
            return
        }
        if !manual {
            checkIsManual = false
        }
        lastAttemptAt = now()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performCheck()
        }
        checkTask = task
        await task.value
    }

    private func performCheck() async {
        defer {
            checkTask = nil
            checkIsManual = false
        }
        guard let localVersion else { return }
        do {
            let data = try await transport.fetchManifest(from: manifestURL)
            var release = try UpdateRelease.parse(manifestData: data)
            if release.version > localVersion {
                release.sizeBytes = await transport.contentLength(of: release.downloadURL)
            }
            let checkedAt = now()
            lastCheckAt = checkedAt
            preferences.lastCheckAt = checkedAt
            apply(release: release, localVersion: localVersion, checkedAt: checkedAt)
            if checkIsManual {
                clearStatusLine()
            }
        } catch {
            let failure = error as? UpdateCheckFailure ?? .offline
            if checkIsManual {
                phase = .failed(failure)
                postStatusLine(failure.statusLine)
            }
            // 自动检查失败完全静默: 不改主态、不写状态行 (R5).
        }
    }

    /// 检查结果落到状态机; 跳过语义: 远端不高于已跳过版本保持跳过, 出现更新版本自动解除 (R4).
    private func apply(release: UpdateRelease, localVersion: SemanticVersion, checkedAt: Date) {
        switch phase {
        case .downloading, .ready, .relaunching:
            // 静默检查在途期间用户已开始下载/安装: 迟到的结果不得覆盖用户驱动的状态.
            return
        case .idle, .checking, .latest, .available, .failed, .skipped:
            break
        }
        if let skipped = preferences.skippedVersion,
           skipped <= localVersion || release.version > skipped {
            preferences.skippedVersion = nil
        }
        guard release.version > localVersion else {
            phase = .latest(checkedAt: checkedAt)
            return
        }
        if let skipped = preferences.skippedVersion, release.version <= skipped {
            phase = .skipped(release)
            return
        }
        // 已下载并校验过同一版本时直接回到就绪态, 不重复下载.
        if let stagedApp, stagedApp.version == release.version,
           FileManager.default.fileExists(atPath: stagedApp.url.path) {
            phase = .ready(release)
            return
        }
        phase = .available(release)
    }

    // MARK: 跳过版本

    package func skipCurrentVersion() {
        guard case .available(let release) = phase else { return }
        preferences.skippedVersion = release.version
        phase = .skipped(release)
    }

    package func resumeSkippedVersion() {
        guard case .skipped(let release) = phase else { return }
        preferences.skippedVersion = nil
        phase = .available(release)
    }

    package var skippedVersion: SemanticVersion? { preferences.skippedVersion }

    // MARK: 下载与安装

    package func startDownload() {
        guard case .available(let release) = phase,
              canSelfInstall,
              let installer,
              let localVersion else { return }
        clearStatusLine()
        downloadGeneration += 1
        let generation = downloadGeneration
        phase = .downloading(release, UpdateDownloadProgress(
            receivedBytes: 0,
            totalBytes: release.sizeBytes
        ))
        let transport = self.transport
        let bundleIdentifier = self.bundleIdentifier
        let reportProgress: @Sendable (UpdateDownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.updateProgress(progress, generation: generation)
            }
        }
        downloadTask = Task { [weak self] in
            do {
                try installer.prepareUpdatesRoot()
                let archive = installer.downloadURL(for: release.version)
                try await transport.download(
                    from: release.downloadURL,
                    to: archive,
                    progress: reportProgress
                )
                try Task.checkCancellation()
                let app = try await installer.prepare(
                    archive: archive,
                    release: release,
                    localVersion: localVersion,
                    bundleIdentifier: bundleIdentifier
                )
                self?.finishDownload(release: release, app: app, generation: generation)
            } catch {
                self?.failDownload(release: release, error: error, generation: generation)
            }
        }
    }

    private func updateProgress(_ progress: UpdateDownloadProgress, generation: Int) {
        guard generation == downloadGeneration,
              case .downloading(let release, let current) = phase,
              // 只在可见文案变化时发布 (0.1 MB / 1% 粒度), 避免每个网络分块都重绘整个设置窗口.
              UpdatePresentation.downloadMeta(progress) != UpdatePresentation.downloadMeta(current)
        else { return }
        phase = .downloading(release, progress)
    }

    private func finishDownload(release: UpdateRelease, app: URL, generation: Int) {
        guard generation == downloadGeneration else { return }
        downloadTask = nil
        stagedApp = (release.version, app)
        phase = .ready(release)
    }

    private func failDownload(release: UpdateRelease, error: Error, generation: Int) {
        guard generation == downloadGeneration else { return }
        downloadTask = nil
        installer?.removeStaleArtifacts()
        phase = .available(release)
        if !(error is CancellationError) {
            let failure = error as? UpdateInstallFailure ?? .downloadFailed
            postStatusLine(failure.statusLine)
        }
    }

    /// 「取消」: 立即回到 available, 在途下载随后被取消且其结果作废.
    package func cancelDownload() {
        guard case .downloading(let release, _) = phase else { return }
        downloadGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
        installer?.removeStaleArtifacts()
        phase = .available(release)
    }

    /// 「稍后」: 保留已下载的暂存包, 回到 available; 再次检查同版本时直接回到就绪态.
    package func postponeInstall() {
        guard case .ready(let release) = phase else { return }
        phase = .available(release)
    }

    /// 「安装并重启」: 原子替换 → 启动等待器 → 退出当前进程; 替换失败已回滚并告警.
    package func installAndRelaunch() {
        guard case .ready(let release) = phase,
              let installer,
              let stagedApp,
              stagedApp.version == release.version else { return }
        phase = .relaunching(release)
        do {
            try installer.replace(installedApp: installedApp, with: stagedApp.url)
        } catch {
            self.stagedApp = nil
            let failure = error as? UpdateInstallFailure ?? .replaceFailed(rolledBack: true)
            let rolledBack: Bool
            if case .replaceFailed(let rb) = failure {
                rolledBack = rb
            } else {
                rolledBack = true
            }
            if rolledBack {
                installer.removeStaleArtifacts()
            } else {
                // 回滚失败时保护 backup 目录, 只清理暂存包
                installer.removeWorkingArtifacts(keepBackup: true)
            }
            phase = .available(release)
            postStatusLine(failure.statusLine)
            return
        }
        self.stagedApp = nil
        do {
            try installer.relaunch(
                app: installedApp,
                waitingFor: ProcessInfo.processInfo.processIdentifier
            )
        } catch {
            // 新版本已就位, 旧进程继续运行旧代码; 提示用户手动重开.
            phase = .ready(release)
            postStatusLine(UpdateInstallFailure.relaunchFailed.statusLine)
            return
        }
        terminate()
    }

    // MARK: 状态行

    private func postStatusLine(_ message: String) {
        postedStatusLine = message
        model?.setSettingsError(message)
    }

    private func clearStatusLine() {
        guard let postedStatusLine else { return }
        if model?.settingsErrorMessage == postedStatusLine {
            model?.setSettingsError(nil)
        }
        self.postedStatusLine = nil
    }
}
