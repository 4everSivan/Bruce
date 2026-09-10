import Foundation

/// Bruce 应用层系统通知投递策略.
///
/// macOS 的授权状态由系统管理; 这里仅决定 Bruce 是否应该尝试投递当前预警.
package enum SystemNotificationDeliveryPolicy {
    package static func shouldDeliver(
        alertCount: Int,
        enabled: Bool
    ) -> Bool {
        enabled && alertCount > 0
    }
}
