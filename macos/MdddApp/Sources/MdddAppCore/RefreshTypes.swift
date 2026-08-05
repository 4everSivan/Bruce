import Foundation

package enum RefreshTriggerReason: Equatable, Sendable {
    case timer
    case manual
    case wake
}

package struct RefreshIntent: Equatable, Sendable {
    package var reason: RefreshTriggerReason
    package var includesManual: Bool

    package init(reason: RefreshTriggerReason, includesManual: Bool) {
        self.reason = reason
        self.includesManual = includesManual
    }

    package static func manual() -> RefreshIntent {
        RefreshIntent(reason: .manual, includesManual: true)
    }

    package static func timer() -> RefreshIntent {
        RefreshIntent(reason: .timer, includesManual: false)
    }

    package static func wake() -> RefreshIntent {
        RefreshIntent(reason: .wake, includesManual: false)
    }
}

package enum RefreshIntentMerge {
    package static func merge(existing: RefreshIntent?, incoming: RefreshIntent) -> RefreshIntent {
        guard let existing else { return incoming }
        let includesManual = existing.includesManual
            || incoming.includesManual
            || existing.reason == .manual
            || incoming.reason == .manual
        let reason: RefreshTriggerReason
        if includesManual {
            reason = .manual
        } else {
            reason = existing.reason
        }
        return RefreshIntent(reason: reason, includesManual: includesManual)
    }
}
