import Foundation
@testable import BruceAppCore

// MARK: - semver / 清单 / 调度 / 偏好

enum SoftwareUpdateModelTests {
    static func semverParsesStrictTriples() throws {
        try expectEqual(SemanticVersion("0.12.2"), SemanticVersion(major: 0, minor: 12, patch: 2), "纯三段")
        try expectEqual(SemanticVersion("v0.13.0"), SemanticVersion(major: 0, minor: 13, patch: 0), "v 前缀")
        try expectEqual(SemanticVersion(" 1.2.3\n"), SemanticVersion(major: 1, minor: 2, patch: 3), "首尾空白")
        for invalid in ["", "unknown", "0.13", "0.13.0.1", "0.13.0-beta", "0..1", "a.b.c", "1.2.-3", "1.2.３"] {
            try expect(SemanticVersion(invalid) == nil, "非法版本应拒绝: \(invalid)")
        }
        try expectEqual(SemanticVersion("0.13.0")?.tag, "v0.13.0", "tag 带 v")
    }

    static func semverComparesNumerically() throws {
        func v(_ raw: String) -> SemanticVersion { SemanticVersion(raw)! }
        try expect(v("0.12.10") > v("0.12.9"), "patch 按整数比较")
        try expect(v("0.13.0") > v("0.12.99"), "minor 优先于 patch")
        try expect(v("1.0.0") > v("0.99.99"), "major 优先")
        try expect(!(v("0.12.2") < v("0.12.2")), "相等不小于")
        try expect(v("0.12.2") <= v("0.12.2"), "本地 ≥ 远端判已是最新")
    }

    static func generatorManifestFixtureParses(repoRoot: URL) throws {
        // 由 T09 真实生成器 scripts/generate-update-manifest.mjs 以占位输入产出, 锁定双端契约.
        let url = repoRoot.appendingPathComponent("tests/fixtures/update-manifest/latest.json")
        let release = try UpdateRelease.parse(manifestData: Data(contentsOf: url))
        try expectEqual(release.version, SemanticVersion(major: 0, minor: 13, patch: 0), "清单版本")
        try expectEqual(
            release.downloadURL.absoluteString,
            "https://github.com/4everSivan/Bruce/releases/download/v0.13.0/Bruce.zip",
            "darwin 下载地址"
        )
        try expectEqual(
            release.sha256,
            "4a83e99bf13939d3d91485823ec8d049bc9febf2da9e55c79f5a0ebcf69183a6",
            "darwin sha256"
        )
        try expect(release.notes.hasPrefix("应用内软件更新; "), "notes 为「; 」连接的要点")
        try expectEqual(release.sizeBytes, nil, "清单不含尺寸")
        try expectEqual(
            release.releasePageURL.absoluteString,
            "https://github.com/4everSivan/Bruce/releases/tag/v0.13.0",
            "发布页"
        )
    }

    static func manifestRejectsUntrustedOrMalformedEntries() throws {
        let sha = String(repeating: "b", count: 64)
        let rejected: [(String, Data)] = [
            ("非 JSON", Data("not json".utf8)),
            ("版本缺段", manifestData(version: "0.13", sha256: sha)),
            ("预发布版本", manifestData(version: "0.13.0-rc1", sha256: sha)),
            ("http 明文", manifestData(version: "0.13.0", sha256: sha, url: "http://github.com/4everSivan/Bruce/releases/download/v0.13.0/Bruce.zip")),
            ("第三方主机", manifestData(version: "0.13.0", sha256: sha, url: "https://evil.example.com/Bruce.zip")),
            ("sha 过短", manifestData(version: "0.13.0", sha256: "abc")),
            ("sha 非十六进制", manifestData(version: "0.13.0", sha256: String(repeating: "z", count: 64))),
        ]
        for (label, data) in rejected {
            do {
                _ = try UpdateRelease.parse(manifestData: data)
                throw UpdateHarnessFailure.expectation("应拒绝清单: \(label)")
            } catch let failure as UpdateCheckFailure {
                try expectEqual(failure, .invalidManifest, label)
            }
        }
        let missingDarwin = try JSONSerialization.data(withJSONObject: [
            "version": "0.13.0",
            "platforms": ["windows-x86_64": ["url": "https://github.com/x", "signature": "s"]],
        ])
        do {
            _ = try UpdateRelease.parse(manifestData: missingDarwin)
            throw UpdateHarnessFailure.expectation("缺 darwin 条目应拒绝")
        } catch let failure as UpdateCheckFailure {
            try expectEqual(failure, .invalidManifest, "缺 darwin 条目")
        }
        let upper = try UpdateRelease.parse(manifestData: manifestData(
            version: "0.13.0",
            sha256: String(repeating: "C", count: 64)
        ))
        try expectEqual(upper.sha256, String(repeating: "c", count: 64), "sha 统一小写")
    }

