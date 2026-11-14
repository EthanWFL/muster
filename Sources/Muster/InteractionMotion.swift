import SwiftUI

/// Shared timings keep small controls responsive without moving their layout.
enum InteractionMotion {
    static let hover = Animation.easeOut(duration: 0.14)
    static let press = Animation.easeOut(duration: 0.09)
    static let release = Animation.spring(duration: 0.22, bounce: 0.16)
    static let selection = Animation.snappy(duration: 0.20, extraBounce: 0)
}

struct ButtonPressFeedback: ViewModifier {
    let isPressed: Bool
    var scale: CGFloat = 0.97
    @Environment(\.isEnabled) private var isEnabled
    @ReducedMotion private var reduceMotion

    private var pressed: Bool { isPressed && isEnabled }

    func body(content: Content) -> some View {
        content
            .brightness(pressed ? -0.06 : 0)
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .animation(reduceMotion ? nil : (pressed ? InteractionMotion.press : InteractionMotion.release), value: pressed)
    }
}

/// The rotating view exists only while work is active; no repeating animation survives completion.
struct ActivitySymbol: View {
    let symbol: String
    let isActive: Bool
    @ReducedMotion private var reduceMotion
    @Environment(\.panelSurfaceVisible) private var surfaceVisible

    var body: some View {
        Group {
            if isActive && !reduceMotion && surfaceVisible {
                RotatingSymbol(symbol: symbol)
            } else {
                Image(systemName: isActive ? "hourglass" : symbol)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RotatingSymbol: View {
    let symbol: String
    @State private var rotating = false

    var body: some View {
        Image(systemName: symbol)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotating = true
                }
            }
    }
}

/// Reflects the model's saved state, including autosave, instead of assuming a click succeeded.
struct SaveStateLabel: View {
    let title: String
    let glyph: String
    let isSaved: Bool
    @ReducedMotion private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .opacity(isSaved ? 1 : 0)
                .scaleEffect(reduceMotion || isSaved ? 1 : 0.65)
                .accessibilityHidden(true)
            ShortcutLabel(title: title, glyph: glyph)
        }
        .animation(reduceMotion ? nil : InteractionMotion.release, value: isSaved)
    }
}
