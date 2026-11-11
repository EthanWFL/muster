import SwiftUI

@main
struct MusterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(store: SettingsStore.shared, model: appDelegate.model)
        }
    }
}
