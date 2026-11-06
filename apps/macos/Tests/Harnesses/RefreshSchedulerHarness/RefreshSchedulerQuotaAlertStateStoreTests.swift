import Foundation
@testable import BruceAppCore

// MARK: - 预警状态文件 (T30)

extension RefreshSchedulerHarness {
    static func quotaAlertStateStoreRoundTripsAndRejectsCorruption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-alert-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("quota-alert-state-v1.json")
        let store = QuotaAlertStateStore(url: url)
        let state = JSONValue.object([
            "version": .integer(1),
            "windows": .object([:]),
        ])
        try refreshExpect(store.save(state), "状态文件应写入成功")
        try refreshExpect(
            QuotaAlertStateStore(url: url).load() == state,
            "新实例应读回同一状态"
        )

        try Data("not-json".utf8).write(to: url)
        try refreshExpect(
            QuotaAlertStateStore(url: url).load() == nil,
            "损坏状态应返回 nil 交由静默 bootstrap"
        )
    }
}
