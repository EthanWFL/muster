import Foundation

enum AgentSection: String, CaseIterable, Identifiable {
    case rules, skills, configuration
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rules: return L10n.t("Rules")
        case .skills: return L10n.t("Skills")
        case .configuration: return L10n.t("Configuration")
        }
    }
}

enum QuickAgentSection: String, CaseIterable {
    case rules, configuration
    var title: String { L10n.t(self == .rules ? "Rules" : "Config") }
    var windowSection: AgentSection { self == .rules ? .rules : .configuration }
}

enum AgentNavigation {
    static func migrate(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: "MusterAgentNavigationV1") else { return }
        let last = defaults.string(forKey: "MusterLastTab")
        if last == "Instructions" || last == "Configuration" {
            defaults.set(last == "Instructions" ? AgentSection.rules.rawValue : AgentSection.configuration.rawValue, forKey: "MusterAgentSection")
            defaults.set("Agent", forKey: "MusterLastTab")
        }
        if let old = defaults.stringArray(forKey: "MusterTabOrder") {
            var seen = Set<String>()
            let order = old.map { ["Instructions", "Configuration"].contains($0) ? "Agent" : $0 }
                .filter { seen.insert($0).inserted }
            defaults.set(order, forKey: "MusterTabOrder")
        }
        defaults.set(true, forKey: "MusterAgentNavigationV1")
    }
}
