import AppKit
import Observation
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

/// Reading a color token registers its appearance dependency in every SwiftUI view,
/// including nested cards and controls, without recreating their local state.
@Observable @MainActor
final class Theme {
    static let shared = Theme()

    private(set) var isDark = false
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    private init() {
        isDark = Self.darkNow()
        // Observe the resolved appearance, after AppKit has applied a system change
        // or app override; notification timing must not leave custom colors stale.
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func apply(_ preference: AppAppearance) {
        NSApplication.shared.appearance = preference.appKitAppearance
        refresh()
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
    private static var comfortable: Bool {
        MainActor.assumeIsolated { SettingsStore.shared.comfortableLayout }
    }
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
    /// Readable supporting text on the page, cards and control surfaces.
    static var muted: Color { pick(light: 0x6B6B74, dark: 0x9797A1) }
    /// Reserved for disabled or decorative details, never supporting text/actions.
    static var faint: Color { pick(light: 0xB9B9C2, dark: 0x56565F) }
    /// 控件上的安静文字：每种底色上都压到 4.5:1 以上
    static var ctlFg: Color { pick(light: 0x63636B, dark: 0xA1A1AA) }

    // 唯一强调色 + 语义色
    static var accent: Color { pick(light: 0x4F46E5, dark: 0xA5B4FC) }
    static var onAccent: Color { pick(light: 0xFFFFFF, dark: 0x1A1A1E) }
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
    static var rowCompact: CGFloat { comfortable ? 34 : 30 }
    static var rowSingle: CGFloat { comfortable ? 38 : 34 }
    static var rowDouble: CGFloat { comfortable ? 48 : 40 }
    static var controlHeight: CGFloat { comfortable ? 30 : 28 }
    static var iconHitSize: CGFloat { comfortable ? 32 : 28 }

    // 圆角
    static let rInner: CGFloat = 5
    static let r: CGFloat = 7

    // 字号：语义样式跟随系统辅助功能字号，不再锁死像素值
    static var body: Font { .body }
    static var small: Font { .callout }
    static var micro: Font { .caption }
    static var seg: Font { .callout }
    static var section: Font { .caption.weight(.semibold) }
    static var mono: Font { .system(.callout, design: .monospaced) }
    static var monoMicro: Font { .system(.caption, design: .monospaced) }
    /// 指示性小图标（chevron、勾选）：最小一档，不再往下开新字号
    static let glyph = Font.caption2.weight(.semibold)
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
    case busy, failed, idle, neutral

    var color: Color {
        switch self {
        case .busy: return T.green
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
