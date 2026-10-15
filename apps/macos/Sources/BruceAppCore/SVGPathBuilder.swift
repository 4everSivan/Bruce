import CoreGraphics

// MARK: - SVGPathBuilder

/// 订阅 Provider 品牌图形的迷你路径解析器 (C026)。
///
/// 只接受生成器 (scripts/gen-provider-glyphs.py) 产出的归一化**绝对**命令集
/// M / L / C / Z —— 圆弧与简写曲线已在生成期展开为三次贝塞尔, 因此这里不做
/// 二次拟合, 也不兼容相对命令与隐式重复: 任何非预期输入一律返回 nil
/// (fail-closed), 由徽章回退首字母兜底, 避免半解析出的畸形图形进入界面。
package enum SVGPathBuilder {
    package static func cgPath(from data: String) -> CGPath? {
        guard let tokens = tokens(of: data) else { return nil }

        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var index = 0

        func nextNumber() -> CGFloat? {
            guard index < tokens.count, case let .number(value) = tokens[index] else {
                return nil
            }
            index += 1
            return value
        }

        while index < tokens.count {
            guard case let .command(command) = tokens[index] else { return nil }
            index += 1

            switch command {
            case "M":
                guard let x = nextNumber(), let y = nextNumber() else { return nil }
                current = CGPoint(x: x, y: y)
                subpathStart = current
                path.move(to: current)
            case "L":
                guard let x = nextNumber(), let y = nextNumber() else { return nil }
                current = CGPoint(x: x, y: y)
                path.addLine(to: current)
            case "C":
                guard let c1x = nextNumber(), let c1y = nextNumber(),
                      let c2x = nextNumber(), let c2y = nextNumber(),
                      let x = nextNumber(), let y = nextNumber() else { return nil }
                current = CGPoint(x: x, y: y)
                path.addCurve(
                    to: current,
                    control1: CGPoint(x: c1x, y: c1y),
                    control2: CGPoint(x: c2x, y: c2y)
                )
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                return nil
            }
        }

        return path.isEmpty ? nil : path
    }

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    private static func tokens(of data: String) -> [Token]? {
        var result: [Token] = []
        var numberText = ""

        func flushNumber() -> Bool {
            guard !numberText.isEmpty else { return true }
            guard let value = Double(numberText) else { return false }
            result.append(.number(CGFloat(value)))
            numberText = ""
            return true
        }

        for character in data {
            switch character {
            case "M", "L", "C", "Z":
                guard flushNumber() else { return nil }
                result.append(.command(character))
            case "0"..."9", ".", "-", "+":
                numberText.append(character)
            case " ", ",", "\n", "\t":
                guard flushNumber() else { return nil }
            default:
                // 其余字符 (含相对命令、小写 z 与科学计数法) 一律拒绝。
                return nil
            }
        }

        guard flushNumber() else { return nil }
        return result
    }
}
