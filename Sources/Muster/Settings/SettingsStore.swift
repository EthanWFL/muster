import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var language: L10n.Language {
        didSet {
            defaults.set(language.rawValue, forKey: L10n.languageKey)
            if language == .system {
                defaults.removeObject(forKey: "AppleLanguages")
            } else {
                defaults.set([language.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }

    @Published var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Self.hotKeyKey) }
    }

    @Published private(set) var loginItemError: String?
    @Published var hotKeyError: String?

    private static let hotKeyKey = "MusterHotKeyEnabled"
    private let defaults = UserDefaults.standard
    private var applyingLoginStatus = false

    private init() {
        language = L10n.Language(rawValue: defaults.string(forKey: L10n.languageKey) ?? "") ?? .system
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hotKeyEnabled = defaults.object(forKey: Self.hotKeyKey) as? Bool ?? true
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private func updateLoginItem() {
        guard !applyingLoginStatus else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = L10n.t("Login item error: %@", error.localizedDescription)
            applyingLoginStatus = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            applyingLoginStatus = false
        }
    }
}
