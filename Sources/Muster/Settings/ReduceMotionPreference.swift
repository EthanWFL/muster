import SwiftUI

enum ReduceMotionPreference: String, CaseIterable, Identifiable {
    case system, on, off

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return L10n.t("Follow System")
        case .on: return L10n.t("Enabled")
        case .off: return L10n.t("Disabled")
        }
    }

    func isEnabled(systemValue: Bool) -> Bool {
        switch self {
        case .system: return systemValue
        case .on: return true
        case .off: return false
        }
    }
}

/// Resolve the app override wherever motion is used, including separate titlebar hosts.
@MainActor @propertyWrapper
struct ReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemValue
    @ObservedObject private var settings = SettingsStore.shared

    var wrappedValue: Bool {
        settings.reduceMotion.isEnabled(systemValue: systemValue)
    }
}
