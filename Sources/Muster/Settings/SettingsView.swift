import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var model: PanelModel

    var body: some View {
        TabView {
            general.tabItem { Label(L10n.t("General"), systemImage: "gearshape") }
            shortcuts.tabItem { Label(L10n.t("Shortcuts"), systemImage: "keyboard") }
            approvals.tabItem { Label(L10n.t("Approvals"), systemImage: "checkmark.shield") }
            updates.tabItem { Label(L10n.t("Updates"), systemImage: "arrow.down.circle") }
            about.tabItem { Label(L10n.t("About"), systemImage: "info.circle") }
        }
        .frame(width: 520, height: 380)
    }

    private var general: some View {
        Form {
            Toggle(L10n.t("Launch at login"), isOn: $store.launchAtLogin)
            if let error = store.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Picker(L10n.t("Language"), selection: $store.language) {
                ForEach(L10n.Language.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            Text(L10n.t("Restart Muster to apply the language."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if store.launchAtLogin == false, store.loginItemError != nil {
                Text(L10n.t("Launch at login requires the packaged app."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Toggle(L10n.t("Enable global hotkey"), isOn: $store.hotKeyEnabled)
            LabeledContent(L10n.t("Global hotkey")) {
                Text("⌃⌥A").font(.system(.body, design: .monospaced))
            }
            if let error = store.hotKeyError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private var approvals: some View {
        Form {
            LabeledContent(L10n.t("Approval timeout")) {
                Text(L10n.t("%ds", Int(model.approvalTimeout.rounded())))
            }
            Toggle(L10n.t("Show a notification when a new approval arrives"), isOn: $store.notificationsEnabled)
        }
        .formStyle(.grouped)
    }

    private var updates: some View {
        Form {
            Text(L10n.t("Current version %@", store.appVersion))
            Button(L10n.t("Check for Updates…")) { SettingsCoordinator.shared.checkForUpdates() }
            Text(L10n.t("Updates are checked against GitHub releases."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(L10n.t("Source code"), destination: URL(string: "https://github.com/EthanWFL/muster")!)
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        Form {
            LabeledContent("Muster", value: store.appVersion)
            LabeledContent(L10n.t("Hook"), value: model.hookInstalled == true ? L10n.t("Installed") : L10n.t("Not installed"))
            Button(L10n.t("Open settings file")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.settingsPath)])
            }
            Link(L10n.t("Source code"), destination: URL(string: "https://github.com/EthanWFL/muster")!)
        }
        .formStyle(.grouped)
    }
}
