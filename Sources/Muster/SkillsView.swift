import MusterCore
import SwiftUI

struct SkillsView: View {
    @ObservedObject var model: SkillsModel
    let agentID: String
    @State private var showsCreate = false
    @State private var showsNewFile = false
    @State private var newFilePath = ""
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            HSplitView {
                skillList.frame(minWidth: 200, idealWidth: 250, maxWidth: 330, maxHeight: .infinity)
                detail.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.isBusy { busyBar }
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
        .sheet(isPresented: Binding(get: { model.showsPlan && model.plan != nil }, set: { if !$0 { model.dismissPlan() } })) {
            if let plan = model.plan { SkillPlanSheet(model: model, plan: plan) }
        }
        .sheet(item: $model.updateCandidate, onDismiss: { model.dismissUpdate() }) { candidate in SkillUpdateSheet(model: model, candidate: candidate) }
        .alert(L10n.t("Keep this skill draft?"), isPresented: $model.confirmsSelection) {
            Button(L10n.t("Save draft and switch")) { model.resolveSelection(save: true) }
            Button(L10n.t("Discard and switch"), role: .destructive) { model.resolveSelection(save: false) }
            Button(L10n.t("Cancel"), role: .cancel) { }
        } message: { Text(L10n.t("The editor has pending changes. Unapplied Agent selections will be discarded when switching.")) }
        .alert(L10n.t("Remove this skill?"), isPresented: $model.confirmsRemove) {
            Button(L10n.t("Remove"), role: .destructive) { model.removeSelected() }
            Button(L10n.t("Cancel"), role: .cancel) { }
        } message: { Text(L10n.t("Its library versions and drafts are deleted. Agent folders are not touched because only undeployed skills can be removed.")) }
        .alert(L10n.t("Rename this skill?"), isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField(L10n.t("New skill name"), text: $renameText)
            Button(L10n.t("Rename")) { model.renameSelected(to: renameText) }
            Button(L10n.t("Cancel"), role: .cancel) { }
        } message: { Text(L10n.t("Only the frontmatter name changes; the rest of SKILL.md and every other file stay as they are.")) }
        .alert(L10n.t("New file"), isPresented: $showsNewFile) {
            TextField(L10n.t("e.g. references/guide.md"), text: $newFilePath)
            Button(L10n.t("Add")) { model.addFile(path: newFilePath); newFilePath = "" }
            Button(L10n.t("Cancel"), role: .cancel) { newFilePath = "" }
        }
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
                .disabled(model.unsaved || model.deploymentDirty || model.isBusy)
            IconButton(symbol: "folder", label: L10n.t("Open skill library")) { model.openLibrary() }
            IconButton(symbol: "arrow.uturn.backward", label: L10n.t("Restore last deployment")) { model.previewUndo() }.disabled(!model.snapshot.canUndo || model.isBusy)
            IconButton(symbol: "arrow.clockwise", label: L10n.t("Refresh skills"), isBusy: model.isBusy) { model.load(force: true) }
        }.padding(T.s3).disabled(model.isBusy)
    }

    private var busyBar: some View {
        HStack(spacing: T.s2) {
            ProgressView().controlSize(.small)
            Text(L10n.t("%@…", model.busyLabel)).font(T.small).foregroundStyle(T.muted)
            Spacer()
            Button(L10n.t("Cancel")) { model.cancel() }.buttonStyle(PillButtonStyle(kind: .secondary))
        }.padding(.horizontal, T.s3).padding(.vertical, T.s2)
            .background(T.card2)
    }

    private var skillList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: T.s2) {
                    HStack(spacing: T.s2) {
                        Text(L10n.t("In library") + " · \(model.snapshot.skills.count)").font(T.section).foregroundStyle(T.muted)
                        Spacer()
                        if model.snapshot.skills.count > 1 {
                            Button(model.markedIDs.count > 1 ? L10n.t("Clear selection") : L10n.t("Select all")) {
                                model.markedIDs.count > 1 ? model.clearMarks() : model.markAll()
                            }.buttonStyle(PillButtonStyle(kind: .quiet))
                        }
                    }.padding(.horizontal, T.s2)
                    if model.visibleSkills.isEmpty {
                        Text(L10n.t(model.search.isEmpty ? "Import a skill folder or create your first skill." : "No matching skills."))
                            .font(T.small).foregroundStyle(T.muted).padding(T.s2)
                    }
                    ForEach(model.visibleSkills) { skill in
                        skillRow(skill)
                    }
                    Hairline().padding(.vertical, T.s2)
                    Text(L10n.t("Agent skills outside Muster")).font(T.section).foregroundStyle(T.muted).padding(.horizontal, T.s2)
                    if model.discovered.isEmpty && !model.isBusy && !model.deploymentTargets.isEmpty {
                        Text(L10n.t("Every skill in the Agent folders is managed by Muster, or those folders are empty."))
                            .font(T.small).foregroundStyle(T.muted).padding(T.s2).fixedSize(horizontal: false, vertical: true)
                    }
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
            if model.batchDirty || model.deploymentDirty {
                Hairline()
                Button { model.preview() } label: {
                    Text(L10n.t(model.pendingItems > 1 ? "Review %d skill changes" : "Review 1 skill change", model.pendingItems))
                        .frame(maxWidth: .infinity)
                }.buttonStyle(PillButtonStyle(kind: .primary)).padding(T.s2).disabled(model.isBusy)
            }
        }
    }

    private func skillRow(_ skill: SkillRecord) -> some View {
        let marked = model.markedIDs.contains(skill.id)
        let deployments = model.snapshot.deployments.filter { $0.skillID == skill.id }
        let outsideScope = deployments.filter { model.availableAgentIDs?.contains($0.targetID) == false }
        return Button { model.select(skill.id) } label: {
            HStack(alignment: .top, spacing: T.s2) {
                Button {
                    model.mark(skill.id)
                } label: {
                    Image(systemName: marked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12)).foregroundStyle(marked ? T.accent : T.faint)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(InteractivePlainButtonStyle(pressedScale: 0.88))
                .help(L10n.t(marked ? "Remove from the batch" : "Add to the batch"))
                .opacity(model.markedIDs.count > 1 || marked || model.isBatch ? 1 : 0.35)
                VStack(alignment: .leading, spacing: T.s1) {
                    HStack(spacing: T.s2) {
                        Text(skill.name).font(T.body.weight(.medium)).lineLimit(1)
                        if deployments.contains(where: { $0.revision != skill.revision }) {
                            Text(L10n.t("Needs update")).font(T.micro).foregroundStyle(T.amber)
                        }
                    }
                    Text(skill.summary).font(T.small).foregroundStyle(T.muted).lineLimit(2)
                    if !outsideScope.isEmpty {
                        Text(outsideScope.map {
                            let name = AgentRegistry.agent($0.targetID)?.name ?? $0.targetID
                            return L10n.t("%@ (outside current scope)", name)
                        }.joined(separator: " · ")).font(T.micro).foregroundStyle(T.muted).lineLimit(1)
                    }
                }.padding(.bottom, model.deploymentTargets.isEmpty ? 0 : 28)
            }.padding(T.s2).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: T.r).fill(model.selectedID == skill.id ? T.accentSoft : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(InteractivePlainButtonStyle(pressedScale: 1)).disabled(model.isBusy)
            .overlay(alignment: .bottomTrailing) {
                if !model.deploymentTargets.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(model.deploymentTargets) { target in
                            agentToggle(skill, target: target,
                                deployment: deployments.first { $0.targetID == target.id })
                        }
                    }.padding(.trailing, T.s2).padding(.bottom, T.s2)
                }
            }
            .accessibilityAddTraits(model.selectedID == skill.id ? .isSelected : [])
    }

    /// A compact per-Agent switch; the deployment still goes through the library plan.
    private func agentToggle(_ skill: SkillRecord, target: SkillTarget, deployment: SkillDeployment?) -> some View {
        let deployed = deployment != nil
        let label = L10n.t(deployed ? "Disable in %@" : "Enable in %@", target.name)
        let directory = (target.directory as NSString).abbreviatingWithTildeInPath
        return Button { model.toggleDeployment(skill, target: target) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.card2)
                AgentLogo(agentID: target.id,
                          mark: target.id == "pi" ? "π" : String(target.name.prefix(1)), size: 17)
                    .saturation(deployed ? 1 : 0)
                    .opacity(deployed ? 1 : 0.45)
            }
            .frame(width: 26, height: 26)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(T.line, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(InteractivePlainButtonStyle(pressedScale: 0.88))
        .help("\(label) · \(directory)")
        .accessibilityLabel(label)
        .contextMenu {
            Button(label) { model.toggleDeployment(skill, target: target) }
            if let deployment {
                Divider()
                Button(L10n.t("Use symbolic link")) { model.setDeploymentMode(skill, target: target, .symlink) }
                    .disabled(deployment.mode == .symlink)
                Button(L10n.t("Use a copy")) { model.setDeploymentMode(skill, target: target, .copy) }
                    .disabled(deployment.mode == .copy)
            }
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
                                Button(L10n.t("Rename skill…")) { renameText = skill.name; model.renaming = skill.id }
                                    .disabled(model.dirty || model.unsaved || model.isBusy)
                                Button(L10n.t("Remove from library")) { model.confirmsRemove = true }
                                    .disabled(!model.canRemove)
                                Divider()
                                Button(L10n.t("Check skill update")) { model.checkUpdate() }.disabled(model.dirty || model.isBusy || model.updateBlockedReason != nil)
                                if skill.revisions.count > 1 {
                                    Divider()
                                    ForEach(skill.revisions.reversed().filter { $0.id != skill.revision }) { revision in
                                        Button(L10n.t("Restore version %@", String(revision.id.prefix(8)))) { model.restore(revision.id) }.disabled(model.dirty)
                                    }
                                }
                            } label: { CompactMenuLabel(title: L10n.t("Versions"), symbol: "clock.arrow.circlepath") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isBusy)
                        }
                        if !model.canRemove {
                            Label(L10n.t("Disable every deployment before removing this skill."), systemImage: "info.circle")
                                .font(T.micro).foregroundStyle(T.muted)
                        }
                        if let reason = model.updateBlockedReason, skill.source.kind != .created {
                            Label(L10n.t(reason), systemImage: "exclamationmark.triangle")
                                .font(T.micro).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true)
                        }
                        source(skill)
                        if model.deploymentTargets.isEmpty {
                            Label(scopeExplanation, systemImage: "info.circle")
                                .font(T.micro).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        if model.isBatch { batchDeployment(skill) }
                        editorSection
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

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            HStack {
                Text("SKILL.md").font(T.section)
                Spacer()
                Text(L10n.t("Editing the draft leaves deployed versions unchanged.")).font(T.micro).foregroundStyle(T.muted)
            }
            TextEditor(text: $model.draft).font(T.mono).foregroundStyle(T.fg).scrollContentBackground(.hidden)
                .padding(T.s2).frame(minHeight: 220).background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
                .overlay(RoundedRectangle(cornerRadius: T.r).strokeBorder(T.line, lineWidth: 0.5)).disabled(model.isBusy)
            fileEditor
        }
    }

    private var fileEditor: some View {
        DisclosureGroup(L10n.t("Included files (%d)", model.files.count)) {
            VStack(alignment: .leading, spacing: T.s2) {
                ForEach(model.files.filter { $0 != "SKILL.md" }, id: \.self) { path in
                    fileRow(path)
                }
                ForEach(Array(model.removedFiles).sorted(), id: \.self) { path in
                    HStack(spacing: T.s2) {
                        Text(path).font(T.monoMicro).foregroundStyle(T.muted).strikethrough()
                        Spacer()
                        Button(L10n.t("Restore")) { model.restoreFile(path) }.buttonStyle(PillButtonStyle(kind: .quiet))
                    }
                }
                HStack(spacing: T.s2) {
                    Button(L10n.t("Add text file…")) { showsNewFile = true }.buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.isBusy)
                    if let directory = model.selectedDirectory {
                        Button(L10n.t("Reveal in Finder")) { model.reveal(directory) }.buttonStyle(PillButtonStyle(kind: .quiet))
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, T.s2)
        }.font(T.small).foregroundStyle(T.muted)
    }

    @ViewBuilder private func fileRow(_ path: String) -> some View {
        let editable = model.textFiles.contains(path)
        VStack(alignment: .leading, spacing: T.s1) {
            HStack(spacing: T.s2) {
                Text(path).font(T.monoMicro).foregroundStyle(T.muted).textSelection(.enabled)
                if model.currentFiles[path] != nil && model.publishedTexts[path] != model.currentFiles[path] {
                    Text(L10n.t("Edited")).font(T.micro).foregroundStyle(T.amber)
                }
                Spacer()
                if editable {
                    Button(L10n.t("Remove")) { model.removeFile(path) }.buttonStyle(PillButtonStyle(kind: .quiet)).disabled(model.isBusy)
                }
            }
            if editable {
                TextEditor(text: Binding(get: { model.currentFiles[path] ?? "" },
                                         set: { model.setFileText(path, $0) }))
                    .font(T.monoMicro).foregroundStyle(T.fg).scrollContentBackground(.hidden)
                    .padding(T.s1).frame(minHeight: 96).background(RoundedRectangle(cornerRadius: T.r).fill(T.card2))
                    .overlay(RoundedRectangle(cornerRadius: T.r).strokeBorder(T.line, lineWidth: 0.5)).disabled(model.isBusy)
            } else {
                Text(L10n.t("Binary or oversized file. Reveal it in Finder to edit it outside Muster."))
                    .font(T.micro).foregroundStyle(T.muted)
            }
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

    private func batchDeployment(_ skill: SkillRecord) -> some View {
        let targets = model.deploymentTargets.filter { agentID == "all" || $0.id == agentID }
        return VStack(alignment: .leading, spacing: T.s2) {
            HStack {
                Text(L10n.t("Deploy %d selected skills", model.markedIDs.count)).font(T.section)
                Spacer()
                Button(L10n.t("Preview deployment")) { model.preview() }.buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.isBusy)
            }
            Text(L10n.t("These switches apply to every selected skill at once.")).font(T.micro).foregroundStyle(T.muted)
            ForEach(targets) { target in
                targetRow(target, skill: skill)
            }
        }
    }

    /// Says which Agent is missing and where to enable it, instead of a bare "unsupported".
    private var scopeExplanation: String {
        let out = model.scopedOutTargets
        guard !out.isEmpty else {
            return L10n.t(agentID == "all"
                ? "No Agents in the current scope support skill deployment. You can still manage the library."
                : "Skill deployment is not supported for this Agent yet.")
        }
        let enabled = Set(model.deploymentTargets.map(\.id))
        // Prefer the Agent the user is looking at; otherwise name every supported one.
        let missing = agentID != "all" ? out.filter { $0.id == agentID } : out
        let names = (missing.isEmpty ? out : missing).map(\.name).joined(separator: L10n.t(", "))
        if agentID != "all", enabled.contains(agentID) { return "" }
        return L10n.t("Claude Code, Codex and Pi are supported, but none of them are both installed and enabled right now. Enable %@ in Settings → Agent management, or install the Agent.", names)
    }

    private func targetRow(_ target: SkillTarget, skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: T.s1) {
            HStack {
                Toggle(target.name, isOn: Binding(get: { model.isEnabled(target) }, set: { model.setEnabled(target, $0) }))
                    .toggleStyle(.checkbox).font(T.body)
                Spacer(minLength: T.s2)
                InlineSelect(items: SkillInstallMode.allCases, label: { L10n.t($0 == .symlink ? "Symbolic link" : "Copy") },
                    selection: Binding(get: { model.mode(target) }, set: { model.setMode(target, $0) }))
                    .disabled(!model.isEnabled(target))
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
            if model.isBusy { HStack { ProgressView().controlSize(.small); Text(L10n.t("%@…", model.busyLabel)).font(T.small) } }
            if !model.candidates.isEmpty {
                HStack {
                    Text(L10n.t("%d selected", model.chosenCandidates.count)).font(T.small).foregroundStyle(T.muted)
                    Spacer()
                    Button(L10n.t("Select all")) { model.selectAllCandidates(true) }.buttonStyle(PillButtonStyle(kind: .quiet))
                    Button(L10n.t("Select none")) { model.selectAllCandidates(false) }.buttonStyle(PillButtonStyle(kind: .quiet))
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: T.s2) {
                    if !model.isBusy && model.candidates.isEmpty { Text(L10n.t("No skill candidates yet.")).font(T.small).foregroundStyle(T.muted) }
                    ForEach(model.candidates) { candidate in
                        Toggle(isOn: Binding(get: { model.chosenCandidates.contains(candidate.id) }, set: { _ in model.toggleCandidate(candidate.id) })) {
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
            if !plan.adoptablePaths.isEmpty { adoptionBanner }
            ScrollView {
                VStack(alignment: .leading, spacing: T.s3) {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: T.s1) {
                            Text(item.skillName + " → " + item.targetName + " · " + L10n.t(item.after == nil ? "Disable skill" : (item.after?.mode == .copy ? "Deploy copy" : "Deploy symbolic link"))).font(T.body.weight(.medium))
                            Text(item.path).font(T.monoMicro).textSelection(.enabled)
                            if let after = item.after { Text(L10n.t("Version %@", String(after.revision.prefix(8)))).font(T.small).foregroundStyle(T.muted) }
                            if let backup = item.backup, item.adopts { Text(L10n.t("Existing folder moved to %@", backup)).font(T.monoMicro).foregroundStyle(T.amber).textSelection(.enabled) }
                            if !item.sharedReaders.isEmpty { Text(L10n.t("Shared readers: %@", item.sharedReaders.joined(separator: ", "))).font(T.small).foregroundStyle(T.amber) }
                            if let conflict = item.conflict { Text(L10n.t(conflict)).font(T.small).foregroundStyle(T.red).fixedSize(horizontal: false, vertical: true) }
                            if item.adoptable {
                                Button(L10n.t("Back up and replace this folder")) { model.toggleAdoption(item.path) }
                                    .buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.isBusy)
                            }
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
        }.padding(T.s4).frame(width: 620).interactiveDismissDisabled(model.isBusy)
    }

    private var adoptionBanner: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Text(L10n.t("%d folders already exist in Agent directories.", plan.adoptablePaths.count)).font(T.body.weight(.medium))
            Text(L10n.t("Muster never overwrites them on its own. Allow the ones you want replaced: each is first moved into the library backup folder, so nothing is deleted."))
                .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            Button(L10n.t("Back up and replace all")) { model.adoptAll() }.buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.isBusy)
        }.padding(T.s3).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: T.r).fill(T.accentSoft))
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
