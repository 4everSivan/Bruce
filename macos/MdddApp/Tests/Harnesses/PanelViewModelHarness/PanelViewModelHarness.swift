import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

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
        projects: projects
    )
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
    extra: String? = nil
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
        extra: extra
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
    static func main() throws {
        try windowWordingMatrixMapsMinutes()
        try windowWordingFallsBackToKnownLabels()
        try ownRowFlagIsPreserved()
        try balanceSinksToBottom()
        try codexAccountsGroupIntoOneSection()
        try subscriptionIsNilWhenAllPlaceholders()
        try serviceErrorKeepsNoteAndDiagnoses()
        try malformedWindowIsDroppedWithDiagnostic()
        try usageHeroAggregatesTotalsAndFormatting()
        try liveStateFollowsFreshnessThreshold()
        try chartBuilds14DaysWithStableSegments()
        try legendOnlyIncludesActiveAgents()
        try hourlyRowsFilterAndShape()
        try hourlyDetailAggregatesTopAndOther()
        try resetTextVariants()
        try negativeResetEpochYieldsEmptyResetText()
        try tokenAndBalanceFormatting()
        try costTextConvertsUsdToCny()
        try unknownAgentColorIsStable()
        try emptyArtifactsProduceDiagnostics()
        print("PanelViewModel tests passed: 20")
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
        try expect(group.id == "codex" && group.name == "Codex", "codex 分组头错误")
        try expect(group.accountCountText == "2 个账号", "账号数文案错误")
        try expect(group.status == "partial", "分组状态应取最差: \(group.status)")
        let accounts = group.codexAccounts ?? []
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
        try expect(labels == ["输入", "输出", "缓存读取", "缓存创建"], "细分顺序错误: \(labels)")
        try expect(usage?.breakdown[0].value == 159000, "输入聚合错误")
        try expect(usage?.breakdown[2].value == 34000, "缓存读取聚合错误")
        try expect(usage?.isLive == true, "新鲜 artifact 应为 LIVE")
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
        try expect(lastSegments[1].color == .orange, "Claude 应为橙色")
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

    // 明细: 模型 Top 3 + 其他; 项目 collector 只给 Top 3, 其他由总量补差.
    private static func hourlyDetailAggregatesTopAndOther() throws {
        let agent = makeAgent(
            id: "kimi-code-cli",
            name: "Kimi Code CLI",
            today: makeBucket(input: 90000, output: 8000),
            models: ["kimi-k2": 70500, "kimi-k1.5": 20600, "m3": 5000, "m4": 1900],
            projects: [
                AgentProjectUsage(name: "mddd", total: 56800),
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
        try expect(texts[2] == "已到期", "过期应显示已到期: \(texts[2])")
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

    // 未知 agent 颜色稳定落在调色板内.
    private static func unknownAgentColorIsStable() throws {
        let first = PanelAgentColor.resolve(agentID: "some-future-agent")
        let second = PanelAgentColor.resolve(agentID: "some-future-agent")
        try expect(first == second, "同一 id 颜色必须稳定")
        try expect(PanelAgentColor.allCases.contains(first), "必须落在调色板内")
        try expect(PanelAgentColor.resolve(agentID: "kimi-code-cli") == .blue, "Kimi Code CLI 配色错误")
        try expect(PanelAgentColor.resolve(agentID: "kimi-work") == .cyan, "Kimi Work 配色错误")
        try expect(PanelAgentColor.resolve(agentID: "claude-code") == .orange, "Claude 配色错误")
        try expect(PanelAgentColor.resolve(agentID: "codex-orca") == .purple, "Codex · Orca 配色错误")
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
}