    static func scheduleChecksThirtySecondsAfterLaunchThenDaily() throws {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        try expectEqual(
            UpdateCheckSchedule.nextCheck(launchedAt: launch, lastAttemptAt: nil),
            launch.addingTimeInterval(30),
            "启动 30 秒后首查"
        )
        let attempt = launch.addingTimeInterval(31)
        try expectEqual(
            UpdateCheckSchedule.nextCheck(launchedAt: launch, lastAttemptAt: attempt),
            attempt.addingTimeInterval(24 * 60 * 60),
            "此后距上次尝试 24 小时"
        )
    }

    @MainActor
    static func preferencesDefaultOnAndRoundTrip() throws {
        let suiteName = "test.bruce.softwareUpdate.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            throw UpdateHarnessFailure.expectation("无法创建隔离 UserDefaults")
        }
        defer { suite.removePersistentDomain(forName: suiteName) }
        let preferences = UpdatePreferences(defaults: suite)
        try expect(preferences.autoCheckEnabled, "自动检查默认开启")
        try expectEqual(preferences.lastCheckAt, nil, "默认未检查")
        try expectEqual(preferences.skippedVersion, nil, "默认无跳过")

        preferences.autoCheckEnabled = false
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_123)
        preferences.lastCheckAt = checkedAt
        preferences.skippedVersion = SemanticVersion("0.13.0")
        let reloaded = UpdatePreferences(defaults: suite)
        try expect(!reloaded.autoCheckEnabled, "关闭状态持久化")
        try expectEqual(reloaded.lastCheckAt, checkedAt, "上次检查时间持久化")
        try expectEqual(reloaded.skippedVersion, SemanticVersion("0.13.0"), "跳过版本持久化")

        reloaded.skippedVersion = nil
        reloaded.lastCheckAt = nil
        try expectEqual(UpdatePreferences(defaults: suite).skippedVersion, nil, "跳过版本可清除")
        try expectEqual(UpdatePreferences(defaults: suite).lastCheckAt, nil, "检查时间可清除")
    }

    static func transportClassifiesTimeouts() throws {
        try expectEqual(URLSessionUpdateTransport.classify(URLError(.timedOut)), .timedOut, "超时")
        try expectEqual(URLSessionUpdateTransport.classify(URLError(.notConnectedToInternet)), .offline, "断网")
        try expectEqual(URLSessionUpdateTransport.classify(URLError(.cannotFindHost)), .offline, "DNS")
        try expectEqual(URLSessionUpdateTransport.manifestTimeout, 10, "清单请求超时 10 秒")
    }
}

// MARK: - 双端文案对拍 (tests/fixtures/update-copy-parity)

private struct CopyFixture: Decodable {
    struct Release: Decodable {
        let version: String
        let notes: String
        let sizeBytes: Int64?
    }

    struct Rows: Decodable {
        // C142: toggleOn / toggleOff 随行内状态字一并移除, 不再属于文案契约.
        let caption, autoCheckTitle, autoCheckSubtitle: String
        let currentVersionTitle, checkTitle, checkButton, navigationBadge: String
    }

    struct CurrentVersionCase: Decodable {
        let name: String
        let localVersion: String?
        let expectedValue: String
    }

    struct LastCheckCase: Decodable {
        let name: String
        let at: String?
        let expected: String
    }

    struct Phase: Decodable {
        let kind: String
        let checkedAt: String?
        let receivedBytes: Int64?
        let totalBytes: Int64?
        let failure: String?
        let httpStatus: Int?
    }

    struct Expected: Decodable {
        let kind: String
        let text: String?
        let title: String?
        let detail: String?
        let fromVersion: String?
        let toVersion: String?
        let collapsedNotes: String?
        let fullNotes: String?
        let notesTruncated: Bool?
        let sizeText: String?
        let actions: [String]?
        let hint: String?
        let percent: Int?
        let meta: String?
        let statusLine: String?
    }

