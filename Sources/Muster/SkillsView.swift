import MusterCore
import SwiftUI

struct SkillsView: View {
    @ObservedObject var model: SkillsModel
    let agentID: String
    @State private var showsCreate = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            HSplitView {
                skillList.frame(minWidth: 200, idealWidth: 250, maxWidth: 330, maxHeight: .infinity)
                detail.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = model.errorMessage ?? model.notice {
                Hairline()
                Text(message).font(T.small).foregroundStyle(model.errorMessage == nil ? T.muted : T.red)
                    .fixedSize(horizontal: false, vertical: true).padding(T.s3).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(T.fg)
        .onAppear { if model.searchFocusRequest > 0 { searchFocused = true } }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .sheet(isPresented: $model.showsImport, onDismiss: { model.cancel(); model.clearImport() }) { SkillImportSheet(model: model) }
        .sheet(isPresented: $showsCreate) { SkillCreateSheet(model: model) }
        .sheet(item: $model.plan) { plan in SkillPlanSheet(model: model, plan: plan) }
        .sheet(item: $model.updateCandidate, onDismiss: { model.dismissUpdate() }) { candidate in SkillUpdateSheet(model: model, candidate: candidate) }
        .alert(L10n.t("Keep this skill draft?"), isPresented: $model.confirmsSelection) {
            Button(L10n.t("Save draft and switch")) { model.resolveSelection(save: true) }
            Button(L10n.t("Discard and switch"), role: .destructive) { model.resolveSelection(save: false) }
            Button(L10n.t("Cancel"), role: .cancel) { }
        } message: { Text(L10n.t("The editor has pending changes. Unapplied Agent selections will be discarded when switching.")) }
    }

    private var toolbar: some View {
        HStack(spacing: T.s2) {
            HStack(spacing: T.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(T.muted)
                TextField(L10n.t("Search skills…"), text: $model.search).textFieldStyle(.plain).font(T.body).focused($searchFocused)
                if !model.search.isEmpty { IconButton(symbol: "xmark.circle.fill", label: L10n.t("Clear search")) { model.search = "" } }
            }.padding(.horizontal, T.s2).frame(height: T.controlHeight + 4)
                .background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
            Button(L10n.t("Import skills")) { model.clearImport(); model.showsImport = true }.buttonStyle(PillButtonStyle(kind: .secondary))
            Button(L10n.t("New skill")) { showsCreate = true }.buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(model.unsaved || model.deploymentDirty)
            IconButton(symbol: "folder", label: L10n.t("Open skill library")) { model.openLibrary() }
            IconButton(symbol: "arrow.uturn.backward", label: L10n.t("Restore last deployment")) { model.previewUndo() }.disabled(!model.snapshot.canUndo)
            IconButton(symbol: "arrow.clockwise", label: L10n.t("Refresh skills"), isBusy: model.isBusy) { model.load(force: true) }
        }.padding(T.s3).disabled(model.isBusy)
    }

    private var skillList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: T.s2) {
                Text(L10n.t("In library") + " · \(model.snapshot.skills.count)").font(T.section).foregroundStyle(T.muted)
                    .padding(.horizontal, T.s2)
                if model.visibleSkills.isEmpty {
                    Text(L10n.t(model.search.isEmpty ? "Import a skill folder or create your first skill." : "No matching skills."))
                        .font(T.small).foregroundStyle(T.muted).padding(T.s2)
                }
                ForEach(model.visibleSkills) { skill in
                    Button { model.select(skill.id) } label: {
                        VStack(alignment: .leading, spacing: T.s1) {
                            Text(skill.name).font(T.body.weight(.medium)).lineLimit(1)
                            Text(skill.summary).font(T.small).foregroundStyle(T.muted).lineLimit(2)
                            let deployments = model.snapshot.deployments.filter { $0.skillID == skill.id }
                            Text(deployments.isEmpty ? L10n.t("Not deployed") : deployments.map {
                                let name = AgentRegistry.agent($0.targetID)?.name ?? $0.targetID
                                return model.availableAgentIDs?.contains($0.targetID) == false ? L10n.t("%@ (outside current scope)", name) : name
                            }.joined(separator: " · "))
                                .font(T.micro).foregroundStyle(T.muted).lineLimit(1)
                        }.padding(T.s2).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: T.r).fill(model.selectedID == skill.id ? T.accentSoft : .clear))
                            .contentShape(Rectangle())
                    }.buttonStyle(InteractivePlainButtonStyle(pressedScale: 1)).disabled(model.isBusy)
                        .accessibilityAddTraits(model.selectedID == skill.id ? .isSelected : [])
                }
                Hairline().padding(.vertical, T.s2)
                Text(L10n.t("Agent skills outside Muster")).font(T.section).foregroundStyle(T.muted).padding(.horizontal, T.s2)
                ForEach(model.discovered.filter { !$0.managed && (agentID == "all" || $0.readers.contains(agentID)) &&
                    (model.search.isEmpty || ($0.name + " " + $0.summary).localizedStandardContains(model.search)) }) { found in
                    VStack(alignment: .leading, spacing: T.s1) {
                        Text(found.name).font(T.body)
                        Text(found.readers.map { AgentRegistry.agent($0)?.name ?? $0 }.joined(separator: " · ")).font(T.micro).foregroundStyle(T.muted)
                        if found.isShared { Text(L10n.t("Visible through a shared directory")).font(T.micro).foregroundStyle(T.amber) }
                        if let issue = found.issue { Text(L10n.t(issue)).font(T.micro).foregroundStyle(T.amber).lineLimit(2) }
                        HStack {
                            Button(L10n.t("Import")) { model.findLocal(URL(fileURLWithPath: found.path)) }.buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.isBusy)
                            IconButton(symbol: "folder", label: L10n.t("Reveal in Finder")) { model.reveal(found.path) }
                        }
                    }.padding(T.s2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(T.s3)
        }
    }

    @ViewBuilder private var detail: some View {
        if let skill = model.selected {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: T.s4) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: T.s2) {
                                Text(skill.name).font(.system(size: 21, weight: .semibold)).textSelection(.enabled)
                                Text(skill.summary).font(T.body).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Menu {
                                Button(L10n.t("Check skill update")) { model.checkUpdate() }.disabled(skill.source.kind == .created || model.dirty)
                                if skill.revisions.count > 1 {
                                    Divider()
                                    ForEach(skill.revisions.reversed().filter { $0.id != skill.revision }) { revision in
                                        Button(L10n.t("Restore version %@", String(revision.id.prefix(8)))) { model.restore(revision.id) }.disabled(model.dirty)
                                    }
                                }
                            } label: { CompactMenuLabel(title: L10n.t("Versions"), symbol: "clock.arrow.circlepath") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isBusy)
                        }
                        source(skill)
                        deployment(skill)
                        HStack {
                            Text("SKILL.md").font(T.section)
                            Spacer()
                            Text(L10n.t("Editing the draft leaves deployed versions unchanged.")).font(T.micro).foregroundStyle(T.muted)
                        }
                        TextEditor(text: $model.draft).font(T.mono).foregroundStyle(T.fg).scrollContentBackground(.hidden)
                            .padding(T.s2).frame(minHeight: 220).background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
                            .overlay(RoundedRectangle(cornerRadius: T.r).strokeBorder(T.line, lineWidth: 0.5)).disabled(model.isBusy)
                        DisclosureGroup(L10n.t("Included files (%d)", model.files.count)) {
                            VStack(alignment: .leading, spacing: T.s1) {
                                ForEach(model.files, id: \.self) { Text($0).font(T.monoMicro).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, T.s2)
                        }.font(T.small).foregroundStyle(T.muted)
                    }.padding(T.s4)
                }
                Hairline()
                ViewThatFits(in: .horizontal) {
                    HStack { draftStatus; Spacer(); editorActions }
                    VStack(alignment: .leading, spacing: T.s2) { draftStatus; HStack { Spacer(); editorActions } }
                }.padding(T.s3)
            }
        } else {
            VStack(spacing: T.s3) {
                Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(T.muted)
                Text(L10n.t("Select a skill")).font(T.body.weight(.medium))
                Text(L10n.t("Keep one library and choose which Agents receive each skill."))
                    .font(T.small).foregroundStyle(T.muted).multilineTextAlignment(.center)
            }.padding(T.s4).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var draftStatus: some View {
        Text(L10n.t(model.unsaved ? "Unsaved changes" : (model.dirty ? "Draft saved" : "Published version")))
            .font(T.small).foregroundStyle(T.muted)
    }
    private var editorActions: some View {
        HStack(spacing: T.s2) {
            Button(L10n.t("Discard")) { model.discardDraft() }.buttonStyle(PillButtonStyle(kind: .quiet)).disabled(!model.dirty || model.isBusy)
            Button(L10n.t("Save draft")) { model.saveDraft() }.buttonStyle(PillButtonStyle(kind: .secondary))
                .keyboardShortcut("s").disabled(!model.unsaved || model.isBusy)
            Button(L10n.t("Publish to library")) { model.publish() }.buttonStyle(PillButtonStyle(kind: .primary)).disabled(!model.canPublish)
        }.fixedSize()
    }
    private func source(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: T.s1) {
            Text(skill.source.kind == .created ? L10n.t("Created in Muster") : skill.source.location)
                .font(T.monoMicro).foregroundStyle(T.muted).lineLimit(2).textSelection(.enabled)
            HStack(spacing: T.s2) {
                Text(L10n.t("Version %@", String(skill.revision.prefix(8))))
                if let commit = skill.source.commit { Text("Git " + commit.prefix(8)) }
                if let license = skill.license { Text(license) }
            }.font(T.micro).foregroundStyle(T.muted)
        }
    }
    private func deployment(_ skill: SkillRecord) -> some View {
        let targets = model.deploymentTargets.filter { agentID == "all" || $0.id == agentID }
        return VStack(alignment: .leading, spacing: T.s2) {
            HStack {
                Text(L10n.t("Deploy to Agents")).font(T.section)
                Spacer()
                Button(L10n.t("Preview deployment")) { model.preview() }.buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.isBusy)
            }
            if targets.isEmpty {
                Text(L10n.t(agentID == "all" ? "No Agents in the current scope support skill deployment. You can still manage the library."
                           : "Skill deployment is not supported for this Agent yet.")).font(T.small).foregroundStyle(T.muted)
            }
            ForEach(targets) { target in
                VStack(alignment: .leading, spacing: T.s1) {
                    HStack {
                        Toggle(target.name, isOn: Binding(get: { model.desired[target.id] != nil }, set: { model.setEnabled(target, $0) }))
                            .toggleStyle(.checkbox).font(T.body)
                        Spacer(minLength: T.s2)
                        let deployed = model.snapshot.deployments.first { $0.skillID == skill.id && $0.targetID == target.id }
                        if let deployed {
                            Text(L10n.t(deployed.revision == skill.revision ? "Deployed" : "Older version deployed"))
                                .font(T.micro).foregroundStyle(deployed.revision == skill.revision ? T.muted : T.amber)
                        }
                        InlineSelect(items: SkillInstallMode.allCases, label: { L10n.t($0 == .symlink ? "Symbolic link" : "Copy") },
                            selection: Binding(get: { model.mode(target) }, set: { model.setMode(target, $0) }))
                            .disabled(model.desired[target.id] == nil)
                    }
                    Text((target.directory as NSString).abbreviatingWithTildeInPath).font(T.monoMicro).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
                    if target.sharedReaders.isEmpty,
                       model.discovered.contains(where: { $0.name == skill.name && $0.isShared && $0.readers.contains(target.id) }) {
                        Text(L10n.t("A skill with this name is also visible in a shared directory. This switch controls only the dedicated directory."))
                            .font(T.micro).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true)
                    }
                    if target.sharedReaders.contains(where: { $0 != target.id }) {
                        Text(L10n.t("Shared directory: also visible to %@. Per-Agent switches cannot hide its contents.",
                            target.sharedReaders.filter { $0 != target.id }.map { AgentRegistry.agent($0)?.name ?? $0 }.joined(separator: ", ")))
                            .font(T.micro).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true)
                    } else if !target.sharedReaders.isEmpty {
                        Text(L10n.t("This is a shared skills directory. Other compatible Agents may also read its contents."))
                            .font(T.micro).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(T.s2).background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
            }.disabled(model.isBusy)
        }
    }
}

