import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PanelModel()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 打包前也不出现 Dock 图标；打包后由 Info.plist 的 LSUIElement 接管
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(model: model)
        model.start()
        SettingsCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
