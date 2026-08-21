import BruceAppCore
import UserNotifications

/// 后台刷新额度预警的系统通知投递.
/// 首次投递时请求通知授权; 应用前台也展示横幅 (菜单栏应用常在前台运行).
@MainActor
final class QuotaAlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false

    override init() {
        super.init()
        center.delegate = self
    }

    func deliver(_ alerts: [QuotaAlert]) {
        guard !alerts.isEmpty else { return }
        requestAuthorizationIfNeeded { [weak self] granted in
            guard granted, let self else { return }
            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = "订阅额度预警"
                content.body = "\(alert.serviceName) \(alert.windowLabel)已用 "
                    + "\(Int(alert.usedPercent.rounded()))%, 超过 80% 阈值"
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: "quota-alert-\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
                self.center.add(request)
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        if authorizationRequested {
            center.getNotificationSettings { settings in
                let status = settings.authorizationStatus
                let granted = status == .authorized || status == .provisional
                Task { @MainActor in completion(granted) }
            }
            return
        }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in completion(granted) }
        }
    }

    /// 前台运行时同样展示横幅与声音, 否则预警会被静默吞掉.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
