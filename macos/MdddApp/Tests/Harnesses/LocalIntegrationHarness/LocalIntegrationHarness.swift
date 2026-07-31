import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

private enum IntegrationTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

private func integrationExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw IntegrationTestFailure.expectation(message)
    }
}

@MainActor
private struct IsolatedRunInputProvider: CollectorRunInputProviding {
    let home: URL
    let secret: String

    func runInput(for module: CollectorModule) throws -> CollectorRunInput {
        guard module == .agentUsage else {
            throw CollectorRunInputError.missingDependency(
                module: module,
                reason: "integration harness only enables Agent usage"
            )
        }
        return CollectorRunInput(
            context: [
                "home": .string(home.path),
                "now": .string("2026-07-28T12:00:00+08:00"),
                "timezone": .string("Asia/Shanghai"),
                "capabilities": .array([
                    .string("localSessions"),
                    .string("localPricing"),
                ]),
            ],
            credentials: [
                "providerEnv": .object([
                    "MDDD_FIXTURE_TOKEN": .string(secret),
                ]),
            ]
        )
    }
}

@main
@MainActor
struct LocalIntegrationHarness {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw IntegrationTestFailure.expectation(
                "expected repository root, Python path and Bridge path"
            )
        }
        let repository = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        let bridge = URL(fileURLWithPath: CommandLine.arguments[3])
        try integrationExpect(
            repository.isFileURL
                && python.path.hasPrefix("/")
                && bridge.path.hasPrefix("/"),
            "integration paths must be absolute"
        )
        try await startupRefreshCacheDiagnosticsAndCleanup(
            repository: repository,
            python: python,
            bridge: bridge
        )
        print("Local integration tests passed: 1")
    }

    private static func startupRefreshCacheDiagnosticsAndCleanup(
        repository: URL,
        python: URL,
        bridge: URL
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mddd-local-integration-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let applicationSupport = root.appendingPathComponent(
            "Application Support/mddd",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        let secret = "fixture-secret-\(UUID().uuidString)"
        let store = try ArtifactStore(rootURL: applicationSupport)
        let runner = CollectorRunner(
            pythonURL: python,
            bridgeURL: bridge
        )
        let scheduler = RefreshScheduler(
            executor: runner,
            store: store,
            registerWakeNotifications: false,
            runInputProvider: IsolatedRunInputProvider(
                home: home,
                secret: secret
            )
        )
        let model = AppModel()
        scheduler.onStatusChange = { module, state, detail in
            model.setStatus(
                ModuleStatus(state: state, detail: detail),
                for: DashboardModule(module)
            )
        }
        scheduler.onArtifactChange = { module, artifact in
            model.setArtifact(artifact, for: DashboardModule(module))
        }
        scheduler.setAutoRefresh(false, for: .agentUsage)
        scheduler.start()
        scheduler.enableModule(.agentUsage)
        scheduler.refresh(.agentUsage)

        for _ in 0..<5_000 {
            if model.moduleArtifacts[.agentUsage] != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try integrationExpect(
            model.moduleArtifacts[.agentUsage] != nil,
            "isolated refresh did not publish an Agent artifact"
        )
        let snapshotURL = store.snapshotURL(for: .agentUsage)
        let snapshotData = try Data(contentsOf: snapshotURL)
        let snapshotText = String(decoding: snapshotData, as: UTF8.self)
        try integrationExpect(
            !snapshotText.contains(secret),
            "credential leaked into snapshot"
        )
        try integrationExpect(
            !snapshotText.contains(home.path),
            "isolated HOME leaked into snapshot"
        )

        let restartedModel = AppModel()
        let restartedScheduler = RefreshScheduler(
            executor: runner,
            store: store,
            registerWakeNotifications: false
        )
        restartedScheduler.onArtifactChange = { module, artifact in
            restartedModel.setArtifact(
                artifact,
                for: DashboardModule(module)
            )
        }
        restartedScheduler.start()
        try integrationExpect(
            restartedModel.moduleArtifacts[.agentUsage] != nil,
            "cache-first restart did not load the last successful snapshot"
        )

        let diagnostics = DiagnosticService(
            model: model,
            scheduler: scheduler,
            store: store
        )
        let preview = try diagnostics.preview()
        try integrationExpect(
            !preview.contains(secret)
                && !preview.contains(home.path)
                && !preview.lowercased().contains("\"artifact\""),
            "diagnostics preview contains non-allowlisted data"
        )
        let archive = root.appendingPathComponent("diagnostics.zip")
        try diagnostics.export(to: archive)
        let extracted = root.appendingPathComponent(
            "diagnostics-extracted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: extracted,
            withIntermediateDirectories: true
        )
        try expandArchive(archive, to: extracted)
        let files = try regularFiles(in: extracted)
        try integrationExpect(
            files == [
                "mddd-diagnostics/README.txt",
                "mddd-diagnostics/report.json",
            ],
            "diagnostics ZIP contains unexpected files: \(files)"
        )
        for relativePath in files {
            let data = try Data(contentsOf: extracted.appendingPathComponent(
                relativePath
            ))
            try integrationExpect(
                !DiagnosticContentPolicy.containsSensitiveContent(data),
                "diagnostics file failed sensitive-content scan"
            )
            let text = String(decoding: data, as: UTF8.self)
            try integrationExpect(
                !text.contains(secret) && !text.contains(home.path),
                "diagnostics file contains isolated secret or HOME"
            )
        }

        let widgetFiles = [
            repository.appendingPathComponent(
                "agent-usage/widget/index.html"
            ),
        ]
        for widget in widgetFiles {
            let source = try String(contentsOf: widget, encoding: .utf8)
            try integrationExpect(
                !source.contains(secret),
                "fixture credential leaked into Widget source"
            )
        }

        scheduler.stop()
        restartedScheduler.stop()
        try FileManager.default.removeItem(at: root)
        try integrationExpect(
            !FileManager.default.fileExists(atPath: root.path),
            "isolated Application Support cleanup failed"
        )
    }

    private static func expandArchive(
        _ archive: URL,
        to destination: URL
    ) throws {
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
        try process.run()
        process.waitUntilExit()
        try integrationExpect(
            process.terminationStatus == 0,
            "failed to expand diagnostics ZIP"
        )
    }

    private static func regularFiles(in root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            if values.isRegularFile == true {
                let relativeComponents = url.standardizedFileURL
                    .pathComponents
                    .dropFirst(root.standardizedFileURL.pathComponents.count)
                files.append(relativeComponents.joined(separator: "/"))
            }
        }
        return files.sorted()
    }
}
