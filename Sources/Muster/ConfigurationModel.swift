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
    @Published var provider = ""
    @Published var model = ""
    /// 本地模型列表之外手填；列表只有一项或没有时视图自己退回手填
    @Published var customEntry = false
    @Published private(set) var fileInfo: String?
    @Published var confirmingRestore = false
    @Published var confirmingReload = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var presets: [ConfigurationPreset] = []
    @Published var presetName = ""
    private let store: AgentConfigurationStore
    private let presetStore: ConfigurationPresetStore
    private let detectTargets: () -> [AgentConfiguration]

    init(store: AgentConfigurationStore = AgentConfigurationStore(),
         presetStore: ConfigurationPresetStore = ConfigurationPresetStore(),
         detectTargets: @escaping () -> [AgentConfiguration] = { AgentConfiguration.detect() }) {
        self.store = store
        self.presetStore = presetStore
        self.detectTargets = detectTargets
    }

    func savePreset() {
        guard let selected, selected.editable else { return }
        do {
            try presetStore.save(ConfigurationPreset(name: presetName.trimmingCharacters(in: .whitespacesAndNewlines),
                agentID: selected.id, provider: provider, model: model))
            presetName = ""
            try loadPresets()
            notice = L10n.t("Preset saved. Agent configuration is unchanged.")
            errorMessage = nil
        } catch { show(error) }
    }

    func usePreset(_ preset: ConfigurationPreset) {
        guard !dirty, snapshot != nil, selected?.id == preset.agentID else { return }
        provider = preset.provider
        model = preset.model
        customEntry = !choices.contains(currentChoice)
        notice = L10n.t("Preset loaded into the form. Review the diff, then save.")
    }

    func removePreset(_ preset: ConfigurationPreset) {
        do { try presetStore.remove(preset.id); try loadPresets() } catch { show(error) }
    }

    private func loadPresets() throws {
        presets = try presetStore.load().filter { $0.agentID == selected?.id }.sorted { $0.name < $1.name }
    }

    var currentChoice: ConfigurationModelChoice { .init(provider: provider, model: model) }
    var availableChoices: [ConfigurationModelChoice] {
        choices.contains(currentChoice) ? choices : [currentChoice] + choices
    }

    var dirty: Bool { snapshot.map { provider != $0.provider || model != $0.model } ?? false }

    func loadIfNeeded() {
        guard selected == nil else { return }
        targets = detectTargets()
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
        customEntry = false
        errorMessage = nil
        notice = nil
        presets = []
        do { try loadPresets() } catch { show(error) }
        fileInfo = selected.flatMap { Self.describe($0.path) }
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

    /// 变更在页内实时以 diff 展示；`store.save` 自己会先校验再写
    func save() {
        guard let snapshot else { return }
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

    private static func describe(_ path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              let size = attributes[.size] as? Int64 ?? (attributes[.size] as? Int).map(Int64.init),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return L10n.t("%@ · Modified %@", ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                      date.formatted(date: .abbreviated, time: .shortened))
    }

    private func show(_ error: Error) {
        errorMessage = L10n.t(error.localizedDescription)
    }
}
