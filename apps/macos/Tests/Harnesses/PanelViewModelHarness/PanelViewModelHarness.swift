import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import BruceAppCore
import BruceOnboardingCore

private enum PanelTestFailure: Error, CustomStringConvertible {
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
        throw PanelTestFailure.expectation(message)
    }
}

// MARK: - Fixture 构造 (内嵌, 不读真实 data/)

private let fixedNow: Date = ISO8601DateFormatter()
    .date(from: "2026-07-30T14:00:00+00:00")! // swiftlint:disable:this force_unwrap

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private let dayList: [String] = (0..<14).reversed().map { offset in
    let date = fixedNow.addingTimeInterval(TimeInterval(-offset * 86400))
    let formatter = DateFormatter()
    formatter.calendar = utcCalendar
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func makeBucket(
    input: Int = 0,
    output: Int = 0,
    cacheRead: Int = 0,
    cacheCreation: Int = 0
) -> AgentTokenBucket {
    AgentTokenBucket(
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheCreation: cacheCreation,
        total: input + output + cacheRead + cacheCreation
    )
}

private func makeAgent(
    id: String,
    name: String,
    status: String = "ok",
    note: String? = nil,
    today: AgentTokenBucket = AgentTokenBucket(
        input: 0, output: 0, cacheRead: 0, cacheCreation: 0, total: 0
    ),
    dailyTotals: [Int]? = nil,
    hours: [Int] = Array(repeating: 0, count: 24),
    todayCostUsd: Double? = nil,
    models: [String: Int]? = nil,
    modelMonths: [String: [String: Int]]? = nil,
    projects: [AgentProjectUsage]? = nil
) -> AgentUsageItem {
    let totals = dailyTotals ?? Array(repeating: 0, count: 14)
    let daily = zip(dayList, totals).map { date, total in
        AgentDailyUsage(date: date, input: total, output: 0, total: total)
    }
    return AgentUsageItem(
        id: id,
        name: name,
        status: status,
        note: note,
        today: today,
        daily: daily,
        hours: hours,
        todayCostUsd: todayCostUsd,
        models: models,
        modelMonths: modelMonths,
        projects: projects
    )
}

/// 工作台 fixture (C070): 两个活跃 Agent + 一个零用量 Agent, 金额取 0.25 的倍数以免浮点噪声.
/// - Claude Code: 14 天每天 500 (原始输入 100 / 输出 50 / 缓存读 300 / 缓存写 50),
///   模型 sonnet 400 ($1.25, 省 $0.5) + 未定价 deepseek-flash 100; 今日 9 点 200、14 点 300.
/// - Codex: 仅最后 2 天每天 2000 (输入 1000 / 输出 200 / 缓存读 800), gpt-5.4 $2.0 (省 $0.75); 今日 14 点.
private func makeWorkbenchArtifact() -> AgentUsageArtifact {
    func detail(
        date: String? = nil, month: String? = nil, hour: Int? = nil, model: String,
        _ input: Int, _ output: Int, _ cacheRead: Int, _ cacheCreation: Int,
        cost: Double?, savings: Double?
    ) -> AgentModelDetail {
        AgentModelDetail(
            date: date, month: month, hour: hour, model: model,
            input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation,
            total: input + output + cacheRead + cacheCreation, costUsd: cost, cacheSavingsUsd: savings
        )
    }
    var claudeHours = Array(repeating: 0, count: 24)
    claudeHours[9] = 200
    claudeHours[14] = 300
    let claude = AgentUsageItem(
        id: "claude-code", name: "Claude Code", status: "ok", note: nil,
        today: makeBucket(input: 100, output: 50, cacheRead: 300, cacheCreation: 50),
        daily: dayList.map {
            AgentDailyUsage(date: $0, input: 450, output: 50, total: 500, cacheRead: 300, cacheCreation: 50)
        },
        hours: claudeHours, todayCostUsd: 1.25, models: nil, modelMonths: nil,
        projects: [AgentProjectUsage(name: "bruce", total: 500)],
        dailyModels: dayList.flatMap { date in [
            detail(date: date, model: "anthropic/claude-sonnet-5", 80, 40, 240, 40, cost: 1.25, savings: 0.5),
            detail(date: date, model: "deepseek-flash", 20, 10, 60, 10, cost: nil, savings: nil),
        ] },
        monthModels: [
            detail(month: "2026-07", model: "anthropic/claude-sonnet-5", 1_120, 560, 3_360, 560, cost: 17.5, savings: 7.0),
            detail(month: "2026-07", model: "deepseek-flash", 280, 140, 840, 140, cost: nil, savings: nil),
        ],
        hourModels: [
            detail(hour: 9, model: "anthropic/claude-sonnet-5", 40, 20, 120, 20, cost: 0.5, savings: 0.2),
            detail(hour: 14, model: "anthropic/claude-sonnet-5", 40, 20, 120, 20, cost: 0.75, savings: 0.3),
            detail(hour: 14, model: "deepseek-flash", 20, 10, 60, 10, cost: nil, savings: nil),
        ]
    )
    var codexHours = Array(repeating: 0, count: 24)
    codexHours[14] = 2_000
    let activeDays = Array(dayList.suffix(2))
    let codex = AgentUsageItem(
        id: "codex", name: "Codex", status: "ok", note: nil,
        today: makeBucket(input: 1_000, output: 200, cacheRead: 800),
        daily: dayList.map { date in
            activeDays.contains(date)
                ? AgentDailyUsage(date: date, input: 1_800, output: 200, total: 2_000, cacheRead: 800, cacheCreation: 0)
                : AgentDailyUsage(date: date, input: 0, output: 0, total: 0, cacheRead: 0, cacheCreation: 0)
        },
        hours: codexHours, todayCostUsd: 2.0, models: nil, modelMonths: nil, projects: nil,
        dailyModels: activeDays.map {
            detail(date: $0, model: "gpt-5.4", 1_000, 200, 800, 0, cost: 2.0, savings: 0.75)
        },
        monthModels: [detail(month: "2026-07", model: "gpt-5.4", 2_000, 400, 1_600, 0, cost: 4.0, savings: 1.5)],
        hourModels: [detail(hour: 14, model: "gpt-5.4", 1_000, 200, 800, 0, cost: 2.0, savings: 0.75)]
    )
    let idle = AgentUsageItem(
        id: "gemini-cli", name: "Gemini CLI", status: "ok", note: nil,
        today: makeBucket(),
        daily: dayList.map { AgentDailyUsage(date: $0, input: 0, output: 0, total: 0, cacheRead: 0, cacheCreation: 0) },
        hours: Array(repeating: 0, count: 24), todayCostUsd: nil, models: nil, modelMonths: nil, projects: nil,
        dailyModels: [], monthModels: [], hourModels: []
    )
    return makeAgentUsageArtifact(agents: [claude, codex, idle], services: [], totalCostUsd: 3.25)
}

private func makeWindow(
    label: String,
    usedPercent: Double,
    windowMinutes: Int? = nil,
    resetsAt: JSONValue? = nil,
    ownRow: Bool? = nil
) -> JSONValue {
    var object: [String: JSONValue] = [
        "label": .string(label),
        "usedPercent": .double(usedPercent),
    ]
    if let windowMinutes {
        object["windowMinutes"] = .integer(windowMinutes)
    } else {
        object["windowMinutes"] = .null
    }
    object["resetsAt"] = resetsAt ?? .null
    if let ownRow {
        object["ownRow"] = .boolean(ownRow)
    }
    return .object(object)
}

private func makeService(
    id: String,
    name: String,
    status: String = "ok",
    kind: String? = nil,
    windows: [JSONValue] = [],
    app: String? = nil,
    isCurrent: Bool? = nil,
    plan: String? = nil,
    balance: Double? = nil,
    currency: String? = nil,
    note: String? = nil,
    extra: String? = nil,
    capturedAt: String? = nil,
    freshness: String? = nil,
    failureKind: String? = nil
) -> AgentServiceItem {
    AgentServiceItem(
        id: id,
        name: name,
        status: status,
        windows: windows,
        app: app,
        isCurrent: isCurrent,
        kind: kind,
        plan: plan,
        balance: balance,
        currency: currency,
        note: note,
        extra: extra,
        capturedAt: capturedAt,
        freshness: freshness,
        failureKind: failureKind
    )
}

private func makeAgentUsageArtifact(
    agents: [AgentUsageItem],
    services: [AgentServiceItem],
    totalCostUsd: Double? = nil,
    generatedAt: String = "2026-07-30T13:50:00+00:00"
) -> AgentUsageArtifact {
    AgentUsageArtifact(
        schemaVersion: 1,
        module: .agentUsage,
        generatedAt: generatedAt,
        agents: agents,
        services: services,
        totalCostUsd: totalCostUsd
    )
}

private func makeMapper() -> PanelViewModelMapper {
    PanelViewModelMapper(now: { fixedNow }, calendar: utcCalendar)
}

private let readyStatuses: [DashboardModule: ModuleStatus] = [
    .agentUsage: ModuleStatus(state: .fresh, detail: nil),
]

@main
struct PanelViewModelHarness {
    @MainActor
    static func main() throws {
        try windowWordingMatrixMapsMinutes()
        try windowWordingFallsBackToKnownLabels()
        try windowWordingKeepsSuffixedWeeklyLabels()
        try ownRowFlagIsPreserved()
        try balanceSinksToBottom()
        try kimiDisabledBoosterExtraIsHidden()
        try codexAccountsGroupIntoOneSection()
        try subscriptionIsNilWhenAllPlaceholders()
        try serviceErrorKeepsNoteAndDiagnoses()
        try malformedWindowIsDroppedWithDiagnostic()
        try usageHeroAggregatesTotalsAndFormatting()
        try usageTierFollowsTotalThresholds()
        try usageHeatmapBuildsWeekGrid()
        try usageMonthlyAggregatesCalendarMonths()
        try liveStateFollowsFreshnessThreshold()
        try chartBuilds14DaysWithStableSegments()
        try legendOnlyIncludesActiveAgents()
        try hourlyRowsFilterAndShape()
        try hourlyRowsHideAgentsWithoutUsage()
        try hourlyRowsSortByTodayTotalDesc()
        try hourlyDetailAggregatesTopAndOther()
        try modelUsageBuildsTiersMonthsAndColors()
        try modelUsageHiddenWithoutMonthData()
        try nothingRampStableAndDistinctForTopAgents()
        try resetTextVariants()
        try negativeResetEpochYieldsEmptyResetText()
        try tokenAndBalanceFormatting()
        try costTextConvertsUsdToCny()
        try unknownAgentColorIsStable()
        try emptyArtifactsProduceDiagnostics()
        try subscriptionUpdatedTextFormatsGeneratedAt()
        try subscriptionUpdatedTextNilForBadDate()
        try subscriptionEmptyStatusStillRenders()
        try quota100PercentRendersNormally()
        try codexErrorShowsLastSuccessTime()
        try codexFreshnessStaleShowsLastSuccess()
        try codexFreshnessUnavailableHidesLastSuccess()
        try codexDisplayNameStripsPrefixOnly()
        try providerOrderOverridesDefaultSort()
        try providerOrderUnknownIDsGoLast()
        try providerOrderNormalizesKimiCodingID()
        try providerOrderMatchesOpenCodeGoRawValue()
        try presentationPolicyTableDrivenRules()
        try singleAccountSectionNameOmitsAccountSuffix()
        try appVersionReadsBundleAndFallsBack()
        try collapsedWeekLevelsTakesLast7Days()
        try collapsedWeekLevelsHandlesShortWindowAndZeroDays()
        try collapsedPeakWindowPicksTightestWindow()
        try collapsedPeakWindowSpansAccountsAndSkipsBalanceOnly()
        try hourlyCollapsedPointsSumWithPeakText()
        try collapseStatePersistsAcrossAppModelInstances()
        try cardCollapseAnimationStabilityContracts()
        try modelNormalizerCanonicalKeyContracts()
        try workbenchTodayRangeUsesRealBucketsContracts()
        try workbenchMultiDayRangesUseDailyDetailContracts()
        try workbenchThisMonthStopsAtMonthBoundaryContracts()
        try workbenchLegacyArtifactShowsDashesContracts()
        try billionTokenFormattingContracts()
        try subscriptionEmptyStatePolicyContracts()
        try meterMotionPolicyContracts()
        try balanceRowAmountMatchesTextContracts()
        print("PanelViewModel tests passed: 63")
    }

    // 措辞映射矩阵: windowMinutes 优先, 容差约 2%.
    private static func windowWordingMatrixMapsMinutes() throws {
        let service = makeService(
            id: "kimi",
            name: "Kimi",
            windows: [
                makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300),
                makeWindow(label: "x", usedPercent: 1, windowMinutes: 298),
                makeWindow(label: "7天窗口", usedPercent: 39, windowMinutes: 10080),
                makeWindow(label: "x", usedPercent: 1, windowMinutes: 10090),
                makeWindow(label: "每月窗口", usedPercent: 52, windowMinutes: 43200),
                makeWindow(label: "x", usedPercent: 1, windowMinutes: 43000),
                makeWindow(label: "自定义窗口", usedPercent: 7, windowMinutes: 999),
            ]
        )
        let vm = try subscriptionSections(services: [service])
        let labels = vm[0].windows.map(\.label)
        try expect(
            labels == ["每 5 小时", "每 5 小时", "每周", "每周", "每月", "每月", "自定义窗口"],
            "措辞映射矩阵失败: \(labels)"
        )
    }

    // windowMinutes 缺失时按 collector 规范 label 归一.
    private static func windowWordingFallsBackToKnownLabels() throws {
        let service = makeService(
            id: "volc",
            name: "火山引擎",
            windows: [
                makeWindow(label: "5小时窗口", usedPercent: 74),
                makeWindow(label: "7天窗口", usedPercent: 46),
                makeWindow(label: "每周窗口", usedPercent: 47),
                makeWindow(label: "每月窗口", usedPercent: 63),
                makeWindow(label: "赠送额度", usedPercent: 81),
            ]
        )
        let vm = try subscriptionSections(services: [service])
        let labels = vm[0].windows.map(\.label)
        try expect(
            labels == ["每 5 小时", "每周", "每周", "每月", "赠送额度"],
            "label 回落映射失败: \(labels)"
        )
    }

    // Claude 模型专属周窗口 (C058): 带「每周」前缀的 label 原样保留,
    // 避免总量 + Fable/Opus/Sonnet 多行被归一成同一文案; 普通 7 天窗口仍归一.
    private static func windowWordingKeepsSuffixedWeeklyLabels() throws {
        let service = makeService(
            id: "claude",
            name: "Claude",
            windows: [
                makeWindow(label: "每 5 小时", usedPercent: 68, windowMinutes: 300),
                makeWindow(label: "每周", usedPercent: 39, windowMinutes: 10080),
                makeWindow(label: "每周 Fable", usedPercent: 41, windowMinutes: 10080),
                makeWindow(label: "每周 Opus", usedPercent: 12, windowMinutes: 10090),
                makeWindow(label: "每周 Sonnet", usedPercent: 5, windowMinutes: 10080),
                makeWindow(label: "7天窗口", usedPercent: 9, windowMinutes: 10080),
            ]
        )
        let vm = try subscriptionSections(services: [service])
        let labels = vm[0].windows.map(\.label)
        try expect(
            labels == ["每 5 小时", "每周", "每周 Fable", "每周 Opus", "每周 Sonnet", "每周"],
            "模型专属周窗口文案保留失败: \(labels)"
        )
    }

    // ownRow (赠送额度单独占一行) 原样保留.
    private static func ownRowFlagIsPreserved() throws {
        let service = makeService(
            id: "kimi",
            name: "Kimi",
            windows: [
                makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300),
                makeWindow(label: "赠送额度", usedPercent: 81, ownRow: true),
            ]
        )
        let vm = try subscriptionSections(services: [service])
        try expect(vm[0].windows[0].ownRow == false, "普通窗口不应 ownRow")
        try expect(vm[0].windows[1].ownRow == true, "赠送额度 ownRow 未保留")
    }

    // kind=balance 的 DeepSeek 沉底, 左右排版数据齐全.
    private static func balanceSinksToBottom() throws {
        let deepseek = makeService(
            id: "deepseek",
            name: "DeepSeek",
            kind: "balance",
            balance: 38.21,
            currency: "CNY"
        )
        let kimi = makeService(
            id: "kimi",
            name: "Kimi",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300)]
        )
        // artifact 中 DeepSeek 在前, 映射后必须沉底.
        let vm = try subscriptionSections(services: [deepseek, kimi])
        try expect(vm.count == 2, "provider 段数量错误: \(vm.count)")
        try expect(vm[0].id == "kimi", "窗口型应在前: \(vm.map(\.id))")
        try expect(vm[1].id == "deepseek", "余额型应沉底: \(vm.map(\.id))")
        let balance = vm[1].balance
        try expect(balance?.label == "账户余额", "余额标签错误")
        try expect(balance?.amountText == "¥ 38.21", "余额文案错误: \(balance?.amountText ?? "nil")")
        try expect(vm[1].windows.isEmpty, "余额型不应有量条")
    }

    // Kimi 加量包未启用的附加文案不展示, 余额文案保留.
    private static func kimiDisabledBoosterExtraIsHidden() throws {
        let disabled = makeService(
            id: "kimi",
            name: "Kimi",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300)],
            extra: "加量包未启用"
        )
        let withBalance = makeService(
            id: "kimi2",
            name: "Kimi",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 20, windowMinutes: 300)],
            extra: "加量包余额 ¥12.00"
        )
        let vm = try subscriptionSections(services: [disabled, withBalance])
        try expect(vm[0].extraText == nil, "加量包未启用应隐藏: \(vm[0].extraText ?? "nil")")
        try expect(vm[1].extraText == "加量包余额 ¥12.00", "余额文案应保留: \(vm[1].extraText ?? "nil")")
    }

    // app=="codex" 的多账号分组成一张卡内多个账号子卡.
    private static func codexAccountsGroupIntoOneSection() throws {
        let personal = makeService(
            id: "codex_abcd1234",
            name: "Codex · sivan",
            windows: [
                makeWindow(label: "5小时窗口", usedPercent: 57, windowMinutes: 300),
                makeWindow(label: "每周窗口", usedPercent: 8, windowMinutes: 10080),
            ],
            app: "codex",
            isCurrent: true,
            plan: "plus"
        )
        let work = makeService(
            id: "codex_efgh5678",
            name: "Codex · work",
            status: "partial",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 92, windowMinutes: 300)],
            app: "codex",
            isCurrent: false,
            plan: "team",
            note: "接口已通但未返回额度窗口"
        )
        let kimi = makeService(
            id: "kimi",
            name: "Kimi",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300)]
        )
        let vm = try subscriptionSections(services: [kimi, personal, work])
        try expect(vm.count == 2, "codex 应合并为一段: \(vm.map(\.id))")
        let group = vm[1]
        try expect(group.id == "codex" && group.name == "ChatGPT", "codex 分组头错误")
        try expect(group.accountCountText == "2 个账号", "账号数文案错误")
        try expect(group.status == "partial", "分组状态应取最差: \(group.status)")
        let accounts = group.accounts
        try expect(accounts.count == 2, "账号子卡数量错误")
        try expect(accounts[0].name == "sivan", "应去掉 Codex 前缀: \(accounts[0].name)")
        try expect(accounts[0].plan == "plus", "账号 plan 丢失")
        try expect(accounts[0].windows.count == 2, "账号窗口丢失")
        try expect(accounts[1].note == "接口已通但未返回额度窗口", "账号 note 未保留")
    }

    // 全部条目是未授权占位时订阅卡为 nil, 且留下诊断.
    private static func subscriptionIsNilWhenAllPlaceholders() throws {
        let placeholders = [
            makeService(
                id: "cc_switch_providers",
                name: "CC Switch 云端额度",
                status: "partial",
                app: "cc-switch",
                note: "未授权 externalQuotas 能力, 已跳过云端额度查询"
            ),
            makeService(
                id: "codex_accounts",
                name: "Codex 账号额度",
                status: "partial",
                app: "codex",
                note: "未授权 externalQuotas 能力, 已跳过云端额度查询"
            ),
        ]
        let artifact = makeAgentUsageArtifact(agents: [], services: placeholders)
        let vm = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        )
        try expect(vm.subscription == nil, "未授权占位不应渲染订阅卡")
        let skipped = vm.diagnostics.filter {
            if case .serviceSkipped = $0 { return true }
            return false
        }
        try expect(skipped.count == 2, "占位条目应各留一条诊断: \(vm.diagnostics)")
    }

    // status=error 的 provider 保留在卡内并带 note, 同时产生诊断.
    private static func serviceErrorKeepsNoteAndDiagnoses() throws {
        let failing = makeService(
            id: "kimi",
            name: "Kimi",
            status: "error",
            note: "查询失败: HTTP 401"
        )
        let vm = try subscriptionSectionsWithDiagnostics(services: [failing])
        try expect(vm.sections.count == 1, "error provider 应保留展示")
        try expect(vm.sections[0].status == "error", "error 状态未保留")
        try expect(vm.sections[0].note == "查询失败: HTTP 401", "error note 未保留")
        try expect(
            vm.diagnostics.contains(.serviceIssue(
                serviceID: "kimi",
                status: "error",
                note: "查询失败: HTTP 401"
            )),
            "缺少 serviceIssue 诊断: \(vm.diagnostics)"
        )
    }

    // 单个窗口解析失败被丢弃并产生诊断, 不拖垮整段.
    private static func malformedWindowIsDroppedWithDiagnostic() throws {
        let service = makeService(
            id: "kimi",
            name: "Kimi",
            windows: [
                makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300),
                .object(["label": .string("坏窗口")]),
                .string("not-an-object"),
            ]
        )
        let vm = try subscriptionSectionsWithDiagnostics(services: [service])
        try expect(vm.sections[0].windows.count == 1, "坏窗口应被丢弃")
        let dropped = vm.diagnostics.filter {
            if case .windowDropped = $0 { return true }
            return false
        }
        try expect(dropped.count == 2, "每个坏窗口一条诊断: \(vm.diagnostics)")
    }

    // hero 总量, 成本, 四格细分与 K 格式化.
    private static func usageHeroAggregatesTotalsAndFormatting() throws {
        let cli = makeAgent(
            id: "kimi-code-cli",
            name: "Kimi Code CLI",
            today: makeBucket(input: 80000, output: 15000, cacheRead: 2000, cacheCreation: 1000)
        )
        let work = makeAgent(
            id: "kimi-work",
            name: "Kimi Work",
            today: makeBucket(input: 79000, output: 10000, cacheRead: 32000, cacheCreation: 11000)
        )
        let artifact = makeAgentUsageArtifact(
            agents: [cli, work],
            services: [],
            totalCostUsd: 0.375
        )
        let vm = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        )
        let usage = vm.usage
        try expect(usage?.totalTokens == 230000, "总量聚合错误: \(usage?.totalTokens ?? -1)")
        try expect(usage?.totalTokensText == "230K", "K 格式化错误: \(usage?.totalTokensText ?? "")")
        try expect(usage?.costText == "≈ ¥2.70", "成本文案错误: \(usage?.costText ?? "nil")")
        let labels = usage?.breakdown.map(\.label) ?? []
        try expect(labels == ["输入", "输出", "缓存读取", "缓存命中率"], "细分顺序错误: \(labels)")
        try expect(usage?.breakdown[0].value == 159000, "输入聚合错误")
        try expect(usage?.breakdown[2].value == 34000, "缓存读取聚合错误")
        // 命中率 = 34000 / (159000 + 34000 + 12000) ≈ 16.6% -> "17%".
        try expect(usage?.breakdown[3].valueText == "17%", "缓存命中率错误: \(usage?.breakdown[3].valueText ?? "nil")")
        try expect(usage?.isLive == true, "新鲜 artifact 应为 LIVE")
    }

    // 总量档位: 统一绿色阶, <100M sage, 100M-200M moss, 200M-300M fern,
    // 300M-400M pine, >=400M forest.
    private static func usageTierFollowsTotalThresholds() throws {
        func tier(for total: Int) -> UsageTier {
            UsageHeroViewModel(
                totalTokens: total,
                costText: nil,
                breakdown: [],
                days: [],
                legend: [],
                isLive: false
            ).usageTier
        }
        try expect(tier(for: 0) == .sage, "0 应为 sage")
        try expect(tier(for: 99_999_999) == .sage, "100M-1 应为 sage")
        try expect(tier(for: 100_000_000) == .moss, "100M 应为 moss")
        try expect(tier(for: 199_999_999) == .moss, "200M-1 应为 moss")
        try expect(tier(for: 200_000_000) == .fern, "200M 应为 fern")
        try expect(tier(for: 299_999_999) == .fern, "300M-1 应为 fern")
        try expect(tier(for: 300_000_000) == .pine, "300M 应为 pine")
        try expect(tier(for: 399_999_999) == .pine, "400M-1 应为 pine")
        try expect(tier(for: 400_000_000) == .forest, "400M 应为 forest")
        try expect(tier(for: 900_000_000) == .forest, "900M 应为 forest")
    }

    // 热力图: 全量 daily 按周列 × 周日行 (周一起), level 按当日绝对总量
    // 100M 步进分 0-5 档, 窗口外与未来格为 nil, 柱状图仍固定 14 天.
    // 固定时钟 2026-07-30 (周四), 窗口 2026-07-17 (周五) 至 07-30 -> 3 周列.
    private static func usageHeatmapBuildsWeekGrid() throws {
        var totals = Array(repeating: 0, count: 14)
        totals[13] = 450_000_000 // 07-30 今天, >=400M -> level 5
        totals[6] = 250_000_000 // 07-23, 200M-300M -> level 3
        totals[0] = 150_000_000 // 07-17, 100M-200M -> level 2
        totals[1] = 50_000_000 // 07-18, <100M -> level 1
        let agent = makeAgent(
            id: "kimi-code-cli", name: "Kimi Code CLI", dailyTotals: totals
        )
        let artifact = makeAgentUsageArtifact(agents: [agent], services: [])
        let vm = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        )
        let heatmap = vm.usage?.heatmap ?? []
        try expect(heatmap.count == 3, "14 天窗口应覆盖 3 周列: \(heatmap.count)")
        // 首周: 07-17 是周五, 周一到周四为 nil 占位.
        let firstWeek = heatmap[0].cells
        try expect(firstWeek.count == 7, "周列必须 7 格")
        try expect(
            firstWeek[0] == nil && firstWeek[3] == nil,
            "首周窗口前应为 nil 占位"
        )
        try expect(
            firstWeek[4]?.date == "2026-07-17",
            "首周周五应为窗口首日: \(firstWeek[4]?.date ?? "nil")"
        )
        try expect(
            firstWeek[4]?.level == 2,
            "150M 应为 level 2: \(firstWeek[4]?.level ?? -1)"
        )
        try expect(
            firstWeek[5]?.level == 1,
            "50M 应为 level 1: \(firstWeek[5]?.level ?? -1)"
        )
        // 第二周: 07-23 周四 250M -> level 3; 07-20 周一无量 -> level 0.
        let midWeek = heatmap[1].cells
        try expect(
            midWeek[3]?.level == 3,
            "250M 应为 level 3: \(midWeek[3]?.level ?? -1)"
        )
        try expect(
            midWeek[0]?.level == 0,
            "无量日应为 level 0: \(midWeek[0]?.level ?? -1)"
        )
        // 末周: 今天 07-30 周四 450M -> level 5, 周五起为 nil (未来).
        let lastWeek = heatmap[2].cells
        try expect(
            lastWeek[3]?.date == "2026-07-30",
            "末周周四应为今天: \(lastWeek[3]?.date ?? "nil")"
        )
        try expect(
            lastWeek[3]?.level == 5,
            "450M 应为 level 5: \(lastWeek[3]?.level ?? -1)"
        )
        try expect(
            lastWeek[4] == nil && lastWeek[5] == nil && lastWeek[6] == nil,
            "未来格应为 nil"
        )
        // 柱状图窗口不受热力图影响, 仍为 14 天.
        try expect(
            vm.usage?.days.count == 14,
            "柱状图应仍为 14 天: \(vm.usage?.days.count ?? -1)"
        )
    }

    // 按月聚合: 日历月分组, 保留最近 6 个月, 末位为当月;
    // 半年总量含全部被裁月份, 月均按实际覆盖月数平均.
    private static func usageMonthlyAggregatesCalendarMonths() throws {
        func day(_ date: String, _ total: Int) -> AgentDailyUsage {
            AgentDailyUsage(date: date, input: total, output: 0, total: total)
        }
        let agent = AgentUsageItem(
            id: "kimi-code-cli",
            name: "Kimi Code",
            status: "ok",
            note: nil,
            today: AgentTokenBucket(
                input: 0, output: 0, cacheRead: 0, cacheCreation: 0, total: 0
            ),
            daily: [
                day("2026-01-15", 100), // 1月: 超出 6 个月上限, 应被裁
                day("2026-02-10", 2_000_000),
                day("2026-03-05", 1_500_000),
                day("2026-04-20", 1_000_000),
                day("2026-05-01", 500_000),
                day("2026-06-30", 2_500_000),
                day("2026-07-30", 3_000_000),
            ],
            hours: Array(repeating: 0, count: 24),
            todayCostUsd: nil,
            models: nil,
            modelMonths: nil,
            projects: nil
        )
        let artifact = makeAgentUsageArtifact(agents: [agent], services: [])
        let vm = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        )
        let monthly = vm.usage?.monthly ?? []
        try expect(monthly.count == 6, "应保留最近 6 个月: \(monthly.count)")
        try expect(
            monthly.first?.label == "2月",
            "首月应为 2月 (1月被裁): \(monthly.first?.label ?? "")"
        )
        try expect(
            monthly.first?.isCurrent == false,
            "首月不应为当月"
        )
        try expect(monthly.last?.label == "7月", "末月应为 7月")
        try expect(monthly.last?.isCurrent == true, "末月应为当月")
        try expect(
            monthly.last?.totalText == "3M",
            "7月总量: \(monthly.last?.totalText ?? "")"
        )
        // 半年总量 = 全部 daily 之和 (含被裁的 1月 100): 10,500,100 -> "10.5M".
        try expect(
            vm.usage?.halfYear?.totalText == "10.5M",
            "半年总量: \(vm.usage?.halfYear?.totalText ?? "")"
        )
        // 月均 = 10,500,100 / 6 = 1,750,016 -> "1.8M".
        try expect(
            vm.usage?.halfYear?.averageText == "1.8M",
            "月均: \(vm.usage?.halfYear?.averageText ?? "")"
        )

        // 无数据: monthly 为空, halfYear 为 nil.
        let empty = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: []),
            moduleStatuses: readyStatuses
        )
        try expect(
            empty.usage?.monthly.isEmpty == true,
            "无数据 monthly 应为空"
        )
        try expect(empty.usage?.halfYear == nil, "无数据 halfYear 应为 nil")
    }

    // LIVE 由 generatedAt 新鲜度决定, 超过阈值或解析失败均为 false.
    private static func liveStateFollowsFreshnessThreshold() throws {
        let agent = makeAgent(id: "kimi-code-cli", name: "Kimi Code CLI")
        let stale = makeAgentUsageArtifact(
            agents: [agent],
            services: [],
            generatedAt: "2026-07-30T12:00:00+00:00" // 2 小时前
        )
        let vm = makeMapper().make(
            agentUsage: stale,
            moduleStatuses: readyStatuses
        )
        try expect(vm.usage?.isLive == false, "过期 artifact 不应 LIVE")

        let badDate = makeAgentUsageArtifact(
            agents: [agent],
            services: [],
            generatedAt: "not-a-date"
        )
        let vm2 = makeMapper().make(
            agentUsage: badDate,
            moduleStatuses: readyStatuses
        )
        try expect(vm2.usage?.isLive == false, "无法解析的 generatedAt 不应 LIVE")
    }

    // 14 日堆叠柱状图: 每日总量 + 按 agent 分段, 颜色稳定.
    private static func chartBuilds14DaysWithStableSegments() throws {
        let cli = makeAgent(
            id: "kimi-code-cli",
            name: "Kimi Code CLI",
            dailyTotals: Array(repeating: 1000, count: 14)
        )
        let claude = makeAgent(
            id: "claude-code",
            name: "Claude Code",
            dailyTotals: [0, 0, 0, 0, 0, 0, 0, 500, 0, 0, 0, 0, 0, 500]
        )
        let artifact = makeAgentUsageArtifact(agents: [cli, claude], services: [])
        let usage = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        ).usage
        let days = usage?.days ?? []
        try expect(days.count == 14, "柱状图应为 14 天: \(days.count)")
        try expect(days.last?.date == dayList.last, "最后一天应为今天")
        try expect(days.last?.total == 1500, "每日总量错误")
        try expect(days.last?.totalText == "1.5K", "柱顶标注错误: \(days.last?.totalText ?? "")")
        let lastSegments = days.last?.segments ?? []
        try expect(lastSegments.count == 2, "有量的 agent 各占一段")
        try expect(lastSegments[0].agentID == "kimi-code-cli", "分段顺序应与 artifact 一致")
        try expect(lastSegments[0].color == .blue, "Kimi Code CLI 应为蓝色")
        try expect(lastSegments[1].color == .coral, "Claude 应为珊瑚暖色")
        try expect(days[7].segments.count == 2, "中间日两段")
        try expect(days[0].segments.count == 1, "无量的 agent 不占段")
    }

    // 图例只包含 14 日窗口内有量的 agent.
    private static func legendOnlyIncludesActiveAgents() throws {
        let active = makeAgent(
            id: "kimi-code-cli",
            name: "Kimi Code CLI",
            dailyTotals: Array(repeating: 100, count: 14)
        )
        let idle = makeAgent(id: "codex", name: "Codex CLI")
        let artifact = makeAgentUsageArtifact(agents: [active, idle], services: [])
        let usage = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        ).usage
        let legend = usage?.legend ?? []
        try expect(legend.count == 1, "无量 agent 不进图例: \(legend)")
        try expect(legend[0].name == "Kimi Code CLI", "图例名称错误")
        try expect(legend[0].color.hex == "#0a84ff", "图例颜色错误")
    }

    // 逐小时卡: 过滤无量 not_found, 24 点折线, 今日总量.
    private static func hourlyRowsFilterAndShape() throws {
        var hours = Array(repeating: 0, count: 24)
        hours[9] = 5000
        let cli = makeAgent(
            id: "kimi-code-cli",
            name: "Kimi Code CLI",
            today: makeBucket(input: 9000, output: 1000),
            hours: hours,
            models: ["kimi-k2": 9000]
        )
        let missing = makeAgent(
            id: "claude-code",
            name: "Claude Code",
            status: "not_found",
            note: "未发现会话记录"
        )
        let artifact = makeAgentUsageArtifact(agents: [cli, missing], services: [])
        let vm = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        )
        let rows = vm.hourly?.rows ?? []
        try expect(rows.count == 1, "无量的 not_found agent 应被过滤: \(rows.map(\.agentID))")
        try expect(rows[0].points.count == 24, "折线应为 24 点")
        try expect(rows[0].points[9] == 5000, "折线数据错位")
        try expect(rows[0].todayTotal == 10000, "今日总量错误")
        try expect(rows[0].todayTotalText == "10K", "今日总量文案错误")
        try expect(rows[0].name == "Kimi Code", "展示名应简化: \(rows[0].name)")
        try expect(rows[0].isExpandable == true, "有模型明细应可展开")
        try expect(
            vm.diagnostics.contains(.agentIssue(
                agentID: "claude-code",
                status: "not_found",
                note: "未发现会话记录"
            )),
            "缺少 agentIssue 诊断"
        )
    }

    // 逐小时卡: 柱状图下方只显示今日有量的 agent; ok 但今日无量 (含窗口内有历史量) 也不显示.
    private static func hourlyRowsHideAgentsWithoutUsage() throws {
        let idle = makeAgent(id: "grok", name: "Grok") // ok 但今日与 14 日均无量
        let earlier = makeAgent(
            id: "codex",
            name: "Codex",
            dailyTotals: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 800, 0] // 窗口内有量, 今日为 0
        )
        let active = makeAgent(
            id: "zcode",
            name: "ZCode",
            today: makeBucket(input: 900, output: 100)
        )
        let artifact = makeAgentUsageArtifact(agents: [idle, earlier, active], services: [])
        let rows = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        ).hourly?.rows ?? []
        let ids = rows.map(\.agentID)
        try expect(ids == ["zcode"], "柱状图下方只应显示今日有量的 agent: \(ids)")
    }

    // 逐小时卡: 行按今日用量从高到低排序.
    private static func hourlyRowsSortByTodayTotalDesc() throws {
        let low = makeAgent(
            id: "kimi-code-cli",
            name: "Kimi Code CLI",
            today: makeBucket(input: 9000, output: 1000)
        )
        let high = makeAgent(
            id: "codex-cli",
            name: "Codex CLI",
            today: makeBucket(input: 50000, output: 5000)
        )
        let artifact = makeAgentUsageArtifact(agents: [low, high], services: [])
        let vm = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        )
        let ids = vm.hourly?.rows.map(\.agentID) ?? []
        try expect(ids == ["codex-cli", "kimi-code-cli"], "行应按今日用量降序: \(ids)")
    }

    // 明细: 模型 Top 3 + 其他; 项目 collector 只给 Top 3, 其他由总量补差.
    private static func hourlyDetailAggregatesTopAndOther() throws {
        let agent = makeAgent(
            id: "kimi-code-cli",
            name: "Kimi Code CLI",
            today: makeBucket(input: 90000, output: 8000),
            models: ["kimi-k2": 70500, "kimi-k1.5": 20600, "m3": 5000, "m4": 1900],
            projects: [
                AgentProjectUsage(name: "Bruce", total: 56800),
                AgentProjectUsage(name: "app_project", total: 30400),
            ]
        )
        let artifact = makeAgentUsageArtifact(agents: [agent], services: [])
        let row = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        ).hourly?.rows.first
        let models = row?.models ?? []
        try expect(models.count == 4, "Top 3 + 其他: \(models.map(\.name))")
        try expect(models[0].name == "kimi-k2" && models[0].total == 70500, "模型排序错误")
        try expect(models.last?.name == "其他" && models.last?.total == 1900, "模型其他聚合错误")
        try expect(abs(models[0].share - 70500.0 / 98000.0) < 0.0001, "模型份额错误")
        let projects = row?.projects ?? []
        try expect(projects.count == 3, "项目 Top 2 + 其他: \(projects.map(\.name))")
        try expect(projects.last?.name == "其他" && projects.last?.total == 10800, "项目其他补差错误")
        let noDetail = makeAgent(id: "codex", name: "Codex CLI", today: makeBucket(input: 100))
        let row2 = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [noDetail], services: []),
            moduleStatuses: readyStatuses
        ).hourly?.rows.first
        try expect(row2?.isExpandable == false, "无明细不应可展开")
    }

    // 重置时间文案: 当天 HH:mm, 跨天 N 天后, 过期与空值.
    private static func resetTextVariants() throws {
        let service = makeService(
            id: "kimi",
            name: "Kimi",
            windows: [
                makeWindow(
                    label: "5小时窗口",
                    usedPercent: 68,
                    resetsAt: .integer(Int(fixedNow.timeIntervalSince1970) + 3600)
                ),
                makeWindow(
                    label: "每周窗口",
                    usedPercent: 39,
                    resetsAt: .integer(Int(fixedNow.timeIntervalSince1970) + 3 * 86400)
                ),
                makeWindow(
                    label: "每月窗口",
                    usedPercent: 52,
                    resetsAt: .integer(Int(fixedNow.timeIntervalSince1970) - 100)
                ),
                makeWindow(label: "赠送额度", usedPercent: 81),
            ]
        )
        let vm = try subscriptionSections(services: [service])
        let texts = vm[0].windows.map(\.resetText)
        try expect(texts[0] == "15:00", "当天应显示时刻: \(texts[0])")
        try expect(texts[1] == "3 天后", "跨天应显示天数: \(texts[1])")
        try expect(texts[2] == "刷新中", "过期应显示刷新中 (窗口已重置, 刷新在途): \(texts[2])")
        try expect(texts[3] == "", "无 resetsAt 应为空串")
    }

    // 防御: 非正 epoch (如火山未开始窗口的 ResetTimestamp=-1) 不得解析成 1970 误判「已到期」.
    private static func negativeResetEpochYieldsEmptyResetText() throws {
        let service = makeService(
            id: "volcengine",
            name: "火山引擎（Coding Plan）",
            windows: [
                makeWindow(label: "5小时窗口", usedPercent: 0, resetsAt: .integer(-1)),
                makeWindow(label: "每周窗口", usedPercent: 10, resetsAt: .double(0)),
            ]
        )
        let vm = try subscriptionSectionsWithDiagnostics(services: [service])
        try expect(vm.sections[0].name == "火山引擎", "Coding Plan 后缀应剥离: \(vm.sections[0].name)")
        let texts = vm.sections[0].windows.map(\.resetText)
        try expect(texts == ["", ""], "resetsAt 非正数应为空串: \(texts)")
        let dropped = vm.diagnostics.filter {
            if case .windowDropped = $0 { return true }
            return false
        }
        try expect(dropped.isEmpty, "resetsAt 非正数不应产生诊断: \(vm.diagnostics)")
    }

    // K 格式化与余额格式化边界.
    private static func tokenAndBalanceFormatting() throws {
        try expect(PanelFormat.tokenCount(0) == "0", "0 格式化错误")
        try expect(PanelFormat.tokenCount(900) == "900", "百位格式化错误")
        try expect(PanelFormat.tokenCount(9000) == "9K", "整 K 格式化错误")
        try expect(PanelFormat.tokenCount(70500) == "70.5K", "小数 K 格式化错误")
        try expect(PanelFormat.tokenCount(1_200_000) == "1.2M", "M 格式化错误")
        try expect(PanelFormat.balanceText(38.2, currency: "CNY") == "¥ 38.20", "CNY 格式化错误")
        try expect(PanelFormat.balanceText(5, currency: "USD") == "$ 5.00", "USD 格式化错误")
        try expect(PanelFormat.costText(0.4) == "≈ ¥2.88", "成本两位下限错误")
        try expect(PanelFormat.costText(0.375) == "≈ ¥2.70", "成本小数裁剪错误")
    }

    // 成本按 cnyPerUsd (7.2) 从 USD 换算为 CNY.
    private static func costTextConvertsUsdToCny() throws {
        try expect(PanelFormat.costText(1.0) == "≈ ¥7.20", "1 USD 应换算为 ¥7.20")
        try expect(PanelFormat.costText(2.5) == "≈ ¥18.00", "2.5 USD 应换算为 ¥18.00")
        try expect(PanelFormat.costText(0.05) == "≈ ¥0.36", "0.05 USD 应换算为 ¥0.36")
    }

    // 已知 agent 固定配色 + 未知 id 稳定落在调色板; Claude/Grok 必须互不重合.
    private static func unknownAgentColorIsStable() throws {
        let first = PanelAgentColor.resolve(agentID: "some-future-agent")
        let second = PanelAgentColor.resolve(agentID: "some-future-agent")
        try expect(first == second, "同一 id 颜色必须稳定")
        try expect(PanelAgentColor.allCases.contains(first), "必须落在调色板内")
        try expect(PanelAgentColor.resolve(agentID: "kimi-work") == .cyan, "Kimi Work 配色错误")
        try expect(PanelAgentColor.resolve(agentID: "kimi-code-cli") == .blue, "Kimi Code CLI 配色错误")
        try expect(PanelAgentColor.resolve(agentID: "grok") == .indigo, "Grok 配色错误")
        try expect(PanelAgentColor.resolve(agentID: "codex") == .purple, "Codex 配色错误")
        try expect(PanelAgentColor.resolve(agentID: "claude-code") == .coral, "Claude 配色错误")
        try expect(
            PanelAgentColor.resolve(agentID: "claude-code")
                != PanelAgentColor.resolve(agentID: "grok"),
            "Claude 与 Grok 不得共用同一色"
        )
        try expect(PanelAgentColor.resolve(agentID: "pi") == .rose, "Pi 应为显式 rose 色")
        try expect(PanelAgentColor.resolve(agentID: "zcode") == .mint, "ZCode 应为显式 mint 色")
        try expect(PanelAgentColor.resolve(agentID: "opencode") == .green, "OpenCode 应为显式 green 色")
        try expect(PanelAgentColor.resolve(agentID: "codebuddy") == .orange, "CodeBuddy 应为显式 orange 色")
        let knownIDs = [
            "kimi-work", "kimi-code-cli", "grok", "codex",
            "claude-code", "pi", "zcode", "opencode", "codebuddy",
        ]
        let knownColors = knownIDs.map { PanelAgentColor.resolve(agentID: $0) }
        try expect(
            Set(knownColors).count == knownIDs.count,
            "已知 agent 配色必须互不重复: \(zip(knownIDs, knownColors.map(\.rawValue)))"
        )
        for id in ["kimi-work", "kimi-code-cli", "grok", "codex", "claude-code", "zcode"] {
            try expect(
                PanelAgentColor.resolve(agentID: id) != .rose,
                "Pi 与 \(id) 不得共用同一色"
            )
        }
        try expect(
            PanelAgentColor.coral.distributionHex(at: 0) == PanelAgentColor.coral.hex,
            "占比条 0 档应为主色"
        )
        try expect(
            PanelAgentColor.coral.distributionHex(at: 1)
                != PanelAgentColor.coral.distributionHex(at: 0),
            "占比条相邻档必须可区分"
        )
    }

    // 空 agents / 全缺失全部产生可诊断状态.
    private static func emptyArtifactsProduceDiagnostics() throws {
        let emptyUsage = makeAgentUsageArtifact(agents: [], services: [])
        let vm = makeMapper().make(
            agentUsage: emptyUsage,
            moduleStatuses: readyStatuses
        )
        try expect(vm.diagnostics.contains(.emptyUsageAgents), "空 agents 应有诊断")
        try expect(vm.usage != nil, "空 agents 仍渲染用量卡骨架")
        try expect(vm.usage?.days.isEmpty == true, "空 agents 无日期轴")
        try expect(vm.subscription == nil, "无 provider 时订阅卡为 nil")
    }

    // MARK: - 辅助


    private static func subscriptionSections(
        services: [AgentServiceItem]
    ) throws -> [SubscriptionProviderSection] {
        try subscriptionSectionsWithDiagnostics(services: services).sections
    }

    private static func subscriptionSectionsWithDiagnostics(
        services: [AgentServiceItem]
    ) throws -> (sections: [SubscriptionProviderSection], diagnostics: [PanelDiagnostic]) {
        let artifact = makeAgentUsageArtifact(agents: [], services: services)
        let vm = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses
        )
        guard let subscription = vm.subscription else {
            throw PanelTestFailure.expectation("订阅卡意外为 nil, diagnostics: \(vm.diagnostics)")
        }
        return (subscription.sections, vm.diagnostics)
    }

    // 订阅卡右上角展示 artifact generatedAt 的本地 HH:mm.
    private static func subscriptionUpdatedTextFormatsGeneratedAt() throws {
        let service = makeService(
            id: "kimi",
            name: "Kimi",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300)]
        )
        let vm = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: [service]),
            moduleStatuses: readyStatuses
        )
        try expect(vm.subscription?.updatedText == "最后更新 13:50", "更新时间文本错误: \(vm.subscription?.updatedText ?? "nil")")
    }

    // generatedAt 无法解析时不渲染更新时间.
    private static func subscriptionUpdatedTextNilForBadDate() throws {
        let service = makeService(
            id: "kimi",
            name: "Kimi",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300)]
        )
        let vm = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: [service], generatedAt: "not-a-date"),
            moduleStatuses: readyStatuses
        )
        try expect(vm.subscription?.updatedText == nil, "坏日期不应渲染更新时间")
    }

    // 12.1.11: 额度 100% 不进入 authRequired, 正常渲染窗口与重置时间.
    private static func quota100PercentRendersNormally() throws {        let service = makeService(
            id: "codex_acc-1",
            name: "Codex · user",
            status: "ok",
            kind: "windows",
            windows: [
                makeWindow(
                    label: "5小时窗口",
                    usedPercent: 100,
                    windowMinutes: 300,
                    resetsAt: .string("2026-07-30T16:00:00+00:00")
                ),
            ],
            app: "codex",
            plan: "team"
        )
        let vm = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: [service]),
            moduleStatuses: readyStatuses
        )
        let section = vm.subscription?.sections.first
        try expect(section?.status == "ok", "100% 额度不应改变认证状态: \(section?.status ?? "nil")")
        let window = section?.windows.first
        try expect(window?.usedPercent == 100, "100% 窗口应保留")
        try expect(window?.percentText == "100%", "百分比文案错误")
        try expect(window?.resetText == "16:00", "重置时间错误: \(window?.resetText ?? "nil")")
        let issues = vm.diagnostics.filter {
            if case .serviceIssue = $0 { return true }
            return false
        }
        try expect(issues.isEmpty, "100% 额度不应产生 serviceIssue 诊断: \(vm.diagnostics)")
    }

    // 13.1.2: freshness=stale 的 Codex 账号显示"上次成功 HH:mm" (保留的旧
    // capturedAt); freshness=fresh 不显示.
    private static func codexErrorShowsLastSuccessTime() throws {
        let service = makeService(
            id: "codex_acc-1",
            name: "Codex · user",
            status: "error",
            kind: "windows",
            windows: [],
            app: "codex",
            note: "额度查询暂时失败, 请稍后重试",
            capturedAt: "2026-07-30T13:50:00+00:00",
            freshness: "stale",
            failureKind: "network"
        )
        let vm = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: [service]),
            moduleStatuses: readyStatuses
        )
        let account = vm.subscription?.sections.first?.accounts.first
        try expect(
            account?.lastSuccessText == "上次成功 13:50",
            "stale 状态应显示上次成功时间, got \(account?.lastSuccessText ?? "nil")"
        )

        // fresh 状态不显示
        let okService = makeService(
            id: "codex_acc-2",
            name: "Codex · other",
            status: "ok",
            kind: "windows",
            windows: [],
            app: "codex",
            capturedAt: "2026-07-30T13:50:00+00:00",
            freshness: "fresh"
        )
        let okVM = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: [okService]),
            moduleStatuses: readyStatuses
        )
        let okAccount = okVM.subscription?.sections.first?.accounts.first
        try expect(
            okAccount?.lastSuccessText == nil,
            "fresh 状态不应显示上次成功时间"
        )
    }

    // freshness=stale 且有 capturedAt 时显示"上次成功 HH:mm".
    private static func codexFreshnessStaleShowsLastSuccess() throws {
        let service = makeService(
            id: "codex_acc-1",
            name: "Codex · user",
            status: "error",
            kind: "windows",
            windows: [],
            app: "codex",
            note: "额度查询暂时失败, 请稍后重试",
            capturedAt: "2026-07-30T13:50:00+00:00",
            freshness: "stale",
            failureKind: "network"
        )
        let vm = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: [service]),
            moduleStatuses: readyStatuses
        )
        let account = vm.subscription?.sections.first?.accounts.first
        try expect(
            account?.lastSuccessText == "上次成功 13:50",
            "stale + capturedAt 应显示上次成功时间: \(account?.lastSuccessText ?? "nil")"
        )
    }

    // freshness=unavailable 不显示"上次成功", 即使 capturedAt 存在也不显示.
    private static func codexFreshnessUnavailableHidesLastSuccess() throws {
        let service = makeService(
            id: "codex_acc-1",
            name: "Codex · user",
            status: "error",
            kind: "windows",
            windows: [],
            app: "codex",
            note: "额度查询暂时失败, 请稍后重试",
            capturedAt: "2026-07-30T13:50:00+00:00",
            freshness: "unavailable",
            failureKind: "network"
        )
        let vm = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: [service]),
            moduleStatuses: readyStatuses
        )
        let account = vm.subscription?.sections.first?.accounts.first
        try expect(
            account?.lastSuccessText == nil,
            "unavailable 不应显示上次成功时间: \(account?.lastSuccessText ?? "nil")"
        )
    }

    // 账号行名称只删除开头固定前缀 "Codex · ", 不用 replacingOccurrences 全局替换.
    // 账号名内部包含 "Codex · " 时不应被误改.
    private static func codexDisplayNameStripsPrefixOnly() throws {
        let service = makeService(
            id: "codex_acc-1",
            name: "Codex · Codex · sivan",
            status: "ok",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 42, windowMinutes: 300)],
            app: "codex",
            plan: "plus"
        )
        let vm = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: [service]),
            moduleStatuses: readyStatuses
        )
        let account = vm.subscription?.sections.first?.accounts.first
        try expect(
            account?.name == "Codex · sivan",
            "只应删开头前缀, 保留内部: \(account?.name ?? "nil")"
        )
    }

    // status=empty (瞬时故障未取到数据) 不是未授权占位, 必须保留段和 note.
    private static func subscriptionEmptyStatusStillRenders() throws {        let service = makeService(
            id: "kimi",
            name: "Kimi",
            status: "empty",
            note: "未取到额度数据"
        )
        let vm = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: [service]),
            moduleStatuses: readyStatuses
        )
        let section = vm.subscription?.sections.first
        try expect(section?.id == "kimi", "empty 段应保留: \(vm.subscription?.sections.map(\.id) ?? [])")
        try expect(section?.note == "未取到额度数据", "empty 段 note 错误: \(section?.note ?? "nil")")
        let issues = vm.diagnostics.filter {
            if case .serviceIssue = $0 { return true }
            return false
        }
        try expect(issues.count == 1, "empty 应留一条 serviceIssue 诊断: \(vm.diagnostics)")
    }

    // 用户自定义 provider 顺序优先于默认的"余额沉底"排序.
    private static func providerOrderOverridesDefaultSort() throws {
        let deepseek = makeService(
            id: "deepseek",
            name: "DeepSeek",
            kind: "balance",
            balance: 38.21,
            currency: "CNY"
        )
        let kimi = makeService(
            id: "kimi",
            name: "Kimi",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300)]
        )
        let volcengine = makeService(
            id: "volcengine",
            name: "火山引擎",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 50, windowMinutes: 300)]
        )

        // 默认 (无自定义顺序): 余额型沉底 -> [kimi, volcengine, deepseek]
        let defaultVM = try subscriptionSections(services: [deepseek, kimi, volcengine])
        try expect(defaultVM.count == 3, "默认段数量错误: \(defaultVM.count)")
        try expect(defaultVM[0].id == "kimi", "默认 kimi 应在前: \(defaultVM.map(\.id))")
        try expect(defaultVM[2].id == "deepseek", "默认 deepseek 应沉底: \(defaultVM.map(\.id))")

        // 自定义顺序: deepseek 在前, kimi 在后
        let order = ["deepseek", "volcengine", "kimi"]
        let artifact = makeAgentUsageArtifact(agents: [], services: [deepseek, kimi, volcengine])
        let customVM = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses,
            providerOrder: order
        )
        guard let sections = customVM.subscription?.sections else {
            throw PanelTestFailure.expectation("自定义顺序订阅卡意外为 nil")
        }
        try expect(sections.count == 3, "自定义顺序段数量错误: \(sections.count)")
        try expect(sections[0].id == "deepseek", "自定义顺序 deepseek 应在前: \(sections.map(\.id))")
        try expect(sections[1].id == "volcengine", "自定义顺序 volcengine 应居中: \(sections.map(\.id))")
        try expect(sections[2].id == "kimi", "自定义顺序 kimi 应在后: \(sections.map(\.id))")
    }

    // 不在自定义顺序中的 service ID 排在已知 ID 之后, 保持 artifact 顺序.
    private static func providerOrderUnknownIDsGoLast() throws {
        let kimi = makeService(
            id: "kimi",
            name: "Kimi",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300)]
        )
        let unknown = makeService(
            id: "custom-provider",
            name: "Custom",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 50, windowMinutes: 300)]
        )
        let artifact = makeAgentUsageArtifact(agents: [], services: [kimi, unknown])
        let vm = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses,
            providerOrder: ["kimi"]
        )
        guard let sections = vm.subscription?.sections else {
            throw PanelTestFailure.expectation("订阅卡意外为 nil")
        }
        try expect(sections.count == 2, "段数量错误: \(sections.count)")
        try expect(sections[0].id == "kimi", "已知 ID 应在前: \(sections.map(\.id))")
        try expect(sections[1].id == "custom-provider", "未知 ID 应在后: \(sections.map(\.id))")
    }

    // artifact 中 Kimi 的 service ID 是 "kimi_coding", 用户顺序中用 "kimi";
    // 映射器必须归一化后匹配, 否则 Kimi 不受自定义顺序控制.
    private static func providerOrderNormalizesKimiCodingID() throws {
        let kimi = makeService(
            id: "kimi_coding",
            name: "Kimi",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300)]
        )
        let deepseek = makeService(
            id: "deepseek",
            name: "DeepSeek",
            kind: "balance",
            balance: 38.21,
            currency: "CNY"
        )
        let artifact = makeAgentUsageArtifact(agents: [], services: [kimi, deepseek])
        // 用户顺序: kimi (rawValue) 在前, deepseek 在后
        let vm = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses,
            providerOrder: ["kimi", "deepseek"]
        )
        guard let sections = vm.subscription?.sections else {
            throw PanelTestFailure.expectation("订阅卡意外为 nil")
        }
        try expect(sections.count == 2, "段数量错误: \(sections.count)")
        try expect(
            sections[0].id == "kimi_coding",
            "kimi_coding 应被 'kimi' 顺序匹配并排在前面: \(sections.map(\.id))"
        )
        try expect(
            sections[1].id == "deepseek",
            "deepseek 应排在后面: \(sections.map(\.id))"
        )
    }
    /// opencode_go service ID 归一为 rawValue "opencodeGo",
    /// 与配置 providerOrder 键一致, 用户调整顺序可正确匹配.
    private static func providerOrderMatchesOpenCodeGoRawValue() throws {
        let go = makeService(
            id: "opencode_go_eada03635c22306a",
            name: "OpenCode GO · eada0363",
            kind: "windows",
            windows: [makeWindow(label: "每 5 小时", usedPercent: 3, windowMinutes: 300)]
        )
        let kimi = makeService(
            id: "kimi_coding",
            name: "Kimi",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 68, windowMinutes: 300)]
        )
        let artifact = makeAgentUsageArtifact(agents: [], services: [go, kimi])
        // 配置顺序: opencodeGo 在前 (rawValue 键)
        let vm = makeMapper().make(
            agentUsage: artifact,
            moduleStatuses: readyStatuses,
            providerOrder: ["opencodeGo", "kimi"]
        )
        guard let sections = vm.subscription?.sections else {
            throw PanelTestFailure.expectation("订阅卡意外为 nil")
        }
        try expect(sections.count == 2, "段数量错误: \(sections.count)")
        try expect(
            sections[0].id == "opencode_go_eada03635c22306a",
            "opencodeGo 应按 rawValue 顺序排前: \(sections.map(\.id))"
        )
        try expect(
            sections[0].name == "OpenCode GO",
            "分组名应为 OpenCode GO: \(sections[0].name)"
        )
    }

    // S5a: SubscriptionPresentationPolicy 纯规则表驱动锁定.
    private static func presentationPolicyTableDrivenRules() throws {        // kimi_coding → kimi 排序键; 其他原样.
        let providerIDCases: [(String, String)] = [
            ("kimi_coding", "kimi"),
            ("kimi", "kimi"),
            ("deepseek", "deepseek"),
            ("volcengine", "volcengine"),
            ("zhipu", "zhipu"),
            ("zhipu_abc12345", "zhipu"),
            ("codex", "codex"),
            ("opencode_go_eada03635c22306a", "opencodeGo"),
            ("opencode_go_acct1", "opencodeGo"),
        ]
        for (input, expected) in providerIDCases {
            let got = SubscriptionPresentationPolicy.providerID(forServiceID: input)
            try expect(got == expected, "providerID(\(input)) => \(got), expected \(expected)")
        }

        // volcengine 显示名剥离 Coding Plan 后缀; 其他保留.
        let displayCases: [(String, String, String)] = [
            ("volcengine", "火山引擎（Coding Plan）", "火山引擎"),
            ("volcengine", "火山引擎", "火山引擎"),
            ("zhipu", "Z.ai", "Z.ai"),
            ("kimi", "Kimi Coding", "Kimi Coding"),
            ("deepseek", "DeepSeek", "DeepSeek"),
        ]
        for (id, name, expected) in displayCases {
            let got = SubscriptionPresentationPolicy.displayName(serviceID: id, serviceName: name)
            try expect(got == expected, "displayName(\(id), \(name)) => \(got)")
        }

        // 加量包未启用隐藏; 其他 extra 保留.
        let extraCases: [(String?, String?)] = [
            ("加量包未启用", nil),
            ("加量包余额 ¥12.00", "加量包余额 ¥12.00"),
            (nil, nil),
            ("其他说明", "其他说明"),
        ]
        for (input, expected) in extraCases {
            let got = SubscriptionPresentationPolicy.extraText(input)
            try expect(
                got == expected,
                "extraText(\(String(describing: input))) => \(String(describing: got))"
            )
        }

        // partial 占位 skip; empty 仍渲染; 有窗口/余额不 skip.
        struct SkipCase {
            let kind: String?
            let hasWindows: Bool
            let hasBalance: Bool
            let status: String
            let skip: Bool
        }
        let skipCases: [SkipCase] = [
            SkipCase(kind: nil, hasWindows: false, hasBalance: false, status: "partial", skip: true),
            SkipCase(kind: nil, hasWindows: false, hasBalance: false, status: "empty", skip: false),
            SkipCase(kind: nil, hasWindows: false, hasBalance: false, status: "error", skip: false),
            SkipCase(kind: "windows", hasWindows: false, hasBalance: false, status: "partial", skip: false),
            SkipCase(kind: nil, hasWindows: true, hasBalance: false, status: "partial", skip: false),
            SkipCase(kind: nil, hasWindows: false, hasBalance: true, status: "partial", skip: false),
        ]
        for c in skipCases {
            let got = SubscriptionPresentationPolicy.shouldSkipPlaceholder(
                kind: c.kind, hasWindows: c.hasWindows, hasBalance: c.hasBalance, status: c.status
            )
            try expect(
                got == c.skip,
                "skip(kind:\(String(describing: c.kind)), win:\(c.hasWindows), bal:\(c.hasBalance), \(c.status)) => \(got)"
            )
        }

        // codex 分组判定.
        try expect(SubscriptionPresentationPolicy.isCodex(app: "codex"), "app=codex 应为 codex")
        try expect(!SubscriptionPresentationPolicy.isCodex(app: "claude"), "app=claude 不应为 codex")
        try expect(!SubscriptionPresentationPolicy.isCodex(app: nil), "app=nil 不应为 codex")

        // Codex 账号短名: 只剥开头前缀.
        let nameCases: [(String, String)] = [
            ("Codex · work", "work"),
            ("Codex · Codex · nested", "Codex · nested"),
            ("plain", "plain"),
            ("My Codex · account", "My Codex · account"),
        ]
        for (input, expected) in nameCases {
            let got = SubscriptionPresentationPolicy.codexAccountShortName(from: input)
            try expect(got == expected, "codexShortName(\(input)) => \(got)")
        }

        // Codex 分组最差状态.
        // 空列表沿用原公式 max() ?? 0 → "ok" (生产路径有 isEmpty 守卫不会调用).
        let statusCases: [([String], String)] = [
            (["ok", "ok"], "ok"),
            (["ok", "partial"], "partial"),
            (["ok", "error", "partial"], "error"),
            (["unknown"], "partial"),
            ([], "ok"),
        ]
        for (statuses, expected) in statusCases {
            let got = SubscriptionPresentationPolicy.codexGroupStatus(from: statuses)
            try expect(got == expected, "groupStatus(\(statuses)) => \(got)")
        }

        // Jev 暂时屏蔽规则 (C018)
        try expect(
            SubscriptionPresentationPolicy.isProviderTemporarilyDisabled("jev"),
            "jev 应被暂时屏蔽"
        )
        try expect(
            !SubscriptionPresentationPolicy.isProviderTemporarilyDisabled("deepseek"),
            "deepseek 不应被屏蔽"
        )
        try expect(
            !SubscriptionPresentationPolicy.isProviderTemporarilyDisabled("kimi"),
            "kimi 不应被屏蔽"
        )

        // 移除入口门禁 (C019): 半添加状态 (已添加未配置) 必须可移除,
        // 否则「启用开关随未配置禁用 + 无移除入口」形成死锁态.
        let removalCases: [(isAdded: Bool, isConfigured: Bool, expected: Bool, label: String)] = [
            (true, false, true, "已添加未配置 → 必须可移除 (C019 缺陷场景)"),
            (true, true, true, "已添加已配置 → 可移除"),
            (false, true, true, "未添加而已配置 → 可移除 (防御性清理)"),
            (false, false, false, "未添加未配置 → 不可移除"),
        ]
        for removalCase in removalCases {
            let got = SubscriptionPresentationPolicy.showsProviderRemoval(
                isAdded: removalCase.isAdded,
                isConfigured: removalCase.isConfigured
            )
            try expect(
                got == removalCase.expected,
                "showsProviderRemoval(added:\(removalCase.isAdded), configured:\(removalCase.isConfigured)) => \(got), 期望 \(removalCase.expected) [\(removalCase.label)]"
            )
        }

        // 仪表盘展示门禁 (C020): 仅验证状态 ok 进入订阅段, 其余三态一律不展示.
        let verificationCases: [(SubscriptionVerificationStatus, Bool, String)] = [
            (.ok, true, "已通过验证 → 展示"),
            (.none, false, "未验证 → 不展示"),
            (.failed(reason: "fixture"), false, "验证失败 → 不展示"),
            (.needsRelogin, false, "需重新登录 → 不展示"),
        ]
        for (status, expected, label) in verificationCases {
            let got = SubscriptionPresentationPolicy.isVerifiedForDashboard(status)
            try expect(
                got == expected,
                "isVerifiedForDashboard(\(status)) => \(got), 期望 \(expected) [\(label)]"
            )
        }

        let jevService = makeService(
            id: "jev",
            name: "Jev",
            status: "ok",
            kind: "balance",
            windows: [],
            balance: 10.0,
            currency: "USD"
        )
        let jevVM = makeMapper().make(
            agentUsage: makeAgentUsageArtifact(agents: [], services: [jevService]),
            moduleStatuses: readyStatuses
        )
        try expect(
            jevVM.subscription?.sections.isEmpty ?? true,
            "屏蔽状态下的 jev service 不应生成 subscription section"
        )
    }

    // 单账号 section 名称只显示 provider 名, 不带账号后缀 (无需区分).
    // 多账号分组名由 groupDisplayName 提供.
    private static func singleAccountSectionNameOmitsAccountSuffix() throws {
        let deepseek = makeService(
            id: "deepseek_sk-12345",
            name: "DeepSeek · sk-12345",
            kind: "balance",
            balance: 38.21,
            currency: "CNY"
        )
        let vm = try subscriptionSections(services: [deepseek])
        try expect(vm.count == 1, "单账号应只有 1 段: \(vm.count)")
        try expect(
            vm[0].name == "DeepSeek",
            "单账号不应显示账号名: \(vm[0].name)"
        )
        try expect(
            !vm[0].name.contains("sk-12345"),
            "单账号名称不得含账号 ID: \(vm[0].name)"
        )
        // 徽章取色键必须归一化为 provider rawValue, 否则带后缀的
        // serviceID 会让品牌色全部落空为默认灰 (回归断言).
        try expect(
            vm[0].badgeProviderID == "deepseek",
            "单账号徽章键应归一化为 deepseek: \(vm[0].badgeProviderID)"
        )

        // 多账号: 分组名仍为 provider 名, 账号名在 accounts 子卡内.
        let second = makeService(
            id: "deepseek_sk-67890",
            name: "DeepSeek · sk-67890",
            kind: "balance",
            balance: 10.0,
            currency: "CNY"
        )
        let multi = try subscriptionSections(services: [deepseek, second])
        try expect(multi.count == 1, "多账号应合并为 1 段: \(multi.count)")
        try expect(multi[0].name == "DeepSeek", "多账号分组名应为 DeepSeek: \(multi[0].name)")
        try expect(multi[0].isMultiAccount, "多账号应标记 isMultiAccount")
        try expect(multi[0].accounts.count == 2, "多账号应有 2 个子卡: \(multi[0].accounts.count)")
        try expect(
            multi[0].accounts.map(\.name) == ["sk-12345", "sk-67890"],
            "子卡名应剥离 DeepSeek 前缀: \(multi[0].accounts.map(\.name))"
        )

        // StepFun 国内站与国外站标记规则:
        // 1. 仅有 1 个国际站账号时: 不做标记 (tag == nil, section.name == "StepFun")
        let stepfunGlobalOnly = makeService(
            id: "stepfun_a5c5847a",
            name: "StepFun (国际) · a5c5847a",
            kind: "rateLimit"
        )
        let singleStepfun = try subscriptionSections(services: [stepfunGlobalOnly])
        try expect(singleStepfun.count == 1, "单个 StepFun 国际站账号应为 1 段")
        try expect(singleStepfun[0].name == "StepFun", "单个账号 section 名称应为 StepFun: \(singleStepfun[0].name)")
        try expect(!singleStepfun[0].isMultiAccount, "单个账号不应为多账号")
        try expect(singleStepfun[0].accounts.first?.tag == nil, "单个国际站账号不应做标记")

        // 2. 多个账号 (国内 + 国际): 仅国际站账号在子卡头部标记 "国际", 国内站不做标记
        let stepfunDomestic = makeService(
            id: "stepfun_cfc5d7b3",
            name: "StepFun · cfc5d7b3",
            kind: "rateLimit"
        )
        let multiStepfun = try subscriptionSections(services: [stepfunDomestic, stepfunGlobalOnly])
        try expect(multiStepfun.count == 1, "多账号应合并为 1 段")
        try expect(multiStepfun[0].isMultiAccount, "多账号应标记 isMultiAccount")
        try expect(multiStepfun[0].accounts.count == 2, "应有 2 个子卡")
        let domAccount = multiStepfun[0].accounts.first(where: { $0.id == "stepfun_cfc5d7b3" })
        let globalAccount = multiStepfun[0].accounts.first(where: { $0.id == "stepfun_a5c5847a" })
        try expect(domAccount?.tag == nil, "国内站账号不应做标记")
        try expect(globalAccount?.tag == "国际", "国外站账号旁边应标记 '国际': \(String(describing: globalAccount?.tag))")
    }

    // MARK: - AppVersion

    /// AppVersion: 纯逻辑读取版本; 缺失回落 unknown.
    private static func appVersionReadsBundleAndFallsBack() throws {
        try expect(
            AppVersion.current(raw: "0.3.0") == "0.3.0",
            "应读取注入的短版本字符串"
        )
        try expect(
            AppVersion.current(raw: nil) == "unknown",
            "缺版本应回落 unknown"
        )
        try expect(
            AppVersion.current(raw: "") == "unknown",
            "空字符串应回落 unknown"
        )
        try expect(
            AppVersion.current(raw: 123) == "unknown",
            "非字符串应回落 unknown"
        )
    }

    // MARK: - 模型用量

    /// 模型用量: 三档窗口求和、月卡数据、降序排序与颜色跨周期稳定.
    private static func modelUsageBuildsTiersMonthsAndColors() throws {
        let agentA = makeAgent(
            id: "zcode",
            name: "ZCode",
            modelMonths: [
                "2026-08": ["GLM-5.3": 300, "Kimi K3": 100],
                "2026-07": ["GLM-5.3": 200, "Kimi K3": 250],
                "2026-06": ["GLM-5.3": 50, "Kimi K3": 400],
            ]
        )
        let agentB = makeAgent(
            id: "claude-code",
            name: "Claude Code",
            modelMonths: [
                "2026-08": ["Claude Sonnet": 150],
                "2026-07": ["Claude Sonnet": 120],
            ]
        )
        let artifact = makeAgentUsageArtifact(agents: [agentA, agentB], services: [])
        let vm = makeMapper().make(agentUsage: artifact, moduleStatuses: readyStatuses)
        let models = vm.usage?.models
        try expect(models != nil, "modelMonths 存在时模型区块不应为 nil")

        let tiers = models?.tiers ?? []
        try expect(
            tiers.map(\.label) == ["本月", "3 月", "6 月"],
            "三档窗口标签顺序错误: \(tiers.map(\.label))"
        )
        // 本月 = 2026-08 跨 agent 求和, 降序.
        try expect(
            tiers[0].rows.map(\.name) == ["GLM-5.3", "Claude Sonnet", "Kimi K3"],
            "本月排序应按用量降序: \(tiers[0].rows.map(\.name))"
        )
        try expect(
            tiers[0].rows[0].totalText == PanelFormat.tokenCount(300),
            "本月 GLM 应跨 agent 求和: \(tiers[0].rows[0].totalText)"
        )
        try expect(
            tiers[0].rows[0].pctText == "55%",
            "本月 GLM 份额应约 55%: \(tiers[0].rows[0].pctText)"
        )
        // 3 月 = 6+7+8 月求和.
        let kimi3m = tiers[1].rows.first(where: { $0.name == "Kimi K3" })
        try expect(
            kimi3m?.totalText == PanelFormat.tokenCount(750),
            "3 月窗口应覆盖 6-8 月: \(kimi3m?.totalText ?? "nil")"
        )
        try expect(tiers[2].rows.count == 3, "6 月窗口模型数应一致")

        // 日历月降序 + 同一模型颜色跨周期稳定.
        try expect(
            models?.months.map(\.id) == ["2026-08", "2026-07", "2026-06"],
            "日历月应最新在前: \(models?.months.map(\.id) ?? [])"
        )
        let glmTierColor = tiers[0].rows[0].colorHex
        let glmJuneColor = models?.months.last?.rows.first(where: { $0.name == "GLM-5.3" })?.colorHex
        try expect(
            glmJuneColor == glmTierColor,
            "同一模型颜色应跨周期稳定: \(String(describing: glmJuneColor)) vs \(glmTierColor)"
        )
        // 进度条份额 = 周期内占比.
        let share = tiers[0].rows[0].share
        try expect(
            abs(share - 300.0 / 550.0) < 0.001,
            "进度条份额应为周期内占比: \(share)"
        )
    }

    /// 旧版 artifact (无 modelMonths): 模型区块为 nil, 按月/热力图不受影响.
    private static func modelUsageHiddenWithoutMonthData() throws {
        let agent = makeAgent(
            id: "kimi-code-cli",
            name: "Kimi Code CLI",
            dailyTotals: [100, 200],
            models: ["k3": 300]
        )
        let artifact = makeAgentUsageArtifact(agents: [agent], services: [])
        let vm = makeMapper().make(agentUsage: artifact, moduleStatuses: readyStatuses)
        try expect(vm.usage?.models == nil, "无 modelMonths 时模型区块应为 nil")
        try expect(
            !(vm.usage?.monthly.isEmpty ?? true),
            "按月区块不应受模型数据缺失影响"
        )
    }

    /// Nothing 绿阶系列色: 5 个高频 agent 占满 5 档且稳定, 深浅模式色板互为反转, 未知 agent 也能落档.
    private static func nothingRampStableAndDistinctForTopAgents() throws {
        let top = ["kimi-code-cli", "claude-code", "codex", "zcode", "opencode"]
        let colors = top.map { PanelAgentColor.nothingRampHex(agentID: $0, darkMode: true) }
        try expect(
            Set(colors).count == 5,
            "5 个高频 agent 应占满 5 档绿阶: \(colors)"
        )
        try expect(
            colors == top.map { PanelAgentColor.nothingRampHex(agentID: $0, darkMode: true) },
            "同一 agent 绿阶色应稳定不变"
        )
        try expect(
            Set(colors).isSubset(of: ["#8CCB98", "#5FAF6E", "#4A9E5C", "#35854A", "#2A6B3C"]),
            "深色绿阶色值必须落在定稿 5 档内"
        )
        try expect(
            PanelAgentColor.nothingRampHex(agentID: "kimi-code-cli", darkMode: false) == "#2A6B3C",
            "浅色模式应取反转色板"
        )
        try expect(
            !PanelAgentColor.nothingRampHex(agentID: "unknown-agent", darkMode: true).isEmpty,
            "未知 agent 也应稳定落档"
        )
    }

    // MARK: - 卡片收起态

    /// 收起态近 7 天热力档位: 14 天数据取末 7 天, 档位与热力图绝对阈值同源.
    private static func collapsedWeekLevelsTakesLast7Days() throws {
        let totals = [0, 50_000_000, 150_000_000, 250_000_000, 350_000_000,
                      450_000_000, 10_000_000, 20_000_000, 120_000_000,
                      220_000_000, 320_000_000, 420_000_000, 80_000_000, 500_000_000]
        let artifact = makeAgentUsageArtifact(
            agents: [makeAgent(
                id: "kimi-code-cli", name: "Kimi Code",
                today: makeBucket(input: 1), dailyTotals: totals
            )],
            services: []
        )
        let panel = makeMapper().make(agentUsage: artifact, moduleStatuses: readyStatuses)
        let levels = try unwrap(panel.usage?.collapsedWeekLevels)
        try expect(
            levels == [20_000_000, 120_000_000, 220_000_000, 320_000_000, 420_000_000, 80_000_000, 500_000_000]
                .map { UsageTier.forTotal($0).heatmapLevel },
            "应取末 7 天并按绝对阈值分档"
        )
    }

    /// 不足 7 天时只返回实际天数; 零量日档位为 0.
    private static func collapsedWeekLevelsHandlesShortWindowAndZeroDays() throws {
        let artifact = makeAgentUsageArtifact(
            agents: [makeAgent(
                id: "kimi-code-cli", name: "Kimi Code",
                today: makeBucket(input: 1),
                dailyTotals: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50_000_000, 150_000_000]
            )],
            services: []
        )
        let panel = makeMapper().make(agentUsage: artifact, moduleStatuses: readyStatuses)
        let levels = try unwrap(panel.usage?.collapsedWeekLevels)
        try expect(levels.count == 7, "14 天窗口应恒取末 7 天")
        try expect(levels == [0, 0, 0, 0, 0, 1, 2], "零量日落 0, 50M/150M 分档 1/2")
    }

    /// 订阅卡收起态: 单账号多窗口取 usedPercent 最大的窗口.
    private static func collapsedPeakWindowPicksTightestWindow() throws {
        let artifact = makeAgentUsageArtifact(
            agents: [],
            services: [makeService(
                id: "kimi", name: "Kimi",
                windows: [
                    makeWindow(label: "每 5 小时", usedPercent: 68),
                    makeWindow(label: "每周", usedPercent: 92),
                    makeWindow(label: "每月", usedPercent: 39),
                ]
            )]
        )
        let panel = makeMapper().make(agentUsage: artifact, moduleStatuses: readyStatuses)
        let peak = try unwrap(panel.subscription?.sections.first?.collapsedPeakWindow)
        try expect(peak.label == "每周" && peak.usedPercent == 92, "应取最紧张窗口")
    }

    /// 多账号 section 跨账号取最紧张窗口; 纯余额型 (无窗口) 为 nil.
    private static func collapsedPeakWindowSpansAccountsAndSkipsBalanceOnly() throws {
        let artifact = makeAgentUsageArtifact(
            agents: [],
            services: [
                makeService(
                    id: "codex_abcd1234", name: "Codex · a",
                    windows: [makeWindow(label: "每 5 小时", usedPercent: 57)]
                ),
                makeService(
                    id: "codex_efgh5678", name: "Codex · b",
                    windows: [makeWindow(label: "每周", usedPercent: 96)]
                ),
                makeService(id: "deepseek", name: "DeepSeek", balance: 38.21, currency: "CNY"),
            ]
        )
        let panel = makeMapper().make(agentUsage: artifact, moduleStatuses: readyStatuses)
        let sections = panel.subscription?.sections ?? []
        let codex = sections.first { $0.isMultiAccount }
        let deepseek = sections.first { $0.balance != nil }
        try expect(codex?.collapsedPeakWindow?.usedPercent == 96, "多账号应跨账号取 max")
        try expect(deepseek?.collapsedPeakWindow == nil, "纯余额型 provider 无最紧张窗口")
    }

    /// 逐小时卡收起态: 24 点全 agent 合计 + 峰值文案.
    private static func hourlyCollapsedPointsSumWithPeakText() throws {
        var hoursA = Array(repeating: 0, count: 24)
        var hoursB = Array(repeating: 0, count: 24)
        hoursA[10] = 9000
        hoursB[10] = 6500
        hoursB[22] = 2000
        let artifact = makeAgentUsageArtifact(
            agents: [
                makeAgent(id: "kimi-code-cli", name: "Kimi Code",
                          today: makeBucket(input: 9000), hours: hoursA),
                makeAgent(id: "claude-code", name: "Claude Code",
                          today: makeBucket(input: 8500), hours: hoursB),
            ],
            services: []
        )
        let panel = makeMapper().make(agentUsage: artifact, moduleStatuses: readyStatuses)
        let hourly = try unwrap(panel.hourly)
        try expect(hourly.collapsedPoints.count == 24, "合计序列恒为 24 点")
        try expect(hourly.collapsedPoints[10] == 15_500, "同一小时应跨 agent 合计")
        try expect(hourly.collapsedPoints[22] == 2000, "单 agent 小时保留")
        try expect(hourly.collapsedPeakText == "峰值 15.5K", "峰值文案取合计最大值")
    }

    /// 收起状态持久化: 写入 UserDefaults 后新实例恢复; 未知 rawValue 读取时丢弃.
    @MainActor
    private static func collapseStatePersistsAcrossAppModelInstances() throws {
        let suite = "BrucePanelCollapseTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(collapsedDefaults: defaults)
        try expect(!model.isCardCollapsed(.usage), "默认全部展开")
        model.toggleCardCollapsed(.usage)
        model.toggleCardCollapsed(.hourly)
        model.toggleCardCollapsed(.usage) // 再切回展开
        try expect(!model.isCardCollapsed(.usage) && model.isCardCollapsed(.hourly),
                   "切换语义应正确")
        defaults.set(["hourly", "bogus-card"], forKey: "dashboard.collapsedCards")
        let restored = AppModel(collapsedDefaults: defaults)
        try expect(restored.isCardCollapsed(.hourly), "重启后应恢复收起状态")
        try expect(!restored.isCardCollapsed(.subscription), "未收起卡片不受影响")
        try expect(restored.collapsedCards.count == 1, "未知 rawValue 读取时必须丢弃")

        // 卡片顺序与拖拽调序持久化
        try expect(model.cardOrder == [.usage, .subscription, .hourly], "默认卡片顺序应为 usage, subscription, hourly")
        model.moveCard(from: .hourly, to: .usage)
        try expect(model.cardOrder == [.hourly, .usage, .subscription], "卡片调序应成功")
        let restoredOrderModel = AppModel(collapsedDefaults: defaults)
        try expect(restoredOrderModel.cardOrder == [.hourly, .usage, .subscription], "重启后应恢复卡片顺序")
        defaults.set(["subscription", "bogus-card"], forKey: "dashboard.cardOrder")
        let fallbackModel = AppModel(collapsedDefaults: defaults)
        try expect(fallbackModel.cardOrder == [.subscription, .usage, .hourly], "未知或缺失卡片应自动补齐并去重")
    }

    /// 卡片收起动画与静态呈现契约: 确保三种卡片状态切换幂等，且收起态迷你图表点序列稳定保真.
    @MainActor
    private static func cardCollapseAnimationStabilityContracts() throws {
        let defaults = UserDefaults(suiteName: "BruceCardAnimTest.\(UUID().uuidString)")!
        let model = AppModel(collapsedDefaults: defaults)

        // 1. 三卡全部具备可收起能力，切换幂等且状态集合自洽
        for card in [DashboardCardID.usage, DashboardCardID.subscription, DashboardCardID.hourly] {
            try expect(!model.isCardCollapsed(card), "\(card) 默认展开")
            model.toggleCardCollapsed(card)
            try expect(model.isCardCollapsed(card), "\(card) 收起状态应生效")
            model.toggleCardCollapsed(card)
            try expect(!model.isCardCollapsed(card), "\(card) 再次展开应还原")
        }

        // 2. 空数据/全零数据下 Hourly 迷你图表序列恒为 24 点，避免动画阶段 Y 域除零或 NaN 导致图表重绘崩溃
        let zeroArtifact = makeAgentUsageArtifact(agents: [], services: [])
        let panelZero = makeMapper().make(agentUsage: zeroArtifact, moduleStatuses: readyStatuses)
        if let hourly = panelZero.hourly {
            try expect(hourly.collapsedPoints.count == 24, "零数据下收起态点数恒为 24")
            let maxP = hourly.collapsedPoints.max() ?? 0
            try expect(maxP == 0, "零数据下最大点为 0")
            // 契约：YDomain 采用 max(maxPoint, 1) * 1.1，保证 0 值时不崩溃
            let safeScale = Double(max(maxP, 1)) * 1.1
            try expect(safeScale > 1.0, "安全尺度必须大于 1.0 杜绝零除")
        }
    }

    // MARK: - ModelNormalizer 与工作台分析 (C070)

    private static func modelNormalizerCanonicalKeyContracts() throws {
        // 1. 渠道 / 厂商前缀剥离, 目录精确命中取展示名与厂商
        let deepseekKey = ModelNormalizer.canonicalKey(for: "cline-pass/deepseek-v4.1-flash")
        try expect(deepseekKey == "deepseek-v4.1-flash", "前缀剥离后必须为 deepseek-v4.1-flash: \(deepseekKey)")
        try expect(ModelNormalizer.vendor(for: deepseekKey) == "DeepSeek", "厂商必须为 DeepSeek")
        try expect(ModelNormalizer.displayName(for: deepseekKey) == "DeepSeek V4.1 Flash", "显示名取目录")
        for raw in ["zhipu/glm-5.3", "openrouter/glm-5.3", "GLM-5.3"] {
            try expect(ModelNormalizer.canonicalKey(for: raw) == "glm-5.3", "\(raw) 必须收敛为 glm-5.3")
        }
        try expect(ModelNormalizer.vendor(for: "glm-5.3").contains("智谱 AI"), "厂商必须包含 智谱 AI")

        // 2. 快照日期 / -latest / [标记] 修剪
        let claudeKey = ModelNormalizer.canonicalKey(for: "anthropic/claude-3-7-sonnet-20250219")
        try expect(claudeKey == "claude-3-7-sonnet", "日期后缀与厂商前缀必须剔除: \(claudeKey)")
        try expect(ModelNormalizer.vendor(for: claudeKey) == "Anthropic", "厂商必须为 Anthropic")
        try expect(ModelNormalizer.canonicalKey(for: "gpt-4o-latest") == "gpt-4o", "-latest 必须剔除")
        try expect(ModelNormalizer.canonicalKey(for: "deepseek-r1[thinking]") == "deepseek-r1", "[thinking] 必须剥离")
        try expect(ModelNormalizer.canonicalKey(for: "  ") == "unknown", "空名归为 unknown")

        // 3. 不做跨型号别名: 不同型号单价不同, 合并即混算
        for raw in ["deepseek-flash", "glm-4.5", "gpt-5.4-preview", "claude-opus-4-1", "deepseek-chat"] {
            try expect(ModelNormalizer.canonicalKey(for: raw) == raw, "\(raw) 不得被别名合并")
        }
        try expect(ModelNormalizer.displayName(for: "deepseek-flash") == "deepseek-flash", "目录未收录时展示名即规范键")
        try expect(ModelNormalizer.vendor(for: "deepseek-flash") == "DeepSeek", "目录未收录时按前缀推断厂商")
        try expect(ModelNormalizer.vendor(for: "acme-coder") == "其他", "未知厂商为「其他」")
    }

    private static func workbenchTodayRangeUsesRealBucketsContracts() throws {
        let snapshot = WorkbenchAnalytics.make(artifact: makeWorkbenchArtifact(), range: .today)
        let kpi = snapshot.kpi
        // 四象限为原始口径, 之和 = 总量
        try expect(kpi.totalTokens == 2_500, "今日总量: \(kpi.totalTokens)")
        try expect(
            [kpi.inputTokens, kpi.outputTokens, kpi.cacheReadTokens, kpi.cacheCreationTokens] == [1_100, 250, 1_100, 50],
            "今日四象限取 today 桶"
        )
        try expect(kpi.costText == "$3.25", "费用 = 已定价明细桶之和: \(kpi.costText)")
        try expect(kpi.pricedTokens == 2_400 && kpi.unpricedTokens == 100, "已定价 / 未定价 token 分别计")
        try expect(kpi.costTagText == "100 未定价", "未定价量标在费用标签: \(kpi.costTagText)")
        try expect(kpi.averageCostPerMillionText == "$1354.17 / 1M", "均价 = 费用 ÷ 已定价 tokens: \(kpi.averageCostPerMillionText)")
        try expect(kpi.cacheHitRateText == "48.9%", "命中率 = 缓存读 ÷ (输入 + 缓存读写): \(kpi.cacheHitRateText)")
        try expect(kpi.cacheSavedCostText == "省 $1.25", "缓存节省取采集端计价: \(kpi.cacheSavedCostText)")
        try expect(kpi.activeAgentsCount == 2, "零用量 Agent 不计入活跃")
        try expect(kpi.topAgentText == "最活跃 Codex · 80.0%", "最活跃 Agent: \(kpi.topAgentText)")

        // 时序: 24 个整点, Token 构成取小时 × 模型桶, 三者之和 = 该小时总量
        let timeline = snapshot.timeline
        try expect(timeline.granularity == .hour && timeline.points.count == 24, "今日逐小时 24 点")
        let peak = timeline.points[14]
        try expect(peak.label == "14:00" && peak.totalTokens == 2_300, "14 点合计")
        try expect(peak.seriesValues["claude-code"] == 300 && peak.seriesValues["codex"] == 2_000, "Agent 序列取 hours")
        try expect(
            [peak.seriesValues["type_input"], peak.seriesValues["type_output"], peak.seriesValues["type_cache"]] == [1_090, 230, 980],
            "小时 Token 构成 (输入含缓存写入)"
        )
        try expect(peak.costUsd == 2.75, "小时费用取小时桶计价: \(peak.costUsd)")
        try expect(peak.seriesValues["model_gpt-5.4"] == 2_000, "模型序列按规范键")
        let idle = timeline.points[3]
        try expect(idle.totalTokens == 0 && idle.seriesValues["type_input"] == 0 && idle.costUsd == 0, "空小时构成为 0")
        try expect(timeline.peakSummary == "🔥 峰值时段: **14:00** (\(PanelFormat.tokenCount(2_300)) Tokens)", timeline.peakSummary)
        try expect(timeline.avgSummary == "时均: **\(PanelFormat.tokenCount(2_500 / 24))** Tokens", timeline.avgSummary)
        try expect(snapshot.todayHourlyTokens[9] == 200 && snapshot.todayHourlyTokens[14] == 2_300, "今日 24h 密度")

        // C162: 方案 A1 (3h 等步长) + 峰值防撞吸附与主导系列色
        let todayTicks = WorkbenchAnalytics.timelineAxisTicks(for: timeline.points)
        try expect(
            todayTicks.map(\.label) == ["00:00", "03:00", "06:00", "09:00", "12:00", "14:00", "18:00", "21:00"],
            "14:00 峰值距离 15:00 为 1h，自动替换 15:00 防止重叠: \(todayTicks.map(\.label))"
        )
        try expect(todayTicks.filter(\.isPeak).map(\.label) == ["14:00"], "仅 14:00 标记为峰值刻度")
        let agentSeries = snapshot.agents.map {
            AnalyticsChartSeriesMeta(key: $0.agentID, name: $0.name, colorHex: $0.colorHex)
        }
        let codexHex = try unwrap(snapshot.agents.first { $0.agentID == "codex" }?.colorHex)
        try expect(
            WorkbenchAnalytics.peakDominantColorHex(points: timeline.points, series: agentSeries) == codexHex,
            "14:00 峰值处 Codex 占优，胶囊颜色跟随 Codex 系列色"
        )
        let grid15Points = (0..<24).map { hour in
            AnalyticsTimelinePoint(
                label: String(format: "%02d:00", hour),
                totalTokens: hour == 15 ? 87_500_000 : 0,
                costUsd: 0,
                seriesValues: [:]
            )
        }
        let grid15Ticks = WorkbenchAnalytics.timelineAxisTicks(for: grid15Points)
        try expect(
            grid15Ticks.map(\.label) == ["00:00", "03:00", "06:00", "09:00", "12:00", "15:00", "18:00", "21:00"],
            "15:00 恰在 3h 网格上，保持 8 个严格 3h 等距刻度"
        )
        try expect(grid15Ticks.filter(\.isPeak).map(\.label) == ["15:00"], "15:00 标记为峰值")

        // 项目分布只有今日数据, 今日范围才下发
        let claude = try unwrap(snapshot.agents.first { $0.agentID == "claude-code" })
        try expect(claude.topProjects.map(\.name) == ["bruce"], "今日范围下发项目分布")
    }

    private static func workbenchMultiDayRangesUseDailyDetailContracts() throws {
        let artifact = makeWorkbenchArtifact()
        let week = WorkbenchAnalytics.make(artifact: artifact, range: .sevenDays)
        try expect(week.kpi.totalTokens == 7_500, "近 7 天总量: \(week.kpi.totalTokens)")
        try expect(week.kpi.inputTokens == 2_700 && week.kpi.cacheCreationTokens == 350, "原始输入 = daily.input − 缓存读写")
        try expect(week.kpi.costText == "$12.75", "近 7 天费用取逐日明细: \(week.kpi.costText)")
        try expect(week.kpi.topAgentText == "最活跃 Codex · 53.3%", week.kpi.topAgentText)

        // 模型归并: token 降序, 来源保留原始名与 Agent
        try expect(week.models.map(\.canonicalKey) == ["gpt-5.4", "claude-sonnet-5", "deepseek-flash"], "模型按量降序")
        let sonnet = week.models[1]
        try expect(sonnet.totalTokens == 2_800 && sonnet.costText == "$8.75", "模型费用为来源费用之和")
        try expect(sonnet.sources.map(\.rawModelName) == ["anthropic/claude-sonnet-5"], "来源为原始模型名")
        try expect(week.models[2].costText == nil, "未定价模型不出费用")
        let shareSum = week.models.reduce(0.0) { $0 + $1.sharePercent }
        try expect(abs(shareSum - 100) < 1e-9, "模型占比之和为 100%")

        // Agent 对比: 只列活跃者, 比例条三段之和 = 总量, 非今日不冒用今日项目
        try expect(week.agents.map(\.agentID) == ["codex", "claude-code"], "活跃 Agent 按量降序")
        let claude = week.agents[1]
        try expect(claude.inputTokens + claude.outputTokens + claude.cacheReadTokens == claude.totalTokens, "比例条守恒")
        try expect(claude.costText == "$8.75" && claude.topProjects.isEmpty, "Agent 费用取自身明细; 项目仅今日")
        try expect(claude.topModels.map(\.canonicalKey) == ["claude-sonnet-5", "deepseek-flash"], "Agent 模型下钻")

        // 逐日时序: 标签 MM-dd, 构成之和 = 当日总量, 峰值取首个最大日
        let timeline = week.timeline
        try expect(timeline.granularity == .day && timeline.points.map(\.label).first == "07-24", "近 7 天逐日")
        let last = try unwrap(timeline.points.last)
        try expect(last.label == "07-30" && last.totalTokens == 2_500 && last.costUsd == 3.25, "当日合计与费用")
        let types = ["type_input", "type_output", "type_cache"].compactMap { last.seriesValues[$0] }
        try expect(types == [1_150, 250, 1_100], "逐日 Token 构成: \(types)")
        try expect(timeline.peakSummary.contains("**07-29**"), "峰值取首个最大日: \(timeline.peakSummary)")
        try expect(timeline.avgSummary == "日均: **\(PanelFormat.tokenCount(7_500 / 7))** Tokens", timeline.avgSummary)

        // 全部历史: monthModels 定模型与费用, 逐月时序
        let all = WorkbenchAnalytics.make(artifact: artifact, range: .allTime)
        try expect(all.kpi.totalTokens == 11_000 && all.kpi.costText == "$21.50", "全部历史取月明细: \(all.kpi.costText)")
        try expect(all.timeline.granularity == .month && all.timeline.points.map(\.label) == ["2026-07"], "逐月时序")
        try expect(all.timeline.points[0].costUsd == 21.5, "月费用")
        let month = WorkbenchAnalytics.make(artifact: artifact, range: .thisMonth)
        try expect(month.kpi.totalTokens == 11_000 && month.kpi.costText == "$21.50", "本月 = 当月逐日明细")
    }

    private static func workbenchThisMonthStopsAtMonthBoundaryContracts() throws {
        let dates = ["2026-07-30", "2026-07-31", "2026-08-01", "2026-08-02"]
        let daily = dates.map { AgentDailyUsage(date: $0, input: 100, output: 0, total: 100, cacheRead: 0, cacheCreation: 0) }
        let agent = AgentUsageItem(
            id: "codex", name: "Codex", status: "ok", note: nil,
            today: makeBucket(input: 100), daily: daily, hours: Array(repeating: 0, count: 24),
            todayCostUsd: nil, models: nil, modelMonths: nil, projects: nil,
            dailyModels: dates.map {
                AgentModelDetail(date: $0, model: "gpt-5.4", input: 100, output: 0, cacheRead: 0, cacheCreation: 0,
                                 total: 100, costUsd: 0.25, cacheSavingsUsd: 0)
            },
            monthModels: [], hourModels: []
        )
        let artifact = makeAgentUsageArtifact(agents: [agent], services: [], generatedAt: "2026-08-02T09:00:00+00:00")
        let month = WorkbenchAnalytics.make(artifact: artifact, range: .thisMonth)
        try expect(month.kpi.totalTokens == 200 && month.kpi.costText == "$0.50", "本月只含今日所在自然月")
        try expect(month.timeline.points.map(\.label) == ["08-01", "08-02"], "本月时序从 1 日起")
        let all = WorkbenchAnalytics.make(artifact: artifact, range: .allTime)
        try expect(all.timeline.points.map(\.label) == ["2026-07", "2026-08"], "全部历史跨月分桶")
    }

    private static func workbenchLegacyArtifactShowsDashesContracts() throws {
        // C070 前的 artifact: 无明细桶, daily 无缓存拆分 —— 一律「—」, 不估算
        let agent = makeAgent(
            id: "codex", name: "Codex",
            today: makeBucket(input: 400, output: 200, cacheRead: 400),
            dailyTotals: Array(repeating: 0, count: 13) + [1_000],
            todayCostUsd: 0.5,
            models: ["gpt-5.4": 1_000]
        )
        let artifact = makeAgentUsageArtifact(agents: [agent], services: [], totalCostUsd: 0.5)
        let week = WorkbenchAnalytics.make(artifact: artifact, range: .sevenDays)
        try expect(week.kpi.totalTokens == 1_000, "总量仍取 daily")
        try expect(week.kpi.costText == "—" && week.kpi.costTagText == "无明细", "无明细不估算费用")
        try expect(week.kpi.cacheHitRateText == "—" && week.kpi.cacheReadTokensText == "—", "无拆分不出缓存指标")
        try expect(week.kpi.inputTokensText == "—" && week.kpi.outputTokensText == "0", "输入未知, 输出已知")
        try expect(week.kpi.cacheSavedCostText == "—" && week.kpi.averageCostPerMillionText == "—", "节省 / 均价为「—」")
        try expect(week.models.isEmpty, "无明细不出模型归并")
        try expect(week.agents.first?.costText == "—", "Agent 费用为「—」")
        let last = try unwrap(week.timeline.points.last)
        try expect(last.seriesValues["type_input"] == nil, "无拆分不出 Token 构成序列")

        let today = WorkbenchAnalytics.make(artifact: artifact, range: .today)
        try expect(today.kpi.cacheHitRateText == "50.0%", "今日 today 桶恒带拆分: \(today.kpi.cacheHitRateText)")
        try expect(today.timeline.points[0].seriesValues["type_input"] == nil, "无小时明细不出构成")

        let empty = WorkbenchAnalytics.empty(range: .today)
        try expect(empty.kpi.costText == "—" && empty.agents.isEmpty && empty.todayHourlyTokens.count == 24, "无 artifact 空快照")
    }

    private static func billionTokenFormattingContracts() throws {
        try expect(PanelFormat.tokenCount(1_000_000_000) == "1B", "1B 格式化错误: \(PanelFormat.tokenCount(1_000_000_000))")
        try expect(PanelFormat.tokenCount(1_500_000_000) == "1.5B", "1.5B 格式化错误: \(PanelFormat.tokenCount(1_500_000_000))")
        try expect(PanelFormat.tokenCount(3_530_000_000) == "3.53B", "3.53B 格式化错误: \(PanelFormat.tokenCount(3_530_000_000))")
        try expect(PanelFormat.tokenCount(4_743_838_856) == "4.74B", "4.74B 格式化错误: \(PanelFormat.tokenCount(4_743_838_856))")
    }

    /// C157: 订阅卡空状态只做未配置 / 无数据两态; artifact 缺失与已有订阅都不出空态.
    private static func subscriptionEmptyStatePolicyContracts() throws {
        try expect(
            SubscriptionEmptyStatePolicy.resolve(
                hasArtifact: false,
                hasSubscription: false,
                eligibleProviderCount: 0
            ) == nil,
            "无 artifact 不应出空态"
        )
        try expect(
            SubscriptionEmptyStatePolicy.resolve(
                hasArtifact: true,
                hasSubscription: true,
                eligibleProviderCount: 2
            ) == nil,
            "已有订阅卡不应出空态"
        )

        let notConfigured = try unwrap(SubscriptionEmptyStatePolicy.resolve(
            hasArtifact: true,
            hasSubscription: false,
            eligibleProviderCount: 0
        ))
        try expect(notConfigured.reason == .notConfigured, "无 eligible provider 应判未配置")
        try expect(notConfigured.statusText == "未配置", "未配置状态词")
        try expect(notConfigured.actionTitle == "添加订阅", "未配置动作")
        try expect(notConfigured.systemImage == "creditcard", "未配置图标必须是有效 SF Symbol 名")

        let noData = try unwrap(SubscriptionEmptyStatePolicy.resolve(
            hasArtifact: true,
            hasSubscription: false,
            eligibleProviderCount: 1
        ))
        try expect(noData.reason == .noData, "有 eligible provider 但无 section 应判无数据")
        try expect(noData.statusText == "无数据", "无数据状态词")
        try expect(noData.actionTitle == "刷新额度", "无数据动作")
        try expect(noData.systemImage == "arrow.clockwise", "无数据图标")

        #if canImport(AppKit)
        // 图标名必须能解析为系统 SF Symbol, 否则 Image(systemName:) 静默渲染为空.
        for model in [notConfigured, noData] {
            try expect(
                NSImage(systemSymbolName: model.systemImage, accessibilityDescription: nil) != nil,
                "空态图标不是有效 SF Symbol: \(model.systemImage)"
            )
        }
        #endif
    }

    /// C158: 更新动效的时长 / 曲线 / 门控单一来源; 弹簧零过冲, 隐藏或减弱时一律不播.
    private static func meterMotionPolicyContracts() throws {
        let expected: [(MeterMotionKind, MeterMotionCurve)] = [
            (.fill, .spring(duration: 0.85, bounce: 0)),
            (.percent, .spring(duration: 0.85, bounce: 0)),
            (.balance, .spring(duration: 0.6, bounce: 0)),
            (.levelCrossfade, .easeOut(duration: 0.34)),
            (.thresholdColor, .easeOut(duration: 0.25)),
            (.highlight, .easeOut(duration: 0.2)),
            (.sheen, .timingCurve(c0x: 0.33, c0y: 0, c1x: 0.2, c1y: 1, duration: 0.85)),
        ]
        try expect(expected.count == MeterMotionKind.allCases.count, "每种动效都必须有断言")
        for (kind, curve) in expected {
            let visible = MeterMotionPolicy.curve(for: kind, panelVisible: true, motionSuppressed: false)
            try expect(visible == curve, "\(kind) 曲线错误: \(String(describing: visible))")
            if case let .spring(_, bounce) = curve {
                try expect(bounce == 0, "\(kind) 弹簧必须零过冲")
            }
            for (panelVisible, motionSuppressed) in [(false, false), (true, true), (false, true)] {
                try expect(
                    MeterMotionPolicy.curve(
                        for: kind,
                        panelVisible: panelVisible,
                        motionSuppressed: motionSuppressed
                    ) == nil,
                    "\(kind) 在隐藏或减弱动态时必须直接落值"
                )
            }
        }
        // 百分比与量条同一事务; 高光保持覆盖整段量条动画.
        try expect(
            MeterMotionPolicy.curve(for: .percent, panelVisible: true, motionSuppressed: false)
                == MeterMotionPolicy.curve(for: .fill, panelVisible: true, motionSuppressed: false),
            "百分比必须与量条同曲线"
        )
        try expect(
            MeterMotionPolicy.highlightHoldSeconds >= MeterMotionCurve.spring(duration: 0.85, bounce: 0).duration,
            "高光必须覆盖整段量条动画"
        )

        let playCases: [(Double, Double, Bool, Bool, Bool, String)] = [
            (0.40, 0.42, true, false, true, "可见增长应播放"),
            (0.42, 0.40, true, false, true, "可见下降应播放"),
            (0.40, 0.4004, true, false, false, "同值抖动不空转"),
            (0.40, 0.42, false, false, false, "面板隐藏不播放"),
            (0.40, 0.42, true, true, false, "减弱动态不播放"),
            (0.40, .nan, true, false, false, "非有限值不播放"),
        ]
        for (old, new, panelVisible, motionSuppressed, shouldPlay, message) in playCases {
            try expect(
                MeterMotionPolicy.shouldPlayUpdate(
                    from: old,
                    to: new,
                    panelVisible: panelVisible,
                    motionSuppressed: motionSuppressed
                ) == shouldPlay,
                message
            )
        }
    }

    /// C158: BalanceRow.amount 与 amountText 同源; 滚动方向取 amount, 展示仍以 amountText 为准.
    private static func balanceRowAmountMatchesTextContracts() throws {
        let deepseek = makeService(
            id: "deepseek",
            name: "DeepSeek",
            kind: "balance",
            balance: 12_345.6,
            currency: "CNY"
        )
        let codex = makeService(
            id: "codex",
            name: "Codex",
            kind: "windows",
            windows: [makeWindow(label: "5小时窗口", usedPercent: 10, windowMinutes: 300)],
            balance: 1_520.5,
            currency: "credits"
        )
        let sections = try subscriptionSections(services: [deepseek, codex])
        let money = try unwrap(sections.first { $0.id == "deepseek" }?.balance)
        try expect(money.amount == 12_345.6, "货币余额 amount 必须取自 artifact: \(money.amount)")
        try expect(
            money.amountText == PanelFormat.balanceText(money.amount, currency: "CNY"),
            "货币余额文案必须由 amount 格式化: \(money.amountText)"
        )
        let credits = try unwrap(sections.first { $0.id == "codex" }?.balance)
        try expect(credits.amount == 1_520.5, "Credits amount 必须取自 artifact: \(credits.amount)")
        try expect(
            credits.amountText == PanelFormat.creditsText(credits.amount),
            "Credits 文案必须由 amount 格式化: \(credits.amountText)"
        )
        for amount in [0, -3.5, 999.99, 1_000.12] {
            let row = BalanceRow(amount: amount, currency: "USD")
            try expect(row.amount == amount, "amount 必须原样保留: \(amount)")
            try expect(
                row.amountText == PanelFormat.balanceText(amount, currency: "USD"),
                "amountText 与 amount 不一致: \(row.amountText)"
            )
        }
    }

    /// 轻量解包: 与 expect 同风格, 避免引入 XCTest.
    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else {
            throw PanelTestFailure.expectation("期望非 nil 值")
        }
        return value
    }

}
