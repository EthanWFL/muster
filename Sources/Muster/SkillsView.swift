import MusterCore
import SwiftUI

struct SkillsView: View {
    @ObservedObject var model: SkillsModel
    let agentID: String
    let managedAgents: [AgentDescriptor]
    @State private var showsCreate = false
    @State private var showsNewFile = false
    @State private var newFilePath = ""
    @State private var renameText = ""
    @State private var showsDetail = false
    @State private var editing = false
    @State private var selectedFile = "SKILL.md"
    @State private var pendingDetailID: UUID?
    @State private var confirmsClose = false
    @State private var closeAfterSave = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            if model.deploymentTargets.isEmpty {
                Label(scopeExplanation, systemImage: "info.circle")
                    .font(T.small).foregroundStyle(T.muted).padding(T.s3)
            }
            SkillsBrowser(model: model, agentID: agentID, managedAgents: managedAgents, open: openDetail, row: skillRow)
            if model.isBatch, let skill = model.selected {
                Hairline()
                batchDeployment(skill).padding(T.s3).background(T.card2).disabled(model.isBusy)
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
        .onChange(of: model.isBusy) { _, busy in
            if !busy { presentPendingDetail() }
        }
        .sheet(item: $model.deploymentConflict, onDismiss: { model.finishConflictPresentation() }) { inspection in
            SkillDeploymentConflictSheet(model: model, inspection: inspection)
        }
        .sheet(isPresented: $showsDetail) { detailSheet }
        .sheet(isPresented: $model.showsImport, onDismiss: { model.cancel(); model.clearImport() }) { SkillImportSheet(model: model) }
        .sheet(isPresented: $showsCreate, onDismiss: presentPendingDetail) {
            SkillCreateSheet(model: model) { pendingDetailID = model.selectedID; editing = true }
        }
        .sheet(isPresented: Binding(get: { model.showsPlan && model.plan != nil }, set: { if !$0 { model.dismissPlan() } })) {
            if let plan = model.plan { SkillPlanSheet(model: model, plan: plan) }
        }
        .alert(L10n.t("Keep this skill draft?"), isPresented: $model.confirmsSelection) {
            Button(L10n.t("Save draft and switch")) { model.resolveSelection(save: true) }
            Button(L10n.t("Discard and switch"), role: .destructive) { model.resolveSelection(save: false) }
            Button(L10n.t("Cancel"), role: .cancel) { pendingDetailID = nil }
        } message: { Text(L10n.t("The editor has pending changes. Unapplied Agent selections will be discarded when switching.")) }
    }

