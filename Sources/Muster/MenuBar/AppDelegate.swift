import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PanelModel()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 打包前也不出现 Dock 图标；打包后由 Info.plist 的 LSUIElement 接管
        NSApp.setActivationPolicy(.accessory)
        model.start()
        statusItemController = StatusItemController(model: model)
        SettingsCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
