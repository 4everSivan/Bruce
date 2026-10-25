import Foundation
@testable import BruceAppCore

// MARK: - 断言

enum UpdateHarnessFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw UpdateHarnessFailure.expectation(message)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw UpdateHarnessFailure.expectation("\(message): 期望 \(expected), 实得 \(actual)")
    }
}

func expectThrows<E: Error & Equatable>(
    _ expected: E,
    _ message: String,
    _ body: () async throws -> Void
) async throws {
    do {
        try await body()
    } catch let error as E {
        try expectEqual(error, expected, message)
        return
    } catch {
        throw UpdateHarnessFailure.expectation("\(message): 期望 \(expected), 实得 \(error)")
    }
    throw UpdateHarnessFailure.expectation("\(message): 期望抛出 \(expected), 实际未抛出")
}

/// 轮询等待异步状态收敛 (下载任务在独立 Task 中推进).
@MainActor
func waitUntil(
    _ message: String,
    timeout: TimeInterval = 10,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            throw UpdateHarnessFailure.expectation("等待超时: \(message)")
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

// MARK: - 临时目录

/// 临时目录: 原子计数器 + UUID 命名 (pid+纳秒在 macOS 微秒级时钟下会撞名).
enum TemporaryDirectories {
    nonisolated(unsafe) private static var counter = 0
    private static let lock = NSLock()

    static func make(_ label: String) throws -> URL {
        lock.lock()
        counter += 1
        let index = counter
        lock.unlock()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bruce-update-harness-\(index)-\(UUID().uuidString)-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        // 只读夹具需先恢复写权限才能删除.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 夹具 bundle

enum FixtureBundle {
    static let bundleIdentifier = "io.bruce.dashboard"

    /// 在 `directory` 下生成最小 Bruce.app: Info.plist + 可执行文件.
    @discardableResult
    static func makeApp(
        in directory: URL,
        version: String,
        bundleIdentifier: String = FixtureBundle.bundleIdentifier,
        includeExecutable: Bool = true
    ) throws -> URL {
        let app = directory.appendingPathComponent("Bruce.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "BruceApp",
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        if includeExecutable {
            let executable = macOS.appendingPathComponent("BruceApp")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return app
    }

    /// 与 build-test-app.sh 同口径打包: zip 根目录即 Bruce.app.
    static func zip(app: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", app.path, archive.path]
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "ditto 打包夹具失败")
    }

    static func version(of app: URL) -> String? {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }
}

func manifestData(
    version: String,
    sha256: String = String(repeating: "a", count: 64),
    url: String? = nil,
    notes: String = "应用内软件更新; 修复托盘图标"
) -> Data {
    let assetURL = url ?? "https://github.com/4everSivan/Bruce/releases/download/v\(version)/Bruce.zip"
    let json: [String: Any] = [
        "version": version,
        "pub_date": "2026-10-30T00:00:00Z",
        "notes": notes,
        "platforms": [
            "darwin-universal": ["url": assetURL, "sha256": sha256, "signature": "c2ln"],
            "windows-x86_64": ["url": "https://github.com/4everSivan/Bruce/releases/download/v\(version)/setup.exe", "signature": "c2ln"],
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

// MARK: - 网络假实现

/// 可编排的更新网络边界: 不访问任何真实端点.
final class FakeUpdateTransport: UpdateTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _manifest: Result<Data, UpdateCheckFailure> = .failure(.offline)
    private var _contentLength: Int64?
    private var _downloadSource: URL?
    private var _downloadError: UpdateInstallFailure?
    private var _holdFetch = false
    private var _holdDownload = false
    private var _fetchCount = 0
    private var _headCount = 0
    private var _downloadCount = 0
    private var _progressEvents = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var manifest: Result<Data, UpdateCheckFailure> {
        get { locked { _manifest } }
        set { locked { _manifest = newValue } }
    }
    var contentLength: Int64? {
        get { locked { _contentLength } }
        set { locked { _contentLength = newValue } }
    }
    var downloadSource: URL? {
        get { locked { _downloadSource } }
        set { locked { _downloadSource = newValue } }
    }
    var downloadError: UpdateInstallFailure? {
        get { locked { _downloadError } }
        set { locked { _downloadError = newValue } }
    }
    var holdFetch: Bool {
        get { locked { _holdFetch } }
        set { locked { _holdFetch = newValue } }
    }
    var holdDownload: Bool {
        get { locked { _holdDownload } }
        set { locked { _holdDownload = newValue } }
    }
    var fetchCount: Int { locked { _fetchCount } }
    var headCount: Int { locked { _headCount } }
    var downloadCount: Int { locked { _downloadCount } }
    var progressEvents: Int { locked { _progressEvents } }

    func fetchManifest(from url: URL) async throws -> Data {
        locked { _fetchCount += 1 }
        while holdFetch {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return try manifest.get()
    }

    func contentLength(of url: URL) async -> Int64? {
        locked { _headCount += 1 }
        return contentLength
    }

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (UpdateDownloadProgress) -> Void
    ) async throws {
        locked { _downloadCount += 1 }
        while holdDownload {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try Task.checkCancellation()
        if let downloadError {
            throw downloadError
        }
        guard let source = downloadSource else {
            throw UpdateInstallFailure.downloadFailed
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
        progress(UpdateDownloadProgress(receivedBytes: size / 2, totalBytes: size))
        progress(UpdateDownloadProgress(receivedBytes: size, totalBytes: size))
        locked { _progressEvents += 2 }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

/// 解压/剥离属性走真实 /usr/bin (本地工具, 无网络); 重启等待器只记录不执行.
final class RecordingCommandRunner: UpdateCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let system = SystemUpdateCommandRunner()
    private var _detached: [(String, [String])] = []
    private var _failingExecutables: Set<String> = []
    private var _detachedFails = false

    var detached: [(String, [String])] {
        lock.lock()
        defer { lock.unlock() }
        return _detached
    }

    var failingExecutables: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _failingExecutables }
        set { lock.lock(); _failingExecutables = newValue; lock.unlock() }
    }

    var detachedFails: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _detachedFails }
        set { lock.lock(); _detachedFails = newValue; lock.unlock() }
    }

    func run(_ executablePath: String, _ arguments: [String]) async -> Bool {
        if failingExecutables.contains(executablePath) {
            return false
        }
        return await system.run(executablePath, arguments)
    }

    func launchDetached(_ executablePath: String, _ arguments: [String]) throws {
        if detachedFails {
            throw UpdateHarnessFailure.expectation("detached launch disabled")
        }
        lock.lock()
        _detached.append((executablePath, arguments))
        lock.unlock()
    }
}

/// 可拨动的测试时钟 (服务只在 MainActor 上读取).
@MainActor
final class TestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
