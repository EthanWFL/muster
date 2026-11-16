import AppKit
import MusterCore
import SwiftUI

/// Opens the identified client application, without terminal/session navigation.
struct SessionClientButton: View {
    let session: Session
    let action: () -> Void

    var body: some View {
        if session.isProcessAlive, let client = session.client {
            Button(action: action) {
                SessionClientIcon(session: session, size: 18)
                    .frame(width: T.iconHitSize, height: T.iconHitSize)
                    .contentShape(Rectangle()).accessibilityHidden(true)
            }
            .buttonStyle(InteractivePlainButtonStyle())
            .help(L10n.t("Open %@", client.name))
            .accessibilityLabel(L10n.t("Open %@", client.name))
        }
    }
}

private struct SessionClientIcon: View {
    let session: Session
    var size: CGFloat = 14

    var body: some View {
        if session.isProcessAlive, let client = session.client {
            Group {
                if let image = ClientIcons.image(for: client.bundlePath) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app").resizable().foregroundStyle(T.muted)
                }
            }
            .scaledToFit().frame(width: size, height: size)
        }
    }
}

@MainActor private enum ClientIcons {
    private static var images: [String: NSImage] = [:]

    static func image(for path: String) -> NSImage? {
        if let cached = images[path] { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        images[path] = image
        return image
    }
}
