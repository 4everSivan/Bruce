import AppKit
import CoreGraphics
import Foundation

// MARK: - 下拉菜单图标

extension ProviderBrandGlyph {
    /// 菜单项图标: size×size 品牌瓷砖 + 白色品牌图形, 右侧可留 `trailingGap` 透明间距。
    ///
    /// 供 `NSMenuItem.image` 原样展示 (与原 SwiftUI Picker 同一原生控件的菜单项),
    /// 显式关闭模板染色以保留品牌色; 无图形数据的 provider 返回 nil, 该菜单项仅显示文字。
    ///
    /// AppKit 菜单项的标题位置 = 图像列宽 + 固定间距, 没有单独的间距开关, 因此
    /// 通过加宽画布 (图形右侧留白) 把标题右移, 避免图标与名称挤在一起。
    ///
    /// 图形按 SVG 坐标语义 (y 轴向下) 构建, 故绘图上下文取 flipped, 避免上下镜像。
    package static func menuImage(
        for providerID: String,
        size: CGFloat = 16,
        trailingGap: CGFloat = 0
    ) -> NSImage? {
        guard size > 0, trailingGap >= 0,
              let shapes = resolvedShapes(for: providerID, size: size),
              let tile = NSColor(brandHex: ProviderBrandPalette.hex(for: providerID))
        else { return nil }

        let tileRect = CGRect(x: 0, y: 0, width: size, height: size)
        let image = NSImage(
            size: NSSize(width: size + trailingGap, height: size),
            flipped: true
        ) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let radius = size * 0.3
            context.addPath(
                CGPath(roundedRect: tileRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            )
            context.setFillColor(tile.cgColor)
            context.fillPath()
            for shape in shapes {
                context.addPath(shape.path)
                context.setFillColor(NSColor.white.withAlphaComponent(CGFloat(shape.opacity)).cgColor)
                context.fillPath()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

private extension NSColor {
    /// 解析 6 位 #RRGGBB (与 app 侧 Color(hex:) 同口径); 非法输入返回 nil。
    convenience init?(brandHex hex: String) {
        var text = hex
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
