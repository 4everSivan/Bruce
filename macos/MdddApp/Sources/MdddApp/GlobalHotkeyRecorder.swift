import AppKit
import Carbon.HIToolbox
import MdddOnboardingCore
import SwiftUI

/// 全局快捷键录制控件: 点击进入录制态, 捕获下一个按键组合并提交校验.
/// 本地事件监视仅在设置窗口为 key 时生效, 不会拦截其他应用按键.
struct GlobalHotkeyRecorder: View {
    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @State private var isRecording = false
    @State private var recordingError: String?
    @State private var keyDownMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(coordinator.dashboardHotkey?.displayString ?? "未设置")
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .foregroundStyle(coordinator.dashboardHotkey == nil ? .secondary : .primary)
                    .accessibilityLabel(coordinator.dashboardHotkey?.displayString ?? "未设置全局快捷键")
                Spacer()
                Button(isRecording ? "请按下快捷键… (Esc 取消)" : "录制") {
                    isRecording ? stopRecording() : startRecording()
                }
                Button("清除") {
                    coordinator.setDashboardHotkey(nil)
                    recordingError = nil
                }
                .disabled(coordinator.dashboardHotkey == nil || isRecording)
            }
            Text("按快捷键后立即生效, 可在任意应用中切换仪表盘")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let recordingError {
                Label(recordingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recordingError = nil
        isRecording = true
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
            return nil
        }
    }

    private func stopRecording() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        isRecording = false
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Esc 且无修饰键: 取消录制
        if event.keyCode == UInt16(kVK_Escape),
           Self.modifiers(from: event.modifierFlags).isEmpty {
            stopRecording()
            return
        }
        let hotkey = GlobalHotkey(
            keyCode: UInt32(event.keyCode),
            modifiers: Self.modifiers(from: event.modifierFlags)
        )
        switch hotkey.validation {
        case .valid:
            coordinator.setDashboardHotkey(hotkey)
            stopRecording()
        case .requiresModifier:
            recordingError = "快捷键需至少一个修饰键, 请重试"
        case .unsupportedKey:
            recordingError = "该键不支持, 请换一个"
        case .systemReserved:
            recordingError = "该组合被系统保留, 请换一个"
        }
    }

    /// 事件修饰标志 -> 修饰键列表 (只取四类修饰键).
    private static func modifiers(from flags: NSEvent.ModifierFlags) -> [HotkeyModifier] {
        var result: [HotkeyModifier] = []
        if flags.contains(.command) { result.append(.command) }
        if flags.contains(.control) { result.append(.control) }
        if flags.contains(.option) { result.append(.option) }
        if flags.contains(.shift) { result.append(.shift) }
        return result
    }
}
