import AppKit
import Combine
import MusterCore

@MainActor
final class SettingsCoordinator {
    static let shared = SettingsCoordinator()

    /// Set by the status-item controller so settings/notifications can reveal the panel.
    var onOpenPanel: (() -> Void)?

    private let store = SettingsStore.shared
    private var hotKey: GlobalHotKey?
    private var hotKeySubscription: AnyCancellable?

    func start() {
        let hotKey = GlobalHotKey()
        hotKey.onTrigger = { [weak self] in self?.onOpenPanel?() }
        self.hotKey = hotKey
        hotKey.setEnabled(store.hotKeyEnabled)
        hotKeySubscription = store.$hotKeyEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.hotKey?.setEnabled(enabled) }
    }

    func checkForUpdates() {
        Task { @MainActor in
            do {
                if let release = try await UpdateChecker.latest() {
                    if AppVersion.isNewer(release.version, than: store.appVersion) {
                        alert(
                            title: L10n.t("Check for Updates…"),
                            message: L10n.t("Version %@ is available.", release.version),
                            open: release.url
                        )
                    } else {
                        alert(title: L10n.t("Check for Updates…"), message: L10n.t("Muster is up to date."))
                    }
                } else {
                    alert(
                        title: L10n.t("Check for Updates…"),
                        message: L10n.t("Could not check for updates: %@", "no public release information"),
                        open: releasesURL
                    )
                }
            } catch {
                alert(
                    title: L10n.t("Check for Updates…"),
                    message: L10n.t("Could not check for updates: %@", error.localizedDescription),
                    open: releasesURL
                )
            }
        }
    }

    private var releasesURL: URL {
        URL(string: "https://github.com/EthanWFL/muster/releases")!
    }

    private func alert(title: String, message: String, open url: URL? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let url {
            alert.addButton(withTitle: L10n.t("Open Releases"))
            alert.addButton(withTitle: L10n.t("OK"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.addButton(withTitle: L10n.t("OK"))
            alert.runModal()
        }
    }
}
