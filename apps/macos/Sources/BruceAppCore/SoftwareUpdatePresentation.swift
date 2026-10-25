import Foundation

// MARK: - 软件更新卡呈现 (07-软件更新 §4.2 R3 / R4, 逐字对齐 demo)

/// 卡内与状态区的固定文案. 字面量以
/// apps/win/demo/win-settings-update-flow-demo.html 为准 (含半角 , ; 与全角 ：),
/// 双端经 tests/fixtures/update-copy-parity/cases.json 对拍, 改动须同步 fixture 与 Windows.
package enum UpdateCopy {
    package static let caption = "软件更新"
    package static let autoCheckTitle = "自动检查更新"
    package static let autoCheckSubtitle = "启动 30 秒后静默检查一次, 之后每 24 小时一次; 检查失败不打扰"
    package static let toggleOn = "已开启"
    package static let toggleOff = "已关闭"
    package static let currentVersionTitle = "当前版本"
    package static let releaseChannelSubtitle = "正式版 · 从 GitHub Releases 检查 (\(UpdateRepository.slug))"
    /// dev 构建降级 (07 §4.2 R2).
    package static let devVersionValue = "开发版本"
    package static let devChannelSubtitle = "以 Release 构建安装后可用应用内更新"
    package static let checkTitle = "检查更新"
    package static let checkButton = "检查更新"
    package static let navigationBadge = "有可用更新"

    package static let checking = "正在检查更新…"
    package static let bannerTitle = "发现新版本"
    package static let expandNotes = " 展开"
    package static let collapseNotes = " 收起"
    package static let failedTitle = "检查失败"
    package static let relaunching = "正在安装并重启…"
    /// 非用户可写位置降级引导 (07 §4.2 R6.4).
    package static let manualInstallHint = "当前安装位置不支持自动更新, 请从发布页下载新版本"
}

/// 状态区按钮; 标题逐字对齐 demo, 角色决定 primary / 普通 / link 样式.
package enum UpdateStageAction: String, Equatable, Sendable, CaseIterable {
    case downloadAndInstall
    case skipVersion
    case openReleasePage
    case cancelDownload
    case installAndRelaunch
    case later
    case retry
    case manualDownload
    case resumeChecks

    package enum Role: Sendable {
        case primary, plain, link
    }

    package var title: String {
        switch self {
        case .downloadAndInstall: return "下载并安装"
        case .skipVersion: return "跳过此版本"
        case .openReleasePage: return "查看发布页 ↗"
        case .cancelDownload: return "取消"
        case .installAndRelaunch: return "安装并重启"
        case .later: return "稍后"
        case .retry: return "重试"
        case .manualDownload: return "手动下载 ↗"
        case .resumeChecks: return "恢复检查"
        }
    }

    package var role: Role {
        switch self {
        case .downloadAndInstall, .installAndRelaunch: return .primary
        case .skipVersion: return .plain
        case .openReleasePage, .cancelDownload, .later, .retry, .manualDownload, .resumeChecks:
            return .link
        }
    }
}

/// 「发现新版本」横幅 (update-banner).
package struct UpdateBannerContent: Equatable, Sendable {
    package let title: String
    package let fromVersion: String
    package let toVersion: String
    /// 收起态: 前 2 条要点 (demo 取 notes 前 2 行).
    package let collapsedNotes: String
    /// 展开态全文.
    package let fullNotes: String
    /// 要点多于 2 条时才出现「展开 / 收起」.
    package let notesTruncated: Bool
    package let sizeText: String?
    package let actions: [UpdateStageAction]
    /// 不能自替换时的引导文案; 可自替换为 nil.
    package let hint: String?
}

/// 状态区内容 (update-stage); `hidden` 对应 demo `:empty { display: none }`.
package enum UpdateStageContent: Equatable, Sendable {
    case hidden
    /// spinner + 文案 (checking / relaunching).
    case spinner(text: String)
    /// ✓ + 文案 (latest).
    case confirmation(text: String)
    case banner(UpdateBannerContent)
    case download(fraction: Double, meta: String, actions: [UpdateStageAction])
    /// ✓ + 文案 + 动作行 (ready).
    case ready(text: String, actions: [UpdateStageAction])
    /// warn 色标题 + 说明 + link 动作 (failed).
    case failure(title: String, detail: String, actions: [UpdateStageAction])
    case skipped(text: String, actions: [UpdateStageAction])
}