private struct SkillImportSheet: View {
    @ObservedObject var model: SkillsModel
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var ref = ""
    @State private var subdirectory = ""
    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(L10n.t("Import skills")).font(.title2)
            Text(L10n.t("Choose a local folder or find skills in an HTTPS Git repository."))
                .font(T.small).foregroundStyle(T.muted)
            HStack {
                TextField(L10n.t("GitHub owner/repo or HTTPS Git URL"), text: $repository).textFieldStyle(.roundedBorder)
                Button(L10n.t("Find skills")) { model.findRepository(location: repository, ref: ref, subdirectory: subdirectory) }
                    .buttonStyle(PillButtonStyle(kind: .secondary)).disabled(repository.isEmpty || model.isBusy)
                Button(L10n.t("Local folder…")) { model.chooseFolder() }.buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.isBusy)
            }
            HStack {
                TextField(L10n.t("Branch or tag (optional)"), text: $ref).textFieldStyle(.roundedBorder)
                TextField(L10n.t("Repository subdirectory (optional)"), text: $subdirectory).textFieldStyle(.roundedBorder)
            }.disabled(model.isBusy)
            if model.isBusy { HStack { ProgressView().controlSize(.small); Text(L10n.t("Working…")).font(T.small) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: T.s2) {
                    if !model.isBusy && model.candidates.isEmpty { Text(L10n.t("No skill candidates yet.")).font(T.small).foregroundStyle(T.muted) }
                    ForEach(model.candidates) { candidate in
                        Toggle(isOn: Binding(get: { model.chosenCandidates.contains(candidate.id) }, set: {
                            if $0 { model.chosenCandidates.insert(candidate.id) } else { model.chosenCandidates.remove(candidate.id) }
                        })) {
                            VStack(alignment: .leading, spacing: T.s1) {
                                Text(candidate.name).font(T.body.weight(.medium))
                                Text(candidate.summary).font(T.small).foregroundStyle(T.muted).lineLimit(2)
                                Text(candidate.source.subdirectory.isEmpty ? candidate.directory.lastPathComponent : candidate.source.subdirectory)
                                    .font(T.monoMicro).foregroundStyle(T.muted)
                                if let warning = candidate.warning { Text(L10n.t(warning)).font(T.small).foregroundStyle(T.amber) }
                            }
                        }.toggleStyle(.checkbox).padding(T.s2).disabled(!candidate.isValid)
                    }
                }
            }.frame(height: 240).disabled(model.isBusy)
            if let error = model.errorMessage { Text(error).font(T.small).foregroundStyle(T.red) }
            Text(L10n.t("Import copies the complete skill folder into Muster. Original files and Agent deployments stay unchanged."))
                .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t(model.isBusy ? "Cancel operation" : "Cancel")) { if model.isBusy { model.cancel() } else { dismiss() } }
                    .buttonStyle(PillButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button(L10n.t("Import selected")) { model.importChosen() }.buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(model.chosenCandidates.isEmpty || model.isBusy)
            }
        }.padding(T.s4).frame(width: 640).interactiveDismissDisabled(model.isBusy)
    }
}

