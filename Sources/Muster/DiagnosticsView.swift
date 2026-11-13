import MusterCore
import SwiftUI

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var reports: [AgentDiagnostic] = []
    @Published private(set) var isChecking = false

    func check() {
        guard !isChecking else { return }
        isChecking = true
        Task { [weak self] in
            let reports = await Task.detached(priority: .utility) { AgentDiagnostics.scan() }.value
            self?.reports = reports
            self?.isChecking = false
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            HStack {
                SectionTitle(text: L10n.t("Environment diagnostics"))
                Button(model.isChecking ? L10n.t("Checking…") : L10n.t("Check environment")) { model.check() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(model.isChecking)
            }
            if model.reports.isEmpty {
                Text(L10n.t("Check CLI locations, configuration files and supported capabilities."))
                    .font(T.small).foregroundStyle(T.muted).padding(.horizontal, T.s3)
            } else {
                Card {
                    ForEach(model.reports) { report in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(report.id) },
                            set: { if $0 { expanded.insert(report.id) } else { expanded.remove(report.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: T.s2) {
                                if report.agent.tracksProcesses {
                                    detail(L10n.t("CLI location"), report.executablePath ?? L10n.t("Not found on searched paths"))
                                }
                                if let path = report.configurationPath, let state = report.configurationState {
                                    detail(L10n.t("Configuration") + " · " + fileStatus(state), path)
                                }
                                if let path = report.rulesPath, let state = report.rulesState {
                                    detail(L10n.t("Rules") + " · " + fileStatus(state), path)
                                }
                                Text(capabilities(report.agent)).font(T.small).foregroundStyle(T.fg2)
                                if report.configurationState == .invalid || report.configurationState == .unsupported {
                                    Text(L10n.t("Open the original configuration to inspect its format."))
                                        .font(T.small).foregroundStyle(T.amber)
                                }
                            }
                            .padding(.vertical, T.s2)
                        } label: {
                            HStack {
                                Text(report.agent.name).font(T.body)
                                Spacer()
                                Text(report.agent.tracksProcesses
                                     ? L10n.t(report.executablePath == nil ? "CLI not found" : "CLI found")
                                     : L10n.t("File access only"))
                                    .font(T.micro).foregroundStyle(T.muted)
                            }
                        }
                        .padding(.horizontal, T.s3).padding(.vertical, T.s2)
                    }
                }
                Text(L10n.t("Missing files do not prove an agent is uninstalled. Custom shell paths may differ."))
                    .font(T.small).foregroundStyle(T.muted).padding(.horizontal, T.s3)
            }
        }
    }

    private func detail(_ title: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(T.small).foregroundStyle(T.muted)
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(T.mono).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileStatus(_ state: DiagnosticFileState) -> String {
        switch state {
        case .missing: return L10n.t("File missing")
        case .unreadable: return L10n.t("Not readable")
        case .readable: return L10n.t("Readable")
        case .invalid: return L10n.t("Invalid configuration")
        case .unsupported: return L10n.t("Unsupported format")
        }
    }

    private func capabilities(_ agent: AgentDescriptor) -> String {
        var items: [String] = []
        if agent.tracksProcesses { items.append(L10n.t("Process detection")) }
        if agent.tracksActivity { items.append(L10n.t("Activity inference")) }
        if agent.resumesSessions { items.append(L10n.t("Resume command")) }
        if agent.syncsRules { items.append(L10n.t("Rules sync")) }
        if agent.editableConfiguration { items.append(L10n.t("Model editing")) }
        return items.isEmpty ? L10n.t("File access only") : items.joined(separator: " · ")
    }
}
