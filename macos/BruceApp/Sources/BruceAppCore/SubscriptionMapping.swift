import Foundation

// MARK: - Subscription mapping

extension PanelViewModelMapper {
    /// 领域月度状态 -> 展示 view model.
    /// nil -> nil (映射层未启用账本, 订阅卡不显示月度统计).
    /// unavailable -> 显示"月度统计暂不可用" (不暴露内部错误细节).
    /// baseline -> 只有覆盖说明与"正在建立本月趋势", 不可绘制趋势.
    /// trend -> 推算消费, 余额, 覆盖说明, 趋势点和入账注记.
    func deepSeekMonthlyUsageViewModel(
        _ usage: DeepSeekMonthlyUsage?
    ) -> DeepSeekMonthlyUsageViewModel? {
        switch usage {
        case .trend(let trend):
            return DeepSeekMonthlyUsageViewModel(
                state: .trend,
                estimatedConsumptionText: PanelFormat.decimalBalanceText(
                    trend.estimatedConsumption, currency: trend.currency
                ),
                currentBalanceText: PanelFormat.decimalBalanceText(
                    trend.currentBalance, currency: trend.currency
                ),
                coverageText: trend.coverageText,
                trendPoints: trend.trendPoints,
                creditNote: trend.recentCreditNote
            )
        case .baseline(let baseline):
            return DeepSeekMonthlyUsageViewModel(
                state: .baseline,
                estimatedConsumptionText: "",
                currentBalanceText: PanelFormat.decimalBalanceText(
                    baseline.currentBalance, currency: baseline.currency
                ),
                coverageText: baseline.coverageStartText,
                trendPoints: [],
                creditNote: nil
            )
        case .unavailable:
            return DeepSeekMonthlyUsageViewModel(
                state: .unavailable,
                estimatedConsumptionText: "",
                currentBalanceText: "",
                coverageText: "月度统计暂不可用",
                trendPoints: [],
                creditNote: nil
            )
        case nil:
            return nil
        }
    }

    // MARK: 订阅卡

