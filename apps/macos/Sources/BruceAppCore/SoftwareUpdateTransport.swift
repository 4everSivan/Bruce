import Foundation

// MARK: - 自动检查调度 (07-软件更新 §4.2 R5)

/// 启动 30 秒后首查, 此后距上次尝试满 24 小时再查; 以墙钟比较, 睡眠唤醒后补查而非顺延.
package enum UpdateCheckSchedule {
    package static let launchDelay: TimeInterval = 30
    package static let interval: TimeInterval = 24 * 60 * 60
    /// 调度循环的最长休眠片段: 睡眠期间单调时钟停走, 分段醒来按墙钟重算.
    package static let pollSlice: TimeInterval = 15 * 60

    /// 下一次自动检查时刻; `lastAttemptAt` 为本次运行内最近一次检查尝试 (成功或失败).
    package static func nextCheck(launchedAt: Date, lastAttemptAt: Date?) -> Date {
        guard let lastAttemptAt else {
            return launchedAt.addingTimeInterval(launchDelay)
        }
        return lastAttemptAt.addingTimeInterval(interval)
    }
}

// MARK: - 偏好持久化

/// 自动检查开关 (默认开启)、上次成功检查时间与跳过版本 (07 §4.2 R4 / R5), 即时写回 UserDefaults.
@MainActor
package final class UpdatePreferences {
    private let defaults: UserDefaults
    private static let autoCheckKey = "softwareUpdate.autoCheckEnabled"
    private static let lastCheckKey = "softwareUpdate.lastCheckAt"
    private static let skippedVersionKey = "softwareUpdate.skippedVersion"

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package var autoCheckEnabled: Bool {
        get { defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoCheckKey) }
    }

    package var lastCheckAt: Date? {
        get {
            (defaults.object(forKey: Self.lastCheckKey) as? Double)
                .map(Date.init(timeIntervalSince1970:))
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Self.lastCheckKey)
            } else {
                defaults.removeObject(forKey: Self.lastCheckKey)
            }
        }
    }

    package var skippedVersion: SemanticVersion? {
        get { defaults.string(forKey: Self.skippedVersionKey).flatMap(SemanticVersion.init) }
        set {
            if let newValue {
                defaults.set(newValue.description, forKey: Self.skippedVersionKey)
            } else {
                defaults.removeObject(forKey: Self.skippedVersionKey)
            }
        }
    }
}

// MARK: - 网络边界

/// 更新链路的网络边界; 测试以 fixture 实现替换, 不访问任何真实端点.
package protocol UpdateTransport: Sendable {
    /// 拉取清单原文; 失败按 `UpdateCheckFailure` 分类抛出.
    func fetchManifest(from url: URL) async throws -> Data
    /// HEAD 取包体尺寸, 失败返回 nil (尺寸只影响展示).
    func contentLength(of url: URL) async -> Int64?
    /// 下载到 `destination` (已存在则覆盖); 进度回调可在任意线程触发, 支持任务取消.
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (UpdateDownloadProgress) -> Void
    ) async throws
}

/// URLSession 实现: ephemeral 会话, 不读写缓存与 Cookie; 清单请求超时 10 秒.
package struct URLSessionUpdateTransport: UpdateTransport {
    package static let manifestTimeout: TimeInterval = 10
    /// 下载为空闲超时 (两次收到数据的最长间隔), 总时长另设上限.
    package static let downloadIdleTimeout: TimeInterval = 30
    package static let downloadResourceTimeout: TimeInterval = 15 * 60

    package init() {}

    package func fetchManifest(from url: URL) async throws -> Data {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: Self.manifestTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: Self.configuration(timeout: Self.manifestTimeout))
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.classify(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateCheckFailure.httpStatus(http.statusCode)
        }
        return data
    }

    package func contentLength(of url: URL) async -> Int64? {
        var request = URLRequest(url: url, timeoutInterval: Self.manifestTimeout)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: Self.configuration(timeout: Self.manifestTimeout))
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.expectedContentLength > 0 else {
            return nil
        }
        return http.expectedContentLength
    }

    package func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (UpdateDownloadProgress) -> Void
    ) async throws {
        let configuration = Self.configuration(timeout: Self.downloadIdleTimeout)
        configuration.timeoutIntervalForResource = Self.downloadResourceTimeout
        let delegate = UpdateDownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return configuration
    }

    package static func classify(_ error: Error) -> UpdateCheckFailure {
        guard let urlError = error as? URLError else { return .offline }
        switch urlError.code {
        case .timedOut:
            return .timedOut
        default:
            return .offline
        }
    }
}

/// 下载委托: 进度透传, 完成时在回调内同步移动临时文件 (系统随后即删除), 一次性恢复 continuation.
private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (UpdateDownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    init(destination: URL, progress: @escaping @Sendable (UpdateDownloadProgress) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(UpdateDownloadProgress(
            receivedBytes: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        ))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateInstallFailure.downloadFailed))
            return
        }
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(UpdateInstallFailure.downloadFailed))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            // 成功路径已在 didFinishDownloadingTo 收口; 这里兜底未触发该回调的情况.
            finish(.failure(UpdateInstallFailure.downloadFailed))
            return
        }
        if (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(UpdateInstallFailure.downloadFailed))
        }
    }

    /// 只认第一次结果; 后续回调 (如成功后的 didComplete) 被忽略.
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
