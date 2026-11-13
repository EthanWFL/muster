import AppKit
import SwiftUI

/// Cursor rectangles follow view/window lifetime without a global push/pop stack.
private struct PointerRegion: NSViewRepresentable {
    let cursor: NSCursor
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ view: CursorView, context: Context) {
        view.cursor = isEnabled ? cursor : nil
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var cursor: NSCursor?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            if let cursor { addCursorRect(visibleRect, cursor: cursor) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }
    }
}

extension View {
    func pointerCursor(_ cursor: NSCursor = .pointingHand) -> some View {
        background(PointerRegion(cursor: cursor))
    }
}

struct InteractivePlainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hoverHighlight()
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .pointerCursor()
    }
}
