import Foundation
import BruceOnboardingCore

// MARK: - 首次启动欢迎与三步引导向导表现层 (10-首次启动欢迎与引导向导 §4.2, 双端对拍同源)

/// 欢迎向导固定文案与步骤定义. 字面量受 tests/fixtures/welcome-onboarding-parity/cases.json 约束, 与 Windows 对齐.
package enum WelcomeCopy {
    package static let windowTitle = "欢迎使用 Bruce"
    package static let brandSubtitle = "LOCAL-FIRST"
    package static let privacyTitle = "100% 本地只读闭环"
    package static let privacyBody = "不代理对话流量、不修改外部会话数据库（SQLite 强制 mode=ro），凭据以 POSIX 0600 权限保存在本机目录。"

    package static let step1NavTitle = "环境扫描与启用"
    package static let step1NavSubtitle = "自动探测本机 Agent 目录"
    package static let step2NavTitle = "订阅额度连接"
    package static let step2NavSubtitle = "可选 · 一键导入或稍后配置"
    package static let step3NavTitle = "外观与快捷唤出"
    package static let step3NavSubtitle = "菜单栏预览 · 主题与快捷键"

    package static let step1Eyebrow = "STEP 01 · WELCOME & LOCAL SCAN"
    package static let step1Title = "欢迎使用 Bruce"
    package static let step1Description = "Bruce 已在后台完成本机只读探测。点击下方主按钮即可一步开启本地 Token 与费用统计，无需逐项翻找设置。"
    package static let step1SectionTitle = "本机 AI Agent 会话源（只读扫描）"
    package static let step1RescanButton = "重新扫描"
    package static let step1ConsentTitle = "一步启用：本地会话统计 + 本机 0600 凭据存储"
    package static let step1ConsentBody = "只读扫描已发现的 Agent 目录与 CC Switch 数据库（每 30 分钟自动刷新）；订阅凭据统一保存在本机受保护文件（权限 0600），彻底告别系统钥匙串频繁弹窗。可随时在「设置 → 授权与隐私」撤销。"
    package static let step1PrimaryButton = "启用本地统计并继续 →"

    package static let step2Eyebrow = "STEP 02 · SUBSCRIPTION QUOTA"
    package static let step2OptionalBadge = "可选步骤 · 可随时跳过"
    package static let step2Title = "连接云端订阅额度"
    package static let step2Description = "监控 5 小时滑动窗、周限额与 API 余额预警。若本机已登录 CLI 或 CC Switch，可直接一键只读导入；也可跳过此步，先看本地 Token 统计。"
    package static let step2DiscoveryTitle = "发现本机已登录凭据（免填 Key 一键导入）"
    package static let step2ImportButton = "一键只读导入"
    package static let step2ImportedBadge = "✓ 已导入"
    package static let step2ProvidersSectionTitle = "支持的服务商（10 家）· 也可在「设置 → 订阅额度」随时添加"
    package static let step2BackButton = "← 上一步"
    package static let step2SkipButton = "稍后在设置中配置"
    package static let step2NextButton = "继续 →"

    package static let step3Eyebrow = "STEP 03 · APPEARANCE & SHORTCUT"
    package static let step3Title = "定制你的菜单栏看板"
    package static let step3Description = "完成最后一步外观与热键偏好，点击「完成并打开看板」即刻在菜单栏展开实时监控。"
    package static let step3RingOuterTitle = "外母环 · 全局平均剩余额度"
    package static let step3RingOuterSubtitle = "≥30% 翡翠绿 · 15~30% 琥珀黄 · <15% 警示红"
    package static let step3RingInnerTitle = "内子环 · 最紧缺窗口短板预警"
    package static let step3RingInnerSubtitle = "防止长周期充裕掩盖 5h 窗口即将耗尽的断流风险"
    package static let step3FinishButton = "完成并打开看板 ↵"

    package static let settingsRowTitle = "欢迎与使用引导"
    package static let settingsRowSubtitle = "重新查看三步快速上手向导、本机 Agent 扫描状态与菜单栏双环图解"
    package static let settingsReopenButton = "重新打开欢迎向导"
}

/// 欢迎向导步骤定义 (1 ~ 3).
package enum WelcomeWizardStep: Int, CaseIterable, Equatable, Sendable {
    case environmentScan = 1
    case subscriptionConnect = 2
    case appearanceAndShortcut = 3

    package var navTitle: String {
        switch self {
        case .environmentScan: return WelcomeCopy.step1NavTitle
        case .subscriptionConnect: return WelcomeCopy.step2NavTitle
        case .appearanceAndShortcut: return WelcomeCopy.step3NavTitle
        }
    }

    package var navSubtitle: String {
        switch self {
        case .environmentScan: return WelcomeCopy.step1NavSubtitle
        case .subscriptionConnect: return WelcomeCopy.step2NavSubtitle
        case .appearanceAndShortcut: return WelcomeCopy.step3NavSubtitle
        }
    }
}

/// 双端同源的欢迎向导纯函数表现层 (10-首次启动欢迎与引导向导 §4.2).
package enum WelcomeOnboardingPresentation {

    /// 首启判定纯函数 (与 OnboardingConfiguration.shouldPresentWelcomeOnStartup 同构, 供双端对拍).
    package static func shouldPresentWelcome(
        welcomeCompletedVersion: Int?,
        consentConfirmed: Bool,
        keychainAccessConfigured: Bool
    ) -> Bool {
        if let completed = welcomeCompletedVersion,
           completed >= OnboardingConfiguration.currentWelcomeVersion {
            return false
        }
        if (welcomeCompletedVersion == nil || welcomeCompletedVersion == 0),
           consentConfirmed,
           keychainAccessConfigured {
            return false
        }
        return true
    }

    /// Step 1 就绪源计数胶囊文案.
    package static func readySourcesSummary(readyCount: Int) -> String {
        if readyCount > 0 {
            return "已发现 \(readyCount) 个就绪源"
        }
        return "暂未发现活跃源（仍可启用）"
    }

    /// Step 3 菜单栏预览条指标读数文案 (联动 Nothing 主题斜杠与纯图标开关).
    package static func menuBarPreviewMetricsText(
        isNothingTheme: Bool,
        iconOnly: Bool
    ) -> String {
        if iconOnly {
            return ""
        }
        if isNothingTheme {
            return "68% / 124K / $1.28"
        }
        return "68%  124K  $1.28"
    }
}
