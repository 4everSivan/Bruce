import Carbon.HIToolbox
import Foundation
@testable import MdddOnboardingCore

private enum HotkeyTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw HotkeyTestFailure.expectation(message)
    }
}

@main
struct GlobalHotkeyHarness {
    static func main() throws {
        try hotkeyCodableRoundTrip()
        try modifiersNormalizeCanonicalOrder()
        try validationRequiresModifier()
        try validationRejectsUnsupportedKey()
        try validationRejectsSystemReservedCombos()
        try validationAcceptsValidCombo()
        try displayStringFormatsModifiersAndKey()
        try displayStringFormatsFunctionAndArrowKeys()
        try carbonModifiersBuildsBitmask()
        try symbolTableCoversExpectedKeys()
        // 配置持久化用例 (依赖 Task 2 的 OnboardingConfiguration.dashboardHotkey).
        try onboardingConfigFallsBackToNil()
        try onboardingConfigExplicitNullFallsBackToNil()
        try onboardingConfigRoundTripsHotkey()
        print("GlobalHotkeyHarness: 全部通过")
    }

    /// Codable 往返: 编码后解码应还原相同快捷键.
    private static func hotkeyCodableRoundTrip() throws {
        let hotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: [.command, .option]
        )
        let data = try JSONEncoder().encode(hotkey)
        let decoded = try JSONDecoder().decode(GlobalHotkey.self, from: data)
        try expect(decoded == hotkey, "Codable 往返应还原相同快捷键")
    }

    /// 修饰键规范化: 无序输入 -> 固定显示顺序 + 去重.
    private static func modifiersNormalizeCanonicalOrder() throws {
        let hotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: [.command, .shift, .option, .control, .command]
        )
        try expect(
            hotkey.modifiers == [.control, .option, .shift, .command],
            "修饰键应按显示顺序规范化并去重: \(hotkey.modifiers)"
        )
    }

    /// 无修饰键的组合非法.
    private static func validationRequiresModifier() throws {
        let hotkey = GlobalHotkey(keyCode: UInt32(kVK_ANSI_D), modifiers: [])
        try expect(
            hotkey.validation == .requiresModifier,
            "无修饰键应判 requiresModifier"
        )
    }

    /// 不在符号表内的键码非法.
    private static func validationRejectsUnsupportedKey() throws {
        let hotkey = GlobalHotkey(keyCode: 0xFFFF, modifiers: [.command])
        try expect(
            hotkey.validation == .unsupportedKey,
            "未知键码应判 unsupportedKey"
        )
    }

    /// 系统保留组合直接拒绝.
    private static func validationRejectsSystemReservedCombos() throws {
        let reserved: [(keyCode: UInt32, modifiers: [HotkeyModifier])] = [
            (UInt32(kVK_Tab), [.command]),               // ⌘Tab
            (UInt32(kVK_Escape), [.command, .option]),   // ⌘⌥Esc
            (UInt32(kVK_Space), [.command]),             // ⌘Space
            (UInt32(kVK_Space), [.control]),             // ⌃Space
            (UInt32(kVK_Space), [.command, .control]),   // ⌘⌃Space
        ]
        for entry in reserved {
            let hotkey = GlobalHotkey(keyCode: entry.keyCode, modifiers: entry.modifiers)
            try expect(
                hotkey.validation == .systemReserved,
                "保留组合应判 systemReserved: \(hotkey.displayString)"
            )
        }
    }

    /// 合法组合通过校验.
    private static func validationAcceptsValidCombo() throws {
        let hotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: [.option, .command]
        )
        try expect(hotkey.validation == .valid, "⌥⌘D 应合法")
    }

    /// 展示字符串: 修饰键符号 + 主键字符.
    private static func displayStringFormatsModifiersAndKey() throws {
        let hotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: [.option, .command]
        )
        try expect(
            hotkey.displayString == "⌥⌘D",
            "应为 ⌥⌘D, 实际 \(hotkey.displayString)"
        )
    }

    /// 展示字符串: 功能键与方向键.
    private static func displayStringFormatsFunctionAndArrowKeys() throws {
        let f5 = GlobalHotkey(keyCode: UInt32(kVK_F5), modifiers: [.control])
        try expect(f5.displayString == "⌃F5", "应为 ⌃F5, 实际 \(f5.displayString)")
        let arrow = GlobalHotkey(keyCode: UInt32(kVK_RightArrow), modifiers: [.command])
        try expect(arrow.displayString == "⌘→", "应为 ⌘→, 实际 \(arrow.displayString)")
    }

    /// Carbon 修饰键掩码.
    private static func carbonModifiersBuildsBitmask() throws {
        let hotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: [.command, .control]
        )
        try expect(
            hotkey.carbonModifiers == UInt32(cmdKey | controlKey),
            "⌘⌃ 掩码应为 cmdKey|controlKey: \(hotkey.carbonModifiers)"
        )
    }

    /// 符号表覆盖字母/数字/特殊键, 未知键码返回 nil.
    private static func symbolTableCoversExpectedKeys() throws {
        try expect(
            GlobalHotkey.symbol(forKeyCode: UInt32(kVK_ANSI_A)) == "A",
            "字母 A 应映射到 A"
        )
        try expect(
            GlobalHotkey.symbol(forKeyCode: UInt32(kVK_ANSI_0)) == "0",
            "数字 0 应映射到 0"
        )
        try expect(
            GlobalHotkey.symbol(forKeyCode: UInt32(kVK_Space)) == "空格",
            "空格应映射到 空格"
        )
        try expect(
            GlobalHotkey.symbol(forKeyCode: 0xFFFF) == nil,
            "未知键码应返回 nil"
        )
    }

    // MARK: - Task 2 恢复 (依赖 OnboardingConfiguration.dashboardHotkey)

    // 旧配置缺 dashboardHotkey 键: 解码回落 nil.
    // 注意: 依赖 Task 2 完成 OnboardingConfiguration 字段后才能通过.
    private static func onboardingConfigFallsBackToNil() throws {
        let json = """
        {"schemaVersion":2,"selectedModules":[],"connectionStates":{},
         "lastVerifiedAt":{}}
        """
        let config = try JSONDecoder().decode(
            OnboardingConfiguration.self, from: Data(json.utf8)
        )
        try expect(config.dashboardHotkey == nil, "缺键应回落 nil")
        try expect(config.resolvedDashboardHotkey == nil, "解析值应回落 nil")
    }

    // 显式 dashboardHotkey:null 字段: 解码回落 nil.
    private static func onboardingConfigExplicitNullFallsBackToNil() throws {
        let json = """
        {"schemaVersion":2,"selectedModules":[],"connectionStates":{},
         "lastVerifiedAt":{},"dashboardHotkey":null}
        """
        let config = try JSONDecoder().decode(
            OnboardingConfiguration.self, from: Data(json.utf8)
        )
        try expect(config.dashboardHotkey == nil, "显式 null 应回落 nil")
        try expect(config.resolvedDashboardHotkey == nil, "解析值应回落 nil")
    }

    // 配置往返携带快捷键.
    private static func onboardingConfigRoundTripsHotkey() throws {
        var config = OnboardingConfiguration()
        config.dashboardHotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: [.option, .command]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(
            OnboardingConfiguration.self, from: data
        )
        try expect(
            decoded.dashboardHotkey == config.dashboardHotkey,
            "配置往返应携带快捷键"
        )
    }
}
