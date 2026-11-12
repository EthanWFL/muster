import AppKit
import SwiftUI

// MARK: - 颜色

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - 外观

/// 跟随系统的深浅色。
///
/// 不用 `NSColor` 的动态 provider + `Color(nsColor:)`：SwiftUI 会把那只颜色按第一次渲染的
/// 外观定死，切换系统外观后不重新解析。这里把「现在是深色吗」变成可观察状态，所有 token
/// 在视图求值时取具体色值，根视图观察它就能整套重画。
@MainActor
final class Theme: ObservableObject {
    static let shared = Theme()

    @Published private(set) var isDark = false

    private init() {
        isDark = Self.darkNow()
        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // 通知偶尔会漏，App 重新激活时再对一次
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let dark = Self.darkNow()
        if dark != isDark { isDark = dark }
    }

    private static func darkNow() -> Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Design tokens

/// 「安静表面」设计语言：一张安静的表面，靠发丝线和底色差分做层级，只有一个强调色。
enum T {
    private static func pick(light: UInt32, dark: UInt32) -> Color {
        Color(hex: MainActor.assumeIsolated { Theme.shared.isDark } ? dark : light)
    }

    // 表面
    static var bg: Color { pick(light: 0xF4F4F6, dark: 0x1A1A1E) }
    static var card: Color { pick(light: 0xFFFFFF, dark: 0x232327) }
    static var card2: Color { pick(light: 0xF9F9FB, dark: 0x1F1F23) }
    static var pill: Color { pick(light: 0xF1F1F4, dark: 0x2D2D33) }
    static var segTrack: Color { pick(light: 0xE6E6EB, dark: 0x23232A) }

    // 线
    static var line: Color { pick(light: 0xE3E3E8, dark: 0x333339) }

    // 文字
    static var fg: Color { pick(light: 0x1C1C21, dark: 0xEDEDF1) }
    static var fg2: Color { pick(light: 0x4B4B53, dark: 0xB9B9C1) }
    static var muted: Color { pick(light: 0x85858D, dark: 0x8B8B94) }
    static var faint: Color { pick(light: 0xB9B9C2, dark: 0x56565F) }
    /// 控件上的安静文字：每种底色上都压到 4.5:1 以上
    static var ctlFg: Color { pick(light: 0x63636B, dark: 0xA1A1AA) }

    // 唯一强调色 + 语义色
    static var accent: Color { pick(light: 0x4F46E5, dark: 0xA5B4FC) }
    static var accentSoft: Color { pick(light: 0xEEEDFD, dark: 0x2B2C47) }
    static var green: Color { pick(light: 0x189A58, dark: 0x6FD99B) }
    static var red: Color { pick(light: 0xD64545, dark: 0xF28B82) }
    static var amber: Color { pick(light: 0xB45309, dark: 0xF2B544) }

    // 4pt 网格
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16

    // 行高：单行 34 / 双行 40–42 / 紧凑行 30
    static let rowCompact: CGFloat = 30
    static let rowSingle: CGFloat = 34
    static let rowDouble: CGFloat = 40

    // 圆角
    static let rInner: CGFloat = 5
    static let r: CGFloat = 7

    // 字号：只许用这几档，尺寸越多越难对齐
    static let body = Font.system(size: 12.5)
    static let small = Font.system(size: 11)
    static let micro = Font.system(size: 10.5)
    static let seg = Font.system(size: 11.5)
    static let section = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 11, design: .monospaced)
    static let monoMicro = Font.system(size: 10.5, design: .monospaced)
    /// 指示性小图标（chevron、勾选）：最小一档，不再往下开新字号
    static let glyph = Font.system(size: 10, weight: .semibold)
}

// MARK: - 发丝线

/// CSS 的 0.5px 在 Retina 上正好是 1 个物理像素，所以按 displayScale 算。
struct Hairline: View {
    @Environment(\.displayScale) private var scale
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(T.line)
            .frame(width: vertical ? 1 / scale : nil, height: vertical ? nil : 1 / scale)
    }
}

// MARK: - 状态点

/// 颜色 + 形状双编码：失败不只靠红点，还叠一个 x 形，灰度下也读得出来。
enum StatusTone {
    case busy, waiting, failed, idle, neutral

    var color: Color {
        switch self {
        case .busy: return T.green
        case .waiting: return T.amber
        case .failed: return T.red
        case .idle: return T.faint
        case .neutral: return T.muted
        }
    }
}

struct StatusDot: View {
    let tone: StatusTone
    var size: CGFloat = 7

    var body: some View {
        Group {
            if tone == .failed {
                Circle()
                    .strokeBorder(tone.color, lineWidth: 1)
                    .overlay(Image(systemName: "xmark")
                        .font(.system(size: size * 0.72, weight: .black))
                        .foregroundStyle(tone.color))
            } else {
                Circle().fill(tone.color)
            }
        }
        .frame(width: size, height: size)
    }
}
