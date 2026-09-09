import Foundation
@testable import BruceAppCore

enum HarnessFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

@MainActor
private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw HarnessFailure.expectation(message)
    }
}

@main
@MainActor
struct PerformancePolicyHarness {
    static func main() throws {
        let unchanged = MenuBarRenderSnapshot(
            summaryKey: "Bruce, 100 tokens",
            isRefreshing: false
        )
        let refreshing = MenuBarRenderSnapshot(
            summaryKey: "Bruce, 100 tokens",
            isRefreshing: true
        )
        let changed = MenuBarRenderSnapshot(
            summaryKey: "Bruce, 200 tokens",
            isRefreshing: false
        )

        try expect(
            MenuBarRenderPolicy.summaryNeedsRender(previous: nil, current: unchanged),
            "the first menu-bar summary must render"
        )
        try expect(
            !MenuBarRenderPolicy.summaryNeedsRender(previous: unchanged, current: refreshing),
            "refresh state alone must not rerender the summary"
        )
        try expect(
            MenuBarRenderPolicy.summaryNeedsRender(previous: unchanged, current: changed),
            "a changed menu-bar summary must render"
        )
        try expect(
            MenuBarRenderPolicy.animationIntervalSeconds >= 0.125,
            "menu-bar animation must be capped at eight frames per second"
        )

        let coalescer = MenuBarRenderCoalescer()
        try expect(coalescer.request(), "the first render request must be accepted")
        try expect(!coalescer.request(), "duplicate render requests must coalesce")
        coalescer.consume()
        try expect(coalescer.request(), "a consumed render may be requested again")

        print("Performance policy tests passed: 7")
    }
}
