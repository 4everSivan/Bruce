import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

private enum DiagnosticsTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

private func diagnosticsExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw DiagnosticsTestFailure.expectation(message)
    }
}

private final class CapturingArchiver: DiagnosticArchiving {
    private(set) var filenames: [String] = []
    private(set) var contents: [String: Data] = [:]

    func archive(directory: URL, to destination: URL) throws {
        filenames = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).sorted()
        for filename in filenames {
            contents[filename] = try Data(contentsOf: directory.appendingPathComponent(
                filename
            ))
        }
        try Data("fixture-zip".utf8).write(to: destination)
    }

    func expand(archive: URL, to destination: URL) throws {
        let package = destination.appendingPathComponent(
            "Bruce-diagnostics",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        for (filename, data) in contents {
            try data.write(to: package.appendingPathComponent(filename))
        }
    }
}

@main
@MainActor
struct DiagnosticsHarness {
    private static let fixedDate = Date(
        timeIntervalSince1970: 1_786_000_000
    )

    static func main() throws {
        try previewContainsOnlyAllowlistedState()
        try exportContainsOnlyMinimalFiles()
        try sensitiveContentPolicyRejectsKnownShapes()
        try filenameIsStableAndNonIdentifying()
        try invalidDestinationIsRejected()
        try migrationDisplayStatusMappings()
        try migrationStatusMessagesAreDesensitized()
        try publishedMergerDiagnosticsEnterReport()
        print("Diagnostics tests passed: 8")
    }

    private static func makeFixture(
        archiver: DiagnosticArchiving = CapturingArchiver(),
        publishedDiagnostics: ((CollectorModule) -> [BridgeDiagnostic])? = nil
    ) throws -> (DiagnosticService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Bruce-diagnostics-harness-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let store = try ArtifactStore(
            rootURL: root.appendingPathComponent("Application Support/Bruce")
        )
        let runner = CollectorRunner(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            bridgeURL: root.appendingPathComponent("run_bridge.py")
        )
        let scheduler = RefreshScheduler(executor: runner, store: store)
        let model = AppModel()
        model.setStatus(
            ModuleStatus(
                state: .stale,
                detail: "Bearer fixture-secret user@example.test /Users/alice"
            ),
            for: .agentUsage
        )
        model.setModuleResult(ModuleReadinessResult(
            module: .agentUsage,
            readiness: .partial,
            localDependencies: [
                DependencyProbe(
                    kind: .python,
                    status: .available,
                    detail: "/Users/alice/bin/python3"
                ),
            ],
            connection: .connected,
            blockingReason: "user@example.test",
            warnings: ["Bearer fixture-secret"]
        ))
        let service = DiagnosticService(
            model: model,
            scheduler: scheduler,
            store: store,
            fileManager: .default,
            archiver: archiver,
            now: { fixedDate },
            applicationVersion: { "1.0.0-test" },
            operatingSystem: { "macOS test" },
            architecture: { "arm64" },
            publishedDiagnostics: publishedDiagnostics
        )
        return (service, root)
    }

