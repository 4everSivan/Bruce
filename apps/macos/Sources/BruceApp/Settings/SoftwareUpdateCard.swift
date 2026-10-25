import AppKit
import BruceAppCore
import SwiftUI

// MARK: - 维护页「软件更新」卡 (07-软件更新 §4.2 R3 / R4, 方案 B)

/// demo PART U 新增 token; 其余取自 SettingsDemoTokens.
private enum UpdateCardTokens {
    /// --accent #0a84ff (进度条填充、横幅底与描边的基色).
    static let accent = Color(hex: "0A84FF")
    /// --accent-soft rgba(10,132,255,.14).
    static let bannerFill = accent.opacity(0.14)
    /// 横幅描边 rgba(10,132,255,.45).
    static let bannerBorder = accent.opacity(0.45)
    /// --meter-track rgba(255,255,255,.12).
    static let meterTrack = Color.adaptive(
        light: Color.black.opacity(0.10),
        dark: Color.white.opacity(0.12)
    )
    /// .ok-tick #5ec273.
    static let okTick = Color(hex: "5EC273")
    /// .ver-flow .from 删除线 rgba(255,255,255,.35).
    static let strikethrough = Color.adaptive(
        light: Color.black.opacity(0.35),
        dark: Color.white.opacity(0.35)
    )
    static let notesToggleURL = URL(string: "bruce-update:toggle-notes")!
}

/// 三行 (自动检查 / 当前版本 / 检查更新) + 底部状态区 (update-stage).
struct SoftwareUpdateCard: View {
    @EnvironmentObject var updates: SoftwareUpdateService
    @State private var notesExpanded = false

    var body: some View {
        // 「今天 HH:mm」跨午夜要变成日期, 按分钟重绘.
        TimelineView(.everyMinute) { context in
            card(now: context.date)
        }
    }