private struct SkillCreateSheet: View {
    @ObservedObject var model: SkillsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(L10n.t("New skill")).font(.title2)
            TextField(L10n.t("Skill name (e.g. code-review)"), text: $name).textFieldStyle(.roundedBorder)
            TextField(L10n.t("Describe when to use this skill"), text: $summary, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
            if let error = model.errorMessage { Text(error).font(T.small).foregroundStyle(T.red) }
            HStack {
                Spacer()
                Button(L10n.t("Cancel")) { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button(L10n.t("Create")) {
                    model.create(name: name, description: summary)
                    Task { @MainActor in await model.operationTask?.value; if model.errorMessage == nil { dismiss() } }
                }.buttonStyle(PillButtonStyle(kind: .primary)).disabled(name.isEmpty || summary.isEmpty || model.isBusy)
            }
        }.padding(T.s4).frame(width: 440).interactiveDismissDisabled(model.isBusy)
    }
}

private struct SkillPlanSheet: View {
    @ObservedObject var model: SkillsModel
    let plan: SkillPlan
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(L10n.t("Review skill deployment")).font(.title2)
            if plan.items.isEmpty { Text(L10n.t("Nothing to write")).foregroundStyle(T.muted) }
            ScrollView {
                VStack(alignment: .leading, spacing: T.s3) {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: T.s1) {
                            Text(item.targetName + " · " + L10n.t(item.after == nil ? "Disable skill" : (item.after?.mode == .copy ? "Deploy copy" : "Deploy symbolic link"))).font(T.body.weight(.medium))
                            Text(item.path).font(T.monoMicro).textSelection(.enabled)
                            if let after = item.after { Text(L10n.t("Version %@", String(after.revision.prefix(8)))).font(T.small).foregroundStyle(T.muted) }
                            if !item.sharedReaders.isEmpty { Text(L10n.t("Shared readers: %@", item.sharedReaders.joined(separator: ", "))).font(T.small).foregroundStyle(T.amber) }
                            if let conflict = item.conflict { Text(L10n.t(conflict)).font(T.small).foregroundStyle(T.red) }
                        }.padding(T.s3).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
                    }
                }
            }.frame(maxHeight: 360)
            if let error = model.errorMessage { Text(error).font(T.small).foregroundStyle(T.red) }
            Text(L10n.t("Only Muster-managed entries are replaced or removed. The last deployment can be restored from the toolbar."))
                .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t("Cancel")) { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Button(L10n.t("Apply changes")) { model.apply() }.buttonStyle(PillButtonStyle(kind: .primary)).disabled(!plan.canApply || model.isBusy)
            }
        }.padding(T.s4).frame(width: 560).interactiveDismissDisabled(model.isBusy)
    }
}