    struct StageCase: Decodable {
        let name: String
        let phase: Phase
        let release: Release?
        let canSelfInstall: Bool?
        let expected: Expected
        let navBadge: Bool
        let checkEnabled: Bool
    }

    struct InstallFailureCase: Decodable {
        let kind: String
        let statusLine: String
    }

    let timeZone: String
    let now: String
    let localVersion: String
    let release: Release
    let rows: Rows
    let currentVersion: [CurrentVersionCase]
    let lastCheck: [LastCheckCase]
    let stages: [StageCase]
    let installFailures: [InstallFailureCase]
}

enum SoftwareUpdateParityTests {
    static func sharedCopyFixture(repoRoot: URL) throws -> Int {
        let url = repoRoot.appendingPathComponent("tests/fixtures/update-copy-parity/cases.json")
        let fixture = try JSONDecoder().decode(CopyFixture.self, from: Data(contentsOf: url))
        guard let timeZone = TimeZone(identifier: fixture.timeZone) else {
            throw UpdateHarnessFailure.expectation("fixture 时区无效: \(fixture.timeZone)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = try date(fixture.now)
        let local = SemanticVersion(fixture.localVersion)
        var checked = 0

        // 行文案
        let rows = fixture.rows
        try expectEqual(UpdateCopy.caption, rows.caption, "分组标题")
        try expectEqual(UpdateCopy.autoCheckTitle, rows.autoCheckTitle, "自动检查标题")
        try expectEqual(UpdateCopy.autoCheckSubtitle, rows.autoCheckSubtitle, "自动检查副标题")
        try expectEqual(UpdateCopy.currentVersionTitle, rows.currentVersionTitle, "当前版本标题")
        try expectEqual(UpdateCopy.checkTitle, rows.checkTitle, "检查更新标题")
        try expectEqual(UpdateCopy.checkButton, rows.checkButton, "检查更新按钮")
        try expectEqual(UpdateCopy.navigationBadge, rows.navigationBadge, "导航角标提示")
        checked += 7

        for item in fixture.currentVersion {
            let resolved = UpdatePresentation.currentVersion(item.localVersion.flatMap(SemanticVersion.init))
            try expectEqual(resolved, item.expectedValue, "\(item.name) 版本值")
            checked += 1
        }

        for item in fixture.lastCheck {
            let at = try item.at.map(date)
            try expectEqual(
                UpdatePresentation.lastCheckSubtitle(at, now: now, calendar: calendar),
                item.expected,
                "\(item.name) 上次检查"
            )
            checked += 1
        }

        try expect(fixture.stages.count >= 18, "状态区用例应覆盖 8 态及各分支")
        for item in fixture.stages {
            let source = item.release ?? fixture.release
            guard let version = SemanticVersion(source.version) else {
                throw UpdateHarnessFailure.expectation("\(item.name): release 版本无效")
            }
            let release = UpdateRelease(
                version: version,
                notes: source.notes,
                downloadURL: URL(string: "https://github.com/4everSivan/Bruce/releases/download/\(version.tag)/Bruce.zip")!,
                sha256: String(repeating: "a", count: 64),
                sizeBytes: source.sizeBytes
            )
            let phase = try phase(item.phase, release: release)
            let content = UpdatePresentation.stage(
                for: phase,
                localVersion: local,
                canSelfInstall: item.canSelfInstall ?? true,
                now: now,
                calendar: calendar
            )
            try verify(content, matches: item.expected, phase: phase, name: item.name)
            try expectEqual(phase.showsNavigationBadge, item.navBadge, "\(item.name) 导航角标")
            try expectEqual(phase.allowsManualCheck, item.checkEnabled, "\(item.name) 检查按钮可用")
            checked += 1
        }

        for item in fixture.installFailures {
            try expectEqual(installFailure(item.kind)?.statusLine, item.statusLine, "\(item.kind) 状态行")
            checked += 1
        }
        try expectEqual(
            fixture.installFailures.count,
            9,
            "安装失败用例应覆盖 UpdateInstallFailure 全部分支"
        )
        return checked
    }

    private static func verify(
        _ content: UpdateStageContent,
        matches expected: CopyFixture.Expected,
        phase: UpdatePhase,
        name: String
    ) throws {
        let titles: ([UpdateStageAction]) -> [String] = { $0.map(\.title) }
        switch (content, expected.kind) {
        case (.hidden, "hidden"):
            return
        case (.spinner(let text), "spinner"), (.confirmation(let text), "confirmation"):
            try expectEqual(text, expected.text, "\(name) 文案")
        case (.banner(let banner), "banner"):
            try expectEqual(banner.title, expected.title, "\(name) 横幅标题")
            try expectEqual(banner.fromVersion, expected.fromVersion, "\(name) 旧版本")
            try expectEqual(banner.toVersion, expected.toVersion, "\(name) 新版本")
            try expectEqual(banner.collapsedNotes, expected.collapsedNotes, "\(name) 收起说明")
            try expectEqual(banner.fullNotes, expected.fullNotes, "\(name) 展开说明")
            try expectEqual(banner.notesTruncated, expected.notesTruncated, "\(name) 是否可展开")
            try expectEqual(banner.sizeText, expected.sizeText, "\(name) 包体尺寸")
            try expectEqual(titles(banner.actions), expected.actions, "\(name) 动作")
            try expectEqual(banner.hint, expected.hint, "\(name) 引导文案")
        case (.download(let fraction, let meta, let actions), "download"):
            try expectEqual(Int((fraction * 100).rounded(.down)), expected.percent, "\(name) 百分比")
            try expectEqual(meta, expected.meta, "\(name) 进度文案")
            try expectEqual(titles(actions), expected.actions, "\(name) 动作")
        case (.ready(let text, let actions), "ready"), (.skipped(let text, let actions), "skipped"):
            try expectEqual(text, expected.text, "\(name) 文案")
            try expectEqual(titles(actions), expected.actions, "\(name) 动作")
        case (.failure(let title, let detail, let actions), "failure"):
            try expectEqual(title, expected.title, "\(name) 标题")
            try expectEqual(detail, expected.detail, "\(name) 说明")
            try expectEqual(titles(actions), expected.actions, "\(name) 动作")
            guard case .failed(let failure) = phase else {
                throw UpdateHarnessFailure.expectation("\(name): failure 内容必须来自 failed 态")
            }
            try expectEqual(failure.statusLine, expected.statusLine, "\(name) 状态行")
        default:
            throw UpdateHarnessFailure.expectation("\(name): 状态区类型应为 \(expected.kind), 实得 \(content)")
        }
    }

    private static func phase(_ raw: CopyFixture.Phase, release: UpdateRelease) throws -> UpdatePhase {
        switch raw.kind {
        case "idle": return .idle
        case "checking": return .checking
        case "latest": return .latest(checkedAt: try date(raw.checkedAt ?? ""))
        case "available": return .available(release)
        case "downloading":
            return .downloading(release, UpdateDownloadProgress(
                receivedBytes: raw.receivedBytes ?? 0,
                totalBytes: raw.totalBytes
            ))
        case "ready": return .ready(release)
        case "skipped": return .skipped(release)
        case "relaunching": return .relaunching(release)
        case "failed":
            switch raw.failure {
            case "timedOut": return .failed(.timedOut)
            case "offline": return .failed(.offline)
            case "httpStatus": return .failed(.httpStatus(raw.httpStatus ?? 0))
            case "invalidManifest": return .failed(.invalidManifest)
            default: break
            }
        default: break
        }
        throw UpdateHarnessFailure.expectation("未知 phase: \(raw.kind) \(raw.failure ?? "")")
    }

    private static func installFailure(_ kind: String) -> UpdateInstallFailure? {
        switch kind {
        case "downloadFailed": return .downloadFailed
        case "checksumMismatch": return .checksumMismatch
        case "extractFailed": return .extractFailed
        case "bundleMismatch": return .bundleMismatch
        case "versionMismatch": return .versionMismatch
        case "versionNotNewer": return .versionNotNewer
        case "replaceFailedRolledBack": return .replaceFailed(rolledBack: true)
        case "replaceFailedNotRolledBack": return .replaceFailed(rolledBack: false)
        case "relaunchFailed": return .relaunchFailed
        default: return nil
        }
    }

    private static func date(_ raw: String) throws -> Date {
        guard let value = ISO8601DateFormatter().date(from: raw) else {
            throw UpdateHarnessFailure.expectation("fixture 时间无效: \(raw)")
        }
        return value
    }
}
