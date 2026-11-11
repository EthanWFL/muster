import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: PanelModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var pendingSubscription: AnyCancellable?

    init(model: PanelModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))

        if let button = statusItem.button {
            button.image = MenuBarIcon.image
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Muster")
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        pendingSubscription = model.$pending
            .map(\.count)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateBadge(count: $0) }

        SettingsCoordinator.shared.onOpenPanel = { [weak self] in self?.showPanel() }
    }

    private func updateBadge(count: Int) {
        statusItem.button?.title = count > 0 ? " \(count)" : ""
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
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }

        let count = model.pending.count
        let menu = NSMenu()
        menu.addItem(item("Open Muster", #selector(openPanel)))
        let status = NSMenuItem(title: count > 0 ? "\(count) approvals waiting" : "No pending approvals", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Install/Repair Hook", #selector(installHook)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "Version 0.1.0", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit Muster", #selector(quit), key: "q"))

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
    @objc private func openSettings() { SettingsCoordinator.shared.show(model: model) }
    @objc private func installHook() {
        showPanel()
        model.requestHook(.install)
    }
    @objc private func checkForUpdates() { SettingsCoordinator.shared.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}
