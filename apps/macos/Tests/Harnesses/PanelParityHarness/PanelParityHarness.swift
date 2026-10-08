import Foundation

import BruceAppCore

// Panel 视图模型双端对拍 Harness (mac 产出侧)。
//
// 读取共享 artifact fixture, 用 BruceAppCore.PanelViewModelMapper 产出视图模型,
// 序列化为与 Windows 侧 Rust viewmodel (bruce-win-viewmodel) 完全同构的
// camelCase JSON。对拍锁: apps/win/viewmodel/tests/fixture_parity.rs 中
// `mac_parity_golden_matches` 用本 Harness 产出的 golden 快照逐字段比对。
//
// 用法:
//   swift run PanelParityHarness <repoRoot>              # 比对模式 (CI 用)
//   swift run PanelParityHarness <repoRoot> --update     # 刷新 golden 快照
//
// 约定: DeepSeek 月度账本 (deepSeekMonthlyUsage) 未接入, 恒输出 null (双端一致)。

// MARK: - 轻量 JSON 构建器 (显式控制 null 与数值类型)

enum J {
    case s(String)
    case i(Int)
    case d(Double)
    case b(Bool)
    case nul
    case a([J])
    case o([(String, J)])

    var any: Any {
        switch self {
        case .s(let value): return value
        case .i(let value): return NSNumber(value: value)
        case .d(let value): return NSNumber(value: value)
        case .b(let value): return NSNumber(value: value)
        case .nul: return NSNull()
        case .a(let items): return items.map(\.any)
        case .o(let pairs):
            var dictionary: [String: Any] = [:]
            for (key, value) in pairs { dictionary[key] = value.any }
            return dictionary
        }
    }

    static func data(_ value: J) throws -> Data {
        let object = value.any
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ParityError.invalidJSON
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}

private enum ParityError: Error, CustomStringConvertible {
    case invalidJSON
    case missingArtifactKey(String)

