import AppKit
import SwiftUI

enum PanelPresentation { case popover, window }

@MainActor
final class PanelSurfaceState: ObservableObject {
    @Published var isVisible = true
}

private struct PanelPresentationKey: EnvironmentKey {
    static let defaultValue = PanelPresentation.popover
}

private struct PanelSurfaceVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelPresentation: PanelPresentation {
        get { self[PanelPresentationKey.self] }
        set { self[PanelPresentationKey.self] = newValue }
    }
    var panelSurfaceVisible: Bool {
        get { self[PanelSurfaceVisibleKey.self] }
        set { self[PanelSurfaceVisibleKey.self] = newValue }
    }
}

/// One reusable window; all editable state remains in the shared model when it closes.
@MainActor
final class ManagementWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultSize = NSSize(width: 1120, height: 740)
    private static let minimumSize = NSSize(width: 960, height: 600)
    private let model: PanelModel
    private let surfaceID = UUID()
    private let surface = PanelSurfaceState()

    init(model: PanelModel) {
        self.model = model
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// External settings entries select the page idempotently, preserving its last section.
    func openSettings(_ section: SettingsSection? = nil) {
        model.showSettings(section ?? model.settingsSection)
        open()
    }

    func open() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Muster"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbarStyle = .unifiedCompact
            let toolbar = NSToolbar(identifier: "MusterManagementToolbar")
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            // Accessories keep the shared SwiftUI controls out of native toolbar capsules.
            window.addTitlebarAccessoryViewController(accessory(WindowToolbarBrand(), edge: .left,
                                                                size: NSSize(width: 100, height: 28)))
            window.addTitlebarAccessoryViewController(accessory(
                PanelHeaderActions(model: model, presentation: .window).padding(.trailing, T.s3), edge: .right,
                size: NSSize(width: 68, height: 28)))
            window.minSize = Self.minimumSize
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("MusterManagementWindow")
            self.window = window
        }
        guard let window else { return }
        surface.isVisible = true
        // AppKit adopts a new content controller's fitting size. Preserve the user's
        // frame across remounts and give SwiftUI the same minimum bounds.
        var frame = window.frame
        if window.contentViewController == nil {
            let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
            let host = NSHostingController(rootView: PanelView(
                model: model, presentation: .window, surfaceID: surfaceID,
                onClose: { [weak self] in self?.close() }, surface: surface)
                .frame(minWidth: Self.minimumSize.width,
                       minHeight: max(0, Self.minimumSize.height - titlebarHeight)))
            host.sizingOptions = [.minSize]
            window.contentViewController = host
        }
        window.minSize = Self.minimumSize
        if frame.width < Self.minimumSize.width || frame.height < Self.minimumSize.height {
            let top = frame.maxY
            frame.size = Self.defaultSize
            frame.origin.y = top - frame.height
        }
        if window.frame != frame { window.setFrame(frame, display: false) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func accessory<Content: View>(_ content: Content, edge: NSLayoutConstraint.Attribute,
                                         size: NSSize) -> NSTitlebarAccessoryViewController {
        let accessory = NSTitlebarAccessoryViewController()
        let host = NSHostingController(rootView: content)
        accessory.addChild(host)
        accessory.view = host.view
        accessory.view.frame.size = size
        accessory.layoutAttribute = edge
        return accessory
    }

    func windowWillClose(_ notification: Notification) {
        surface.isVisible = false
        model.env.setVisible(false, owner: surfaceID)
        // Unmount the view so page visibility and editor focus are released.
        window?.contentViewController = nil
    }

    func windowDidMiniaturize(_ notification: Notification) {
        surface.isVisible = false
        model.env.setVisible(false, owner: surfaceID)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        surface.isVisible = true
        if model.tab == .environment && !model.showsSettings {
            model.env.setVisible(true, owner: surfaceID)
        }
    }
}

private struct WindowToolbarBrand: View {
    var body: some View {
        HStack(spacing: 8) {
            BrandMark()
            Text("Muster").font(.system(size: 13, weight: .semibold))
        }
        .frame(width: 100, height: 28, alignment: .leading)
    }
}
