import AppKit
import SwiftUI

import BruceAppCore
import BruceOnboardingCore

// MARK: - 「选择 Provider」下拉

/// 订阅额度设置中心「添加服务」的选择控件 (C026)。
///
/// 与原 SwiftUI `Picker` 使用同一原生控件 (`NSPopUpButton`) —— 外观、闭合态与
/// 两步「选择 → 添加…」流程完全一致; 唯一差异是每个菜单项携带品牌图形
/// (`NSMenuItem.image`), 闭合态由系统自动带出所选 provider 的图标。
struct ProviderPopUpPicker: NSViewRepresentable {
    /// 可选 provider (只列尚未配置的).
    let providers: [SubscriptionProviderID]
    /// 未选择时的占位文案 (也是控件无障碍名称).
    let placeholder: String
    /// 控件提示 (tooltip / 无障碍提示).
    let hint: String
    @Binding var selection: SubscriptionProviderID?

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.didSelect(_:))
        button.setAccessibilityLabel(placeholder)
        button.toolTip = hint
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.providers = providers

        button.removeAllItems()
        button.addItem(withTitle: placeholder)
        for provider in providers {
            let item = NSMenuItem(title: provider.displayName, action: nil, keyEquivalent: "")
            // 图形右侧留 6pt 透明间距: 菜单项标题跟随图像列宽右移, 避免图标与名称挤在一起。
            item.image = ProviderBrandGlyph.menuImage(for: provider.rawValue, trailingGap: 6)
            button.menu?.addItem(item)
        }

        if let selection, let index = providers.firstIndex(of: selection) {
            button.selectItem(at: index + 1)
            button.setAccessibilityValue(providers[index].displayName)
        } else {
            button.selectItem(at: 0)
            button.setAccessibilityValue("")
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<SubscriptionProviderID?>
        var providers: [SubscriptionProviderID] = []

        init(selection: Binding<SubscriptionProviderID?>) {
            self.selection = selection
        }

        @objc func didSelect(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard index > 0, index - 1 < providers.count else {
                selection.wrappedValue = nil
                return
            }
            selection.wrappedValue = providers[index - 1]
        }
    }
}
