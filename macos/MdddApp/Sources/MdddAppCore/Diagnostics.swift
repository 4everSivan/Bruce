import Combine
import Foundation
import MdddOnboardingCore

package enum DiagnosticSnapshotValidation: String, Codable, Sendable {
    case missing
    case valid
    case invalid
    case unsupportedSchema
}

package struct DiagnosticSnapshotSummary: Codable, Sendable {
    let module: String
    let current: DiagnosticSnapshotValidation
    let previous: DiagnosticSnapshotValidation
    let lastSuccessAt: String?
    let lastAttemptAt: String?
    let isStale: Bool
    let errorCategory: String?
}

private struct DiagnosticApplication: Codable {
    let version: String
    let operatingSystem: String
    let architecture: String
}

private struct DiagnosticDependency: Codable {
    let kind: String
    let status: String
}

private struct DiagnosticIssue: Codable {
    let code: String
    let stage: String
    let category: String
    let retryable: Bool
    let suggestedAction: String?
}

private struct DiagnosticModule: Codable {
    let module: String
    let displayState: String
    let readiness: String?
    let connection: String?
    let schedulePhase: String
    let autoRefreshEnabled: Bool
    let lastSuccessAt: String?
    let lastAttemptAt: String?
    let lastErrorCategory: String?
    let dependencies: [DiagnosticDependency]
    let issues: [DiagnosticIssue]
}

private struct DiagnosticReport: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let application: DiagnosticApplication
    let modules: [DiagnosticModule]
    let snapshots: [DiagnosticSnapshotSummary]
}

package enum DiagnosticExportError: Error, Equatable {
    case sensitiveContent
    case archiveFailed
    case invalidDestination
    case storageFailure
}

protocol DiagnosticArchiving {
    func archive(directory: URL, to destination: URL) throws
    func expand(archive: URL, to destination: URL) throws
}

struct SystemDiagnosticArchiver: DiagnosticArchiving {
    func archive(directory: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--keepParent",
            directory.path,
            destination.path,
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw DiagnosticExportError.archiveFailed
        }
        guard process.terminationStatus == 0 else {
            throw DiagnosticExportError.archiveFailed
        }
    }

    func expand(archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-x",
            "-k",
            archive.path,
            destination.path,
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw DiagnosticExportError.archiveFailed
        }
        guard process.terminationStatus == 0 else {
            throw DiagnosticExportError.archiveFailed
        }
    }
}

enum DiagnosticContentPolicy {
    private static let patterns = [
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
        #"(?i)"(?:access[_-]?token|refresh[_-]?token|id[_-]?token|token|secret|password|authorization|cookie|api[_-]?key|private[_-]?key)"\s*:"#,
        #"(?i)[?&](?:access[_-]?token|token|code|key|secret|password)=[^&\s"]+"#,
        #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        #"/Users/[^/\s"]+"#,
    ]

    static func containsSensitiveContent(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            return true
        }
        return patterns.contains { pattern in
            text.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }
}

