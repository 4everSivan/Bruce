import AppKit
import Carbon.HIToolbox
import BruceOnboardingCore

/// Carbon 注册句柄的持有者 (C256): deinit 为非隔离上下文，
/// 把非 Sendable 的指针收进 @unchecked Sendable 容器，保证析构时能安全反注册。
private final class CarbonHotkeyRegistration: @unchecked Sendable {
    var hotKeyRef: EventHotKeyRef?
    var eventHandlerRef: EventHandlerRef?

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}

/// 全局快捷键注册 (Carbon RegisterEventHotKey) 与按键回调.
/// 零外部依赖; 注册失败 (组合被占用) 非致命, 经 onRegistrationFailure 暴露.
@MainActor
final class GlobalHotkeyMonitor {
    private let onPress: @MainActor () -> Void
    private let onRegistrationFailure: @MainActor (String) -> Void
    private let registration = CarbonHotkeyRegistration()

    init(
        onPress: @escaping @MainActor () -> Void,
        onRegistrationFailure: @escaping @MainActor (String) -> Void
    ) {
        self.onPress = onPress
        self.onRegistrationFailure = onRegistrationFailure
    }

    /// 注册全局快捷键; 传入 nil 仅清理. 变更时先注销旧组合再注册新组合.
    func register(_ hotkey: GlobalHotkey?) {
        unregister()
        guard let hotkey, hotkey.validation == .valid else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var eventHandlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            onRegistrationFailure("全局快捷键注册失败")
            return
        }
        registration.eventHandlerRef = eventHandlerRef

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4D4444),  // 'BRUCE'
            id: 1
        )
        var newRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            hotkey.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &newRef
        )
        guard registerStatus == noErr, let newRef else {
            if let eventHandlerRef = registration.eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                registration.eventHandlerRef = nil
            }
            if registerStatus == eventHotKeyExistsErr {
                onRegistrationFailure("该快捷键已被其他应用占用, 请更换")
            } else {
                onRegistrationFailure("全局快捷键注册失败")
            }
            return
        }
        registration.hotKeyRef = newRef
    }

    /// 注销全局热键与事件处理器.
    func unregister() {
        registration.unregister()
    }

    deinit {
        // C256: Carbon 回调持有未保留指针；监听对象释放前必须移除事件处理器，
        // 否则后续热键事件会解引用悬垂指针。
        registration.unregister()
    }

    /// Carbon 事件回调: 系统在主线程分发事件, 用 assumeIsolated 保持隔离.
    private static let hotKeyEventHandler: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let monitor = Unmanaged<GlobalHotkeyMonitor>
            .fromOpaque(userData)
            .takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.onPress()
        }
        return noErr
    }
}