    private var detailSheet: some View {
        detail
        .frame(minWidth: 640, idealWidth: 800, minHeight: 480, idealHeight: 640)
        .background(T.bg)
        .interactiveDismissDisabled(model.unsaved || model.isBusy)
        .sheet(item: $model.updateCandidate, onDismiss: { model.dismissUpdate() }) { candidate in SkillUpdateSheet(model: model, candidate: candidate) }
        .onChange(of: model.isBusy) { _, busy in
            if !busy, closeAfterSave {
                closeAfterSave = false
                if !model.unsaved && model.errorMessage == nil { showsDetail = false }
            }
        }
        .alert(L10n.t("Save this draft before closing?"), isPresented: $confirmsClose) {
            Button(L10n.t("Save draft")) { closeAfterSave = true; model.saveDraft() }
            Button(L10n.t("Discard"), role: .destructive) { closeAfterSave = true; model.discardDraft() }
            Button(L10n.t("Cancel"), role: .cancel) {}
        }
        .alert(L10n.t("Remove this skill?"), isPresented: $model.confirmsRemove) {
            Button(L10n.t("Remove"), role: .destructive) {
                model.removeSelected()
                Task { @MainActor in await model.operationTask?.value; if model.errorMessage == nil { showsDetail = false } }
            }
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
                .disabled(model.isSelecting)
            Button(L10n.t("New skill")) { showsCreate = true }.buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(model.unsaved || model.deploymentDirty || model.isBusy || model.isSelecting)
            Menu {
                Button(L10n.t("Open skill library")) { model.openLibrary() }
                Button(L10n.t("Restore last deployment")) { model.previewUndo() }.disabled(!model.snapshot.canUndo)
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.t("More actions"))
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

    private func openDetail(_ skill: SkillRecord) {
        guard !model.isSelecting, !model.isBusy else { return }
        editing = false
        selectedFile = "SKILL.md"
        pendingDetailID = skill.id
        model.select(skill.id)
        presentPendingDetail()
    }

    private func presentPendingDetail() {
        guard !showsCreate, !model.isBusy, !model.confirmsSelection,
              let id = pendingDetailID, model.selectedID == id else { return }
        pendingDetailID = nil
        showsDetail = true
    }

    private func closeDetail() {
        if model.unsaved { confirmsClose = true } else { showsDetail = false }
    }

    private func skillRow(_ skill: SkillRecord) -> some View {
        let marked = model.markedIDs.contains(skill.id)
        let deployments = model.snapshot.deployments.filter { $0.skillID == skill.id }
        let outsideScope = deployments.filter { model.availableAgentIDs?.contains($0.targetID) == false }
        return HStack(spacing: T.s3) {
            if model.isSelecting {
                Button { model.mark(skill.id) } label: {
                    Image(systemName: marked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15)).foregroundStyle(marked ? T.accent : T.muted)
                        .frame(width: 24, height: 30).contentShape(Rectangle())
                }.buttonStyle(InteractivePlainButtonStyle(pressedScale: 0.88))
                    .accessibilityLabel(L10n.t(marked ? "Remove from the batch" : "Add to the batch") + " · " + skill.name)
            }
            Button { model.isSelecting ? model.mark(skill.id) : openDetail(skill) } label: {
                HStack(spacing: T.s3) {
                    Image(systemName: "doc.text").foregroundStyle(T.muted)
                    VStack(alignment: .leading, spacing: T.s1) {
                        HStack(spacing: T.s2) {
                            Text(skill.name).font(T.body.weight(.medium)).lineLimit(1)
                            if deployments.contains(where: { $0.revision != skill.revision }) {
                                Text(L10n.t("Needs update")).font(T.micro).foregroundStyle(T.amber)
                            }
                        }
                        Text(skill.summary).font(T.small).foregroundStyle(T.muted).lineLimit(1)
                        if !outsideScope.isEmpty {
                            Text(outsideScope.map {
                                L10n.t("%@ (outside current scope)", AgentRegistry.agent($0.targetID)?.name ?? $0.targetID)
                            }.joined(separator: " · ")).font(T.micro).foregroundStyle(T.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(InteractivePlainButtonStyle(pressedScale: 1))
            HStack(spacing: T.s1) {
                ForEach(managedAgents) { agent in
                    agentToggle(skill, agent: agent, target: model.deploymentTargets.first { $0.id == agent.id },
                                deployment: deployments.first { $0.targetID == agent.id })
                }
            }.disabled(model.isSelecting)
            if !model.isSelecting {
                Button { openDetail(skill) } label: {
                    Image(systemName: "chevron.right").font(T.glyph).frame(width: 24, height: 30)
                }.buttonStyle(InteractivePlainButtonStyle()).accessibilityLabel(L10n.t("View skill"))
            }
        }.padding(T.s3).background(model.isSelecting && marked ? T.accentSoft : .clear)
            .disabled(model.isBusy)
    }

    /// Managed Agents stay visible even when deployment is not supported on this Mac.
    private func agentToggle(_ skill: SkillRecord, agent: AgentDescriptor, target: SkillTarget?, deployment: SkillDeployment?) -> some View {
        let inspection = deployment.flatMap { model.snapshot.deploymentInspections[$0.id] }
        let deployed = inspection?.status == .active
        let label = L10n.t(deployed ? "Disable in %@" : "Enable in %@", agent.name)
        let shared = model.discovered.contains { $0.name == skill.name && $0.isShared && $0.readers.contains(agent.id) }
        let sharedNote = shared || !(target?.sharedReaders.isEmpty ?? true)
            ? " · " + L10n.t("Shared visibility is independent of this deployment switch.") : ""
        let hint: String
        if let inspection, inspection.status != .active {
            hint = agent.name + " · " + L10n.t(inspection.status == .missing
                ? "Deployment is missing. Click to clear its record or redeploy."
                : "Deployment changed outside Muster. Click to resolve ownership.")
        } else if let target {
            hint = label + " · " + (target.directory as NSString).abbreviatingWithTildeInPath + sharedNote
        } else {
            hint = agent.name + " · " + L10n.t(agent.skills == nil
                ? "Skill deployment is not supported for this Agent yet."
                : "This Agent is selected in Settings but was not detected on this Mac.")
        }
        return Button {
            if let target { model.toggleDeployment(skill, target: target) }
        } label: {
            AgentLogo(agentID: agent.id, mark: agent.id == "pi" ? "π" : String(agent.name.prefix(1)), size: 19)
                .saturation(deployed ? 1 : 0)
                .opacity(deployed ? 1 : 0.35)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(T.card2))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(InteractivePlainButtonStyle(pressedScale: 0.88))
        .disabled(target == nil)
        .help(hint)
        .accessibilityLabel(agent.name)
        .accessibilityValue(L10n.t(deployed ? "Enabled" : "Disabled"))
        .contextMenu {
            if let target {
                Button(label) { model.toggleDeployment(skill, target: target) }
                if let deployment, deployed {
                    Divider()
                    Button(L10n.t("Use symbolic link")) { model.setDeploymentMode(skill, target: target, .symlink) }
                        .disabled(deployment.mode == .symlink)
                    Button(L10n.t("Use a copy")) { model.setDeploymentMode(skill, target: target, .copy) }
                        .disabled(deployment.mode == .copy)
                }
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
                                Text(skill.summary).font(T.body).foregroundStyle(T.muted).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Menu {
                                Button(L10n.t("Rename skill…")) { renameText = skill.name; model.renaming = skill.id }
                                    .disabled(model.dirty || model.unsaved || model.isBusy)
                                Button(L10n.t("Remove from library")) { model.confirmsRemove = true }
                                    .disabled(!model.canRemove)
                                    .help(L10n.t("Disable every deployment before removing this skill."))
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
                        if let reason = model.updateBlockedReason, skill.source.kind != .created {
                            Label(L10n.t(reason), systemImage: "exclamationmark.triangle")
                                .font(T.micro).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true)
                        }
                        DisclosureGroup(L10n.t("Source and version")) { source(skill).padding(.top, T.s2) }
                            .font(T.small).foregroundStyle(T.muted)
                        if model.deploymentTargets.isEmpty {
                            Label(scopeExplanation, systemImage: "info.circle")
                                .font(T.micro).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        if editing { editorSection } else { readerSection }
                    }.padding(T.s4)
                }
                if model.isBusy { busyBar }
                if let message = model.errorMessage ?? model.notice {
                    Text(message).font(T.small).foregroundStyle(model.errorMessage == nil ? T.muted : T.red)
                        .padding(.horizontal, T.s3).fixedSize(horizontal: false, vertical: true)
                }
                Hairline()
                ViewThatFits(in: .horizontal) {
                    HStack { draftStatus; Spacer(); detailActions }
                    VStack(alignment: .leading, spacing: T.s2) { draftStatus; HStack { Spacer(); detailActions } }
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

    private var readerSection: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Picker(L10n.t("File"), selection: $selectedFile) {
                Text("SKILL.md").tag("SKILL.md")
                ForEach(model.files.filter { $0 != "SKILL.md" && !model.removedFiles.contains($0) }, id: \.self) { path in
                    Text(path).tag(path)
                }
            }.labelsHidden().frame(maxWidth: 360, alignment: .leading)
            if selectedFile == "SKILL.md" {
                SkillReadView(text: model.draft, markdown: true, stripMetadata: true)
            } else if let text = model.currentFiles[selectedFile] {
                SkillReadView(text: text, markdown: selectedFile.lowercased().hasSuffix(".md"))
            } else {
                Text(L10n.t("Binary or oversized file. Reveal it in Finder to edit it outside Muster."))
                    .font(T.small).foregroundStyle(T.muted)
                if let directory = model.selectedDirectory {
                    Button(L10n.t("Reveal in Finder")) { model.reveal(directory) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailActions: some View {
        HStack(spacing: T.s2) {
            if editing {
                editorActions
                Button(L10n.t("Read")) { editing = false }.buttonStyle(PillButtonStyle(kind: .secondary))
            } else {
                Button(L10n.t("Edit")) { editing = true }.buttonStyle(PillButtonStyle(kind: .secondary))
            }
            Button(L10n.t("Close"), action: closeDetail)
                .buttonStyle(PillButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
        }.disabled(model.isBusy)
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
        Text(L10n.t(model.unsaved ? "Unsaved changes" : (model.dirty ? "Draft saved, not published" : "Matches the published version")))
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
        let supported = model.targets.map(\.name).joined(separator: L10n.t(", "))
        return L10n.t("Supported Agents: %@. Enable %@ in Settings → Agent management, or install the Agent.", supported, names)
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
    var onCreated: () -> Void = {}
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
                    Task { @MainActor in await model.operationTask?.value; if model.errorMessage == nil { onCreated(); dismiss() } }
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
