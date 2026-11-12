import SwiftUI

@main
struct MusterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 设置窗口由 SettingsCoordinator 自己创建（accessory App 用系统 selector 弹不出来），
        // 这里留一个空场景只为满足 App 协议。
        Settings { EmptyView() }
    }
}
