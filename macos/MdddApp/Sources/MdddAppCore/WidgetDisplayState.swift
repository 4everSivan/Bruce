import Foundation

package enum WidgetDisplayState: String, Equatable, Sendable {
    case loading
    case refreshing
    case fresh
    case stale
    case authRequired
    case offline
    case partial
    case error
    case notConfigured

    package init(moduleState: ModuleRunState) {
        switch moduleState {
        case .notConfigured:
            self = .notConfigured
        case .ready:
            self = .loading
        case .refreshing:
            self = .refreshing
        case .fresh:
            self = .fresh
        case .partial:
            self = .partial
        case .stale:
            self = .stale
        case .authRequired:
            self = .authRequired
        case .offline:
            self = .offline
        case .failed:
            self = .error
        }
    }
}