private struct SkillUpdateSheet: View {
    @ObservedObject var model: SkillsModel
    let candidate: SkillCandidate
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(L10n.t("Review skill update")).font(.title2)
            Text(L10n.t("The complete folder will be replaced in the library. Agent deployments are updated separately."))
                .font(T.small).foregroundStyle(T.muted)
            HStack(alignment: .top) {
                preview("Current version", text: model.publishedText)
                preview("New version", text: model.updateText)
            }
            DisclosureGroup(L10n.t("Included files (%d)", candidate.files.count)) {
                ScrollView { Text(candidate.files.joined(separator: "\n")).font(T.monoMicro).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
            }
            if let error = model.errorMessage { Text(error).font(T.small).foregroundStyle(T.red) }
            HStack {
                Button(L10n.t("Reveal in Finder")) { model.reveal(candidate.directory.path) }.buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Button(L10n.t("Cancel")) { dismiss() }.buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.isBusy)
                Button(L10n.t("Update library")) { model.applyUpdate() }.buttonStyle(PillButtonStyle(kind: .primary)).disabled(model.isBusy)
            }
        }.padding(T.s4).frame(width: 720).interactiveDismissDisabled(model.isBusy)
    }
    private func preview(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Text(L10n.t(label)).font(T.section)
            ScrollView { Text(text).font(T.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(T.s2) }
                .frame(height: 290).background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
        }.frame(maxWidth: .infinity)
    }
}
