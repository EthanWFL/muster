import AppKit

/// 菜单栏 / 面板头部用的品牌标记。
///
/// 形态取自 `docs/design/menubar-icons-animals/05-manta-ray.svg`（领航蝠鲼）：
/// 18×18，身体与「嘴」的镂空走 even-odd 填充，尾巴是 1.35pt 圆头描边。
/// 全部用 template 图绘制，跟随菜单栏与面板的明暗自动反色，不需要两套资源。
///
/// 身体和尾巴分两层画，菜单栏那张静态图由两层合成；面板头部改用 `MantaPlayer` 播 GIF。
enum MenuBarIcon {
    /// 身体 + 嘴的镂空，不含尾巴
    static let body: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // 身体：两个头鳍向上翘，双翼向两侧展开，尾部收窄
            let body = CGMutablePath()
            body.move(to: CGPoint(x: 9.0, y: 4.2))
            body.addCurve(
                to: CGPoint(x: 11.0, y: 1.7),
                control1: CGPoint(x: 9.9, y: 4.2), control2: CGPoint(x: 10.6, y: 3.0))
            body.addCurve(
                to: CGPoint(x: 12.1, y: 2.2),
                control1: CGPoint(x: 11.3, y: 1.2), control2: CGPoint(x: 12.1, y: 1.4))
            body.addCurve(
                to: CGPoint(x: 16.7, y: 7.3),
                control1: CGPoint(x: 12.2, y: 4.1), control2: CGPoint(x: 14.4, y: 5.7))
            body.addCurve(
                to: CGPoint(x: 16.3, y: 8.4),
                control1: CGPoint(x: 17.2, y: 7.7), control2: CGPoint(x: 17.0, y: 8.3))
            body.addCurve(
                to: CGPoint(x: 9.7, y: 12.1),
                control1: CGPoint(x: 13.7, y: 8.9), control2: CGPoint(x: 11.4, y: 10.3))
            body.addLine(to: CGPoint(x: 8.3, y: 12.1))
            body.addCurve(
                to: CGPoint(x: 1.7, y: 8.4),
                control1: CGPoint(x: 6.6, y: 10.3), control2: CGPoint(x: 4.3, y: 8.9))
            body.addCurve(
                to: CGPoint(x: 1.3, y: 7.3),
                control1: CGPoint(x: 1.0, y: 8.3), control2: CGPoint(x: 0.8, y: 7.7))
            body.addCurve(
                to: CGPoint(x: 5.9, y: 2.2),
                control1: CGPoint(x: 3.6, y: 5.7), control2: CGPoint(x: 5.8, y: 4.1))
            body.addCurve(
                to: CGPoint(x: 7.0, y: 1.7),
                control1: CGPoint(x: 5.9, y: 1.4), control2: CGPoint(x: 6.7, y: 1.2))
            body.addCurve(
                to: CGPoint(x: 9.0, y: 4.2),
                control1: CGPoint(x: 7.4, y: 3.0), control2: CGPoint(x: 8.1, y: 4.2))
            body.closeSubpath()

            // 嘴 / 鳃的镂空（even-odd 挖空）
            body.move(to: CGPoint(x: 6.4, y: 7.7))
            body.addLine(to: CGPoint(x: 9.0, y: 6.2))
            body.addLine(to: CGPoint(x: 11.6, y: 7.7))
            body.addLine(to: CGPoint(x: 11.0, y: 8.6))
            body.addLine(to: CGPoint(x: 9.0, y: 7.4))
            body.addLine(to: CGPoint(x: 7.0, y: 8.6))
            body.closeSubpath()

            ctx.addPath(body)
            ctx.drawPath(using: .eoFill)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// 尾巴单独一层（菜单栏静态图由它与 body 合成）
    static let tail: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.35)
            let tail = CGMutablePath()
            tail.move(to: CGPoint(x: 9.0, y: 11.6))
            tail.addCurve(
                to: CGPoint(x: 10.5, y: 16.4),
                control1: CGPoint(x: 9.0, y: 13.5), control2: CGPoint(x: 9.4, y: 15.2))
            ctx.addPath(tail)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// 静态整只（菜单栏用）：身体叠尾巴
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            body.draw(in: rect)
            tail.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }()
}
