import Charts
import MdddAppCore
import SwiftUI

// GitHub / GitLab 共用的热力图卡.
// 只排卡片内容; 外层液态玻璃容器由面板装配层统一处理.
// 视觉以 panel-layout-v8.html 为准: 26 列 x 7 行铺满, hero 渐变数字, 统计 chips.
struct HeatmapCardView: View {
    let viewModel: HeatmapViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 格子淡入入场状态; Reduce Motion 下直接置位, 不播放动画.
    @State private var didAppear = false

    init(viewModel: HeatmapViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            heroRow
                .padding(.top, 6)
            grid
                .padding(.top, 8)
            statsRow
                .padding(.top, 6)
        }
        .onAppear {
            if reduceMotion {
                didAppear = true
            } else {
                withAnimation(.easeOut(duration: 0.35)) {
                    didAppear = true
                }
            }
        }
    }

    // MARK: 标题行

    private var titleRow: some View {
        HStack {
            Text(moduleTitle)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            Text(viewModel.captionText)
                .font(.system(size: 9.5))
                .foregroundStyle(Self.chipInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(Self.chipBackground)
                        .overlay(
                            Capsule().strokeBorder(Self.chipStroke, lineWidth: 1)
                        )
                )
        }
    }

    // MARK: hero 行

    private var heroRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(viewModel.heroText)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.adaptive(light: Color(hex: "#1c1c1e"), dark: Color(hex: "#ffffff")),
                            moduleAccent,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(viewModel.unitText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 26 x 7 热力图

    /// columns 为列优先 (每列一周); LazyVGrid 行优先填充,
    /// 因此按行展开单元格, 使每一列仍对应一周.
    private var grid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 2.5),
                count: viewModel.columns.count
            ),
            spacing: 2.5
        ) {
            ForEach(0..<7, id: \.self) { row in
                ForEach(viewModel.columns.indices, id: \.self) { column in
                    if row < viewModel.columns[column].count {
                        cellView(viewModel.columns[column][row])
                            .opacity(didAppear ? 1 : 0)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(moduleTitle), \(viewModel.heroText) \(viewModel.unitText)")
    }

    private func cellView(_ cell: HeatmapCell) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(cellColor(cell))
            .aspectRatio(1, contentMode: .fit)
    }

    // MARK: 统计 chips

    private var statsRow: some View {
        HStack(spacing: 6) {
            ForEach(viewModel.stats.chips, id: \.self) { chip in
                Text(chip)
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(Self.chipInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(Self.chipBackground)
                            .overlay(
                                Capsule().strokeBorder(Self.chipStroke, lineWidth: 1)
                            )
                    )
            }
            Spacer()
        }
    }

    // MARK: 模块配置

    /// chips 与账号胶囊的文字色: 浅色为 mockup 的 #3c3c43 80%, 深色为白 80%.
    private static let chipInk = Color.adaptive(
        light: Color(hex: "#3c3c43").opacity(0.8),
        dark: Color.white.opacity(0.8)
    )
    /// chips 底色: 浅色半透明白, 深色退化为低透明白.
    private static let chipBackground = Color.adaptive(
        light: Color.white.opacity(0.55),
        dark: Color.white.opacity(0.12)
    )
    private static let chipStroke = Color.adaptive(
        light: Color.white.opacity(0.65),
        dark: Color.white.opacity(0.2)
    )

    private var isGitLab: Bool {
        viewModel.module == .gitlab
    }

    private var moduleTitle: String {
        isGitLab ? "GitLab 动态" : "GitHub 贡献"
    }

    /// hero 渐变终点色: github 主绿 / gitlab 主橙; 深色下用各自的浅阶保证可见.
    private var moduleAccent: Color {
        Color.adaptive(
            light: Color(hex: isGitLab ? "#e8590c" : "#30a14e"),
            dark: Color(hex: isGitLab ? "#f69546" : "#40c463")
        )
    }

    /// 强度 1...4 色阶; 0 级与占位格单独处理.
    private var intensityPalette: [Color] {
        if isGitLab {
            return [
                Color(hex: "#fcceb0"),
                Color(hex: "#f69546"),
                Color(hex: "#e8590c"),
                Color(hex: "#a8500a"),
            ]
        }
        return [
            Color(hex: "#9be9a8"),
            Color(hex: "#40c463"),
            Color(hex: "#30a14e"),
            Color(hex: "#216e39"),
        ]
    }

    private func cellColor(_ cell: HeatmapCell) -> Color {
        // 周对齐补位格: 半透明灰白, 深色下退化为低透明白.
        if cell.isPlaceholder {
            return Color.adaptive(light: Color.white.opacity(0.35), dark: Color.white.opacity(0.10))
        }
        // 0 级 (有日期无活动): mockup 的浅底色, 深色下用低透明白格.
        if cell.intensity <= 0 {
            return Color.adaptive(
                light: Color(hex: isGitLab ? "#f3ece6" : "#ebedf0"),
                dark: Color.white.opacity(0.08)
            )
        }
        return intensityPalette[min(cell.intensity, 4) - 1]
    }
}

// MARK: - hex 颜色

private extension Color {
    /// 仅本组件使用的小工具, 不改共享文件.
    init(hex: String) {
        var value = hex
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        var rgb: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }

    /// 深浅色自适应: 浅色外观用 light, 深色外观用 dark.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

// MARK: - 预览

// 命令行 swift build 无法解析 #Preview 宏插件 (PreviewsMacros),
// 这里用 PreviewProvider, Xcode 画布同样可直接预览.
struct HeatmapCardView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            HeatmapCardView(viewModel: HeatmapCardPreviewFixtures.github)
                .padding(15)
                .frame(width: 400)
                .background(Color(hex: "#dce8f2"))
                .previewDisplayName("GitHub")

            HeatmapCardView(viewModel: HeatmapCardPreviewFixtures.gitlab)
                .padding(15)
                .frame(width: 400)
                .background(Color(hex: "#e9e4ef"))
                .previewDisplayName("GitLab")
        }
    }
}

/// 预览 fixture: 26 周, 强度随机分布, 首列上半与整段早期为占位格,
/// 覆盖 placeholder / 0 级 / 1-4 级全部色阶.
private enum HeatmapCardPreviewFixtures {
    static let github = HeatmapViewModel(
        module: .github,
        heroTotal: 42,
        unitText: "次贡献 · 近一年",
        captionText: "@ fixture-user",
        columns: makeColumns(seed: 7),
        stats: HeatmapStats(today: 3, currentStreak: 4, longestStreak: 9, bestDayCount: 8)
    )

    static let gitlab = HeatmapViewModel(
        module: .gitlab,
        heroTotal: 31,
        unitText: "次动态 · 近一年",
        captionText: "gitlab.example.com",
        columns: makeColumns(seed: 13),
        stats: HeatmapStats(today: 2, currentStreak: 3, longestStreak: 7, bestDayCount: 7)
    )

    private static func makeColumns(seed: Int) -> [[HeatmapCell]] {
        (0..<26).map { column in
            (0..<7).map { row in
                // 前两列留占位, 模拟周对齐补位.
                if column < 2 && row < 3 {
                    return HeatmapCell(date: "", count: 0, intensity: 0, isPlaceholder: true)
                }
                let value = (column * 31 + row * 17 + seed) % 6
                let intensity = value == 5 ? 0 : value
                return HeatmapCell(
                    date: "2026-05-\(String(format: "%02d", row + 1))",
                    count: intensity * 2,
                    intensity: intensity,
                    isPlaceholder: false
                )
            }
        }
    }
}
