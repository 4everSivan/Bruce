import Foundation
import BruceOnboardingCore

// MARK: - 模型价格表同步表现层 (09-模型价格表远端同步 §4.2 R5, 双端对拍同源)

/// 价格表卡固定文案. 字面量受 tests/fixtures/pricing-sync-parity/cases.json 约束, 与 Windows 对齐.
package enum PricingCopy {
    package static let caption = "模型价格表"
    package static let autoSyncTitle = "自动同步价格表"
    package static let autoSyncSubtitle = "启动 30 秒后静默同步一次, 之后每 24 小时一次; 同步失败不打扰"
    package static let currentCatalogTitle = "当前价格表"
    package static let syncCatalogTitle = "同步价格表"
    package static let syncButton = "同步更新"
    package static let restoreButton = "恢复内置"
    package static let syncingText = "正在从 GitHub 同步模型价格表…"
    package static let failedTitle = "同步失败"
    package static let retry = "重试"
}

/// 同步失败原因分类 (09 §4.2 R5.3).
package enum PricingSyncFailureReason: Equatable, Sendable {
    case timeout
    case offline
    case httpError(statusCode: Int)
    case invalidCatalog
    case staleVersion

    package var detail: String {
        switch self {
        case .timeout:
            return "无法访问 GitHub (超时 10 秒);当前继续使用本地价格表"
        case .offline:
            return "无法访问 GitHub (网络不可用);当前继续使用本地价格表"
        case .httpError(let code):
            return "无法获取价格表 (HTTP \(code));当前继续使用本地价格表"
        case .invalidCatalog:
            return "远端价格表格式无法识别;已拒绝覆盖本地价格表"
        case .staleVersion:
            return "远端价格表版本低于本地基线;已保留当前价格表"
        }
    }

    package var statusLine: String {
        switch self {
        case .timeout:
            return "同步价格表失败：网络超时"
        case .offline:
            return "同步价格表失败：网络不可用"
        case .httpError(let code):
            return "同步价格表失败：HTTP \(code)"
        case .invalidCatalog:
            return "同步价格表失败：价格表格式无效"
        case .staleVersion:
            return "同步价格表失败：远端版本过期"
        }
    }
}

/// 底部状态区阶段 (09 §4.2 R5.2).
package enum PricingSyncStage: Equatable, Sendable {
    case idle
    case syncing
    case upToDate(updatedAt: String, modelCount: Int)
    case updated(updatedAt: String, modelCount: Int, addedCount: Int, adjustedCount: Int)
    case restored(updatedAt: String, modelCount: Int)
    case failed(reason: PricingSyncFailureReason)
}

/// 状态区渲染模型.
package enum PricingStageDisplay: Equatable, Sendable {
    case hidden
    case spinner(text: String)
    case confirmation(text: String)
    case failure(title: String, detail: String, statusLine: String)
}

package enum PricingCatalogPresentation {

    /// 「当前价格表」副标题: `内置基线 · 86 款模型` / `GitHub 已同步 · 89 款模型`.
    package static func currentCatalogSubtitle(
        source: PricingCatalogSource,
        modelCount: Int
    ) -> String {
        switch source {
        case .builtin:
            return "内置基线 · \(modelCount) 款模型"
        case .synced:
            return "GitHub 已同步 · \(modelCount) 款模型"
        }
    }

    /// 「同步价格表」副标题: `上次同步 今天 14:02` / `上次同步 M月d日 HH:mm`; 从未同步为 `上次同步 —`.
    package static func lastSyncSubtitle(
        _ lastSyncAt: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        guard let lastSyncAt else { return "上次同步 —" }
        return "上次同步 " + timestamp(lastSyncAt, now: now, calendar: calendar)
    }

    /// 同日 `今天 HH:mm`, 跨天 `M月d日 HH:mm` (24 小时制).
    package static func timestamp(_ date: Date, now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(clock)"
        }
        return "\(parts.month ?? 0)月\(parts.day ?? 0)日 \(clock)"
    }

    /// 状态区呈现映射.
    package static func stageDisplay(for stage: PricingSyncStage) -> PricingStageDisplay {
        switch stage {
        case .idle:
            return .hidden
        case .syncing:
            return .spinner(text: PricingCopy.syncingText)
        case .upToDate(let updatedAt, let count):
            return .confirmation(text: "已是最新价格表 · \(updatedAt) (\(count) 款模型)")
        case .updated(let updatedAt, let count, let added, let adjusted):
            let diff: String
            if added > 0 && adjusted > 0 {
                diff = " (新增 \(added) 款 / 调价 \(adjusted) 款)"
            } else if added > 0 {
                diff = " (新增 \(added) 款)"
            } else if adjusted > 0 {
                diff = " (调价 \(adjusted) 款)"
            } else {
                diff = ""
            }
            return .confirmation(text: "已更新至 \(updatedAt) · 共 \(count) 款模型\(diff)")
        case .restored(let updatedAt, let count):
            return .confirmation(text: "已恢复为内置基准价格表 · \(updatedAt) (\(count) 款模型)")
        case .failed(let reason):
            return .failure(
                title: PricingCopy.failedTitle,
                detail: reason.detail,
                statusLine: reason.statusLine
            )
        }
    }

    /// 「同步更新」按钮是否可用 (仅在 syncing 时禁用).
    package static func isSyncButtonEnabled(for stage: PricingSyncStage) -> Bool {
        stage != .syncing
    }

    /// 「恢复内置」按钮是否可用 (仅在 syncing 时禁用).
    package static func isRestoreButtonEnabled(for stage: PricingSyncStage) -> Bool {
        stage != .syncing
    }
}
