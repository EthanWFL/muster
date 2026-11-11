import MusterCore
import SwiftUI

struct EnvironmentView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var env: EnvironmentModel

    private var listeners: [CleanupItem] { env.items.filter { kind($0) == .listener } }
    private var orphans: [CleanupItem] { env.items.filter { kind($0) == .orphan } }
    private var worktrees: [CleanupItem] { env.items.filter { kind($0) == .worktree } }

    private enum Group { case listener, orphan, worktree }

    private func kind(_ item: CleanupItem) -> Group {
        switch item.action {
        case .terminate(let t): return t.kind == .listener ? .listener : .orphan
        case .pruneWorktrees, .removeWorktreeDirectory: return .worktree
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let report = env.report {
                ReportCard(report: report, dismiss: env.dismissReport)
                    .padding(.bottom, 4)
            }
            if env.items.isEmpty {
                VStack(spacing: 4) {
                    Text(env.plan == nil ? L10n.t("Scanning…") : L10n.t("Nothing to clean up")).fontWeight(.semibold)
                    Text(L10n.t("Listening ports, orphaned processes and stale worktrees from agent sessions show up here"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .padding(.horizontal, 16)
            } else {
                section(L10n.t("Listening ports"), listeners)
                section(L10n.t("Orphaned processes"), orphans)
                section(L10n.t("Stale worktrees"), worktrees)
                PlanBox(env: env)
            }
        }
        .onAppear { env.setVisible(true) }
        .onDisappear { env.setVisible(false) }
    }

    @ViewBuilder private func section(_ title: String, _ items: [CleanupItem]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(items) { item in
                CleanupRow(model: model, env: env, item: item)
            }
        }
    }
}

private struct CleanupRow: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var env: EnvironmentModel
    let item: CleanupItem

    private var isSelected: Bool { env.selected.contains(item.id) }
    private var isConfirmed: Bool { env.confirmed.contains(item.id) }

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in env.toggle(item.id) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 0) {
                text.main
                text.sub.font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            trailing.font(.subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { env.toggle(item.id) }
    }

    private var projectName: (String) -> String {
        { id in model.sessions.first(where: { $0.id == id })?.projectName ?? L10n.t("unknown") }
    }

    private var text: (main: Text, sub: Text) {
        switch item.action {
        case .terminate(let t):
            let name = t.name ?? L10n.t("process")
            if t.kind == .listener {
                let ports = t.ports.map { ":\($0)" }.joined(separator: " ")
                return (Text(ports).font(.system(size: 12, design: .monospaced)) + Text("  \(name)"),
                        Text("\(projectName(t.sessionID)) · pid \(t.identity.pid)"))
            }
            return (Text(name) + Text("  pid \(t.identity.pid)").font(.system(size: 12, design: .monospaced)),
                    Text(L10n.t("Orphaned from %@", projectName(t.sessionID))))
        case .pruneWorktrees(let repo):
            return (Text(L10n.t("Prune stale worktrees")), Text((repo as NSString).abbreviatingWithTildeInPath))
        case .removeWorktreeDirectory(_, let path):
            return (Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 12, design: .monospaced)),
                    Text(L10n.t("Merged worktree directory")))
        }
    }

    @ViewBuilder private var trailing: some View {
        if item.needsExplicitConfirmation && isSelected {
            Button(isConfirmed ? L10n.t("Confirmed") : L10n.t("Confirm")) { env.toggleConfirmed(item.id) }
                .buttonStyle(PillButtonStyle(kind: isConfirmed ? .secondary : .primary))
        } else if let c = item.confidence {
            Text(item.isUncertain ? L10n.t("Uncertain") : "\(Int((c * 100).rounded()))%")
                .foregroundStyle(item.isUncertain ? Color.orange : Color.secondary)
                .monospacedDigit()
        } else if case .removeWorktreeDirectory = item.action {
            Text(L10n.t("Needs confirmation")).foregroundStyle(.secondary)
        } else {
            Text(L10n.t("Prune")).foregroundStyle(.secondary)
        }
    }
}

/// 「将执行的命令」：与 `CleanupExecutor` 执行的是同一批 item（R7）
private struct PlanBox: View {
    @ObservedObject var env: EnvironmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(env.commandTexts.isEmpty ? L10n.t("Nothing selected") : env.commandTexts.joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(hint).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(env.isBusy ? L10n.t("Working…") : L10n.t("Clean up %d", env.selectedItems.count)) { env.execute() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(!env.canExecute)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 4)
        .padding(.top, 12)
    }

    private var hint: String {
        env.unconfirmedCount > 0
            ? L10n.t(env.unconfirmedCount == 1
                ? "Confirm %d highlighted item first"
                : "Confirm %d highlighted items first", env.unconfirmedCount)
            : L10n.t("These commands are exactly what runs")
    }
}

private struct ReportCard: View {
    let report: CleanupReport
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("Cleanup result")).fontWeight(.semibold)
                Spacer()
                Button(L10n.t("Dismiss"), action: dismiss).buttonStyle(PillButtonStyle(kind: .quiet))
            }
            ForEach(Array(report.entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.commandText)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(outcomeText(entry.outcome))
                        .font(.subheadline)
                        .foregroundStyle(outcomeColor(entry.outcome))
                }
            }
            if let summary = summary { Text(summary).font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 4)
    }

    private var summary: String? {
        var parts: [String] = []
        if !report.freedPorts.isEmpty {
            parts.append(L10n.t("ports signalled: %@", report.freedPorts.map(String.init).joined(separator: ", ")))
        }
        if !report.prunedRepositories.isEmpty { parts.append(L10n.t("%d repo pruned", report.prunedRepositories.count)) }
        if !report.removedDirectories.isEmpty { parts.append(L10n.t("%d directory removed", report.removedDirectories.count)) }
        if report.reclaimedBytes > 0 {
            parts.append(L10n.t("%@ reclaimed", ByteCountFormatter.string(fromByteCount: report.reclaimedBytes, countStyle: .file)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func outcomeText(_ o: CleanupOutcome) -> String {
        switch o {
        case .done: return L10n.t("Done")
        case .termSent: return L10n.t("SIGTERM sent")
        case .refused(let r): return L10n.t("Refused: %@", refusalText(r))
        case .failed(let m): return L10n.t("Failed: %@", m)
        }
    }

    private func outcomeColor(_ o: CleanupOutcome) -> Color {
        switch o {
        case .done, .termSent: return .secondary
        case .refused: return .orange
        case .failed: return .red
        }
    }

    private func refusalText(_ r: CleanupRefusal) -> String {
        switch r {
        case .invalidPID: return L10n.t("protected pid")
        case .ownProcess: return L10n.t("this app")
        case .processGone: return L10n.t("already gone")
        case .identityChanged: return L10n.t("pid was reused")
        case .notInSessionTree: return L10n.t("not in the session's process tree")
        case .uncertainOwnership: return L10n.t("ownership uncertain")
        case .confirmationRequired: return L10n.t("needs confirmation")
        case .notTerminatedByUs: return L10n.t("not terminated by us")
        case .gracePeriodNotElapsed: return L10n.t("grace period not over")
        case .unsafePath: return L10n.t("unsafe path")
        }
    }
}
