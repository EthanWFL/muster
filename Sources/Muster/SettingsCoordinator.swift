import AppKit

/// Settings/update seam. The settings branch replaces this placeholder.
@MainActor
final class SettingsCoordinator {
    static let shared = SettingsCoordinator()

    /// Set by the status-item controller so settings/notifications can reveal the panel.
    var onOpenPanel: (() -> Void)?

    func start() {}

    func show(model: PanelModel) {}

    func checkForUpdates() {
        guard let url = URL(string: "https://github.com/EthanWFL/muster/releases") else { return }
        NSWorkspace.shared.open(url)
    }
}
