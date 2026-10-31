import Combine
import Foundation
import BruceOnboardingCore

// MARK: - 模型价格表同步调度 (09-模型价格表远端同步 §4.2 R5)

package enum PricingCatalogSyncSchedule {
    package static let launchDelay: TimeInterval = 30
    package static let interval: TimeInterval = 24 * 60 * 60
    package static let pollSlice: TimeInterval = 15 * 60

    package static func nextSync(launchedAt: Date, lastAttemptAt: Date?) -> Date {
        guard let lastAttemptAt else {
            return launchedAt.addingTimeInterval(launchDelay)
        }
        return lastAttemptAt.addingTimeInterval(interval)
    }
}

// MARK: - 偏好持久化

@MainActor
package final class PricingCatalogPreferences {
    private let defaults: UserDefaults
    private static let autoSyncKey = "pricingCatalog.autoSyncEnabled"
    private static let lastSyncKey = "pricingCatalog.lastSyncAt"

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    package var autoSyncEnabled: Bool {
        get { defaults.object(forKey: Self.autoSyncKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoSyncKey) }
    }

    package var lastSyncAt: Date? {
        get {
            (defaults.object(forKey: Self.lastSyncKey) as? Double)
                .map(Date.init(timeIntervalSince1970:))
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Self.lastSyncKey)
            } else {
                defaults.removeObject(forKey: Self.lastSyncKey)
            }
        }
    }
}

// MARK: - 网络拉取边界 (R3 规范)

package protocol PricingCatalogTransport: Sendable {
    func fetchCatalog(from url: URL) async throws -> Data
}

package final class URLSessionPricingCatalogTransport: PricingCatalogTransport {
    package static let defaultRemoteURL = URL(
        string: "https://raw.githubusercontent.com/4everSivan/Bruce/main/config/pricing-catalog.json"
    )!
    package static let maxCatalogBytes = 512 * 1024 // 512 KB
    package static let requestTimeout: TimeInterval = 10

    private let session: URLSession

    package init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.requestTimeout
            config.timeoutIntervalForResource = Self.requestTimeout
            self.session = URLSession(configuration: config)
        }
    }

    package func fetchCatalog(from url: URL) async throws -> Data {
        guard url.scheme == "https" else {
            throw PricingSyncFailureReason.invalidCatalog
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw PricingSyncFailureReason.timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed:
                throw PricingSyncFailureReason.offline
            default:
                throw PricingSyncFailureReason.offline
            }
        } catch {
            throw PricingSyncFailureReason.offline
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PricingSyncFailureReason.httpError(statusCode: http.statusCode)
        }

        guard data.count <= Self.maxCatalogBytes else {
            throw PricingSyncFailureReason.invalidCatalog
        }

        return data
    }
}

extension PricingSyncFailureReason: Error {}

// MARK: - 价格表远端同步服务

