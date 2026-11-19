import AppKit
import MusterCore
import SwiftUI

private struct OpenSessionClientKey: EnvironmentKey {
    static let defaultValue: (Session) -> Void = { _ in }
}

extension EnvironmentValues {
    var openSessionClient: (Session) -> Void {
        get { self[OpenSessionClientKey.self] }
        set { self[OpenSessionClientKey.self] = newValue }
    }
}

/// Each mounted page owns its own activation feedback, including its dismissal timer.
struct SessionClientActions: ViewModifier {
    let model: PanelModel
    @State private var failure: String?
    @State private var attempt = 0
    @Environment(\.panelSurfaceVisible) private var visible

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content.environment(\.openSessionClient, { session in
                failure = model.openClient(session)
                attempt += 1
            })
            if let failure {
                Text(failure).font(T.small).foregroundStyle(T.muted)
                    .padding(.horizontal, T.s4).padding(.bottom, T.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: visible) { _, shown in if !shown { failure = nil } }
        .task(id: attempt) {
            guard failure != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            failure = nil
        }
    }
}

/// Opens the identified client application, without terminal/session navigation.
extension SessionClient {
    @MainActor var actionTitle: String {
        paneURL == nil ? L10n.t("Open %@", name) : L10n.t("Return to Warp pane")
    }
}

struct SessionClientButton: View {
    let session: Session
    @Environment(\.openSessionClient) private var openClient

    var body: some View {
        if session.isProcessAlive, let client = session.client {
            Button { openClient(session) } label: {
                SessionClientIcon(session: session, size: 18)
                    .frame(width: T.iconHitSize, height: T.iconHitSize)
                    .contentShape(Rectangle()).accessibilityHidden(true)
            }
            .buttonStyle(InteractivePlainButtonStyle())
            .help(client.actionTitle)
            .accessibilityLabel(client.actionTitle)
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
