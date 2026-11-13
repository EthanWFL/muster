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

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Self.notificationsKey) }
    }

    @Published var comfortableLayout: Bool {
        didSet { defaults.set(comfortableLayout, forKey: "MusterComfortableLayout") }
    }

    /// shortcut: 明文放 UserDefaults；webhook 只能发消息不能读，要更稳时再迁到 Keychain
    @Published var feishuWebhook: String {
        didSet { defaults.set(feishuWebhook, forKey: Self.feishuKey) }
    }

    @Published private(set) var loginItemError: String?
    @Published var hotKeyError: String?

    private static let hotKeyKey = "MusterHotKeyEnabled"
    private static let notificationsKey = "MusterNotificationsEnabled"
    private static let feishuKey = "MusterFeishuWebhook"
    private let defaults = UserDefaults.standard
    private var applyingLoginStatus = false

    private init() {
        language = L10n.Language(rawValue: defaults.string(forKey: L10n.languageKey) ?? "") ?? .system
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hotKeyEnabled = defaults.object(forKey: Self.hotKeyKey) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Self.notificationsKey) as? Bool ?? true
        comfortableLayout = defaults.bool(forKey: "MusterComfortableLayout")
        feishuWebhook = defaults.string(forKey: Self.feishuKey) ?? ""
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
