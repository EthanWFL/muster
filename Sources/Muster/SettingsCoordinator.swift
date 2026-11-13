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
        case available(UpdateRelease)
        case downloading(UpdateDownloadProgress)
        case installing
        case failed(String)
    }

    @Published private(set) var updateState: UpdateState = .idle
    private var updateTask: Task<Void, Never>?
    private var downloadID: UUID?
    private let updateKey = Bundle.main.object(forInfoDictionaryKey: "MusterUpdatePublicKey") as? String

    var updateBusy: Bool {
        switch updateState {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var hasTrustedUpdateKey: Bool { UpdateTrust.hasValidKey(updateKey) }

    func checkForUpdates() {
        guard !updateBusy else { return }
        updateState = .checking
        Task { @MainActor in
            do {
                guard let release = try await UpdateChecker.latest() else {
                    updateState = .failed(L10n.t("Could not check for updates: %@", "no public release information"))
                    return
                }
                updateState = AppVersion.isNewer(release.version, than: store.appVersion)
                    ? .available(release)
                    : .upToDate
            } catch {
                updateState = .failed(L10n.t("Could not check for updates: %@", error.localizedDescription))
            }
        }
    }

    var releasesURL: URL { URL(string: "https://github.com/EthanWFL/muster/releases")! }

    func cancelDownload() {
        guard case .downloading = updateState else { return }
        updateTask?.cancel()
    }

    /// Download can be cancelled; replacement is a short, non-cancellable transaction.
    func installAvailableUpdate() {
        guard case .available(let release) = updateState, let asset = release.asset, hasTrustedUpdateKey else { return }
        updateState = .downloading(.init(received: 0, expected: nil))
        let id = UUID()
        downloadID = id
        let appURL = Bundle.main.bundleURL
        let currentVersion = store.appVersion
        let key = updateKey
        updateTask = Task {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusterDownload-" + id.uuidString)
            defer {
                try? FileManager.default.removeItem(at: directory)
                downloadID = nil
                updateTask = nil
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let signatureURL = directory.appendingPathComponent("update.sig")
                let dmg = directory.appendingPathComponent("update.dmg")
                try await UpdateDownloader.download(asset.signatureURL, to: signatureURL, limit: 512)
                try Task.checkCancellation()
                try await UpdateDownloader.download(asset.url, to: dmg, limit: UpdateTrust.maximumImageBytes) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.downloadID == id, case .downloading = self.updateState else { return }
                        self.updateState = .downloading(progress)
                    }
                }
                try Task.checkCancellation()
                let signature = try Data(contentsOf: signatureURL)
                updateState = .installing
                try await Task.detached {
                    try UpdateInstaller.install(dmgURL: dmg, signature: signature, publicKey: key,
                        version: release.version, currentVersion: currentVersion, replacing: appURL)
                }.value
                UpdateInstaller.relaunch(appURL)
                NSApp.terminate(nil)
            } catch {
                if Task.isCancelled { updateState = .available(release) }
                else { updateState = .failed(L10n.t("Could not install the update: %@", L10n.t(error.localizedDescription))) }
            }
        }
    }
}