@MainActor
package final class PricingCatalogSyncService: ObservableObject {
    @Published package private(set) var stage: PricingSyncStage = .idle
    @Published package private(set) var autoSyncEnabled: Bool
    @Published package private(set) var lastSyncAt: Date?
    @Published package private(set) var currentSource: PricingCatalogSource
    @Published package private(set) var currentUpdatedAt: String
    @Published package private(set) var currentModelCount: Int

    package var onCatalogUpdated: (@MainActor () -> Void)?

    private let preferences: PricingCatalogPreferences
    private let transport: any PricingCatalogTransport
    private let remoteURL: URL
    private let fileURL: URL
    private let store: AtomicJSONStore
    private let now: () -> Date
    private weak var model: AppModel?

    private var launchedAt: Date?
    private var lastAttemptAt: Date?
    private var syncTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var postedStatusLine: String?

    package init(
        remoteURL: URL = URLSessionPricingCatalogTransport.defaultRemoteURL,
        fileURL: URL = BuiltinModelPricingCatalog.defaultSyncedFileURL(),
        preferences: PricingCatalogPreferences = PricingCatalogPreferences(),
        transport: any PricingCatalogTransport = URLSessionPricingCatalogTransport(),
        store: AtomicJSONStore = AtomicJSONStore(),
        model: AppModel? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.remoteURL = remoteURL
        self.fileURL = fileURL
        self.preferences = preferences
        self.transport = transport
        self.store = store
        self.model = model
        self.now = now

        autoSyncEnabled = preferences.autoSyncEnabled
        lastSyncAt = preferences.lastSyncAt
        currentSource = BuiltinModelPricingCatalog.currentSource
        currentUpdatedAt = BuiltinModelPricingCatalog.currentUpdatedAt
        currentModelCount = BuiltinModelPricingCatalog.currentModelCount
    }

    // MARK: - 调度生命周期

    package func start() {
        guard launchedAt == nil else { return }
        launchedAt = now()
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.secondsUntilNextAutoSync()
                if wait > 0 {
                    let slice = min(wait, PricingCatalogSyncSchedule.pollSlice)
                    try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                    continue
                }
                await self.autoSyncTick()
            }
        }
    }

    package func stop() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    private func secondsUntilNextAutoSync() -> TimeInterval {
        guard let launchedAt else { return PricingCatalogSyncSchedule.pollSlice }
        return PricingCatalogSyncSchedule.nextSync(
            launchedAt: launchedAt,
            lastAttemptAt: lastAttemptAt
        ).timeIntervalSince(now())
    }

    /// 自动静默同步: 失败不打扰用户 (不报错、不写状态行、不改 stage).
    package func autoSyncTick() async {
        guard let launchedAt else { return }
        let current = now()
        guard current >= PricingCatalogSyncSchedule.nextSync(
            launchedAt: launchedAt,
            lastAttemptAt: lastAttemptAt
        ) else { return }

        guard autoSyncEnabled else {
            lastAttemptAt = current
            return
        }

        if stage == .syncing {
            lastAttemptAt = current
            return
        }

        lastAttemptAt = current
        await runSync(manual: false)
    }

    package func setAutoSyncEnabled(_ enabled: Bool) {
        autoSyncEnabled = enabled
        preferences.autoSyncEnabled = enabled
    }

    // MARK: - 手动同步与恢复

    package func syncNow() {
        guard stage != .syncing else { return }
        clearStatusLine()
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.runSync(manual: true)
        }
    }

    package func restoreBuiltin() {
        guard stage != .syncing else { return }
        clearStatusLine()
        BuiltinModelPricingCatalog.resetToBuiltin(fileURL: fileURL)
        refreshCatalogState()
        stage = .restored(
            updatedAt: currentUpdatedAt,
            modelCount: currentModelCount
        )
        onCatalogUpdated?()
    }

    // MARK: - 执行同步核心流程

    private func runSync(manual: Bool) async {
        if manual {
            stage = .syncing
        }

        do {
            let data = try await transport.fetchCatalog(from: remoteURL)
            let parsed = try BuiltinModelPricingCatalog.validateAndParse(data: data, source: .synced)

            // Anti-Rollback 门禁: 远端版本不得低于内置基线
            if BuiltinModelPricingCatalog.compareUpdatedAt(
                parsed.updatedAt,
                BuiltinModelPricingCatalog.builtinUpdatedAt
            ) == .orderedAscending {
                throw PricingSyncFailureReason.staleVersion
            }

            // 比对是否与当前生效目录一致
            let isIdentical: Bool
            if parsed.updatedAt == currentUpdatedAt && parsed.models.count == currentModelCount {
                let currentMap = Dictionary(
                    uniqueKeysWithValues: BuiltinModelPricingCatalog.allModels.map { ($0.modelName.lowercased(), $0) }
                )
                var matches = true
                for m in parsed.models {
                    guard let existing = currentMap[m.modelName.lowercased()],
                          existing.inputPricePerMillion == m.inputPricePerMillion,
                          existing.outputPricePerMillion == m.outputPricePerMillion,
                          existing.cacheReadPricePerMillion == m.cacheReadPricePerMillion
                    else {
                        matches = false
                        break
                    }
                }
                isIdentical = matches
            } else {
                isIdentical = false
            }

            let syncDate = now()
            lastSyncAt = syncDate
            preferences.lastSyncAt = syncDate

            if isIdentical {
                stage = .upToDate(
                    updatedAt: parsed.updatedAt,
                    modelCount: parsed.models.count
                )
            } else {
                // 计算新增与调价差异
                let prevModels = BuiltinModelPricingCatalog.allModels
                let prevMap = Dictionary(
                    uniqueKeysWithValues: prevModels.map { ($0.modelName.lowercased(), $0) }
                )
                var added = 0
                var adjusted = 0
                for m in parsed.models {
                    if let prev = prevMap[m.modelName.lowercased()] {
                        if prev.inputPricePerMillion != m.inputPricePerMillion
                            || prev.outputPricePerMillion != m.outputPricePerMillion
                            || prev.cacheReadPricePerMillion != m.cacheReadPricePerMillion {
                            adjusted += 1
                        }
                    } else {
                        added += 1
                    }
                }

                // POSIX 0600 原子写盘与热加载
                try store.prepareDirectory(at: fileURL.deletingLastPathComponent())
                try store.write(data, to: fileURL)
                BuiltinModelPricingCatalog.setActiveCatalog(parsed)
                refreshCatalogState()

                stage = .updated(
                    updatedAt: parsed.updatedAt,
                    modelCount: parsed.models.count,
                    addedCount: added,
                    adjustedCount: adjusted
                )
                onCatalogUpdated?()
            }
            clearStatusLine()
        } catch {
            let reason: PricingSyncFailureReason
            if let failure = error as? PricingSyncFailureReason {
                reason = failure
            } else if error is PricingCatalogError {
                reason = .invalidCatalog
            } else {
                reason = .offline
            }

            if manual {
                stage = .failed(reason: reason)
                postStatusLine(reason.statusLine)
            }
        }
    }

    private func refreshCatalogState() {
        currentSource = BuiltinModelPricingCatalog.currentSource
        currentUpdatedAt = BuiltinModelPricingCatalog.currentUpdatedAt
        currentModelCount = BuiltinModelPricingCatalog.currentModelCount
    }

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
