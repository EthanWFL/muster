import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PanelModel()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 打包前也不出现 Dock 图标；打包后由 Info.plist 的 LSUIElement 接管
        NSApp.setActivationPolicy(.accessory)
        Theme.shared.apply(SettingsStore.shared.appearance)
        statusItemController = StatusItemController(model: model)
        model.start()
        SettingsCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    /// Quitting must not silently discard notes, rule edits or configuration drafts.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let areas = model.unsavedAreas
        guard !areas.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L10n.t("Quit Muster?")
        alert.informativeText = L10n.t("Unsaved changes in: %@. Quit anyway?", areas.joined(separator: ", "))
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("Quit Anyway"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
