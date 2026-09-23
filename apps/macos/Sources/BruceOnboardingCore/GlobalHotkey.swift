import Carbon.HIToolbox
import Foundation

/// 全局快捷键修饰键. 持久化为 rawValue 字符串.
public enum HotkeyModifier: String, Codable, Sendable, CaseIterable {
    case command
    case control
    case option
    case shift

    /// 显示符号 (系统菜单栏顺序: 控制/选项/Shift/Command).
    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        }
    }

    /// 规范化: 去重并按显示顺序排序, 保证相等比较与持久化稳定.
    static func normalized(_ modifiers: [HotkeyModifier]) -> [HotkeyModifier] {
        let order: [HotkeyModifier] = [.control, .option, .shift, .command]
        return order.filter { modifiers.contains($0) }
    }
}

/// 全局快捷键校验结果.
public enum GlobalHotkeyValidation: Equatable, Sendable {
    case valid
    case requiresModifier
    case unsupportedKey
    case systemReserved
}

/// 全局快捷键: Carbon 虚拟键码 + 规范化修饰键集合.
public struct GlobalHotkey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: [HotkeyModifier]

    public init(keyCode: UInt32, modifiers: [HotkeyModifier]) {
        self.keyCode = keyCode
        self.modifiers = HotkeyModifier.normalized(modifiers)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = HotkeyModifier.normalized(
            try container.decode([HotkeyModifier].self, forKey: .modifiers)
        )
    }

    /// 校验: 至少一个修饰键, 主键在符号表内, 组合不在系统保留黑名单.
    public var validation: GlobalHotkeyValidation {
        guard !modifiers.isEmpty else { return .requiresModifier }
        guard Self.symbol(forKeyCode: keyCode) != nil else { return .unsupportedKey }
        if Self.isSystemReserved(keyCode: keyCode, modifiers: modifiers) {
            return .systemReserved
        }
        return .valid
    }

    /// 人类可读展示, 如 "⌥⌘D", "⌃F5".
    public var displayString: String {
        let symbols = modifiers.map(\.symbol)
        let key = Self.symbol(forKeyCode: keyCode) ?? "?"
        return (symbols + [key]).joined()
    }

    /// Carbon RegisterEventHotKey 修饰键掩码.
    public var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        for modifier in modifiers {
            switch modifier {
            case .command: mask |= UInt32(cmdKey)
            case .control: mask |= UInt32(controlKey)
            case .option: mask |= UInt32(optionKey)
            case .shift: mask |= UInt32(shiftKey)
            }
        }
        return mask
    }

    /// 键码 -> 显示字符. 不在表内返回 nil (录制拒绝, 展示回退 "?").
    static func symbol(forKeyCode keyCode: UInt32) -> String? {
        symbolTable[keyCode]
    }

    /// 系统保留组合黑名单: 精确匹配修饰键集合 + 键码.
    static func isSystemReserved(
        keyCode: UInt32,
        modifiers: [HotkeyModifier]
    ) -> Bool {
        let set = Set(modifiers)
        switch keyCode {
        case UInt32(kVK_Tab):
            return set == [.command]                    // ⌘Tab
        case UInt32(kVK_Escape):
            return set == [.command, .option]           // ⌘⌥Esc
        case UInt32(kVK_Space):
            return set == [.command]                    // ⌘Space
                || set == [.control]                    // ⌃Space
                || set == [.command, .control]          // ⌘⌃Space
        default:
            return false
        }
    }

    /// 符号表: 字母, 数字, 功能键, 特殊键.
    private static let symbolTable: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        let letters: [(UInt32, String)] = [
            (UInt32(kVK_ANSI_A), "A"), (UInt32(kVK_ANSI_B), "B"),
            (UInt32(kVK_ANSI_C), "C"), (UInt32(kVK_ANSI_D), "D"),
            (UInt32(kVK_ANSI_E), "E"), (UInt32(kVK_ANSI_F), "F"),
            (UInt32(kVK_ANSI_G), "G"), (UInt32(kVK_ANSI_H), "H"),
            (UInt32(kVK_ANSI_I), "I"), (UInt32(kVK_ANSI_J), "J"),
            (UInt32(kVK_ANSI_K), "K"), (UInt32(kVK_ANSI_L), "L"),
            (UInt32(kVK_ANSI_M), "M"), (UInt32(kVK_ANSI_N), "N"),
            (UInt32(kVK_ANSI_O), "O"), (UInt32(kVK_ANSI_P), "P"),
            (UInt32(kVK_ANSI_Q), "Q"), (UInt32(kVK_ANSI_R), "R"),
            (UInt32(kVK_ANSI_S), "S"), (UInt32(kVK_ANSI_T), "T"),
            (UInt32(kVK_ANSI_U), "U"), (UInt32(kVK_ANSI_V), "V"),
            (UInt32(kVK_ANSI_W), "W"), (UInt32(kVK_ANSI_X), "X"),
            (UInt32(kVK_ANSI_Y), "Y"), (UInt32(kVK_ANSI_Z), "Z"),
        ]
        for (keyCode, symbol) in letters { table[keyCode] = symbol }
        let digits: [(UInt32, String)] = [
            (UInt32(kVK_ANSI_0), "0"), (UInt32(kVK_ANSI_1), "1"),
            (UInt32(kVK_ANSI_2), "2"), (UInt32(kVK_ANSI_3), "3"),
            (UInt32(kVK_ANSI_4), "4"), (UInt32(kVK_ANSI_5), "5"),
            (UInt32(kVK_ANSI_6), "6"), (UInt32(kVK_ANSI_7), "7"),
            (UInt32(kVK_ANSI_8), "8"), (UInt32(kVK_ANSI_9), "9"),
        ]
        for (keyCode, symbol) in digits { table[keyCode] = symbol }
        let functionKeys: [(UInt32, String)] = [
            (UInt32(kVK_F1), "F1"), (UInt32(kVK_F2), "F2"),
            (UInt32(kVK_F3), "F3"), (UInt32(kVK_F4), "F4"),
            (UInt32(kVK_F5), "F5"), (UInt32(kVK_F6), "F6"),
            (UInt32(kVK_F7), "F7"), (UInt32(kVK_F8), "F8"),
            (UInt32(kVK_F9), "F9"), (UInt32(kVK_F10), "F10"),
            (UInt32(kVK_F11), "F11"), (UInt32(kVK_F12), "F12"),
        ]
        for (keyCode, symbol) in functionKeys { table[keyCode] = symbol }
        let specials: [(UInt32, String)] = [
            (UInt32(kVK_Space), "空格"), (UInt32(kVK_Return), "↩"),
            (UInt32(kVK_Tab), "⇥"), (UInt32(kVK_Delete), "⌫"),
            (UInt32(kVK_Escape), "⎋"), (UInt32(kVK_Home), "↖"),
            (UInt32(kVK_End), "↘"), (UInt32(kVK_PageUp), "⇞"),
            (UInt32(kVK_PageDown), "⇟"), (UInt32(kVK_UpArrow), "↑"),
            (UInt32(kVK_DownArrow), "↓"), (UInt32(kVK_LeftArrow), "←"),
            (UInt32(kVK_RightArrow), "→"),
        ]
        for (keyCode, symbol) in specials { table[keyCode] = symbol }
        return table
    }()
}
