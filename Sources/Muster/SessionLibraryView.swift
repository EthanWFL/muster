import MusterCore
import SwiftUI

struct SessionLibraryView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var library: SessionLibraryModel
    @State private var showsCategories = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar
                HStack(spacing: T.s2) {
                    categoryMenu
                    Text(L10n.t("%d sessions", library.entries(query: model.sessionSearch).count))
                        .font(T.small).foregroundStyle(T.muted)
                    Spacer()
                    if library.isImporting {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("Importing history…")).font(T.small)
                        Button(L10n.t("Cancel")) { library.cancelImport() }
                    } else {
                        Text(L10n.t("Saved locally in Muster")).font(T.small).foregroundStyle(T.muted)
                    }
                }
                .padding(.horizontal, T.s3).padding(.bottom, T.s2)
                Hairline()
                HStack(spacing: 0) {
                    if geometry.size.width >= 860 {
                        categorySidebar
                        Hairline(vertical: true)
                    }
                    HSplitView {
                        sessionList.frame(minWidth: 260, idealWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                        SessionLibraryDetail(model: model, library: library)
                            .frame(minWidth: 320, idealWidth: 370, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if let error = library.errorMessage {
                    message(error, error: true)
                } else if let notice = library.notice {
                    message(notice, error: false)
                }
            }
        }
        .onAppear { library.open(); if model.searchFocusRequest > 0 { searchFocused = true } }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .sheet(isPresented: $showsCategories) { SessionCategoriesView(library: library) }
        .alert(L10n.t("Save session changes?"), isPresented: $library.confirmsDiscard) {
            Button(L10n.t("Save and switch")) { library.save(andSwitch: true) }
            Button(L10n.t("Discard and switch"), role: .destructive) { library.discardAndSwitch() }
            Button(L10n.t("Cancel"), role: .cancel) { }
        } message: { Text(L10n.t("This session has unsaved changes.")) }
    }

    private var toolbar: some View {
        HStack(spacing: T.s2) {
            Picker(L10n.t("Session scope"), selection: $library.scope) {
                Text(L10n.t("Recent")).tag(SessionLibraryScope.recent)
                Text(L10n.t("History")).tag(SessionLibraryScope.history)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(T.muted)
                TextField(L10n.t("Search titles, projects, notes…"), text: $model.sessionSearch)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if let first = library.entries(query: model.sessionSearch).first { library.select(first.id) } }
                if !model.sessionSearch.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", label: L10n.t("Clear search"), tint: T.muted) { model.sessionSearch = "" }
                }
            }
            .padding(T.s2).background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
            Menu {
                Button(L10n.t("Import last 30 days")) { library.importHistory(days: 30) }
                Button(L10n.t("Import all history")) { library.importHistory(days: nil) }
                Divider()
                Button(L10n.t("Rescan open sessions")) { model.refreshSessions() }
            } label: { Image(systemName: "arrow.clockwise") }
            .menuStyle(.borderlessButton).fixedSize().disabled(library.isImporting)
            .help(L10n.t("Import session history"))
            .accessibilityLabel(L10n.t("Import session history"))
            IconButton(symbol: "arrow.uturn.backward", label: L10n.t("Undo organization change"), tint: T.ctlFg) { library.undo() }
                .disabled(!library.canUndo)
                .help(library.snapshot.lastChange.map { L10n.t("Undo") + ": " + L10n.t($0.kind.rawValue) } ?? L10n.t("No changes to undo"))
        }
        .padding(T.s3)
    }

    private var categoryMenu: some View {
        Menu {
            Picker(L10n.t("Category"), selection: $library.filter) {
                Text(L10n.t("All sessions")).tag(SessionLibraryFilter.all)
                Text(L10n.t("Needs attention")).tag(SessionLibraryFilter.attention)
                Text(L10n.t("Uncategorized")).tag(SessionLibraryFilter.uncategorized)
                ForEach(library.snapshot.categories) { category in
                    Text(category.name).tag(SessionLibraryFilter.category(category.id))
                }
            }
            Divider()
            Button(L10n.t("Manage categories…")) { showsCategories = true }
        } label: { Label(filterTitle, systemImage: "line.3.horizontal.decrease.circle") }
        .fixedSize()
    }

    private var filterTitle: String {
        switch library.filter {
        case .all: return L10n.t("All sessions")
        case .attention: return L10n.t("Needs attention")
        case .uncategorized: return L10n.t("Uncategorized")
        case .category(let id): return library.snapshot.categories.first { $0.id == id }?.name ?? L10n.t("Category")
        }
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: T.s1) {
            categoryButton(L10n.t("All sessions"), symbol: "tray", filter: .all)
            categoryButton(L10n.t("Needs attention"), symbol: "flag", filter: .attention)
            categoryButton(L10n.t("Uncategorized"), symbol: "tray.full", filter: .uncategorized)
            Hairline().padding(.vertical, T.s2)
            HStack {
                Text(L10n.t("Categories")).font(T.section).foregroundStyle(T.muted)
                Spacer()
                IconButton(symbol: "plus", label: L10n.t("Manage categories…"), tint: T.muted) { showsCategories = true }
            }.padding(.horizontal, T.s2)
            ScrollView {
                VStack(spacing: T.s1) {
                    ForEach(library.snapshot.categories) { category in
                        categoryButton(category.name, symbol: "folder", filter: .category(category.id))
                    }
                }
            }
            Button(L10n.t("Manage categories…")) { showsCategories = true }
                .buttonStyle(.plain).font(T.small).foregroundStyle(T.muted).padding(T.s2)
        }
        .padding(T.s2).frame(width: 176)
    }

    private func categoryButton(_ title: String, symbol: String, filter: SessionLibraryFilter) -> some View {
        Button { library.filter = filter } label: {
            HStack(spacing: T.s2) {
                Image(systemName: symbol).frame(width: 14)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(library.entries(filter: filter).count)").foregroundStyle(T.muted).monospacedDigit()
            }
            .font(T.small).padding(T.s2)
            .background(RoundedRectangle(cornerRadius: T.r).fill(library.filter == filter ? T.accentSoft : .clear))
        }
        .buttonStyle(.plain).help(title)
        .accessibilityAddTraits(library.filter == filter ? .isSelected : [])
    }

    private var sessionList: some View {
        let entries = library.entries(query: model.sessionSearch)
        return Group {
            if entries.isEmpty {
                VStack(spacing: T.s3) {
                    Spacer()
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(T.muted)
                    Text(L10n.t("No matching sessions")).font(T.section)
                    Text(L10n.t("Try History or import older sessions.")).font(T.small).foregroundStyle(T.muted)
                    Button(L10n.t("Show all history")) {
                        library.scope = .history; library.filter = .all; model.sessionSearch = ""
                    }
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                List(selection: Binding<String?>(get: { library.selectedID }, set: { if let id = $0 { library.select(id) } })) {
                    ForEach(entries) { entry in
                        SessionLibraryRow(entry: entry)
                            .tag(entry.id)
                            .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                            .contextMenu {
                                Button(L10n.t("Edit title")) { library.editTitle(entry.id) }
                                Button(L10n.t(entry.annotation.needsAttention ? "Clear attention flag" : "Mark for attention")) {
                                    library.setAttention(entry, !entry.annotation.needsAttention)
                                }.disabled(entry.stored == nil || library.isSaving || (library.selectedID == entry.id && library.dirty))
                                Menu(L10n.t("Move to category")) {
                                    Button(L10n.t("Uncategorized")) { library.assign(entry, to: nil) }
                                    ForEach(library.snapshot.categories) { category in
                                        Button(category.name) { library.assign(entry, to: category.id) }
                                    }
                                }.disabled(entry.stored == nil || library.isSaving || (library.selectedID == entry.id && library.dirty))
                                if entry.session.resumeCommand != nil {
                                    Divider()
                                    Button(L10n.t("Copy resume command")) { model.copyResume(entry.session) }
                                }
                            }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
    }

    private func message(_ value: String, error: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: error ? "exclamationmark.triangle" : "checkmark.circle")
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(T.small).foregroundStyle(error ? Color.orange : T.muted)
        .padding(T.s2).frame(maxWidth: .infinity, alignment: .leading)
        .background(T.card)
    }
}

private struct SessionLibraryRow: View {
    let entry: LibrarySession
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AgentLogo(agentID: entry.session.agent.rawValue, mark: String(entry.session.agent.displayName.prefix(1)), size: 16)
                Text(entry.displayTitle).font(T.section).lineLimit(1)
                Spacer(minLength: 0)
                if entry.annotation.needsAttention {
                    Image(systemName: "flag.fill").foregroundStyle(.orange).help(L10n.t("Needs attention"))
                }
            }
            Text(entry.session.cwd.isEmpty ? L10n.t("Unknown project") : (entry.session.cwd as NSString).abbreviatingWithTildeInPath)
                .font(T.monoMicro).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                Text(entry.session.agent.displayName)
                Text("·")
                Text(L10n.t(entry.session.isProcessAlive ? "Process present" : "History record"))
                Spacer(minLength: 0)
                Text(entry.session.lastActivityAt, style: .relative)
            }.font(T.micro).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 4).contentShape(Rectangle())
        .help(entry.displayTitle + "\n" + entry.session.cwd)
    }
}

