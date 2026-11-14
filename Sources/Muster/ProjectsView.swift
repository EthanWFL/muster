import MusterCore
import SwiftUI

struct ProjectsView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var projects: ProjectsModel
    @ObservedObject var library: SessionLibraryModel
    var onOpenWindow: (() -> Void)?
    @Environment(\.panelPresentation) private var presentation
    @FocusState private var searchFocused: Bool
    @State private var renaming: WorkspaceProject?
    @State private var removing: WorkspaceProject?
    @State private var projectName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                projectList
                    .frame(width: presentation == .window ? 212 : nil)
                if presentation == .window {
                    Hairline(vertical: true)
                    if let project = projects.selected {
                        detail(project)
                    } else {
                        emptyState("Your projects, in one place", symbol: "folder",
                                   message: "Add a folder or import sessions to get started.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            if let error = projects.errorMessage ?? library.errorMessage {
                Hairline()
                HStack {
                    Text(error).font(T.small).foregroundStyle(T.red).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L10n.t("Reload")) { projects.load(force: true); library.load() }
                        .buttonStyle(PillButtonStyle(kind: .quiet)).disabled(projects.isWorking)
                }.padding(T.s2)
            }
        }
        .foregroundStyle(T.fg)
        .onAppear { projects.load(); library.open() }
        .onChange(of: projects.searchFocusRequest) { _, _ in searchFocused = true }
        .sheet(item: $renaming) { project in renameSheet(project) }
        .alert(L10n.t("Remove project from list?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { project in
            Button(L10n.t("Remove from list"), role: .destructive) { projects.remove(project) }
            Button(L10n.t("Cancel"), role: .cancel) { }
        } message: { _ in
            Text(L10n.t("Project files and sessions will be kept. Add the folder again to restore it to this list."))
        }
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t("Projects")).font(T.body.weight(.semibold))
                Text("\(projects.projects.count)").font(T.small).foregroundStyle(T.muted)
                Spacer()
                IconButton(symbol: "plus", label: L10n.t("Add project")) { projects.chooseFolder() }
                    .disabled(projects.isWorking)
                importMenu
            }.padding(.horizontal, T.s3).padding(.top, T.s3)
            HStack(spacing: T.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(T.muted)
                TextField(L10n.t("Search projects…"), text: $projects.search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit {
                        if let first = projects.visibleProjects.first { select(first) }
                    }
                if !projects.search.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", label: L10n.t("Clear search")) { projects.search = "" }
                }
            }
            .font(T.body).padding(.horizontal, T.s2).frame(height: T.controlHeight + 6)
            .background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
            .overlay(RoundedRectangle(cornerRadius: T.r).strokeBorder(searchFocused ? T.accent : T.line, lineWidth: 0.5))
            .padding(T.s3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: T.s1) {
                    if projects.visibleProjects.isEmpty {
                        emptyState(projects.search.isEmpty ? "No projects yet" : "No matching projects", symbol: "folder",
                                   message: projects.search.isEmpty ? "Add a folder or import sessions to get started." : "Try another project name or path.")
                        if projects.search.isEmpty {
                            Button(L10n.t("Add project")) { projects.chooseFolder() }
                                .buttonStyle(PillButtonStyle(kind: .secondary)).disabled(projects.isWorking)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        projectGroup("Pinned", pinned: true)
                        projectGroup("Recent projects", pinned: false)
                    }
                }.padding(.horizontal, T.s2).padding(.bottom, T.s3)
            }.frame(maxHeight: .infinity)
            if library.isImporting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("Importing history…")).font(T.small).foregroundStyle(T.muted)
                    Spacer(minLength: 0)
                    Button(L10n.t("Cancel")) { library.cancelImport() }.buttonStyle(PillButtonStyle(kind: .quiet))
                }.padding(T.s2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var importMenu: some View {
        Menu {
            Button(L10n.t("Rescan open sessions")) { model.refreshSessions(); projects.load(force: true) }.disabled(model.isRefreshingSessions)
            Button(L10n.t("Import last 30 days")) { library.importHistory(days: 30) }
            Button(L10n.t("Import all history")) { library.importHistory(days: nil) }
        } label: {
            ActivitySymbol(symbol: "arrow.clockwise", isActive: library.isImporting || model.isRefreshingSessions)
                .font(T.seg).foregroundStyle(T.ctlFg).frame(width: T.iconHitSize, height: T.iconHitSize)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(library.isImporting).help(L10n.t("Import session history"))
        .accessibilityLabel(L10n.t("Import session history"))
    }

    @ViewBuilder private func projectGroup(_ title: String, pinned: Bool) -> some View {
        let items = projects.visibleProjects.filter { $0.isPinned == pinned }
        if !items.isEmpty {
            Text(L10n.t(title)).font(T.section).foregroundStyle(T.muted)
                .padding(.horizontal, T.s2).padding(.top, T.s2).padding(.bottom, T.s1)
            ForEach(items) { project in
                Button { select(project) } label: {
                    HStack(alignment: .top, spacing: T.s2) {
                        Image(systemName: "folder").font(T.body).padding(.top, 2)
                        VStack(alignment: .leading, spacing: T.s1) {
                            Text(project.name).font(T.body.weight(.medium)).lineLimit(1)
                            Text(shortPath(project.path)).font(T.monoMicro).foregroundStyle(T.muted)
                                .lineLimit(1).truncationMode(.middle)
                            Text(L10n.t("%d sessions", project.sessions.count)
                                 + (project.pending.isEmpty ? "" : " · " + L10n.t("%d pending", project.pending.count)))
                                .font(T.micro).foregroundStyle(T.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(T.s2).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: T.r)
                        .fill(projects.selected?.id == project.id ? T.accentSoft : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(InteractivePlainButtonStyle(pressedScale: 1))
                .help(project.path)
                .accessibilityAddTraits(projects.selected?.id == project.id ? .isSelected : [])
                .contextMenu {
                    Button(L10n.t(project.isPinned ? "Unpin project" : "Pin project")) { projects.pin(project) }
                    Button(L10n.t("Rename project…")) { projectName = project.name; renaming = project }
                    Button(L10n.t("Open project folder")) { library.openDirectory(project.path) }
                    Divider()
                    Button(L10n.t("Remove from list")) { removing = project }
                }.disabled(projects.isWorking)
            }
        }
    }

    private func select(_ project: WorkspaceProject) {
        projects.selectedPath = project.path
        if presentation == .popover { onOpenWindow?() }
    }

    private func detail(_ project: WorkspaceProject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                projectHeader(project)
                Hairline()
                pendingSection(project)
                sessionsSection(project)
                artifactsSection(project)
            }.padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func projectHeader(_ project: WorkspaceProject) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: T.s2) {
                    Text(project.name).font(.system(size: 24, weight: .semibold)).textSelection(.enabled)
                    Text(shortPath(project.path)).font(T.mono).foregroundStyle(T.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: T.s2)
                IconButton(symbol: project.isPinned ? "pin.fill" : "pin",
                           label: L10n.t(project.isPinned ? "Unpin project" : "Pin project"),
                           tint: project.isPinned ? T.accent : T.ctlFg) { projects.pin(project) }
                    .disabled(projects.isWorking)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: T.s3) { projectFacts(project); Spacer(); openFolder(project) }
                VStack(alignment: .leading, spacing: T.s2) { projectFacts(project); openFolder(project) }
            }
            if let date = project.lastActivity {
                HStack(spacing: T.s1) {
                    Text(L10n.t("Last activity"))
                    Text(date, style: .relative)
                }.font(T.small).foregroundStyle(T.muted)
            }
        }
    }

    private func projectFacts(_ project: WorkspaceProject) -> some View {
        HStack(spacing: T.s2) {
            Text(L10n.t("%d sessions", project.sessions.count))
            Text("·")
            Text(L10n.t("%d pending", project.pending.count))
            if let branch = project.branch { Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1) }
        }.font(T.small).foregroundStyle(T.muted)
    }

    private func openFolder(_ project: WorkspaceProject) -> some View {
        Button { library.openDirectory(project.path) } label: {
            Label(L10n.t("Open folder"), systemImage: "folder")
        }.buttonStyle(PillButtonStyle(kind: .secondary)).fixedSize()
    }

    private func pendingSection(_ project: WorkspaceProject) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            HStack(spacing: T.s2) {
                Image(systemName: "flag").foregroundStyle(T.amber)
                Text(L10n.t("Needs attention")).foregroundStyle(T.fg)
                Text("\(project.pending.count)").foregroundStyle(T.muted)
            }.font(T.body.weight(.semibold))
            if project.pending.isEmpty {
                Text(L10n.t("No pending sessions. Flag a session to keep it here."))
                    .font(T.body).foregroundStyle(T.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(project.pending) { entry in
                        HStack(spacing: T.s3) {
                            VStack(alignment: .leading, spacing: T.s1) {
                                Text(entry.displayTitle).font(T.body.weight(.medium)).lineLimit(1)
                                Text(entry.annotation.notes.isEmpty ? entry.session.agent.displayName : entry.annotation.notes)
                                    .font(T.small).foregroundStyle(T.muted).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Button(L10n.t("View notes")) { model.openLibrarySession(entry) }
                                .buttonStyle(PillButtonStyle(kind: .secondary)).disabled(library.isSaving)
                        }.padding(T.s3)
                        if entry.id != project.pending.last?.id { Hairline().padding(.horizontal, T.s3) }
                    }
                }.background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
            }
        }
    }

    private func sessionsSection(_ project: WorkspaceProject) -> some View {
        let entries = project.entries(recent: projects.recentOnly)
        return VStack(alignment: .leading, spacing: T.s3) {
            HStack {
                Text(L10n.t("Related sessions")).font(T.body.weight(.semibold))
                Spacer()
                SegmentedControl(items: [true, false], selection: $projects.recentOnly,
                                 label: { L10n.t($0 ? "Recent" : "All") }).frame(width: 132)
            }
            if entries.isEmpty {
                Text(L10n.t(project.sessions.isEmpty ? "No sessions in this project yet. Start an Agent in this folder, then refresh."
                            : "No recent sessions. Choose All to view this project's history."))
                    .font(T.body).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        HStack(spacing: T.s3) {
                            Button { model.openLibrarySession(entry) } label: {
                                VStack(alignment: .leading, spacing: T.s1) {
                                    Text(entry.displayTitle).font(T.body.weight(.medium)).lineLimit(1)
                                    HStack(spacing: T.s1) {
                                        if entry.session.isProcessAlive { StatusDot(tone: .busy, size: 5) }
                                        Text(entry.session.agent.displayName)
                                        Text("·")
                                        Text(entry.session.lastActivityAt, style: .relative)
                                    }.font(T.small).foregroundStyle(T.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(InteractivePlainButtonStyle(pressedScale: 1)).disabled(library.isSaving)
                            if entry.session.isProcessAlive || entry.session.resumeCommand != nil {
                                Button { model.continueSession(entry.session) } label: {
                                    Label(L10n.t(entry.session.isProcessAlive ? "Focus terminal" : "Continue"), systemImage: "terminal")
                                }
                                .buttonStyle(PillButtonStyle(kind: .secondary)).disabled(model.resumingSessionKey != nil)
                            }
                        }.padding(T.s3)
                        if entry.id != entries.last?.id { Hairline().padding(.horizontal, T.s3) }
                    }
                }.background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
            }
        }
    }

    private func artifactsSection(_ project: WorkspaceProject) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(L10n.t("Artifact folders")).font(T.body.weight(.semibold))
            if project.artifacts.isEmpty {
                Text(L10n.t("Folders linked to this project's sessions appear here."))
                    .font(T.body).foregroundStyle(T.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(project.artifacts, id: \.self) { path in
                        HStack(spacing: T.s3) {
                            Image(systemName: "folder").foregroundStyle(T.muted)
                            VStack(alignment: .leading, spacing: T.s1) {
                                Text((path as NSString).lastPathComponent).font(T.body)
                                Text(shortPath(path)).font(T.monoMicro).foregroundStyle(T.muted)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            IconButton(symbol: "arrow.up.right.square", label: L10n.t("Open folder")) { library.openDirectory(path) }
                        }.padding(T.s3)
                        if path != project.artifacts.last { Hairline().padding(.horizontal, T.s3) }
                    }
                }.background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
            }
        }
    }

    private func emptyState(_ title: String, symbol: String, message: String) -> some View {
        VStack(spacing: T.s3) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(T.muted)
            Text(L10n.t(title)).font(T.body.weight(.semibold))
            Text(L10n.t(message)).font(T.small).foregroundStyle(T.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.padding(T.s4).frame(maxWidth: .infinity)
    }

    private func renameSheet(_ project: WorkspaceProject) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(L10n.t("Rename project…")).font(.headline)
            TextField(L10n.t("Project name"), text: $projectName).textFieldStyle(.roundedBorder)
            Text(shortPath(project.path)).font(T.monoMicro).foregroundStyle(T.muted).lineLimit(2)
            if let error = projects.errorMessage { Text(error).font(T.small).foregroundStyle(T.red) }
            HStack {
                Spacer()
                Button(L10n.t("Cancel")) { renaming = nil }.buttonStyle(PillButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button(L10n.t("Save")) {
                    projects.rename(project, projectName)
                    Task { @MainActor in
                        await projects.operationTask?.value
                        if projects.errorMessage == nil { renaming = nil }
                    }
                }.buttonStyle(PillButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projects.isWorking)
            }
        }.padding(T.s4).frame(width: 360)
    }

    private func shortPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
