import MusterCore
import SwiftUI

/// The library is the primary workspace; reading a skill is an explicit secondary action.
struct SkillsBrowser<Row: View>: View {
    @ObservedObject var model: SkillsModel
    let agentID: String
    let managedAgents: [AgentDescriptor]
    let open: (SkillRecord) -> Void
    @ViewBuilder let row: (SkillRecord) -> Row
    @State private var section = Section.library
    @State private var collapsed = Set<String>()

    private enum Section: CaseIterable { case library, discovered }
    private var discoveries: [SkillDiscovery] {
        let ids = Set(managedAgents.map(\.id))
        let visible = model.discovered.filter { !$0.readers.allSatisfy { !ids.contains($0) } && (agentID == "all" || $0.readers.contains(agentID)) }
        return Dictionary(grouping: visible, by: { item in item.digest.map { item.name + ":" + $0 } ?? item.id })
            .values.compactMap { entries in
                entries.first { !$0.managed && $0.suspendedID == nil } ?? entries.first
            }.sorted { $0.name == $1.name ? $0.path < $1.path : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var filteredDiscoveries: [SkillDiscovery] {
        let words = model.search.split(whereSeparator: \.isWhitespace)
        return discoveries.filter { item in
            words.allSatisfy { (item.name + " " + item.summary + " " + item.path).localizedStandardContains(String($0)) }
        }
    }
    private var groups: [(String, [SkillRecord])] {
        Dictionary(grouping: model.visibleSkills, by: groupName).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: T.s3) {
                SegmentedControl(items: Section.allCases, selection: $section) { section in
                    section == .library
                        ? L10n.t("In library") + " · \(model.snapshot.skills.count)"
                        : L10n.t("Discovered locally") + " · \(discoveries.count)"
                }.frame(width: 300).disabled(model.isSelecting)
                Spacer()
                if section == .library {
                    if model.isSelecting {
                        Text(L10n.t("%d selected", model.markedIDs.count)).font(T.small).foregroundStyle(T.muted)
                        Button(L10n.t("Select all")) { model.markAll() }.buttonStyle(PillButtonStyle(kind: .quiet))
                        Button(L10n.t("Clear selection")) { model.clearMarks() }.buttonStyle(PillButtonStyle(kind: .quiet))
                    }
                    Button(L10n.t(model.isSelecting ? "Done" : "Select")) {
                        model.isSelecting ? model.endSelection() : model.beginSelection()
                    }.buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.isBusy || model.snapshot.skills.isEmpty)
                }
            }.padding(.horizontal, T.s3).padding(.vertical, T.s2).disabled(model.isBusy)
            ScrollView {
                LazyVStack(spacing: T.s2) {
                    if section == .library {
                        if groups.isEmpty { empty }
                        ForEach(groups, id: \.0) { name, skills in
                            VStack(spacing: 0) {
                                Button {
                                    if !collapsed.insert(name).inserted { collapsed.remove(name) }
                                } label: {
                                    HStack(spacing: T.s2) {
                                        Image(systemName: collapsed.contains(name) ? "chevron.right" : "chevron.down").font(T.glyph)
                                        Image(systemName: "folder").foregroundStyle(T.muted)
                                        Text(name).font(T.section).lineLimit(1).truncationMode(.middle)
                                        Text("\(skills.count)").font(T.small).foregroundStyle(T.muted)
                                        Spacer()
                                    }.padding(T.s3).contentShape(Rectangle())
                                }.buttonStyle(InteractivePlainButtonStyle(pressedScale: 1)).help(name)
                                if !collapsed.contains(name) || !model.search.isEmpty {
                                    ForEach(skills) { skill in
                                        Hairline()
                                        row(skill)
                                    }
                                }
                            }.background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
                                .overlay(RoundedRectangle(cornerRadius: T.r).strokeBorder(T.line, lineWidth: 0.5))
                        }
                    } else {
                        if filteredDiscoveries.isEmpty { empty }
                        ForEach(filteredDiscoveries) { found in discoveredRow(found) }
                    }
                }.padding(.horizontal, T.s3).padding(.bottom, T.s3)
            }
        }
    }

    private var empty: some View {
        EmptyState(title: L10n.t(model.search.isEmpty ? "No skills here yet." : "No matching skills."),
                   message: L10n.t(section == .library ? "Import a skill folder or create your first skill." : "No unmanaged skills were found for the selected Agents."))
    }

    private func groupName(_ skill: SkillRecord) -> String {
        switch skill.source.kind {
        case .created: return L10n.t("Created in Muster")
        case .git: return skill.source.location
        case .local:
            return (URL(fileURLWithPath: skill.source.location).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func discoveredRow(_ found: SkillDiscovery) -> some View {
        let imported = model.importedSkill(for: found)
        let sameName = model.snapshot.skills.contains { $0.name == found.name }
        return HStack(spacing: T.s3) {
            Image(systemName: "doc.text").foregroundStyle(T.muted)
            VStack(alignment: .leading, spacing: T.s1) {
                HStack {
                    Text(found.name).font(T.body.weight(.medium)).lineLimit(1)
                    if imported != nil { Text(L10n.t("Already imported")).font(T.micro).foregroundStyle(T.muted) }
                    else if sameName { Text(L10n.t("Same name in library")).font(T.micro).foregroundStyle(T.amber) }
                }
                Text(found.summary).font(T.small).foregroundStyle(T.muted).lineLimit(1)
                Text(found.readers.map { AgentRegistry.agent($0)?.name ?? $0 }.joined(separator: " · ")
                     + " · " + (found.path as NSString).abbreviatingWithTildeInPath)
                    .font(T.micro).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
                if found.suspendedID != nil { Text(L10n.t("Disabled locally; original entry saved")).font(T.micro).foregroundStyle(T.muted) }
                if found.isShared { Text(L10n.t("Visible through a shared directory")).font(T.micro).foregroundStyle(T.muted) }
                if let issue = found.issue { Text(L10n.t(issue)).font(T.micro).foregroundStyle(T.amber).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: T.s1) {
                ForEach(managedAgents) { agent in
                    DiscoveredAgentButton(model: model, found: found, agent: agent)
                }
            }
            Menu {
                if let imported {
                    Button(L10n.t("View in library")) { section = .library; open(imported) }
                } else if found.suspendedID == nil {
                    Button(L10n.t("Import")) { model.findLocal(URL(fileURLWithPath: found.path)) }.disabled(found.digest == nil)
                }
                Button(L10n.t("Reveal in Finder")) { model.reveal(found.path) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.t("More actions"))
        }.padding(T.s3).background(RoundedRectangle(cornerRadius: T.r).fill(T.card)).disabled(model.isBusy)
    }
}
