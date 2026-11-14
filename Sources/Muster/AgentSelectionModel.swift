import Combine
import Foundation
import MusterCore

struct AgentSelectionState {
    let detected: [AgentDescriptor]
    let managedIDs: Set<String>
    var hasDetected = false
    var available: [AgentDescriptor] { detected.filter { managedIDs.contains($0.id) } }
}

/// One application-wide scope: installation evidence and user choices remain separate.
@MainActor
final class AgentSelectionModel: ObservableObject {
    @Published private(set) var state: AgentSelectionState
    @Published private(set) var isChecking = false
    let settings: SettingsStore
    private let detect: @Sendable () -> [AgentDescriptor]
    private var preferenceObservation: AnyCancellable?
    private(set) var refreshTask: Task<Void, Never>?

    init(settings: SettingsStore, detect: @escaping @Sendable () -> [AgentDescriptor] = { AgentInstallation.detect() }) {
        self.settings = settings
        self.detect = detect
        state = AgentSelectionState(detected: [], managedIDs: settings.managedAgentIDs ?? [])
        preferenceObservation = settings.$managedAgentIDs.sink { [weak self] selection in
            guard let self else { return }
            self.publish(detected: self.state.detected, selection: selection)
        }
    }
    var isAutomatic: Bool { settings.managedAgentIDs == nil }
    func manages(_ id: String) -> Bool { state.managedIDs.contains(id) }
    func setManaged(_ id: String, _ enabled: Bool) {
        guard AgentRegistry.agent(id) != nil else { return }
        var ids = state.managedIDs
        if enabled { ids.insert(id) } else { ids.remove(id) }
        settings.managedAgentIDs = ids
    }
    func selectDetected() { settings.managedAgentIDs = Set(state.detected.map(\.id)) }
    func selectNone() { settings.managedAgentIDs = [] }
    func followDetected() { settings.managedAgentIDs = nil }

    func refresh() {
        guard !isChecking else { return }
        isChecking = true
        let detect = detect
        refreshTask = Task {
            defer { isChecking = false; refreshTask = nil }
            let agents = await Task.detached(priority: .utility) { detect() }.value
            guard !Task.isCancelled else { return }
            publish(detected: agents, selection: settings.managedAgentIDs, hasDetected: true)
        }
    }
    private func publish(detected: [AgentDescriptor], selection: Set<String>?, hasDetected: Bool? = nil) {
        let known = Set(AgentRegistry.all.map(\.id))
        state = AgentSelectionState(detected: detected, managedIDs: (selection ?? Set(detected.map(\.id))).intersection(known),
                                    hasDetected: hasDetected ?? state.hasDetected)
    }
}
