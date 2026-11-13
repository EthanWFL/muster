import AppKit
import Combine
import MusterCore

@MainActor
final class SettingsCoordinator: ObservableObject {
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

    /// 更新状态直接显示在设置页里，不再弹模态窗（模态窗会让面板失焦收起）。
    enum UpdateState: Equatable {
        case idle, checking, upToDate
        case available(version: String, page: URL, asset: URL?)
        case installing
        case failed(String)
    }

    @Published private(set) var updateState: UpdateState = .idle

    func checkForUpdates() {
        guard updateState != .checking, updateState != .installing else { return }
        updateState = .checking
        Task { @MainActor in
            do {
                guard let release = try await UpdateChecker.latest() else {
                    updateState = .failed(L10n.t("Could not check for updates: %@", "no public release information"))
                    return
                }
                updateState = AppVersion.isNewer(release.version, than: store.appVersion)
                    ? .available(version: release.version, page: release.url, asset: release.assetURL)
                    : .upToDate
            } catch {
                updateState = .failed(L10n.t("Could not check for updates: %@", error.localizedDescription))
            }
        }
    }

    var releasesURL: URL { URL(string: "https://github.com/EthanWFL/muster/releases")! }

    /// 下载 → 挂载 → 换包 → 重启。下载和换包都不在主线程。
    // shortcut: 没有进度条和断点续传，DMG 大了会显得卡住；真嫌慢再加进度。
    func install(_ asset: URL) {
        guard updateState != .installing else { return }
        updateState = .installing
        let appURL = Bundle.main.bundleURL
        Task {
            do {
                let (downloaded, response) = try await URLSession.shared.download(from: asset)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw UpdateCheckError.download((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("Muster-update.dmg")
                try? FileManager.default.removeItem(at: dmg)
                try FileManager.default.moveItem(at: downloaded, to: dmg)
                try await Task.detached { try UpdateInstaller.install(dmgURL: dmg, replacing: appURL) }.value
                try? FileManager.default.removeItem(at: dmg)
                UpdateInstaller.relaunch(appURL)
                NSApp.terminate(nil)
            } catch {
                updateState = .failed(L10n.t("Could not install the update: %@", error.localizedDescription))
            }
        }
    }
}