    func makeSubscription(
        _ artifact: AgentUsageArtifact,
        now: Date,
        deepSeekMonthlyUsage: DeepSeekMonthlyUsage?,
        providerOrder: [String],
        diagnostics: inout [PanelDiagnostic]
    ) -> SubscriptionViewModel? {
        // 按 provider 分组所有 service.
        // 同一 provider 的多个 service (多账号) 分组成一个 section;
        // 单个 service 直接作为 section.
        struct ProviderGroup {
            let providerID: String
            let displayName: String
            var services: [(service: AgentServiceItem, windows: [SubscriptionWindowRow], note: String?)] = []
        }
        var groups: [String: ProviderGroup] = [:]
        var groupOrder: [String] = []

        for service in artifact.services {
            let kind = service.kind
            let note = normalizedNote(service.note)
            let hasWindows = !service.windows.isEmpty
            let hasBalance = service.balance != nil

            if SubscriptionPresentationPolicy.shouldSkipPlaceholder(
                kind: kind,
                hasWindows: hasWindows,
                hasBalance: hasBalance,
                status: service.status
            ) {
                diagnostics.append(.serviceSkipped(
                    serviceID: service.id,
                    status: service.status,
                    note: note ?? ""
                ))
                continue
            }

            if service.status != "ok" {
                diagnostics.append(.serviceIssue(
                    serviceID: service.id,
                    status: service.status,
                    note: note ?? ""
                ))
            }

            let windows = service.windows.compactMap { raw -> SubscriptionWindowRow? in
                parseWindow(raw, serviceID: service.id, now: now, diagnostics: &diagnostics)
            }

            let providerID = SubscriptionPresentationPolicy.providerID(forServiceID: service.id)
            let displayName = SubscriptionPresentationPolicy.displayName(
                serviceID: service.id, serviceName: service.name
            )

            if groups[providerID] == nil {
                groups[providerID] = ProviderGroup(providerID: providerID, displayName: displayName)
                groupOrder.append(providerID)
            }
            groups[providerID]?.services.append((service, windows, note))
        }

        // 按 provider 组装 sections.
        var sections: [SubscriptionProviderSection] = []
        for providerID in groupOrder {
            guard let group = groups[providerID] else { continue }
            let services = group.services

            if services.count == 1 {
                // 单账号: 直接作为 section, 保持现有展示.
                // section 名称只用 provider 分组名 (不显示账号名, 无需区分);
                // accounts 携带单条记录 (供测试和 UI 取 lastSuccessText 等),
                // 但 isMultiAccount 为 false, 不触发折叠.
                let svc = services[0]
                let monthlyUsage = SubscriptionPresentationPolicy.shouldAttachDeepSeekMonthly(
                    serviceID: providerID
                ) ? deepSeekMonthlyUsageViewModel(deepSeekMonthlyUsage) : nil

                let accountVM = CodexAccountViewModel(
                    id: svc.service.id,
                    name: SubscriptionPresentationPolicy.accountShortName(
                        from: svc.service.name, providerID: providerID
                    ),
                    plan: svc.service.plan,
                    status: svc.service.status,
                    note: svc.note,
                    windows: svc.windows,
                    lastSuccessText: lastSuccessText(for: svc.service, now: now)
                )

                sections.append(SubscriptionProviderSection(
                    id: svc.service.id,
                    name: SubscriptionPresentationPolicy.groupDisplayName(providerID: providerID),
                    plan: svc.service.plan,
                    status: svc.service.status,
                    note: svc.note,
                    extraText: SubscriptionPresentationPolicy.extraText(normalizedNote(svc.service.extra)),
                    windows: svc.windows,
                    accounts: [accountVM],
                    collapsedWindow: nil,
                    balance: svc.service.balance.map { BalanceRow(amount: $0, currency: svc.service.currency) },
                    accountCountText: nil,
                    deepSeekMonthlyUsage: monthlyUsage
                ))
            } else {
                // 多账号: 分组成 section + accounts + collapsedWindow.
                let accountVMs: [CodexAccountViewModel] = services.map { item in
                    CodexAccountViewModel(
                        id: item.service.id,
                        name: SubscriptionPresentationPolicy.accountShortName(
                            from: item.service.name, providerID: providerID
                        ),
                        plan: item.service.plan,
                        status: item.service.status,
                        note: item.note,
                        windows: item.windows,
                        lastSuccessText: lastSuccessText(for: item.service, now: now)
                    )
                }
                let groupStatus = SubscriptionPresentationPolicy.codexGroupStatus(
                    from: accountVMs.map(\.status)
                )
                let collapsed = SubscriptionPresentationPolicy.collapsedWindow(
                    from: accountVMs
                )
                let monthlyUsage = SubscriptionPresentationPolicy.shouldAttachDeepSeekMonthly(
                    serviceID: providerID
                ) ? deepSeekMonthlyUsageViewModel(deepSeekMonthlyUsage) : nil

                sections.append(SubscriptionProviderSection(
                    id: providerID,
                    name: SubscriptionPresentationPolicy.groupDisplayName(providerID: providerID),
                    plan: nil,
                    status: groupStatus,
                    note: nil,
                    extraText: nil,
                    windows: [],
                    accounts: accountVMs,
                    collapsedWindow: collapsed,
                    balance: nil,
                    accountCountText: "\(accountVMs.count) 个账号",
                    deepSeekMonthlyUsage: monthlyUsage
                ))
            }
        }

        guard !sections.isEmpty else {
            return nil
        }

        // 用户自定义顺序优先; 无自定义顺序时余额型沉底, 其余保持 artifact 顺序.
        let sorted: [SubscriptionProviderSection]
        if providerOrder.isEmpty {
            sorted = sections.enumerated().sorted { lhs, rhs in
                let lhsBalance = lhs.element.balance != nil
                let rhsBalance = rhs.element.balance != nil
                if lhsBalance != rhsBalance {
                    return !lhsBalance
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        } else {
            let orderIndex = Dictionary(
                providerOrder.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { a, _ in a }
            )
            sorted = sections.enumerated().sorted { lhs, rhs in
                let lhsIdx = orderIndex[SubscriptionPresentationPolicy.providerID(forServiceID: lhs.element.id)] ?? Int.max
                let rhsIdx = orderIndex[SubscriptionPresentationPolicy.providerID(forServiceID: rhs.element.id)] ?? Int.max
                if lhsIdx != rhsIdx {
                    return lhsIdx < rhsIdx
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }

        return SubscriptionViewModel(
            sections: sorted,
            updatedText: updatedText(from: artifact.generatedAt)
        )
    }

    /// 订阅卡右上角更新时间: "最后更新 HH:mm" (24 小时制, 跟随 mapper 时区);
    /// generatedAt 解析失败返回 nil, 卡片不渲染该文案.
    func updatedText(from generatedAt: String) -> String? {
        guard let date = Self.parseISODate(generatedAt) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = calendar.timeZone
        return "最后更新 " + formatter.string(from: date)
    }

    func parseWindow(
        _ raw: JSONValue,
        serviceID: String,
        now: Date,
        diagnostics: inout [PanelDiagnostic]
    ) -> SubscriptionWindowRow? {
        guard case .object(let object) = raw else {
            diagnostics.append(.windowDropped(serviceID: serviceID, reason: "窗口条目不是对象"))
            return nil
        }
        guard let label = object["label"]?.stringValue else {
            diagnostics.append(.windowDropped(serviceID: serviceID, reason: "缺少 label"))
            return nil
        }
        guard let usedPercent = object["usedPercent"]?.doubleValue else {
            diagnostics.append(.windowDropped(serviceID: serviceID, reason: "缺少 usedPercent: \(label)"))
            return nil
        }
        let clamped = min(100, max(0, usedPercent))
        let minutes = object["windowMinutes"]?.intValue
        let resetsAt = object["resetsAt"].flatMap(Self.parseResetDate)
        return SubscriptionWindowRow(
            label: PanelFormat.windowLabel(rawLabel: label, windowMinutes: minutes),
            usedPercent: clamped,
            resetText: PanelFormat.resetText(
                resetsAt: resetsAt,
                now: now,
                calendar: calendar
            ),
            ownRow: object["ownRow"]?.boolValue ?? false,
            windowMinutes: minutes
        )
    }

    /// freshness=stale 且有 capturedAt 时显示"上次成功 HH:mm";
    /// freshness=fresh/unavailable 或无 capturedAt 时不显示.
    func lastSuccessText(
        for service: AgentServiceItem,
        now: Date
    ) -> String? {
        guard service.freshness == "stale",
              let capturedAt = service.capturedAt,
              let date = Self.parseISODate(capturedAt) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = calendar.timeZone
        let prefix = "上次成功 "
        return prefix + formatter.string(from: date)
    }
}

extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .integer(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let value):
            return value
        case .double(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }
}
