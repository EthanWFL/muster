import AppKit
import MusterCore
import SwiftUI

@MainActor
final class ConfigurationModel: ObservableObject {
    @Published private(set) var targets: [AgentConfiguration] = []
    @Published private(set) var selected: AgentConfiguration?
    @Published private(set) var snapshot: ConfigurationSnapshot?
    @Published private(set) var choices: [ConfigurationModelChoice] = []
    @Published private(set) var canRestore = false
    @Published var provider = "" { didSet { previewing = false } }
    @Published var model = "" { didSet { previewing = false } }
    @Published var previewing = false
    @Published var confirmingRestore = false
    @Published var confirmingReload = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    private let store = AgentConfigurationStore()

    var currentChoice: ConfigurationModelChoice { .init(provider: provider, model: model) }
    var availableChoices: [ConfigurationModelChoice] {
        choices.contains(currentChoice) ? choices : [currentChoice] + choices
    }

    var dirty: Bool { snapshot.map { provider != $0.provider || model != $0.model } ?? false }

    func loadIfNeeded() {
        guard selected == nil else { return }
        targets = AgentConfiguration.detect()
        if let first = targets.first { select(first) }
    }

    func select(_ target: AgentConfiguration) {
        guard !dirty else { return }
        selected = target
        reload()
    }

    func reload() {
        snapshot = nil
        choices = []
        canRestore = false
        previewing = false
        errorMessage = nil
        notice = nil
        guard let selected, selected.editable else { return }
        do {
            let loaded = try store.load(selected)
            snapshot = loaded
            provider = loaded.provider
            model = loaded.model
            choices = store.choices(loaded)
            canRestore = store.canRestore(loaded)
        } catch { show(error) }
    }

    func preview() {
        guard let snapshot else { return }
        do {
            _ = try store.proposed(snapshot, provider: provider, model: model)
            errorMessage = nil
            notice = nil
            previewing = true
        } catch { show(error) }
    }

    func save() {
        guard previewing, let snapshot else { return }
        do {
            try store.save(snapshot, provider: provider, model: model)
            reload()
            notice = L10n.t("Configuration saved. Start a new agent session to use it.")
        } catch { show(error) }
    }

    func restore() {
        guard let snapshot else { return }
        do {
            try store.restore(snapshot)
            reload()
            notice = L10n.t("Previous configuration restored.")
        } catch { show(error) }
    }

    func openFile() {
        guard let selected else { return }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: selected.path)) {
            errorMessage = L10n.t("Could not open the configuration file.")
        }
    }

    func revealFile() {
        guard let selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selected.path)])
    }

    private func show(_ error: Error) {
        previewing = false
        errorMessage = L10n.t(error.localizedDescription)
    }
}
