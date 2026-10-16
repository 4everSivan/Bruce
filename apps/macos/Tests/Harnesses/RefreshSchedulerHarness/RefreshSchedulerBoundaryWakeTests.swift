import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

// MARK: - 额度窗口边界唤醒 (C037)

extension RefreshSchedulerHarness {
    /// 构造 services 含 windows 条目的 artifact (含应被忽略的形态).
    static func makeBoundaryArtifact() -> JSONValue {
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string("2026-07-28T12:00:00Z"),
            "agents": .array([]),
            "services": .array([
                .object([
                    "id": .string("cline"),
                    "kind": .string("windows"),
                    "status": .string("ok"),
                    "windows": .array([
                        .object(["label": .string("5小时窗口"), "resetsAt": .integer(1_791_543_327)]),
                        .object(["label": .string("每周窗口"), "resetsAt": .null]),
                        .object(["label": .string("每月窗口")]),
                    ]),
                ]),
                .object([
                    "id": .string("deepseek"),
                    "kind": .string("balance"),
                    "status": .string("ok"),
                    "windows": .array([.object(["resetsAt": .integer(1)])]),
                ]),
            ]),
        ])
    }

    /// 只取 kind="windows" 服务的 windows[].resetsAt; 其它 kind / null / 缺字段一律忽略.
    static func boundaryExtractionIgnoresNonWindowServices() throws {
        let boundaries = SubscriptionBoundaryWakePolicy.boundaries(in: makeBoundaryArtifact())
        try refreshExpect(boundaries == [1_791_543_327], "窗口边界提取错误: \(boundaries)")
        try refreshExpect(
            SubscriptionBoundaryWakePolicy.boundaries(in: .object([:])).isEmpty,
            "无 services 应得空集"
        )
    }

    /// 边界策略三道防线: 只认未来边界 / 同一边界只消费一次 / 未命中回落间隔.
    static func boundaryWakePolicyNeverCrossesFutureReset() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowEpoch = Int64(now.timeIntervalSince1970)
        var consumed: Set<Int64> = []

        // 边界还剩 600s (间隔 1800s): 提前到 600 + slack.
        let first = SubscriptionBoundaryWakePolicy.delay(
            intervalRemaining: 1800,
            boundaries: [nowEpoch + 600],
            now: now,
            consumed: &consumed
        )
        try refreshExpect(first == 620, "应提前到边界 + slack: \(first)")
        // 同一边界不重复消费 (窗口尚未刷新时) → 回落原间隔, 无刷新风暴.
        let second = SubscriptionBoundaryWakePolicy.delay(
            intervalRemaining: 1800,
            boundaries: [nowEpoch + 600],
            now: now,
            consumed: &consumed
        )
        try refreshExpect(second == 1800, "同一边界不应二次唤醒: \(second)")

        // 已进入过去的边界 (滚动窗口滑出时刻前移) 既不唤醒也不记忆.
        var past: Set<Int64> = []
        let stale = SubscriptionBoundaryWakePolicy.delay(
            intervalRemaining: 1800,
            boundaries: [nowEpoch - 5],
            now: now,
            consumed: &past
        )
        try refreshExpect(stale == 1800 && past.isEmpty, "过期边界不得参与: \(stale)")

        // 比间隔更远的边界不缩短等待; 多窗口取最近; 空集回落间隔.
        let far = SubscriptionBoundaryWakePolicy.delay(
            intervalRemaining: 1800,
            boundaries: [nowEpoch + 7200],
            now: now,
            consumed: &consumed
        )
        try refreshExpect(far == 1800, "远边界不应提前: \(far)")
        let nearest = SubscriptionBoundaryWakePolicy.delay(
            intervalRemaining: 1800,
            boundaries: [nowEpoch + 3000, nowEpoch + 900, nowEpoch + 5000],
            now: now,
            consumed: &consumed
        )
        try refreshExpect(nearest == 920, "应取最近边界: \(nearest)")
        let empty = SubscriptionBoundaryWakePolicy.delay(
            intervalRemaining: 1800,
            boundaries: [],
            now: now,
            consumed: &consumed
        )
        try refreshExpect(empty == 1800, "无边界应回落间隔: \(empty)")

        // 已消费集合随边界进入过去而收敛.
        var pruned: Set<Int64> = [nowEpoch - 10, nowEpoch + 60]
        let afterPrune = SubscriptionBoundaryWakePolicy.delay(
            intervalRemaining: 1800,
            boundaries: [nowEpoch + 60, nowEpoch + 5000],
            now: now,
            consumed: &pruned
        )
        try refreshExpect(afterPrune == 1800, "已消费边界应被跳过: \(afterPrune)")
        try refreshExpect(pruned == [nowEpoch + 60], "过期条目应被剪掉: \(pruned)")
    }
}
