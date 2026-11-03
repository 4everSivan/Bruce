import SwiftUI
import BruceAppCore
import BruceOnboardingCore

/// 独立出口通道设置卡片 (极简磁贴架构 · 纯图标服务 + 现代 PORT 胶囊)
/// 严格对齐最新交互规范：
/// 1. 标题为「出口IP检查」，描述精简为「受保护的订阅服务通过出口校验后方可查询余额。」；
/// 2. 新建弹窗彻底去除强行滚动条，高度自适应，布局舒展通透；
/// 3. 弹窗内各步骤描述极简，代理端口单行紧凑呈现，服务选择采用紧凑双列网格且默认不强制全选；
/// 4. 彻底解决挤压与溢出问题。
struct EgressSettingsCard: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let providers: [SubscriptionProviderID]

    @State private var showsCreateModal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部标题与通道计数
            HStack(alignment: .firstTextBaseline) {
                Text("出口IP检查")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                Spacer()
                if !coordinator.egressGroups.groups.isEmpty {
                    Text("已激活 \(coordinator.egressGroups.groups.count) 个通道")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SettingsDemoTokens.accent)
                }
            }

            // 精简描述文案
            Text("受保护的订阅服务通过出口校验后方可查询余额。")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsDemoTokens.text2)

            // 已激活通道列表
            if !coordinator.egressGroups.groups.isEmpty {
                FluentCard {
                    ForEach(Array(coordinator.egressGroups.groups.enumerated()), id: \.element.country) { index, group in
                        if index > 0 {
                            SettingsDemoTokens.separator.frame(height: 1)
                        }
                        EgressChannelTile(
                            coordinator: coordinator,
                            group: group,
                            allConfiguredProviders: providers
                        )
                    }
                }
            }

            // 新建通道虚线卡片 (Dashed Card)
            addChannelDashedCard
        }
        .sheet(isPresented: $showsCreateModal) {
            CreateChannelSheet(
                coordinator: coordinator,
                allConfiguredProviders: providers,
                isPresented: $showsCreateModal
            )
        }
    }

    // MARK: - 新建通道虚线卡片

    private var addChannelDashedCard: some View {
        Button {
            showsCreateModal = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(SettingsDemoTokens.accent.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("新建出口通道")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SettingsDemoTokens.text)
                    Text("配置国家、代理端口与受保护服务")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(SettingsDemoTokens.surface.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        SettingsDemoTokens.separator,
                        style: StrokeStyle(lineWidth: 1.2, dash: [4, 4])
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开向导开辟新的出口通道")
    }
}

// MARK: - 常用国家定义

private struct QuickCountryItem: Identifiable {
    let code: String
    let name: String
    let flag: String

    var id: String { code }
}

private let popularCountries: [QuickCountryItem] = [
    QuickCountryItem(code: "JP", name: "日本", flag: "🇯🇵"),
    QuickCountryItem(code: "US", name: "美国", flag: "🇺🇸"),
    QuickCountryItem(code: "SG", name: "新加坡", flag: "🇸🇬"),
    QuickCountryItem(code: "GB", name: "英国", flag: "🇬🇧"),
    QuickCountryItem(code: "DE", name: "德国", flag: "🇩🇪"),
    QuickCountryItem(code: "KR", name: "韩国", flag: "🇰🇷"),
]

// MARK: - 新建出口通道弹窗向导 (舒展通透 · 零多余滚动条 · 文案极简)

private struct CreateChannelSheet: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let allConfiguredProviders: [SubscriptionProviderID]
    @Binding var isPresented: Bool

    @State private var selectedCountry: String = "JP"
    @State private var customCountry: String = ""
    @State private var isCustomCodeActive: Bool = false
    @FocusState private var isCustomCodeFocused: Bool
    @State private var portText: String = "7897"
    @State private var selectedProviders: Set<SubscriptionProviderID> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 弹窗头部标题栏
            HStack {
                Text("新建出口通道")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }
                .buttonStyle(.plain)
            }

            // 步骤 1: 目标出口国家
            step1CountrySection

            // 步骤 2: 绑定专用代理端口 (单行精炼呈现)
            step2PortSection

            // 步骤 3: 选择受保护服务 (双列紧凑卡片，不强制全选)
            step3ServicesSection

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsDemoTokens.danger)
            }

            // 底部操作按钮
            HStack {
                Button("取消") {
                    isPresented = false
                }
                .fluentButton(.plain)

                Spacer()

                Button("创建并测试通道") {
                    commitCreateChannel()
                }
                .fluentButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            initDefaults()
        }
    }

    // 步骤 1: 国家选择
    private var step1CountrySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("1. 目标出口国家")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)

                Spacer()

                if isCustomCodeActive || !customCountry.isEmpty {
                    HStack(spacing: 6) {
                        Text("自定义代码:")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsDemoTokens.text2)
                        TextField("例如 FR", text: $customCountry)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 68)
                            .focused($isCustomCodeFocused)
                            .onChange(of: customCountry) { _, val in
                                let filtered = val.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                                if filtered != val { customCountry = filtered }
                                if filtered.count == 2 {
                                    selectedCountry = filtered
                                    errorMessage = nil
                                }
                            }
                            .onChange(of: isCustomCodeFocused) { _, focused in
                                if !focused && customCountry.isEmpty {
                                    isCustomCodeActive = false
                                }
                            }
                    }
                } else {
                    Button {
                        isCustomCodeActive = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            isCustomCodeFocused = true
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("自定义代码:")
                                .font(.system(size: 11))
                                .foregroundStyle(SettingsDemoTokens.text2)
                            Text("例如 FR")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(SettingsDemoTokens.text3)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(SettingsDemoTokens.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(SettingsDemoTokens.separator, lineWidth: 0.8)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .help("点击输入其他 2 位 ISO 国家代码")
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(popularCountries) { item in
                    let isSelected = selectedCountry == item.code && customCountry.isEmpty
                    let alreadyExists = coordinator.egressGroups.groups.contains { $0.country == item.code }

                    Button {
                        customCountry = ""
                        isCustomCodeActive = false
                        selectedCountry = item.code
                        errorMessage = nil
                    } label: {
                        HStack(spacing: 8) {
                            Text(item.flag)
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(isSelected ? SettingsDemoTokens.text : SettingsDemoTokens.text2)
                                Text(item.code)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(SettingsDemoTokens.text3)
                            }
                            Spacer(minLength: 0)
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(SettingsDemoTokens.accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(isSelected ? SettingsDemoTokens.surfaceHover : SettingsDemoTokens.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    isSelected ? SettingsDemoTokens.accent : SettingsDemoTokens.separator,
                                    lineWidth: isSelected ? 1.5 : 1
                                )
                        )
                        .opacity(alreadyExists ? 0.45 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(alreadyExists)
                    .help(alreadyExists ? "\(item.name)通道已存在" : "选择 \(item.name)")
                }
            }
        }
    }

    // 步骤 2: 端口配置 (精简呈现，扫描按钮靠最右边)
    private var step2PortSection: some View {
        HStack(spacing: 12) {
            Text("2. 代理端口")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(SettingsDemoTokens.text)

            ModernPortCapsule(portText: $portText) {}

            Spacer()

            Button {
                portText = "7897"
            } label: {
                HStack(spacing: 4) {
                    Text("💡")
                    Text("扫描到端口 7897")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SettingsDemoTokens.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(SettingsDemoTokens.surfaceHover)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("一键填入本机检测到的 7897")
        }
    }

    // 步骤 3: 服务勾选 (双列紧凑网格，默认不强制全选)
    private var step3ServicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("3. 保护服务 (可选)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                Spacer()
                Text("勾选的服务将强制经此通道查额")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }

            if allConfiguredProviders.isEmpty {
                Text("尚未配置订阅服务，创建通道后可随时分配。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsDemoTokens.text3)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(allConfiguredProviders, id: \.rawValue) { p in
                        let currentGroup = coordinator.egressGroups.groups.first { $0.providers.contains(p) }
                        let isChecked = selectedProviders.contains(p)

                        Button {
                            if isChecked {
                                selectedProviders.remove(p)
                            } else {
                                selectedProviders.insert(p)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12))
                                    .foregroundStyle(isChecked ? SettingsDemoTokens.accent : SettingsDemoTokens.text3)
                                ProviderBrandBadge(providerID: p.rawValue, name: p.displayName, size: 18)
                                Text(p.displayName)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(SettingsDemoTokens.text)
                                Spacer(minLength: 2)
                                if let cg = currentGroup {
                                    Text("\(cg.flag) \(cg.country)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(SettingsDemoTokens.text3)
                                } else {
                                    Text("未分配")
                                        .font(.system(size: 10))
                                        .foregroundStyle(SettingsDemoTokens.ok)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(isChecked ? SettingsDemoTokens.surfaceHover : SettingsDemoTokens.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        isChecked ? SettingsDemoTokens.accent.opacity(0.6) : SettingsDemoTokens.separator,
                                        lineWidth: 0.8
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func initDefaults() {
        // 自动选择第一个尚未创建的常用国家
        if let firstAvail = popularCountries.first(where: { item in
            !coordinator.egressGroups.groups.contains { $0.country == item.code }
        }) {
            selectedCountry = firstAvail.code
        }
        // 默认不强制全选服务，由用户按需勾选
        selectedProviders = []
        customCountry = ""
        isCustomCodeActive = false
        portText = "7897"
    }

    private func commitCreateChannel() {
        let finalCode = customCountry.isEmpty ? selectedCountry : customCountry
        let trimmed = finalCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard EgressCountryGroups.isValidCountryCode(trimmed) else {
            errorMessage = "无效的国家代码，请输入标准的 2 位字母 ISO 代码"
            return
        }
        if coordinator.egressGroups.groups.contains(where: { $0.country == trimmed }) {
            errorMessage = "该国家通道已存在"
            return
        }

        guard let port = UInt16(portText), port > 0 else {
            errorMessage = "请输入有效的代理端口号 (1-65535)"
            return
        }

        // 1. 创建国家通道
        coordinator.updateEgressGroups { try $0.addCountry(trimmed) }
        // 2. 绑定代理端口
        coordinator.updateEgressGroups { try $0.setProxyPort(port, for: trimmed) }
        // 3. 分配勾选的服务
        for p in selectedProviders {
            coordinator.updateEgressGroups { try $0.assign(p, to: trimmed) }
        }

        isPresented = false
    }
}

// MARK: - 单行极简磁贴通道卡片 (分区呼吸感 + 数量上限折叠)

private struct EgressChannelTile: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let group: EgressCountryGroup
    let allConfiguredProviders: [SubscriptionProviderID]

    @State private var portText: String = ""
    @State private var routeResult: String?
    @State private var testing: Bool = false
    @State private var showsAddServicePopover = false

    /// 单行磁贴中最多直接展示的图标数量，超出部分折叠为 +N 胶囊
    private let maxVisibleIcons = 3

    private var countryLocalizedName: String {
        Locale.current.localizedString(forRegionCode: group.country) ?? group.country
    }

    /// 未分配到任何通道的订阅 Provider
    private var unassignedProviders: [SubscriptionProviderID] {
        allConfiguredProviders.filter { provider in
            !coordinator.egressGroups.groups.contains { $0.providers.contains(provider) }
        }
    }

    private var statusLevel: FluentStatusDot.Level {
        if testing {
            return .warn
        } else if let result = routeResult ?? group.lastTestResult {
            if result.hasPrefix("线路探测匹配") {
                return .ok
            } else if result.hasPrefix("出口国家不匹配") {
                return .danger
            } else {
                return .warn
            }
        } else if group.proxyPort != nil {
            return .off
        } else {
            return .off
        }
    }

    private var statusText: String {
        if testing {
            return "正在探测出口线路…"
        } else if let result = routeResult ?? group.lastTestResult {
            return result
        } else if let port = group.proxyPort {
            return "127.0.0.1:\(port) · 点击 ↻ 测试"
        } else {
            return "尚未配置代理端口"
        }
    }

    private var statusColor: Color {
        statusLevel.color
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 国旗 (纯净裸国旗，无底色卡片包裹)
            Text(group.flag)
                .font(.system(size: 22))
                .frame(width: 28)

            // 通道名称与状态指示
            VStack(alignment: .leading, spacing: 2) {
                Text("\(countryLocalizedName) (\(group.country))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                HStack(spacing: 5) {
                    FluentStatusDot(level: statusLevel)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // 右端操作区 (三大分区清晰隔离，绝不挤压)
            HStack(spacing: 8) {
                // 分区 1: 现代 PORT 胶囊
                ModernPortCapsule(portText: $portText) {
                    commitPort()
                }

                // 竖向细微视觉分隔条
                verticalSeparator

                // 分区 2: 受保护服务图标栈 (有数量上限，防横向无限膨胀)
                protectedServicesCluster

                // 竖向细微视觉分隔条
                verticalSeparator

                // 分区 3: 测试与解散操作区
                actionCluster
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
        .onAppear {
            portText = group.proxyPort.map(String.init) ?? ""
            routeResult = group.lastTestResult
        }
        .onChange(of: portText) { _, newText in
            let digits = newText.filter { $0.isASCII && $0.isNumber }
            if digits != newText {
                portText = digits
                return
            }
            if let port = UInt16(digits), port > 0 {
                if group.proxyPort != port {
                    coordinator.updateEgressGroups { try? $0.setProxyPort(port, for: group.country) }
                }
            } else if digits.isEmpty {
                if group.proxyPort != nil {
                    coordinator.updateEgressGroups { try? $0.setProxyPort(nil, for: group.country) }
                }
            }
        }
    }

    // 细微竖向分隔条
    private var verticalSeparator: some View {
        Rectangle()
            .fill(SettingsDemoTokens.separator)
            .frame(width: 1, height: 16)
    }

    // 分区 2：受保护服务图标栈 (上限保护 + 零下拉箭头)
    private var protectedServicesCluster: some View {
        HStack(spacing: 4) {
            // 最多直接渲染 maxVisibleIcons 个图标
            ForEach(Array(group.providers.prefix(maxVisibleIcons)), id: \.rawValue) { provider in
                ProtectedServiceIconBadge(provider: provider) {
                    coordinator.updateEgressGroups { $0.remove(provider) }
                }
            }

            // 超出部分折叠为精致的 +N 胶囊
            if group.providers.count > maxVisibleIcons {
                Menu {
                    ForEach(Array(group.providers.dropFirst(maxVisibleIcons)), id: \.rawValue) { provider in
                        Button("移出 \(provider.displayName)") {
                            coordinator.updateEgressGroups { $0.remove(provider) }
                        }
                    }
                } label: {
                    Text("+\(group.providers.count - maxVisibleIcons)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SettingsDemoTokens.text2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(SettingsDemoTokens.surfaceHover)
                        .clipShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .help("查看并管理其余 \(group.providers.count - maxVisibleIcons) 个受保护服务")
            }

            // 仅在存在未分配服务且当前通道未达到上限时，才显示 ＋ 分配按钮 (无多余下拉箭头)
            if !unassignedProviders.isEmpty && group.providers.count < 6 {
                Button {
                    showsAddServicePopover = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(SettingsDemoTokens.separator, style: StrokeStyle(lineWidth: 1, dash: [2]))
                            .frame(width: 22, height: 22)
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SettingsDemoTokens.text2)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsAddServicePopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("分配受保护服务")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(SettingsDemoTokens.text)
                            .padding(.bottom, 2)

                        ForEach(unassignedProviders, id: \.rawValue) { p in
                            Button {
                                coordinator.updateEgressGroups { try $0.assign(p, to: group.country) }
                                showsAddServicePopover = false
                            } label: {
                                HStack(spacing: 8) {
                                    ProviderBrandBadge(providerID: p.rawValue, name: p.displayName, size: 18)
                                    Text(p.displayName)
                                        .font(.system(size: 12))
                                        .foregroundStyle(SettingsDemoTokens.text)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .frame(width: 170)
                }
                .help("分配尚未受保护的订阅服务到此通道")
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(SettingsDemoTokens.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // 分区 3：操作按钮区
    private var actionCluster: some View {
        HStack(spacing: 6) {
            // 测试线路按钮
            Button {
                runRouteTest()
            } label: {
                if testing {
                    ProgressView().controlSize(.small)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
            }
            .fluentButton(.plain)
            .disabled(group.proxyPort == nil || testing)
            .help("测试代理线路并探测出口国家")

            // 解散通道按钮
            Button {
                coordinator.updateEgressGroups { try $0.removeCountry(group.country) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .fluentButton(.danger)
            .help("解散此通道（不删除订阅凭据）")
        }
    }

    private func commitPort() {
        let digits = portText.filter { $0.isASCII && $0.isNumber }
        if let port = UInt16(digits), port > 0 {
            coordinator.updateEgressGroups { try? $0.setProxyPort(port, for: group.country) }
        } else if digits.isEmpty {
            coordinator.updateEgressGroups { try? $0.setProxyPort(nil, for: group.country) }
        }
    }

    private func runRouteTest() {
        guard let port = group.proxyPort else { return }
        testing = true
        routeResult = nil
        Task {
            let result = await EgressRouteTester.test(port: port, expected: group.country)
            if coordinator.egressGroups.groups.first(where: { $0.country == group.country })?.proxyPort == port {
                routeResult = result
                coordinator.updateEgressGroups { $0.setLastTestResult(result, for: group.country) }
            }
            testing = false
        }
    }
}

// MARK: - 现代 PORT 胶囊输入组件

private struct ModernPortCapsule: View {
    @Binding var portText: String
    var onCommit: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("PORT")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(SettingsDemoTokens.text3)
            TextField("端口", text: $portText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .onSubmit(onCommit)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(SettingsDemoTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
        .help("回环代理端口 (例如 Clash Verge 混合端口 7897)")
    }
}

// MARK: - 纯品牌图标受保护服务 Badge (带悬停微型移除)

private struct ProtectedServiceIconBadge: View {
    let provider: SubscriptionProviderID
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onRemove) {
            ZStack(alignment: .topTrailing) {
                ProviderBrandBadge(
                    providerID: provider.rawValue,
                    name: provider.displayName,
                    size: 22
                )
                if isHovered {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.red)
                        .background(Circle().fill(Color.black.opacity(0.7)))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(provider.displayName) (点击将此服务移出通道)")
        .accessibilityLabel("\(provider.displayName) 已受此通道保护，点击移出")
    }
}
