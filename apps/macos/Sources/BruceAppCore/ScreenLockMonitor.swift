import AppKit
import CoreGraphics
import Foundation

// MARK: - ScreenLockDetector

package enum ScreenLockDetector {
    /// 实时探测当前控制台 session 是否处于锁屏状态.
    /// 读取 CGSessionCopyCurrentDictionary 中的 CGSSessionScreenIsLocked 标志.
    package static func isScreenCurrentlyLocked() -> Bool {
        guard let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let isLocked = sessionInfo["CGSSessionScreenIsLocked"] as? Bool {
            return isLocked
        }
        if let isLockedNum = sessionInfo["CGSSessionScreenIsLocked"] as? Int {
            return isLockedNum == 1
        }
        return false
    }
}

// MARK: - ScreenLockStateProviding

@MainActor
package protocol ScreenLockStateProviding: AnyObject {
    var isScreenLocked: Bool { get }
    var onScreenLockStateChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - SystemScreenLockMonitor

@MainActor
package final class SystemScreenLockMonitor: ScreenLockStateProviding {
    private var locked = false
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var systemWakeObserver: NSObjectProtocol?

    package var isScreenLocked: Bool {
        locked || ScreenLockDetector.isScreenCurrentlyLocked()
    }
    package var onScreenLockStateChange: ((Bool) -> Void)?

    package init() {
        self.locked = ScreenLockDetector.isScreenCurrentlyLocked()
    }

    package func start() {
        guard lockObserver == nil else { return }
        self.locked = ScreenLockDetector.isScreenCurrentlyLocked()

        // 1. 分布式通知: 屏幕锁定与解锁 (系统级广播)
        let distCenter = DistributedNotificationCenter.default()
        lockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.apply(true)
            }
        }

        unlockObserver = distCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.apply(false)
            }
        }

        // 2. 工作区通知: 屏幕息屏 / 唤醒
        let wsCenter = NSWorkspace.shared.notificationCenter
        screenSleepObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.apply(true)
            }
        }

        screenWakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                let current = ScreenLockDetector.isScreenCurrentlyLocked()
                self?.apply(current)
            }
        }

        systemWakeObserver = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                let current = ScreenLockDetector.isScreenCurrentlyLocked()
                self?.apply(current)
            }
        }
    }

    package func stop() {
        if let observer = lockObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            lockObserver = nil
        }
        if let observer = unlockObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            unlockObserver = nil
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        if let observer = screenSleepObserver {
            wsCenter.removeObserver(observer)
            screenSleepObserver = nil
        }
        if let observer = screenWakeObserver {
            wsCenter.removeObserver(observer)
            screenWakeObserver = nil
        }
        if let observer = systemWakeObserver {
            wsCenter.removeObserver(observer)
            systemWakeObserver = nil
        }
    }

    private func apply(_ locked: Bool) {
        guard locked != self.locked else { return }
        self.locked = locked
        onScreenLockStateChange?(locked)
    }
}
