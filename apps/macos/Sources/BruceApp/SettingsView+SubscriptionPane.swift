import AppKit
import BruceAppCore
import BruceOnboardingCore
import SwiftUI

extension SettingsView {
    // MARK: - 订阅额度面板

    /// 订阅 provider 的标签式管理: 顶部 Picker 只列未配置的 provider,
    /// 点击添加后其管理组出现在下方列表 (默认收起为一行).
    /// 读取本机文件和真实网络验证都只由用户点击触发;
    /// 失败经 model.settingsErrorMessage 提示 (fail-closed).
    var subscriptionPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            paneCaption("云端额度凭证")
            FluentCard {
                ForEach(Array(visibleSubscriptionProviders.enumerated()), id: \.element) { index, id in
                    subscriptionProviderRow(id, divided: index > 0)
                }
                if visibleSubscriptionProviders.isEmpty {
                    FluentRow("尚未配置任何订阅 Provider", sub: "从下方添加服务")
                }
            }
            .accessibilityElement(children: .contain)
            FluentCard {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("添加服务")
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsDemoTokens.text)
                        Text("只列出尚未配置的 Provider, 添加后打开配置窗口")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsDemoTokens.text2)
                    }
                    Spacer()
                    // C026: 同一原生 NSPopUpButton 控件, 每个选项前带该 provider 的品牌图形。
                    ProviderPopUpPicker(
                        providers: unconfiguredSubscriptionProviders,
                        placeholder: "选择 Provider",
                        hint: "只列出尚未配置的订阅 Provider",
                        selection: $providerToAdd
                    )
                    .fixedSize()
                    .accessibilityHint("只列出尚未配置的订阅 Provider")
                    Button("添加…") {
                        guard let id = providerToAdd else { return }
                        // Phase 4: 持久化"已添加"状态, 跨会话保持
                        coordinator.addSubscriptionProvider(id)
                        addedSubscriptionProviders.insert(id)
                        configuringProvider = id
                        providerToAdd = nil
                    }
                    .fluentButton(.primary)
                    .disabled(providerToAdd == nil)
                    .accessibilityHint("将所选 Provider 加入上方列表并打开配置窗口")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Text("配置并启用后, Agent 用量将在统一授权生效时查询对应云端额度; 拖拽行调整看板展示顺序")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsDemoTokens.text3)
        }
        .onAppear {
            coordinator.refreshOfficialLocalAvailability()
        }
    }

    /// 当前在设置中心向用户展示并允许配置的 Provider 集合（Jev 因官方未开放查额 API 暂作界面屏蔽，底层完整保留）.
    var availableSubscriptionProviders: [SubscriptionProviderID] {
        SubscriptionProviderID.allCases.filter { $0 != .jev }
    }

    /// 已在列表中展示的 provider: 配置中已添加 (持久化) 或本次会话刚添加.
    /// Phase 4: 未手动添加不显示 (与"全部手动添加"决策一致).
    var visibleSubscriptionProviders: [SubscriptionProviderID] {
        let order = model.subscriptionProviderOrder.filter { $0 != .jev }
        let inOrder = Set(order)
        let isVisible = { (id: SubscriptionProviderID) -> Bool in
            guard id != .jev else { return false }
            return (self.model.subscriptionProviders[id] != nil)
                || self.addedSubscriptionProviders.contains(id)
        }
        let ordered = order.filter(isVisible)
        let unordered = availableSubscriptionProviders.filter {
            !inOrder.contains($0) && isVisible($0)
        }
        return ordered + unordered
    }

    /// 尚未进入列表的 provider, 供添加 Picker 选择.
    var unconfiguredSubscriptionProviders: [SubscriptionProviderID] {
        availableSubscriptionProviders.filter {
            !visibleSubscriptionProviders.contains($0)
        }
    }

    /// 单个 provider 行 (P2 + D3 定稿, demo .row): 拖拽手柄 (仅此可发起拖拽,
    /// 避免误触行内按钮) + 名称/副标题 + 状态尾件 + 配置按钮 + 启用开关;
    /// 点击「配置」弹出独立配置窗口 (sheet); 拖动经 LiveReorderDropDelegate 实时让位.
    func subscriptionProviderRow(
        _ id: SubscriptionProviderID,
        divided: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(SettingsDemoTokens.text3)
                .accessibilityHidden(true)
                .draggable(id.rawValue)
            // 品牌图形徽章 (C026 方案 A): 26pt 品牌色瓷砖 + 白色图形, 与仪表盘同图形语言;
            // 未收录图形的 provider (Jev) 回退首字母。
            ProviderBrandBadge(providerID: id.rawValue, name: id.displayName, size: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(id.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsDemoTokens.text)
                Text(subscriptionRowSubtitle(id))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsDemoTokens.text2)
            }
            Spacer(minLength: 8)
            // 套餐标签 (C024): 由仪表盘移入设置中心, 与凭证形态/状态同排展示.
            if let plan = model.subscriptionPlan(for: id) {
                SubscriptionPlanTag(text: plan)
            }
            subscriptionStatusTail(id)
            Button("配置") {
                configuringProvider = id
            }
            .fluentButton()
            .accessibilityHint("打开 \(id.displayName) 的配置窗口")
            subscriptionEnabledToggle(id)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            if divided {
                SettingsDemoTokens.separator.frame(height: 1)
            }
        }
        .onDrop(
            of: [.text],
            delegate: LiveReorderDropDelegate<SubscriptionProviderID>(
                target: id,
                move: moveSubscriptionProvider
            )
        )
        .accessibilityElement(children: .contain)
    }

    /// demo .r-sub: 凭证形态 + 账号数摘要.
    func subscriptionRowSubtitle(_ id: SubscriptionProviderID) -> String {
        let kind: String
        switch id {
        case .kimi: kind = "Web 令牌"
        case .deepseek, .volcengine, .zhipu, .jev, .cline: kind = "API Key"
        case .stepfun: kind = "Step Plan Token"
        case .codex: kind = "OAuth 设备码"
        case .claude, .grok: kind = "CLI 登录态"
        case .opencodeGo: kind = "OAuth 设备码"
        }
        let count = model.providerAccountSummaries[id]?.count ?? 0
        return count > 1 ? "\(kind) · \(count) 个账号" : kind
    }

    /// demo .r-tail: 纯文字状态, ok 绿 / warn 黄 / 其他灰.
    func subscriptionStatusTail(_ id: SubscriptionProviderID) -> some View {
        let configured = model.subscriptionCredentialConfigured[id] ?? false
        let status = model.subscriptionProviders[id]?.verificationStatus ?? .none
        let text: String
        let tint: Color
        if !configured {
            text = "未配置"
            tint = SettingsDemoTokens.text3
        } else {
            switch status {
            case .ok:
                text = "已配置"
                tint = SettingsDemoTokens.ok
            case .failed:
                text = "验证失败"
                tint = SettingsDemoTokens.warn
            case .needsRelogin:
                text = "需重新登录"
                tint = SettingsDemoTokens.warn
            case .none:
                text = "已配置"
                tint = SettingsDemoTokens.ok
            }
        }
        return Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(tint)
    }

    /// demo .r-tog: 启用开关 (绑定 Coordinator.setSubscriptionProviderEnabled).
    func subscriptionEnabledToggle(_ id: SubscriptionProviderID) -> some View {
        let configured = model.subscriptionCredentialConfigured[id] ?? false
        let binding = Binding<Bool>(
            get: { model.subscriptionProviders[id]?.enabled ?? false },
            set: { enabled in
                coordinator.setSubscriptionProviderEnabled(id, enabled)
            }
        )
        return Toggle("", isOn: binding)
            .labelsHidden()
            .controlSize(.small)
            .disabled(!configured)
            .accessibilityLabel("\(id.displayName) 启用开关")
    }

    /// demo 对话框路由器 (S3): API key 类走通用弹窗, CLI/OAuth 类走骨架外壳.
    @ViewBuilder
    func providerConfigSheet(
        _ id: SubscriptionProviderID
    ) -> some View {
        switch id {
        case .kimi, .deepseek, .volcengine, .zhipu, .stepfun, .jev, .cline:
            apiKeyProviderDialog(id)
        case .codex, .claude, .grok, .opencodeGo:
            genericProviderConfigSheet(id)
        }
    }

    /// 通用配置外壳: demo 对话框骨架 + 各 provider 既有管理 section;
    /// 这些 section 自带保存/移除操作, footer 只留关闭按钮.
    func genericProviderConfigSheet(
        _ id: SubscriptionProviderID
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // dg-head
            Text("配置 \(id.displayName)")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 16)
            // dg-body
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ProviderStatusBanner(
                        configured: model.subscriptionCredentialConfigured[id] ?? false,
                        status: model.subscriptionProviders[id]?.verificationStatus ?? .none,
                        lastVerifiedAt: model.subscriptionProviders[id]?.lastVerifiedAt
                    )
                    providerAccountList(id)
                    subscriptionProviderManagement(id)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)
            }
            // dg-foot
            HStack {
                Spacer()
                Button("完成") { configuringProvider = nil }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 420)
    }

    /// API key 类 provider 的 demo 版配置对话框; 保存闭包与原内联 section 一致.
    @ViewBuilder
    func apiKeyProviderDialog(
        _ id: SubscriptionProviderID
    ) -> some View {
        let dismiss = { configuringProvider = nil }
        switch id {
        case .kimi:
            APIKeyProviderConfigDialog(
                id: .kimi,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "apiKey",
                        label: "API Key",
                        placeholder: "sk-•••••••••••••••• (输入后不回显)",
                        accessibilityLabel: "Kimi For Coding API key"
                    )
                ],
                values: $kimiValues,
                guide: ProviderCredentialGuide(
                    summary: "在 kimi.com/code 申请 Kimi For Coding API key",
                    linkTitle: nil,
                    linkURL: nil
                ),
                footnote: nil,
                extra: .none,
                onRemove: { removeSubscriptionProvider(.kimi) },
                onSave: { coordinator.saveAndVerifyKimi(apiKey: $0["apiKey"] ?? "") },
                onDismiss: dismiss
            )
        case .deepseek:
            APIKeyProviderConfigDialog(
                id: .deepseek,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "apiKey",
                        label: "API Key",
                        placeholder: "sk-•••••••••••••••• (输入后不回显)",
                        accessibilityLabel: "DeepSeek API key"
                    )
                ],
                values: $deepseekValues,
                guide: ProviderCredentialGuide(
                    summary: "在 DeepSeek 平台获取 API key",
                    linkTitle: nil,
                    linkURL: nil
                ),
                footnote: nil,
                extra: .none,
                onRemove: { removeSubscriptionProvider(.deepseek) },
                onSave: { coordinator.saveAndVerifyDeepSeek(apiKey: $0["apiKey"] ?? "") },
                onDismiss: dismiss
            )
        case .volcengine:
            APIKeyProviderConfigDialog(
                id: .volcengine,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "accessKey",
                        label: "Access Key",
                        placeholder: "AK•••••••• (输入后不回显)",
                        accessibilityLabel: "火山引擎 Access Key"
                    ),
                    APIKeyFieldDescriptor(
                        id: "secretKey",
                        label: "Secret Key",
                        placeholder: "SK•••••••• (输入后不回显)",
                        accessibilityLabel: "火山引擎 Secret Key"
                    )
                ],
                values: $volcengineValues,
                guide: ProviderCredentialGuide(
                    summary: "在火山引擎控制台获取 Access Key 与 Secret Key",
                    linkTitle: nil,
                    linkURL: nil
                ),
                footnote: "此处仅做本地格式校验, 完整额度试查由 Collector 运行时承担",
                extra: .ccSwitchImport($showsVolcengineCCImportConfirm),
                onRemove: { removeSubscriptionProvider(.volcengine) },
                onSave: {
                    coordinator.saveAndVerifyVolcengine(
                        accessKey: $0["accessKey"] ?? "",
                        secretKey: $0["secretKey"] ?? ""
                    )
                },
                onDismiss: dismiss
            )
        case .zhipu:
            APIKeyProviderConfigDialog(
                id: .zhipu,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "apiKey",
                        label: "API Key",
                        placeholder: "•••••••• (输入后不回显)",
                        accessibilityLabel: "Z.ai API key"
                    )
                ],
                values: $zhipuValues,
                guide: ProviderCredentialGuide(
                    summary: "在 Z.ai（BigModel）控制台获取 API key",
                    linkTitle: nil,
                    linkURL: nil
                ),
                footnote: "此处仅做本地格式校验, 完整额度试查由 Collector 运行时承担",
                extra: .sitePicker($zhipuSiteIsCN),
                onRemove: { removeSubscriptionProvider(.zhipu) },
                onSave: {
                    coordinator.saveAndVerifyZhipu(
                        apiKey: $0["apiKey"] ?? "",
                        baseURL: zhipuSiteIsCN
                            ? "https://open.bigmodel.cn/api/paas/v4"
                            : "https://api.z.ai/api/paas/v4"
                    )
                },
                onDismiss: dismiss
            )
        case .stepfun:
            APIKeyProviderConfigDialog(
                id: .stepfun,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "token",
                        label: "Oasis-Token",
                        placeholder: "•••••••• (输入后不回显)",
                        accessibilityLabel: "StepFun Step Plan Oasis-Token"
                    )
                ],
                values: $stepfunValues,
                guide: ProviderCredentialGuide(
                    summary: "可点击上方一键登录自动绑定(支持国内/国际站)，或控制台按 F12 复制 Cookie",
                    linkTitle: "打开 StepFun 控制台",
                    linkURL: URL(string: "https://platform.stepfun.com")
                ),
                footnote: "凭据安全保存在本机 Keychain, 支持国内站与国际站多账号混合添加",
                extra: .stepfunWebLogin(
                    onLoginDomestic: {
                        stepfunLoginSite = .domestic
                        showsStepFunWebLogin = true
                    },
                    onLoginGlobal: {
                        stepfunLoginSite = .global
                        showsStepFunWebLogin = true
                    }
                ),
                onRemove: { removeSubscriptionProvider(.stepfun) },
                onSave: {
                    coordinator.saveAndVerifyStepFun(
                        token: $0["token"] ?? ""
                    )
                },
                onDismiss: dismiss
            )
            .sheet(isPresented: $showsStepFunWebLogin) {
                StepFunWebLoginView(initialSite: stepfunLoginSite) { token, site in
                    coordinator.saveAndVerifyStepFun(token: token, site: site)
                    stepfunValues["token"] = token
                    configuringProvider = nil
                }
            }
        case .jev:
            APIKeyProviderConfigDialog(
                id: .jev,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "apiKey",
                        label: "API Key",
                        placeholder: "•••••••• (输入后不回显)",
                        accessibilityLabel: "TypeSafe Jev API Key"
                    ),
                    APIKeyFieldDescriptor(
                        id: "balance",
                        label: "账户余额 (USD，选填)",
                        placeholder: "输入在控制台充值的当前余额 (如 10.00)",
                        accessibilityLabel: "TypeSafe Jev 账户余额",
                        isOptional: true
                    ),
                ],
                values: $jevValues,
                guide: ProviderCredentialGuide(
                    summary: "在 TypeSafe 控制台获取 Jev API Key 与充值余额",
                    linkTitle: "打开 TypeSafe 控制台",
                    linkURL: URL(string: "https://console.typesafe.ai/keys")
                ),
                footnote: "由于 TypeSafe 暂未开放余额查询接口, 填写充值余额可在看板统一展示余额胶囊",
                extra: .none,
                onRemove: { removeSubscriptionProvider(.jev) },
                onSave: {
                    let key = $0["apiKey"] ?? ""
                    let balanceStr = ($0["balance"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let balance = Double(balanceStr)
                    coordinator.saveAndVerifyJev(
                        apiKey: key,
                        balance: balance
                    )
                },
                onDismiss: dismiss
            )
        case .cline:
            APIKeyProviderConfigDialog(
                id: .cline,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "apiKey",
                        label: "API Key",
                        placeholder: "•••••••• (输入后不回显)",
                        accessibilityLabel: "Cline API Key"
                    ),
                ],
                values: $clineValues,
                guide: ProviderCredentialGuide(
                    summary: "在 Cline 控制台 Settings > API Keys 创建 API Key",
                    linkTitle: "打开 Cline 控制台",
                    linkURL: URL(string: "https://app.cline.bot")
                ),
                footnote: "ClinePass 三窗口额度 (5h / 7d / 30d) 由采集端读取账户计划与逐单台账自动计算",
                extra: .none,
                onRemove: { removeSubscriptionProvider(.cline) },
                onSave: {
                    coordinator.saveAndVerifyCline(apiKey: $0["apiKey"] ?? "")
                },
                onDismiss: dismiss
            )
        default:
            EmptyView()
        }
    }

    /// 多账号列表: 显示该 provider 的全部账号 (名称 + 状态 + 移除按钮).
    /// 单账号 (0 或 1 个) 不显示列表, 保持现有管理 UI.
    /// Codex 走专用 codexGroup (已有账号状态列表).
    func providerAccountList(_ id: SubscriptionProviderID) -> some View {
        let summaries = model.providerAccountSummaries[id] ?? []
        guard id != .codex, summaries.count >= 1 else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(summaries.enumerated()), id: \.element.accountID) {
                    _, summary in
                    HStack(spacing: 6) {
                        Text(summary.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        accountStateLabel(summary)
                        Button {
                            accountRemovalRequest = AccountRemovalRequest(
                                provider: id,
                                accountID: summary.accountID,
                                displayName: summary.displayName
                            )
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除账号 \(summary.displayName)")
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 2)
        )
    }

    /// 订阅套餐标签 (C024): 套餐名从仪表盘移入设置中心后的小型描边标签.
    struct SubscriptionPlanTag: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(SettingsDemoTokens.text2)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(SettingsDemoTokens.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(SettingsDemoTokens.separator, lineWidth: 0.5)
                )
                .accessibilityLabel("订阅套餐 \(text)")
        }
    }

    /// 账号状态文案 (非敏感).
    func accountStateLabel(
        _ summary: ProviderAccountSummary
    ) -> some View {
        let (text, icon): (String, String)
        switch summary.authorizationState {
        case .connected:
            text = "已连接"
            icon = "checkmark.circle.fill"
        case .needsReauthorization:
            text = "需要重新登录"
            icon = "exclamationmark.triangle.fill"
        case .revoked:
            text = "已撤销"
            icon = "xmark.circle.fill"
        }
        return Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(summary.authorizationState == .connected
                ? Color.secondary : Color.orange)
            .accessibilityLabel("\(summary.displayName) 状态: \(text)")
    }

    /// 非 API key 类 provider 的管理 section, 仅用于通用配置外壳;
    /// API key 类 (Kimi/DeepSeek/火山/智谱) 已由 APIKeyProviderConfigDialog 接管.
    @ViewBuilder
    func subscriptionProviderManagement(
        _ id: SubscriptionProviderID
    ) -> some View {
        switch id {
        case .kimi, .deepseek, .volcengine, .zhipu, .stepfun, .jev, .cline:
            // 对话框版表单已接管, 通用外壳不会走到这里.
            EmptyView()
        case .codex:
            CodexProviderSettingsSection(
                showsCodexCCImportConfirm: $showsCodexCCImportConfirm,
                onRemove: { removeSubscriptionProvider(.codex) },
                onRemoveAccount: { accountID, displayName in
                    accountRemovalRequest = AccountRemovalRequest(
                        provider: .codex,
                        accountID: accountID,
                        displayName: displayName
                    )
                }
            )
        case .claude:
            ClaudeProviderSettingsSection(
                claudePasteText: $claudePasteText,
                claudeEditing: $claudeEditing,
                onRemove: { removeSubscriptionProvider(.claude) }
            )
        case .grok:
            GrokProviderSettingsSection(
                grokPasteText: $grokPasteText,
                grokEditing: $grokEditing,
                onRemove: { removeSubscriptionProvider(.grok) }
            )
        case .opencodeGo:
            OfficialLocalProviderSettingsSection(
                id: .opencodeGo,
                available: false,
                missingHint: "未检测到 OpenCode GO 登录态",
                pasteText: $opencodeGoPasteText,
                onRemove: { removeSubscriptionProvider(.opencodeGo) },
                importFromLocal: {},
                savePaste: { coordinator.importOpenCodeGoFromPaste($0) },
                pasteHint: "打开 opencode.ai → 登录 → 开发者工具 → Application → Cookies → 复制 auth 值 (Fe26.2**...) 与 workspace URL 中的 wrk_ ID, 粘贴 JSON",
                showsLocalRedetect: false,
                isEditing: $opencodeGoEditing
            )
        }
    }

    /// 移除 provider: 凭证与配置由 coordinator 处理 (fail-closed),
    /// 成功后该行从列表消失并回到添加 Picker.
    func removeSubscriptionProvider(_ id: SubscriptionProviderID) {
        coordinator.removeSubscriptionProvider(id)
        addedSubscriptionProviders.remove(id)
    }

    /// 调整订阅 provider 在列表中的顺序; 顺序同时作用于面板用量卡展示.
    func moveSubscriptionProvider(
        _ dragged: SubscriptionProviderID,
        onto target: SubscriptionProviderID
    ) {
        var order = visibleSubscriptionProviders
        order.removeAll { $0 == dragged }
        guard let targetIndex = order.firstIndex(of: target) else { return }
        order.insert(dragged, at: targetIndex)
        coordinator.setSubscriptionProviderOrder(order)
    }

}