    private static func previewContainsOnlyAllowlistedState() throws {
        let (service, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try service.preview()
        try diagnosticsExpect(
            preview.contains("\"module\" : \"agent-usage\""),
            "preview omitted module state"
        )
        try diagnosticsExpect(
            preview.contains("\"readiness\" : \"partial\""),
            "preview omitted readiness"
        )
        for forbidden in [
            "fixture-secret",
            "user@example.test",
            "/Users/alice",
            "\"artifact\"",
            "\"login\"",
        ] {
            try diagnosticsExpect(
                !preview.contains(forbidden),
                "preview leaked \(forbidden)"
            )
        }
    }

    private static func exportContainsOnlyMinimalFiles() throws {
        let archiver = CapturingArchiver()
        let (service, root) = try makeFixture(archiver: archiver)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("diagnostics.zip")
        try service.export(to: destination)
        try diagnosticsExpect(
            archiver.filenames == ["README.txt", "report.json"],
            "diagnostics package contains unexpected files"
        )
        try diagnosticsExpect(
            FileManager.default.fileExists(atPath: destination.path),
            "diagnostics archive was not published"
        )
        let permissions = try FileManager.default.attributesOfItem(
            atPath: destination.path
        )[.posixPermissions] as? NSNumber
        try diagnosticsExpect(
            permissions?.intValue == 0o600,
            "diagnostics archive permissions are not private"
        )
        let report = archiver.contents["report.json"] ?? Data()
        try diagnosticsExpect(
            !DiagnosticContentPolicy.containsSensitiveContent(report),
            "exported report failed the sensitive-content policy"
        )
    }

    private static func sensitiveContentPolicyRejectsKnownShapes() throws {
        let samples = [
            #"{"access_token":"fixture"}"#,
            "Authorization: Bearer fixture-secret",
            "user@example.test",
            "/Users/alice/private.json",
            "https://example.test/callback?code=fixture",
        ]
        for sample in samples {
            try diagnosticsExpect(
                DiagnosticContentPolicy.containsSensitiveContent(
                    Data(sample.utf8)
                ),
                "sensitive sample was accepted: \(sample)"
            )
        }
        try diagnosticsExpect(
            !DiagnosticContentPolicy.containsSensitiveContent(
                Data(#"{"status":"authRequired","module":"agent-usage"}"#.utf8)
            ),
            "safe status was rejected"
        )
    }

    private static func filenameIsStableAndNonIdentifying() throws {
        let (service, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try diagnosticsExpect(
            service.suggestedFilename()
                == "Bruce-diagnostics-20260806-070640.zip",
            "diagnostics filename is unstable or identifying"
        )
    }

    private static func invalidDestinationIsRejected() throws {
        let (service, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try service.export(to: root.appendingPathComponent("report.json"))
            throw DiagnosticsTestFailure.expectation(
                "non-ZIP destination was accepted"
            )
        } catch DiagnosticExportError.invalidDestination {
        }
    }

    /// UI-01/02: 迁移结果映射为脱敏展示状态 (阻断与非阻断语义不同).
    /// UI-03: 迁移读取失败 (failed) 不得呈现为"未发现旧数据".
    private static func migrationDisplayStatusMappings() throws {
        // 原始 CodexMigrationResult -> 展示状态映射 (Bootstrap 消费同一工厂)
        try diagnosticsExpect(
            CodexMigrationDisplayStatus.from(.noLegacyData) == .completed
                && CodexMigrationDisplayStatus.from(.migrated(accountCount: 2)) == .completed,
            "noLegacyData/migrated 应映射为 completed"
        )
        try diagnosticsExpect(
            CodexMigrationDisplayStatus.from(.cleanupPending) == .cleanupPending,
            "cleanupPending 应映射为 cleanupPending"
        )
        for result in [
            CodexMigrationResult.corruptedJSON,
            .incompatibleSchema,
            .failed,
        ] {
            try diagnosticsExpect(
                CodexMigrationDisplayStatus.from(result) == .blocked,
                "\(result) 应映射为 blocked"
            )
        }

        let model = AppModel()
        // 正常: 开放 gate, 无提示
        model.setCodexMigrationStatus(.completed)
        try diagnosticsExpect(
            !model.codexMigrationStatus.isBlocking
                && model.codexMigrationStatus.userMessage == nil,
            "completed 不得是阻断态或带提示"
        )
        // cleanupPending: 非阻断, 有非阻断警告
        model.setCodexMigrationStatus(.cleanupPending)
        try diagnosticsExpect(
            !model.codexMigrationStatus.isBlocking,
            "cleanupPending 必须是非阻断"
        )
        try diagnosticsExpect(
            model.codexMigrationStatus.userMessage != nil,
            "cleanupPending 必须显示非阻断警告"
        )
        // corruptedJSON / incompatibleSchema / failed: 阻断 + 可操作错误
        model.setCodexMigrationStatus(.blocked)
        try diagnosticsExpect(
            model.codexMigrationStatus.isBlocking,
            "blocked 必须是阻断态"
        )
        try diagnosticsExpect(
            model.codexMigrationStatus.userMessage != nil,
            "blocked 必须显示可操作错误"
        )
        // UI-03: 迁移失败绝不能被展示成"未发现旧数据"
        try diagnosticsExpect(
            model.codexMigrationStatus.userMessage?
                .contains("未发现") != true,
            "迁移失败不得呈现为未发现旧数据"
        )
        // notStarted 缺省
        let fresh = AppModel()
        try diagnosticsExpect(
            fresh.codexMigrationStatus == .notStarted,
            "缺省迁移状态应为 notStarted"
        )
    }

    /// UI-06: 迁移提示与 Codex 状态不含 token, 完整邮箱或内部账号 ID.
    private static func migrationStatusMessagesAreDesensitized() throws {
        let messages = [
            CodexMigrationDisplayStatus.completed.userMessage,
            CodexMigrationDisplayStatus.cleanupPending.userMessage,
            CodexMigrationDisplayStatus.blocked.userMessage,
            CodexMigrationDisplayStatus.notStarted.userMessage,
        ].compactMap { $0 }
        for message in messages {
            try diagnosticsExpect(
                !message.contains("@"),
                "迁移提示泄露邮箱: \(message)"
            )
            try diagnosticsExpect(
                !message.lowercased().contains("token"),
                "迁移提示泄露 token 字样: \(message)"
            )
            try diagnosticsExpect(
                !message.contains("acc-")
                    && !message.contains("keychain"),
                "迁移提示泄露内部账号或 Keychain 名称: \(message)"
            )
        }
    }

    /// UI-04/UI-05: merger 产生的脱敏诊断进入 App 诊断报告, 只输出稳定
    /// code/stage/category, 不输出可能包含账号信息的 message.
    private static func publishedMergerDiagnosticsEnterReport() throws {
        let (service, root) = try makeFixture(
            publishedDiagnostics: { module in
                guard module == .agentUsage else { return [] }
                return [
                    BridgeDiagnostic(
                        code: "CODEX_LEGACY_AMBIGUOUS",
                        category: "collector",
                        stage: "merge",
                        message: "不应进入报告的账号 acc-private@example.test",
                        retryable: false
                    ),
                    // 同一稳定 key 重复时只保留一条.
                    BridgeDiagnostic(
                        code: "CODEX_LEGACY_AMBIGUOUS",
                        category: "collector",
                        stage: "merge",
                        message: "另一个不应进入报告的 message",
                        retryable: false
                    ),
                ]
            }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try service.preview()
        try diagnosticsExpect(
            preview.components(separatedBy: "CODEX_LEGACY_AMBIGUOUS").count == 2,
            "merger diagnostic 应去重后进入诊断报告一次"
        )
        try diagnosticsExpect(
            preview.contains("\"stage\" : \"merge\"")
                && preview.contains("\"category\" : \"collector\""),
            "merger diagnostic stage/category 缺失"
        )
        try diagnosticsExpect(
            !preview.contains("acc-private")
                && !preview.contains("不应进入报告"),
            "诊断报告不得包含 merger message 或账号信息"
        )
    }
}
