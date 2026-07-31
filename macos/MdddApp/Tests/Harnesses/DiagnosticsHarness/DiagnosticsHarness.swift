import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

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
            "mddd-diagnostics",
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
        print("Diagnostics tests passed: 5")
    }

    private static func makeFixture(
        archiver: DiagnosticArchiving = CapturingArchiver()
    ) throws -> (DiagnosticService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mddd-diagnostics-harness-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let store = try ArtifactStore(
            rootURL: root.appendingPathComponent("Application Support/mddd")
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
            architecture: { "arm64" }
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
                == "mddd-diagnostics-20260806-070640.zip",
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
}