@MainActor
package final class DiagnosticService: ObservableObject {
    private let model: AppModel
    private let scheduler: RefreshScheduler
    private let store: ArtifactStore
    private let fileManager: FileManager
    private let archiver: DiagnosticArchiving
    private let now: () -> Date
    private let applicationVersion: () -> String
    private let operatingSystem: () -> String
    private let architecture: () -> String
    /// 最近一次已发布 Bridge/merger 诊断的脱敏来源. 生产默认读取 Scheduler;
    /// 测试可注入固定值, 不需要开放 Scheduler 状态写入口.
    private let publishedDiagnostics: (CollectorModule) -> [BridgeDiagnostic]

    package convenience init(
        model: AppModel,
        scheduler: RefreshScheduler,
        store: ArtifactStore
    ) {
        self.init(
            model: model,
            scheduler: scheduler,
            store: store,
            fileManager: .default,
            archiver: SystemDiagnosticArchiver(),
            now: Date.init,
            applicationVersion: {
                Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "development"
            },
            operatingSystem: {
                ProcessInfo.processInfo.operatingSystemVersionString
            },
            architecture: {
                #if arch(arm64)
                return "arm64"
                #elseif arch(x86_64)
                return "x86_64"
                #else
                return "unknown"
                #endif
            }
        )
    }

    init(
        model: AppModel,
        scheduler: RefreshScheduler,
        store: ArtifactStore,
        fileManager: FileManager,
        archiver: DiagnosticArchiving,
        now: @escaping () -> Date,
        applicationVersion: @escaping () -> String,
        operatingSystem: @escaping () -> String,
        architecture: @escaping () -> String,
        publishedDiagnostics: ((CollectorModule) -> [BridgeDiagnostic])? = nil
    ) {
        self.model = model
        self.scheduler = scheduler
        self.store = store
        self.fileManager = fileManager
        self.archiver = archiver
        self.now = now
        self.applicationVersion = applicationVersion
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.publishedDiagnostics = publishedDiagnostics ?? { [weak scheduler] module in
            guard module == .agentUsage else { return [] }
            return scheduler?.lastPublishedDiagnostics ?? []
        }
    }

    package func preview() throws -> String {
        let data = try reportData()
        guard let text = String(data: data, encoding: .utf8) else {
            throw DiagnosticExportError.storageFailure
        }
        return text
    }

    package func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "mddd-diagnostics-\(formatter.string(from: now())).zip"
    }

    package func export(to destination: URL) throws {
        guard destination.isFileURL,
              destination.pathExtension.lowercased() == "zip" else {
            throw DiagnosticExportError.invalidDestination
        }

        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "mddd-diagnostics-\(UUID().uuidString)",
            isDirectory: true
        )
        let packageURL = temporaryRoot.appendingPathComponent(
            "mddd-diagnostics",
            isDirectory: true
        )
        let temporaryArchive = temporaryRoot.appendingPathComponent(
            "mddd-diagnostics.zip"
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        do {
            try fileManager.createDirectory(
                at: packageURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let report = try reportData()
            let readme = Data(
                """
                mddd 诊断包

                仅包含应用版本、系统版本、模块状态、依赖状态和快照校验结果。
                不包含凭证、账号邮箱、完整本机路径、Artifact 或业务活动数据。
                """.utf8
            )
            guard !DiagnosticContentPolicy.containsSensitiveContent(readme) else {
                throw DiagnosticExportError.sensitiveContent
            }
            try writePrivate(report, to: packageURL.appendingPathComponent(
                "report.json"
            ))
            try writePrivate(readme, to: packageURL.appendingPathComponent(
                "README.txt"
            ))
            try archiver.archive(
                directory: packageURL,
                to: temporaryArchive
            )
            guard fileManager.fileExists(atPath: temporaryArchive.path) else {
                throw DiagnosticExportError.archiveFailed
            }
            let verificationURL = temporaryRoot.appendingPathComponent(
                "verification",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: verificationURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try archiver.expand(
                archive: temporaryArchive,
                to: verificationURL
            )
            try validateExpandedArchive(at: verificationURL)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporaryArchive
                )
            } else {
                try fileManager.moveItem(
                    at: temporaryArchive,
                    to: destination
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch let error as DiagnosticExportError {
            throw error
        } catch {
            throw DiagnosticExportError.storageFailure
        }
    }

    private func reportData() throws -> Data {
        let date = now()
        let modules = CollectorModule.allCases.map { module in
            let result = model.moduleResults[module]
            let state = scheduler.moduleState(for: module)
            var issues: [DiagnosticIssue] = (result?.issues ?? []).map {
                DiagnosticIssue(
                    code: $0.code,
                    stage: $0.stage,
                    category: $0.category.rawValue,
                    retryable: $0.retryable,
                    suggestedAction: $0.suggestedAction?.rawValue
                )
            }
            var seenIssueKeys = Set(
                issues.map { "\($0.code)|\($0.stage)|\($0.category)" }
            )
            for diagnostic in publishedDiagnostics(module) {
                let key = "\(diagnostic.code)|\(diagnostic.stage)|\(diagnostic.category)"
                guard seenIssueKeys.insert(key).inserted else { continue }
                issues.append(DiagnosticIssue(
                    code: diagnostic.code,
                    stage: diagnostic.stage,
                    category: diagnostic.category,
                    retryable: diagnostic.retryable,
                    suggestedAction: nil
                ))
            }
            return DiagnosticModule(
                module: module.rawValue,
                displayState: model.status(
                    for: DashboardModule(module)
                ).state.rawValue,
                readiness: result?.readiness.rawValue,
                connection: result?.connection.rawValue,
                schedulePhase: state?.phase.rawValue ?? "unknown",
                autoRefreshEnabled: state?.autoRefreshEnabled ?? false,
                lastSuccessAt: state?.lastSuccessAt.map(Self.timestamp),
                lastAttemptAt: state?.lastAttemptAt.map(Self.timestamp),
                lastErrorCategory: state?.lastErrorCategory?.rawValue,
                dependencies: (result?.localDependencies ?? []).map {
                    DiagnosticDependency(
                        kind: $0.kind.rawValue,
                        status: $0.status.rawValue
                    )
                },
                issues: issues
            )
        }
        let report = DiagnosticReport(
            schemaVersion: 1,
            generatedAt: Self.timestamp(date),
            application: DiagnosticApplication(
                version: applicationVersion(),
                operatingSystem: operatingSystem(),
                architecture: architecture()
            ),
            modules: modules,
            snapshots: CollectorModule.allCases.map {
                store.diagnosticSnapshotSummary(for: $0)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let data = try encoder.encode(report)
        guard !DiagnosticContentPolicy.containsSensitiveContent(data) else {
            throw DiagnosticExportError.sensitiveContent
        }
        return data
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func validateExpandedArchive(at root: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        ) else {
            throw DiagnosticExportError.archiveFailed
        }
        var regularFiles: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw DiagnosticExportError.archiveFailed
            }
            if values.isRegularFile == true {
                let relativeComponents = url.standardizedFileURL
                    .pathComponents
                    .dropFirst(
                        root.standardizedFileURL.pathComponents.count
                    )
                let relativePath = relativeComponents.joined(separator: "/")
                regularFiles.append(relativePath)
                let data = try Data(contentsOf: url)
                guard !DiagnosticContentPolicy.containsSensitiveContent(data) else {
                    throw DiagnosticExportError.sensitiveContent
                }
            } else if values.isDirectory != true {
                throw DiagnosticExportError.archiveFailed
            }
        }
        guard regularFiles.sorted() == [
            "mddd-diagnostics/README.txt",
            "mddd-diagnostics/report.json",
        ] else {
            throw DiagnosticExportError.archiveFailed
        }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
