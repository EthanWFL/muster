import Foundation

/// Runtime localization. Keeping this outside SwiftUI's `Text("key")` lookup lets
/// the language be chosen in Settings without relying on the process locale at launch.
enum L10n {
    static let languageKey = "MusterLanguage"

    enum Language: String, CaseIterable, Identifiable {
        case system
        case english = "en"
        case chinese = "zh-Hans"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return L10n.t("Follow System")
            case .english: return "English"
            case .chinese: return "简体中文"
            }
        }
    }

    static var language: Language {
        Language(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system
    }

    static var code: String {
        switch language {
        case .english: return "en"
        case .chinese: return "zh-Hans"
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        }
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = localized(key)
        return args.isEmpty ? format : String(format: format, arguments: args)
    }

    private static func localized(_ key: String) -> String {
        guard code != "en", let bundle = bundle(for: code) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private static func bundle(for code: String) -> Bundle? {
        let resource = Bundle.main.resourceURL
        let root = Bundle.main.bundleURL
        let names = [code, code.lowercased()]
        var candidates: [URL?] = []
        for name in names {
            candidates += [
                resource?.appendingPathComponent("\(name).lproj"),
                resource?.appendingPathComponent("Muster_Muster.bundle/Contents/Resources/\(name).lproj"),
                resource?.appendingPathComponent("Muster_Muster.bundle/\(name).lproj"),
                root.appendingPathComponent("Muster_Muster.bundle/Contents/Resources/\(name).lproj"),
                root.appendingPathComponent("Muster_Muster.bundle/\(name).lproj"),
            ]
        }
        for url in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(path: url.path) { return bundle }
        }
        return nil
    }
}