package enum UpdatePresentation {
    // MARK: 行文案

    /// 「当前版本」行: 值 + 副标题; 无合法 bundle 版本时走 dev 降级.
    package static func currentVersion(
        _ localVersion: SemanticVersion?
    ) -> (value: String, subtitle: String) {
        guard let localVersion else {
            return (UpdateCopy.devVersionValue, UpdateCopy.devChannelSubtitle)
        }
        return (localVersion.tag, UpdateCopy.releaseChannelSubtitle)
    }

    /// 「检查更新」行副标题: `上次检查 今天 HH:mm` / `上次检查 M月d日 HH:mm`; 从未成功检查为 `上次检查 —`.
    package static func lastCheckSubtitle(
        _ lastCheckAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> String {
        guard let lastCheckAt else { return "上次检查 —" }
        return "上次检查 " + timestamp(lastCheckAt, now: now, calendar: calendar)
    }

    /// 同日 `今天 HH:mm`, 跨天 `M月d日 HH:mm` (24 小时制, 不随系统 12 小时制漂移).
    package static func timestamp(_ date: Date, now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(clock)"
        }
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日 \(clock)"
    }

    /// 十进制 MB 一位小数 (与 Finder 同口径).
    package static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(max(bytes, 0)) / 1_000_000)
    }

    /// 下载进度元信息: `3.2 / 7.1 MB · 45%`; 总量未知时只显示已下载 `3.2 MB`.
    package static func downloadMeta(_ progress: UpdateDownloadProgress) -> String {
        guard let total = progress.totalBytes, total > 0 else {
            return "\(megabytes(progress.receivedBytes)) MB"
        }
        let percent = Int((downloadFraction(progress) * 100).rounded(.down))
        return "\(megabytes(progress.receivedBytes)) / \(megabytes(total)) MB · \(percent)%"
    }

    package static func downloadFraction(_ progress: UpdateDownloadProgress) -> Double {
        guard let total = progress.totalBytes, total > 0 else { return 0 }
        return min(max(Double(progress.receivedBytes) / Double(total), 0), 1)
    }

    /// 更新说明要点: 清单 notes 为「; 」连接的纯文本 (T09 生成器), demo 为换行分隔, 两者都识别.
    package static func noteItems(_ notes: String) -> (items: [String], separator: String) {
        let separator = notes.contains("\n") ? "\n" : "; "
        let items = notes
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // 换行形态在 demo 中以空格拼接为单段.
        return (items, separator == "\n" ? " " : "; ")
    }

    // MARK: 状态区

    package static func stage(
        for phase: UpdatePhase,
        localVersion: SemanticVersion?,
        canSelfInstall: Bool,
        now: Date,
        calendar: Calendar
    ) -> UpdateStageContent {
        switch phase {
        case .idle:
            return .hidden
        case .checking:
            return .spinner(text: UpdateCopy.checking)
        case .latest(let checkedAt):
            return .confirmation(
                text: "已是最新版本 · 检查于 " + timestamp(checkedAt, now: now, calendar: calendar)
            )
        case .available(let release):
            return .banner(banner(
                release: release,
                localVersion: localVersion,
                canSelfInstall: canSelfInstall
            ))
        case .downloading(_, let progress):
            return .download(
                fraction: downloadFraction(progress),
                meta: downloadMeta(progress),
                actions: [.cancelDownload]
            )
        case .ready(let release):
            return .ready(
                text: "\(release.version.tag) 已下载完成,重启后生效",
                actions: [.installAndRelaunch, .later]
            )
        case .failed(let failure):
            return .failure(
                title: UpdateCopy.failedTitle,
                detail: failure.detail,
                actions: [.retry, .manualDownload]
            )
        case .skipped(let release):
            return .skipped(
                text: "已跳过 \(release.version.tag);发布下个版本前不再提醒 · ",
                actions: [.resumeChecks]
            )
        case .relaunching:
            return .spinner(text: UpdateCopy.relaunching)
        }
    }

    package static func banner(
        release: UpdateRelease,
        localVersion: SemanticVersion?,
        canSelfInstall: Bool
    ) -> UpdateBannerContent {
        let (items, joiner) = noteItems(release.notes)
        let actions: [UpdateStageAction] = canSelfInstall
            ? [.downloadAndInstall, .skipVersion, .openReleasePage]
            : [.skipVersion, .openReleasePage]
        return UpdateBannerContent(
            title: UpdateCopy.bannerTitle,
            fromVersion: localVersion?.tag ?? UpdateCopy.devVersionValue,
            toVersion: release.version.tag,
            collapsedNotes: items.prefix(2).joined(separator: joiner),
            fullNotes: items.joined(separator: joiner),
            notesTruncated: items.count > 2,
            sizeText: release.sizeBytes.map { "\(megabytes($0)) MB" },
            actions: actions,
            hint: canSelfInstall ? nil : UpdateCopy.manualInstallHint
        )
    }
}

// MARK: - 失败文案

extension UpdateCheckFailure {
    /// 状态区说明行; 超时为 demo 原文, 其余分类沿用同一句式.
    package var detail: String {
        switch self {
        case .timedOut:
            return "无法访问 GitHub (超时 10 秒);可稍后重试或手动下载"
        case .offline:
            return "无法访问 GitHub (网络不可用);可稍后重试或手动下载"
        case .httpStatus(let code):
            return "无法获取更新信息 (HTTP \(code));可稍后重试或手动下载"
        case .invalidManifest:
            return "更新信息无法识别;可稍后重试或手动下载"
        }
    }

    /// 设置窗口顶部状态行 (settings-status warn).
    package var statusLine: String {
        switch self {
        case .timedOut: return "检查更新失败：网络超时"
        case .offline: return "检查更新失败：网络不可用"
        case .httpStatus(let code): return "检查更新失败：HTTP \(code)"
        case .invalidManifest: return "检查更新失败：更新信息无效"
        }
    }
}

extension UpdateInstallFailure {
    /// 下载 / 校验 / 替换失败的状态行告警; 校验类一律说明已拒绝安装.
    package var statusLine: String {
        switch self {
        case .downloadFailed:
            return "下载更新失败：网络错误, 可稍后重试"
        case .checksumMismatch:
            return "更新包校验失败：SHA256 不一致, 已拒绝安装"
        case .extractFailed:
            return "更新包校验失败：无法解压, 已拒绝安装"
        case .bundleMismatch:
            return "更新包校验失败：应用标识不符, 已拒绝安装"
        case .versionMismatch:
            return "更新包校验失败：版本与更新信息不符, 已拒绝安装"
        case .versionNotNewer:
            return "更新包校验失败：版本未高于当前版本, 已拒绝安装"
        case .replaceFailed(rolledBack: true):
            return "安装更新失败：已恢复原版本"
        case .replaceFailed(rolledBack: false):
            return "安装更新失败：原版本恢复失败, 请从发布页重新安装"
        case .relaunchFailed:
            return "新版本已安装, 自动重启失败, 请手动重新打开 Bruce"
        }
    }
}