    var description: String {
        switch self {
        case .invalidJSON:
            return "对拍 JSON 构造失败"
        case .missingArtifactKey(let path):
            return "fixture 缺少 artifact 键: \(path)"
        }
    }
}

// MARK: - Fixture 宽容解码

/// 共享 fixture 可能早于 schemaVersion/module 字段, 解码前补默认值。
/// 注意: 解码目标是 envelope 内层的 artifact 对象 (与 Rust 侧 value["artifact"] 一致)。
private func decodeAgentUsageArtifact(fixtureURL: URL) throws -> AgentUsageArtifact {
    let raw = try Data(contentsOf: fixtureURL)
    let root = try JSONSerialization.jsonObject(with: raw)
    guard let envelope = root as? [String: Any], var artifact = envelope["artifact"] as? [String: Any] else {
        throw ParityError.missingArtifactKey(fixtureURL.path)
    }
    if artifact["schemaVersion"] == nil { artifact["schemaVersion"] = 1 }
    if artifact["module"] == nil { artifact["module"] = "agent-usage" }
    let patched = try JSONSerialization.data(withJSONObject: artifact)
    return try JSONDecoder().decode(AgentUsageArtifact.self, from: patched)
}

// MARK: - 视图模型 -> J (与 bruce-win-viewmodel serde 输出同构)

private func colorPair(_ color: PanelAgentColor) -> (String, String) {
    (color.rawValue, color.hex)
}

private func encode(_ panel: PanelViewModel) -> J {
    .o([
        ("usage", panel.usage.map(encodeUsage) ?? .nul),
        ("subscription", panel.subscription.map(encodeSubscription) ?? .nul),
        ("hourly", panel.hourly.map(encodeHourly) ?? .nul),
        ("diagnostics", .a(panel.diagnostics.map(encodeDiagnostic))),
    ])
}

private func encodeUsage(_ usage: UsageHeroViewModel) -> J {
    .o([
        ("totalTokens", .i(usage.totalTokens)),
        ("totalTokensText", .s(usage.totalTokensText)),
        ("costText", usage.costText.map(J.s) ?? .nul),
        ("breakdown", .a(usage.breakdown.map { item in
            .o([
                ("label", .s(item.label)),
                ("value", .i(item.value)),
                ("valueText", .s(item.valueText)),
            ])
        })),
        ("days", .a(usage.days.map { day in
            .o([
                ("date", .s(day.date)),
                ("total", .i(day.total)),
                ("totalText", .s(day.totalText)),
                ("segments", .a(day.segments.map { segment in
                    let (name, hex) = colorPair(segment.color)
                    return J.o([
                        ("agentId", .s(segment.agentID)),
                        ("color", .s(name)),
                        ("colorHex", .s(hex)),
                        ("value", .i(segment.value)),
                    ])
                })),
            ])
        })),
        ("legend", .a(usage.legend.map { item in
            let (name, hex) = colorPair(item.color)
            return J.o([
                ("agentId", .s(item.agentID)),
                ("name", .s(item.name)),
                ("color", .s(name)),
                ("colorHex", .s(hex)),
            ])
        })),
        ("isLive", .b(usage.isLive)),
        ("heatmap", .a(usage.heatmap.map { week in
            .o([("cells", .a(week.cells.map { cell in
                guard let cell else { return J.nul }
                return J.o([
                    ("date", .s(cell.date)),
                    ("total", .i(cell.total)),
                    ("level", .i(cell.level)),
                ])
            }))])
        })),
        ("monthly", .a(usage.monthly.map { month in
            .o([
                ("label", .s(month.label)),
                ("totalText", .s(month.totalText)),
                ("isCurrent", .b(month.isCurrent)),
                ("key", .s(month.key)),
            ])
        })),
        ("halfYear", usage.halfYear.map { summary in
            J.o([
                ("totalText", .s(summary.totalText)),
                ("averageText", .s(summary.averageText)),
            ])
        } ?? .nul),
        ("models", usage.models.map(encodeModels) ?? .nul),
        ("usageTier", .s(usage.usageTier.rawValue)),
        ("collapsedWeekLevels", .a(usage.collapsedWeekLevels.map(J.i))),
    ])
}

private func encodeModels(_ models: UsageModelUsageSection) -> J {
    func period(_ period: UsageModelPeriod) -> J {
        .o([
            ("id", .s(period.id)),
            ("label", .s(period.label)),
            ("rows", .a(period.rows.map { row in
                .o([
                    ("name", .s(row.name)),
                    ("totalText", .s(row.totalText)),
                    ("pctText", .s(row.pctText)),
                    ("share", .d(row.share)),
                    ("colorHex", .s(row.colorHex)),
                ])
            })),
        ])
    }
    return .o([
        ("tiers", .a(models.tiers.map(period))),
        ("months", .a(models.months.map(period))),
        ("currentMonthKey", .s(models.currentMonthKey)),
    ])
}

private func encodeSubscription(_ subscription: SubscriptionViewModel) -> J {
    .o([
        ("sections", .a(subscription.sections.map(encodeSection))),
        ("updatedText", subscription.updatedText.map(J.s) ?? .nul),
    ])
}

private func encodeWindowRow(_ row: SubscriptionWindowRow) -> J {
    .o([
        ("label", .s(row.label)),
        ("usedPercent", .d(row.usedPercent)),
        ("percentText", .s(row.percentText)),
        ("resetText", .s(row.resetText)),
        ("ownRow", .b(row.ownRow)),
        ("windowMinutes", row.windowMinutes.map(J.i) ?? .nul),
    ])
}

private func encodeSection(_ section: SubscriptionProviderSection) -> J {
    .o([
        ("id", .s(section.id)),
        ("name", .s(section.name)),
        ("plan", section.plan.map(J.s) ?? .nul),
        ("status", .s(section.status)),
        ("note", section.note.map(J.s) ?? .nul),
        ("extraText", section.extraText.map(J.s) ?? .nul),
        ("windows", .a(section.windows.map(encodeWindowRow))),
        ("accounts", .a(section.accounts.map(encodeAccount))),
        ("collapsedWindow", section.collapsedWindow.map(encodeWindowRow) ?? .nul),
        ("balance", section.balance.map { balance in
            J.o([("label", .s(balance.label)), ("amountText", .s(balance.amountText))])
        } ?? .nul),
        ("accountCountText", section.accountCountText.map(J.s) ?? .nul),
        ("deepSeekMonthlyUsage", .nul),
    ])
}

private func encodeAccount(_ account: CodexAccountViewModel) -> J {
    .o([
        ("id", .s(account.id)),
        ("name", .s(account.name)),
        ("plan", account.plan.map(J.s) ?? .nul),
        ("status", .s(account.status)),
        ("note", account.note.map(J.s) ?? .nul),
        ("windows", .a(account.windows.map(encodeWindowRow))),
        ("lastSuccessText", account.lastSuccessText.map(J.s) ?? .nul),
        ("tag", account.tag.map(J.s) ?? .nul),
    ])
}

private func encodeHourly(_ hourly: HourlyLineViewModel) -> J {
    .o([
        ("rows", .a(hourly.rows.map { row in
            let (name, hex) = colorPair(row.color)
            func bars(_ bars: [DistributionBar]) -> J {
                .a(bars.map { bar in
                    .o([
                        ("name", .s(bar.name)),
                        ("total", .i(bar.total)),
                        ("totalText", .s(bar.totalText)),
                        ("share", .d(bar.share)),
                    ])
                })
            }
            return J.o([
                ("agentId", .s(row.agentID)),
                ("name", .s(row.name)),
                ("color", .s(name)),
                ("colorHex", .s(hex)),
                ("todayTotal", .i(row.todayTotal)),
                ("todayTotalText", .s(row.todayTotalText)),
                ("points", .a(row.points.map(J.i))),
                ("isExpandable", .b(row.isExpandable)),
                ("models", bars(row.models)),
                ("projects", bars(row.projects)),
            ])
        })),
        ("collapsedPoints", .a(hourly.collapsedPoints.map(J.i))),
        ("collapsedPeakText", .s(hourly.collapsedPeakText)),
    ])
}

private func encodeDiagnostic(_ diagnostic: PanelDiagnostic) -> J {
    switch diagnostic {
    case .missingArtifact(let module):
        return .o([("kind", .s("missingArtifact")), ("module", .s(module.rawValue))])
    case .agentIssue(let agentID, let status, let note):
        return .o([
            ("kind", .s("agentIssue")),
            ("agentId", .s(agentID)),
            ("status", .s(status)),
            ("note", .s(note)),
        ])
    case .serviceIssue(let serviceID, let status, let note):
        return .o([
            ("kind", .s("serviceIssue")),
            ("serviceId", .s(serviceID)),
            ("status", .s(status)),
            ("note", .s(note)),
        ])
    case .serviceSkipped(let serviceID, let status, let note):
        return .o([
            ("kind", .s("serviceSkipped")),
            ("serviceId", .s(serviceID)),
            ("status", .s(status)),
            ("note", .s(note)),
        ])
    case .windowDropped(let serviceID, let reason):
        return .o([
            ("kind", .s("windowDropped")),
            ("serviceId", .s(serviceID)),
            ("reason", .s(reason)),
        ])
    case .emptyUsageAgents:
        return .o([("kind", .s("emptyUsageAgents"))])
    }
}

// MARK: - 结构化对拍 (数值感知)

private func compare(_ lhs: Any, _ rhs: Any, path: String, errors: inout [String]) {
    switch (lhs, rhs) {
    case (is NSNull, is NSNull):
        return
    case (let left as [String: Any], let right as [String: Any]):
        let leftKeys = Set(left.keys), rightKeys = Set(right.keys)
        for key in leftKeys.subtracting(rightKeys).sorted() {
            errors.append("\(path).\(key): mac 有而 golden 无")
        }
        for key in rightKeys.subtracting(leftKeys).sorted() {
            errors.append("\(path).\(key): golden 有而 mac 无")
        }
        for key in leftKeys.intersection(rightKeys).sorted() {
            compare(left[key]!, right[key]!, path: "\(path).\(key)", errors: &errors)
        }
    case (let left as [Any], let right as [Any]):
        if left.count != right.count {
            errors.append("\(path): 数组长度 mac=\(left.count) golden=\(right.count)")
            return
        }
        for (index, element) in left.enumerated() {
            compare(element, right[index], path: "\(path)[\(index)]", errors: &errors)
        }
    case (let left as NSNumber, let right as NSNumber):
        // 布尔先判: kCFBooleanTrue/False 与数值 1/0 需区分。
        if isBoolLike(left) != isBoolLike(right) {
            errors.append("\(path): 布尔/数值类型 mac=\(left) golden=\(right)")
            return
        }
        // token 计数与份额均在 Int64/double 精确表示范围内。
        if left.doubleValue == right.doubleValue {
            return
        }
        errors.append("\(path): 数值 mac=\(left) golden=\(right)")
    case (let left as String, let right as String):
        if left != right {
            errors.append("\(path): 字符串 mac=\(left) golden=\(right)")
        }
    default:
        errors.append("\(path): 类型不匹配 mac=\(type(of: lhs)) golden=\(type(of: rhs))")
    }
}

private func isBoolLike(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}

// MARK: - 主入口

@main
struct PanelParityHarness {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        guard let repoRoot = arguments.first else {
            print("用法: PanelParityHarness <repoRoot> [--update]")
            exit(2)
        }
        let updateMode = arguments.contains("--update")
        let root = URL(fileURLWithPath: repoRoot, isDirectory: true)
        for name in ["valid", "partial", "empty"] {
            let fixtureURL = root.appendingPathComponent("tests/fixtures/artifacts/agent-usage/\(name).json")
            let goldenURL = root.appendingPathComponent("tests/fixtures/viewmodel-parity/agent-usage-\(name).panel.json")

            do {
                let artifact = try decodeAgentUsageArtifact(fixtureURL: fixtureURL)

                // 固定 now (2026-07-28T12:30:00+08:00) 与日历 (Asia/Shanghai, 周一起),
                // 与 Rust 侧 fixture_parity 测试完全一致。
                let fixedNow = try ISO8601DateFormatter().date(from: "2026-07-28T12:30:00+08:00")
                    .unwrapOrThrow()
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
                calendar.firstWeekday = 2

                let mapper = PanelViewModelMapper(
                    liveThreshold: 45 * 60,
                    now: { fixedNow },
                    calendar: calendar
                )
                let panel = mapper.make(
                    agentUsage: artifact,
                    moduleStatuses: [:],
                    deepSeekMonthlyUsage: nil,
                    providerOrder: []
                )

                let produced = try J.data(encode(panel))

                if updateMode {
                    try FileManager.default.createDirectory(
                        at: goldenURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try produced.write(to: goldenURL)
                    print("golden 快照已刷新: \(goldenURL.path)")
                    continue
                }

                guard FileManager.default.fileExists(atPath: goldenURL.path) else {
                    print("golden 快照不存在: \(goldenURL.path) (先运行 --update 生成)")
                    exit(1)
                }
                let goldenObject = try JSONSerialization.jsonObject(with: Data(contentsOf: goldenURL))
                let producedObject = try JSONSerialization.jsonObject(with: produced)
                var errors: [String] = []
                compare(producedObject, goldenObject, path: "$", errors: &errors)
                if errors.isEmpty {
                    print("Panel 视图模型双端对拍通过 (\(name): mac 产出 ≡ golden 快照)")
                } else {
                    print("双端对拍失败, \(errors.count) 处差异:")
                    errors.prefix(20).forEach { print("  - \($0)") }
                    print("若为 mac 端预期行为变更, 运行 --update 刷新 golden 并同步审视 Windows 侧实现")
                    exit(1)
                }
            } catch {
                print("PanelParityHarness 执行失败: \(error)")
                exit(1)
            }
        }
    }
}

private extension Optional where Wrapped == Date {
    func unwrapOrThrow() throws -> Date {
        guard let value = self else { throw ParityError.invalidJSON }
        return value
    }
}