private struct SessionLibraryDetail: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var library: SessionLibraryModel
    @FocusState private var titleFocused: Bool

    var body: some View {
        Group {
            if let entry = library.selected {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: T.s4) {
                            heading(entry)
                            if entry.stored != nil { editor(entry) }
                            else {
                                Text(L10n.t("This process has no linked session record yet. Organization becomes available when its transcript is found."))
                                    .font(T.body).foregroundStyle(T.muted)
                            }
                            facts(entry)
                        }.padding(T.s4)
                    }
                    if entry.stored != nil {
                        Hairline()
                        HStack {
                            Text(L10n.t(library.dirty ? "Unsaved changes" : "Saved locally")).font(T.small).foregroundStyle(T.muted)
                            Spacer()
                            Button(L10n.t("Discard")) { library.reloadDraft() }.disabled(!library.dirty || library.isSaving)
                            Button(L10n.t("Save")) { library.save() }
                                .buttonStyle(.borderedProminent).disabled(!library.dirty || library.isSaving)
                                .keyboardShortcut("s", modifiers: .command)
                        }.padding(T.s3)
                    }
                }
            } else {
                VStack(spacing: T.s3) {
                    Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(T.muted)
                    Text(L10n.t("Select a session")).font(T.section)
                    Text(L10n.t("Give it a title, add notes, and keep track of what needs attention."))
                        .font(T.body).foregroundStyle(T.muted).multilineTextAlignment(.center)
                }.padding(T.s4).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: library.titleFocusRequest) { _, _ in titleFocused = true }
        .onAppear { if library.titleFocusRequest > 0 { titleFocused = true } }
    }

    private func heading(_ entry: LibrarySession) -> some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Text(entry.displayTitle).font(.system(size: 19, weight: .semibold)).textSelection(.enabled)
            Text(entry.session.agent.displayName + " · " + L10n.t(entry.session.isProcessAlive ? "Process present" : "No linked running process"))
                .font(T.small).foregroundStyle(T.muted)
            HStack {
                if entry.session.isProcessAlive || entry.session.resumeCommand != nil {
                    Button { model.continueSession(entry.session) } label: {
                        Label(L10n.t(entry.session.isProcessAlive ? "Focus terminal" : "Continue in Terminal"), systemImage: "terminal")
                    }.disabled(model.resumingSessionKey != nil)
                }
                if entry.session.resumeCommand != nil {
                    IconButton(symbol: "doc.on.doc", label: L10n.t("Copy resume command"), tint: T.ctlFg) { model.copyResume(entry.session) }
                }
            }
        }
    }

    private func editor(_ entry: LibrarySession) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            field(L10n.t("Title")) {
                TextField(entry.displayTitle, text: $library.draft.title).textFieldStyle(.roundedBorder).focused($titleFocused)
            }
            field(L10n.t("Category")) {
                Picker(L10n.t("Category"), selection: $library.draft.categoryID) {
                    Text(L10n.t("Uncategorized")).tag(UUID?.none)
                    ForEach(library.snapshot.categories) { category in Text(category.name).tag(Optional(category.id)) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(L10n.t("Needs attention"), isOn: $library.draft.needsAttention)
            field(L10n.t("Notes")) {
                TextEditor(text: $library.draft.notes).font(T.body).frame(minHeight: 100, maxHeight: 180)
                    .padding(4).background(T.card)
                    .overlay(RoundedRectangle(cornerRadius: T.r).strokeBorder(T.line))
                    .accessibilityLabel(L10n.t("Session notes"))
            }
            field(L10n.t("Artifact folder")) {
                if let path = library.draft.artifactDirectory {
                    Text((path as NSString).abbreviatingWithTildeInPath).font(T.monoMicro)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.t("Open folder")) { library.openDirectory(path) }
                        Button(L10n.t("Remove association")) { library.draft.artifactDirectory = nil }
                    }
                } else {
                    Text(L10n.t("Link a folder containing this session's output.")).font(T.small).foregroundStyle(T.muted)
                }
                Button(L10n.t("Choose folder")) { library.chooseArtifactDirectory() }
            }
        }.disabled(library.isSaving)
    }

    private func facts(_ entry: LibrarySession) -> some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Hairline()
            Text(L10n.t("Session information")).font(T.section)
            Text(entry.session.cwd.isEmpty ? L10n.t("Unknown project") : entry.session.cwd)
                .font(T.monoMicro).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !entry.session.cwd.isEmpty {
                Button(L10n.t("Open project folder")) { library.openDirectory(entry.session.cwd) }
            }
            Text(entry.session.id).font(T.monoMicro).textSelection(.enabled)
            HStack {
                Text(L10n.t("Last activity"))
                Text(entry.session.lastActivityAt, format: .dateTime.year().month().day().hour().minute())
            }.font(T.small).foregroundStyle(T.muted)
            Text(L10n.t("Titles and notes are stored in Muster. Agent session files are unchanged."))
                .font(T.small).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Text(title).font(T.section)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionCategoriesView: View {
    @ObservedObject var library: SessionLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var deleting: SessionCategory?
    var body: some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(L10n.t("Manage categories")).font(.title2)
            HStack {
                TextField(L10n.t("New category name"), text: $newName).textFieldStyle(.roundedBorder)
                Button(L10n.t("Create")) { library.createCategory(newName) }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.isSaving)
            }
            ScrollView {
                VStack(spacing: T.s2) {
                    ForEach(library.snapshot.categories) { category in
                        SessionCategoryEditor(library: library, category: category, onDelete: { deleting = category })
                    }
                }
            }.frame(minHeight: 160, maxHeight: 340)
            if library.dirty { Text(L10n.t("Save or discard session changes before deleting a category.")).font(T.small).foregroundStyle(T.muted) }
            if let error = library.errorMessage { Text(error).font(T.small).foregroundStyle(.orange) }
            HStack { Spacer(); Button(L10n.t("Done")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(T.s4).frame(width: 460)
        .alert(L10n.t("Delete category?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { category in
            Button(L10n.t("Delete"), role: .destructive) { library.deleteCategory(category) }
            Button(L10n.t("Cancel"), role: .cancel) { }
        } message: { _ in Text(L10n.t("Its sessions will become uncategorized. Session records and files will be kept. You can undo this change.")) }
        .onChange(of: library.snapshot.categories.count) { old, new in if new > old { newName = "" } }
    }
}

private struct SessionCategoryEditor: View {
    @ObservedObject var library: SessionLibraryModel
    let category: SessionCategory
    let onDelete: () -> Void
    @State private var name: String
    init(library: SessionLibraryModel, category: SessionCategory, onDelete: @escaping () -> Void) {
        self.library = library; self.category = category; self.onDelete = onDelete
        _name = State(initialValue: category.name)
    }
    var body: some View {
        HStack {
            Image(systemName: "folder").foregroundStyle(T.muted)
            TextField(L10n.t("Category name"), text: $name).textFieldStyle(.roundedBorder)
            Button(L10n.t("Rename")) { library.renameCategory(category, name) }.disabled(name == category.name || library.isSaving)
            IconButton(symbol: "trash", label: L10n.t("Delete category"), tint: T.muted, action: onDelete)
                .disabled(library.isSaving || library.dirty)
        }
        .onChange(of: category.name) { _, value in name = value }
    }
}
