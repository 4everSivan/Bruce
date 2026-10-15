import CoreGraphics

// MARK: - ProviderBrandGlyph

/// 单个图形子路径 + 填充不透明度 (volcengine 的品牌图形含 50% 层次的辅助面)。
package struct ProviderBrandGlyphShape {
    package let path: CGPath
    package let opacity: Double
}

/// 订阅 Provider 品牌图形的解析与画布适配 (C026)。
///
/// 数据来源: BruceAppCore.ProviderBrandGlyphData (由 scripts/gen-provider-glyphs.py
/// 从 docs/assets/provider-icons/ 生成), 几何为绝对 M/L/C/Z。
package enum ProviderBrandGlyph {
    /// 图形在徽章瓷砖内的占位比例 (15pt 徽章内约 8.7pt, 与设计稿一致)。
    package static let glyphBoxFraction: CGFloat = 0.58

    /// 解析 provider 图形并等比 (meet) 适配到 size×size 画布居中。
    /// 返回 nil 表示无图形数据或数据非法 —— 调用方回退首字母徽章 (fail-closed)。
    package static func resolvedShapes(
        for providerID: String,
        size: CGFloat
    ) -> [ProviderBrandGlyphShape]? {
        guard size > 0, let glyph = ProviderBrandGlyphData.glyphs[providerID] else {
            return nil
        }

        let viewBox = glyph.viewBox
        guard viewBox.width > 0, viewBox.height > 0 else { return nil }

        // 显式构造矩阵, 避免 CGAffineTransform 链式方法的乘法序歧义:
        // p -> ((p - viewBox.origin) * scale) + 居中偏移。
        let box = size * glyphBoxFraction
        let scale = min(box / viewBox.width, box / viewBox.height)
        let offsetX = (size - viewBox.width * scale) / 2 - viewBox.minX * scale
        let offsetY = (size - viewBox.height * scale) / 2 - viewBox.minY * scale
        var transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY
        )

        var resolved: [ProviderBrandGlyphShape] = []
        resolved.reserveCapacity(glyph.shapes.count)
        for shape in glyph.shapes {
            guard let path = SVGPathBuilder.cgPath(from: shape.path),
                  let fitted = path.copy(using: &transform) else {
                return nil
            }
            resolved.append(ProviderBrandGlyphShape(path: fitted, opacity: shape.opacity))
        }
        return resolved.isEmpty ? nil : resolved
    }
}