    private func card(now: Date) -> some View {
        let version = UpdatePresentation.currentVersion(updates.localVersion)
        return FluentCard {
            FluentRow(UpdateCopy.autoCheckTitle, sub: UpdateCopy.autoCheckSubtitle) {
                HStack(spacing: 8) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { updates.autoCheckEnabled },
                            set: { updates.setAutoCheckEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    Text(updates.autoCheckEnabled ? UpdateCopy.toggleOn : UpdateCopy.toggleOff)
                        .font(.system(size: 12.5))
                        .foregroundStyle(
                            updates.autoCheckEnabled ? SettingsDemoTokens.ok : SettingsDemoTokens.text3
                        )
                }
            }
            FluentRow(UpdateCopy.currentVersionTitle, sub: version.subtitle, divided: true) {
                Text(version.value)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.text2)
            }
            FluentRow(
                UpdateCopy.checkTitle,
                sub: UpdatePresentation.lastCheckSubtitle(
                    updates.lastCheckAt,
                    now: now,
                    calendar: .current
                ),
                divided: true
            ) {
                Button(UpdateCopy.checkButton) {
                    Task { await updates.checkNow() }
                }
                .fluentButton()
                .disabled(updates.isDevelopmentBuild || !updates.phase.allowsManualCheck)
            }
            stage(now: now)
        }
    }

    // MARK: 状态区

    @ViewBuilder
    private func stage(now: Date) -> some View {
        let content = UpdatePresentation.stage(
            for: updates.phase,
            localVersion: updates.localVersion,
            canSelfInstall: updates.canSelfInstall,
            now: now,
            calendar: .current
        )
        if content != .hidden {
            stageBody(content)
                .font(.system(size: 12))
                .foregroundStyle(SettingsDemoTokens.text2)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    SettingsDemoTokens.separator.frame(height: 1)
                }
        }
    }

    @ViewBuilder
    private func stageBody(_ content: UpdateStageContent) -> some View {
        switch content {
        case .hidden:
            EmptyView()
        case .spinner(let text):
            HStack(spacing: 8) {
                UpdateSpinner()
                Text(text)
            }
        case .confirmation(let text):
            HStack(spacing: 8) {
                okTick
                Text(text)
            }
        case .banner(let banner):
            bannerView(banner)
        case .download(let fraction, let meta, let actions):
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        UpdateCardTokens.meterTrack
                        UpdateCardTokens.accent
                            .frame(width: proxy.size.width * fraction)
                            .animation(.easeOut(duration: 0.3), value: fraction)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                }
                .frame(height: 4)
                HStack(spacing: 10) {
                    Text(meta)
                        .font(.system(size: 11.5, design: .monospaced))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    actionButtons(actions)
                }
            }
        case .ready(let text, let actions):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    okTick
                    Text(text)
                }
                HStack(spacing: 10) {
                    actionButtons(actions)
                }
            }
        case .failure(let title, let detail, let actions):
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(SettingsDemoTokens.warn)
                Text(detail)
                actionButtons(actions)
            }
        case .skipped(let text, let actions):
            HStack(spacing: 8) {
                Text(text)
                actionButtons(actions)
            }
        }
    }

    private var okTick: some View {
        Text("✓")
            .fontWeight(.semibold)
            .foregroundStyle(UpdateCardTokens.okTick)
    }

    // MARK: 横幅

    private func bannerView(_ banner: UpdateBannerContent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(banner.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                HStack(spacing: 5) {
                    Text(banner.fromVersion)
                        .foregroundStyle(SettingsDemoTokens.text3)
                        .strikethrough(color: UpdateCardTokens.strikethrough)
                    Text("→")
                        .fontWeight(.semibold)
                        .foregroundStyle(SettingsDemoTokens.accent)
                    Text(banner.toVersion)
                        .fontWeight(.semibold)
                        .foregroundStyle(SettingsDemoTokens.text)
                }
                .font(.system(size: 11.5, design: .monospaced))
            }
            .padding(.bottom, 6)
            if !banner.fullNotes.isEmpty {
                notesText(banner)
                    .padding(.bottom, 4)
            }
            HStack(spacing: 10) {
                actionButtons(banner.actions)
                if let size = banner.sizeText {
                    Text(size)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }
            }
            .padding(.top, 6)
            if let hint = banner.hint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UpdateCardTokens.bannerFill,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(UpdateCardTokens.bannerBorder, lineWidth: 1)
        )
    }

    /// 更新说明: 收起态前 2 条, 尾随行内 accent「展开 / 收起」(demo .update-notes .more).
    private func notesText(_ banner: UpdateBannerContent) -> some View {
        var text = AttributedString(notesExpanded ? banner.fullNotes : banner.collapsedNotes)
        if banner.notesTruncated {
            var toggle = AttributedString(
                notesExpanded ? UpdateCopy.collapseNotes : UpdateCopy.expandNotes
            )
            toggle.link = UpdateCardTokens.notesToggleURL
            text += toggle
        }
        return Text(text)
            .font(.system(size: 11.5))
            .lineSpacing(3)
            .tint(SettingsDemoTokens.accent)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url == UpdateCardTokens.notesToggleURL else { return .systemAction }
                notesExpanded.toggle()
                return .handled
            })
    }

    // MARK: 动作

    private func actionButtons(_ actions: [UpdateStageAction]) -> some View {
        ForEach(actions, id: \.self) { action in
            Button(action.title) {
                perform(action)
            }
            .fluentButton(buttonRole(action.role))
        }
    }

    private func buttonRole(_ role: UpdateStageAction.Role) -> FluentButtonRole {
        switch role {
        case .primary: return .primary
        case .plain: return .plain
        case .link: return .link
        }
    }

    private func perform(_ action: UpdateStageAction) {
        switch action {
        case .downloadAndInstall:
            updates.startDownload()
        case .skipVersion:
            notesExpanded = false
            updates.skipCurrentVersion()
        case .openReleasePage:
            if case .available(let release) = updates.phase {
                NSWorkspace.shared.open(release.releasePageURL)
            }
        case .cancelDownload:
            updates.cancelDownload()
        case .installAndRelaunch:
            updates.installAndRelaunch()
        case .later:
            updates.postponeInstall()
        case .retry:
            Task { await updates.checkNow() }
        case .manualDownload:
            NSWorkspace.shared.open(UpdateRepository.latestReleasePageURL)
        case .resumeChecks:
            updates.resumeSkippedVersion()
        }
    }
}

// MARK: - 导航角标 (demo .nav-dot)

/// 6pt settings-accent 圆点 + 发光 (box-shadow 0 0 6px rgba(76,156,255,.8)).
struct SoftwareUpdateNavigationBadge: View {
    var body: some View {
        Circle()
            .fill(SettingsDemoTokens.accent)
            .frame(width: 6, height: 6)
            .shadow(color: Color(hex: "4C9CFF").opacity(0.8), radius: 3)
            .help(UpdateCopy.navigationBadge)
            .accessibilityLabel(UpdateCopy.navigationBadge)
    }
}

// MARK: - spinner (demo .update-spinner)

/// 12pt 圆环: meter-track 底环 + settings-accent 顶部弧, 0.8 秒一圈.
private struct UpdateSpinner: View {
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(UpdateCardTokens.meterTrack, lineWidth: 2)
            Circle()
                .inset(by: 1)
                .trim(from: 0, to: 0.25)
                .stroke(SettingsDemoTokens.accent, lineWidth: 2)
                .rotationEffect(.degrees(-135))
        }
        .frame(width: 12, height: 12)
        .rotationEffect(.degrees(spinning ? 360 : 0))
        .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
        .onAppear { spinning = true }
        .accessibilityHidden(true)
    }
}
