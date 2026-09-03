import SwiftUI

// MARK: - Fluent 平面 token (1:1 取自 docs/design/settings-layout-demo.html)

/// 设置窗口 Fluent 平面配色; 不使用 macOS 材质/语义色, 保证任何主题下都是
/// 纯平面表面, 并与未来 WinUI 迁移共享同一套 token.
enum SettingsDemoTokens {
    /// 最深层底色 (picker 轨道等): dark #1B1B1B / light #EFEFEF.
    static let bg = Color.adaptive(light: Color(hex: "EFEFEF"), dark: Color(hex: "1B1B1B"))
    /// 窗口内容底: dark #242424 / light #FAFAFA.
    static let window = Color.adaptive(light: Color(hex: "FAFAFA"), dark: Color(hex: "242424"))
    /// 侧栏底: dark #1F1F1F / light #F3F3F3.
    static let nav = Color.adaptive(light: Color(hex: "F3F3F3"), dark: Color(hex: "1F1F1F"))
    /// 卡片/按钮面: dark #2C2C2C / light #FFFFFF.
    static let surface = Color.adaptive(light: Color(hex: "FFFFFF"), dark: Color(hex: "2C2C2C"))
    /// 悬停/选中浅底: dark #333333 / light #F0F0F0.
    static let surfaceHover = Color.adaptive(light: Color(hex: "F0F0F0"), dark: Color(hex: "333333"))
    /// 分隔线/卡片描边: dark #3A3A3A / light #E2E2E2.
    static let separator = Color.adaptive(light: Color(hex: "E2E2E2"), dark: Color(hex: "3A3A3A"))
    /// 按钮描边: dark #4A4A4A / light #CFCFCF.
    static let borderStrong = Color.adaptive(light: Color(hex: "CFCFCF"), dark: Color(hex: "4A4A4A"))
    /// 正文/次级/三级文字.
    static let text = Color.adaptive(light: Color(hex: "1B1B1B"), dark: Color(hex: "F2F2F2"))
    static let text2 = Color.adaptive(light: Color(hex: "5C5C5C"), dark: Color(hex: "A8A8A8"))
    static let text3 = Color.adaptive(light: Color(hex: "9A9A9A"), dark: Color(hex: "6E6E6E"))
    /// 选中项浅底 (surface-hover): dark #333333 / light #F0F0F0.
    static let navSelected = surfaceHover
    /// accent: dark #4C9CFF / light #0B5CBB.
    static let accent = Color.adaptive(light: Color(hex: "0B5CBB"), dark: Color(hex: "4C9CFF"))
    /// 状态横幅: ok 绿 / warn 黄, 13% 透明度铺底.
    static let ok = Color(hex: "4A9E5C")
    static let warn = Color(hex: "D4A843")
    static let danger = Color(hex: "E5534B")
}

// MARK: - 卡片 (demo .card)

/// demo 卡片: surface 底 + 1px 边框 + 8px 圆角, 行间 1px 分隔;
/// 行内边距由 FluentRow 承担, 容器本身零内边距.
struct FluentCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsDemoTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
    }
}

// MARK: - 行 (demo .row)

/// demo 行: 标题 13px + 副标题 11.5px 灰 + 右端尾件; min-height 42,
/// 行间分隔用 `divided` (非首行传 true).
struct FluentRow<Tail: View>: View {
    let title: String
    var sub: String? = nil
    var divided: Bool = false
    @ViewBuilder var tail: Tail

    init(
        _ title: String,
        sub: String? = nil,
        divided: Bool = false,
        @ViewBuilder tail: () -> Tail
    ) {
        self.title = title
        self.sub = sub
        self.divided = divided
        self.tail = tail()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsDemoTokens.text)
                if let sub {
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsDemoTokens.text2)
                }
            }
            Spacer(minLength: 8)
            tail
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 42)
        .overlay(alignment: .top) {
            if divided {
                SettingsDemoTokens.separator.frame(height: 1)
            }
        }
    }
}

extension FluentRow where Tail == EmptyView {
    init(_ title: String, sub: String? = nil, divided: Bool = false) {
        self.title = title
        self.sub = sub
        self.divided = divided
        self.tail = EmptyView()
    }
}

// MARK: - 分段选择器 (demo .picker)

/// demo 分段选择器: 深底 + 1px 边框 + 6px 圆角; 选中项浅底白字,
/// 不用系统 accent 蓝.
struct FluentSegmentedPicker<Selection: Hashable>: View {
    let options: [(title: String, tag: Selection)]
    @Binding var selection: Selection
    var accessibilityHintText: String? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.tag) { option in
                let isOn = selection == option.tag
                Button {
                    selection = option.tag
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(
                            isOn ? SettingsDemoTokens.text : SettingsDemoTokens.text2
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            isOn ? SettingsDemoTokens.surfaceHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(SettingsDemoTokens.bg)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
        .accessibilityHint(accessibilityHintText ?? "")
    }
}

// MARK: - 按钮 (demo .btn / .btn.primary / .btn.danger)

enum FluentButtonRole {
    case plain, primary, danger
}

/// demo 按钮: 12px 字, 5/12 内边距, 5px 圆角; plain = surface 底 + 描边,
/// primary = accent 实底白字, danger = 红字 (保留底与描边).
struct FluentButtonStyle: SwiftUI.ButtonStyle {
    let role: FluentButtonRole
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(background(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
    }

    private var foreground: Color {
        switch role {
        case .plain: return SettingsDemoTokens.text
        case .primary: return .white
        case .danger: return SettingsDemoTokens.danger
        }
    }

    private func background(isPressed: Bool) -> Color {
        switch role {
        case .plain:
            return isPressed ? SettingsDemoTokens.surfaceHover : SettingsDemoTokens.surface
        case .primary:
            return SettingsDemoTokens.accent.opacity(isPressed ? 0.8 : 1)
        case .danger:
            return isPressed ? SettingsDemoTokens.surfaceHover : SettingsDemoTokens.surface
        }
    }

    private var border: Color {
        switch role {
        case .primary: return SettingsDemoTokens.accent
        case .plain, .danger: return SettingsDemoTokens.borderStrong
        }
    }
}

extension View {
    func fluentButton(_ role: FluentButtonRole = .plain) -> some View {
        buttonStyle(FluentButtonStyle(role: role))
    }
}

// MARK: - 状态点 (demo .statusdot)

struct FluentStatusDot: View {
    enum Level {
        case ok, warn, off

        var color: Color {
            switch self {
            case .ok: return SettingsDemoTokens.ok
            case .warn: return SettingsDemoTokens.warn
            case .off: return SettingsDemoTokens.text3
            }
        }
    }

    let level: Level

    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}
