import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: PanelModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var resignObserver: NSObjectProtocol?
    private let surfaceID = UUID()
    private let surface = PanelSurfaceState()
    private let management: ManagementWindowController

    init(model: PanelModel) {
        self.model = model
        management = ManagementWindowController(model: model)
        super.init()
        surface.isVisible = false

        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = NSHostingController(rootView: PanelView(
            model: model, surfaceID: surfaceID,
            onOpenWindow: { [weak self] in self?.openManagement() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onClose: { [weak self] in self?.closeIfShown() }, surface: surface))

        if let button = statusItem.button {
            button.image = MenuBarIcon.image
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Muster")
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        SettingsCoordinator.shared.onOpenPanel = { [weak self] in
            // The quick panel always shows workspace tabs; keep the window's settings selection.
            self?.showPanel()
        }

        // `.transient` 只在 App 还活着的时候响应外部点击；切到别的 App（⌘Tab、点别人窗口）时
        // popover 会留着。失去焦点就关，但草稿留在 model 里，下次打开还在。
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.closeIfShown() }
        }
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    private func closeIfShown() {
        surface.isVisible = false
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        surface.isVisible = false
        model.env.setVisible(false, owner: surfaceID)
    }

    @objc private func openManagement() {
        closeIfShown()
        management.open()
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem.button else { return }
        surface.isVisible = true
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()
        menu.addItem(item(L10n.t("Open Muster"), #selector(openPanel)))
        menu.addItem(item(L10n.t("Open management window"), #selector(openManagement)))
        menu.addItem(.separator())
        menu.addItem(item(L10n.t("Settings…"), #selector(openSettings), key: ","))
        menu.addItem(item(L10n.t("Check for Updates…"), #selector(checkForUpdates)))
        menu.addItem(.separator())
        let version = NSMenuItem(
            title: L10n.t("Version %@", SettingsStore.shared.appVersion),
            action: nil,
            keyEquivalent: ""
        )
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item(L10n.t("Quit Muster"), #selector(quit), key: "q"))

        // 临时挂菜单才能弹出；performClick 结束后立即摘掉，否则之后左键也会走菜单
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openPanel() { showPanel() }
    @objc private func openSettings() {
        closeIfShown()
        management.openSettings()
    }
    /// Update results belong to the management window's About section.
    @objc private func checkForUpdates() {
        closeIfShown()
        management.openSettings(.about)
        SettingsCoordinator.shared.checkForUpdates()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
