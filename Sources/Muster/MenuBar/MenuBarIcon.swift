import AppKit

enum MenuBarIcon {
    // "A muster of peacocks" — drawn as an AppKit template image so `swift run` and `Scripts/package.sh` need no extra bundle assets.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.1)

            let plumes: [(CGPoint, CGPoint, CGPoint)] = [
                (CGPoint(x: 7.6, y: 6.4), CGPoint(x: 3.9, y: 4.5), CGPoint(x: 3.5, y: 4.2)),
                (CGPoint(x: 8.3, y: 5.8), CGPoint(x: 5.5, y: 2.8), CGPoint(x: 5.1, y: 2.4)),
                (CGPoint(x: 9.2, y: 5.6), CGPoint(x: 8.1, y: 2.2), CGPoint(x: 7.9, y: 1.85)),
            ]
            for (start, end, tip) in plumes {
                ctx.move(to: start)
                ctx.addLine(to: end)
                ctx.strokePath()
                ctx.fillEllipse(in: CGRect(x: tip.x - 0.9, y: tip.y - 0.9, width: 1.8, height: 1.8))
            }

            let head = CGMutablePath()
            head.move(to: CGPoint(x: 9.9, y: 5.4))
            head.addCurve(to: CGPoint(x: 13.1, y: 7.3), control1: CGPoint(x: 11.5, y: 5.4), control2: CGPoint(x: 12.6, y: 6.3))
            head.addLine(to: CGPoint(x: 15.5, y: 8.0))
            head.addCurve(to: CGPoint(x: 15.4, y: 8.75), control1: CGPoint(x: 16.0, y: 8.15), control2: CGPoint(x: 15.95, y: 8.6))
            head.addLine(to: CGPoint(x: 12.9, y: 9.5))
            head.addCurve(to: CGPoint(x: 10.4, y: 10.4), control1: CGPoint(x: 12.3, y: 10.1), control2: CGPoint(x: 11.3, y: 10.4))
            head.addCurve(to: CGPoint(x: 12.0, y: 16.0), control1: CGPoint(x: 9.4, y: 12.0), control2: CGPoint(x: 10.1, y: 14.1))
            head.addLine(to: CGPoint(x: 5.8, y: 16.0))
            head.addCurve(to: CGPoint(x: 7.9, y: 9.7), control1: CGPoint(x: 5.5, y: 13.8), control2: CGPoint(x: 6.5, y: 11.6))
            head.addCurve(to: CGPoint(x: 9.9, y: 5.4), control1: CGPoint(x: 7.2, y: 7.9), control2: CGPoint(x: 8.0, y: 5.4))
            head.closeSubpath()
            head.addEllipse(in: CGRect(x: 10.3, y: 6.95, width: 1.35, height: 1.35))
            ctx.addPath(head)
            ctx.drawPath(using: .eoFill)
            return true
        }
        image.isTemplate = true
        return image
    }()
}
