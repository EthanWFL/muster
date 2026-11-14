import MusterCore
import SwiftUI

struct SessionsView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var library: SessionLibraryModel
    var onOpenLibrary: (() -> Void)?
    private enum Focus: Hashable { case search, list }
    @FocusState private var focus: Focus?

    private var groups: [SessionGroup] {
        SessionBrowser(query: model.sessionSearch, activity: model.sessionFilter,
                       grouping: model.sessionGrouping).groups(in: model.sessions, titles: titles)
    }
    private var titles: [String: String] {
        Dictionary(uniqueKeysWithValues: library.snapshot.sessions.map { ($0.id, $0.annotation.title) })
    }
    private var visibleSessions: [Session] { groups.flatMap(\.sessions) }
    private var visibleKeys: [String] { visibleSessions.map(\.key) }
    private var hasFilters: Bool { !model.sessionSearch.isEmpty || model.sessionFilter != .all }

    var body: some View {
        VStack(spacing: 0) {
            if let onOpenLibrary {
                HStack {
                    Button(L10n.t("Open session library")) { onOpenLibrary() }
                        .buttonStyle(.plain)
                    Spacer()
                    Button {
                        library.scope = .history; library.filter = .attention
                        model.sessionSearch = ""
                        onOpenLibrary()
                    } label: {
                        Label(L10n.t("%d need attention", library.pendingCount), systemImage: "flag")
                    }.buttonStyle(.plain).foregroundStyle(library.pendingCount > 0 ? Color.orange : T.muted)
                }.font(T.small).padding(.horizontal, T.s3).padding(.top, T.s3)
            }
            searchAndFilters
            Hairline()
            if groups.isEmpty {
                VStack {
                    EmptyState(title: hasFilters ? L10n.t("No matching sessions") : L10n.t("No recent sessions"),
                               message: hasFilters ? L10n.t("Try another project, agent or branch.")
                                   : L10n.t("Open sessions of installed agents show up here"))
                    if hasFilters {
                        Button(L10n.t("Reset filters")) { model.resetSessionFilters(); focus = .search }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                    Spacer(minLength: 0)
                }
            } else {
                List(selection: $model.selectedSessionKey) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.sessions, id: \.key) { session in
                                SessionRow(model: model, session: session, showsAgent: model.sessionGrouping == .project,
                                           customTitle: titles[session.key])
                                    .tag(session.key)
                                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                                    .onTapGesture(count: 2) { model.jumpToTerminal(session) }
                                    .contextMenu {
                                        if let onOpenLibrary {
                                            Button(L10n.t("Edit session details")) {
                                                library.select(session.key)
                                                onOpenLibrary()
                                            }
                                        }
                                        Button(L10n.t("Focus terminal")) { model.jumpToTerminal(session) }
                                        if session.resumeCommand != nil {
                                            Button(L10n.t("Copy resume command")) { model.copyResume(session) }
                                        }
                                    }
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .list)
                .onKeyPress(.return) {
                    guard let session = visibleSessions.first(where: { $0.key == model.selectedSessionKey }) else { return .ignored }
                    model.jumpToTerminal(session)
                    return .handled
                }
                .accessibilityLabel(L10n.t("Sessions"))
            }
        }
        .onAppear { if model.searchFocusRequest > 0 { focus = .search } }
        .onChange(of: model.searchFocusRequest) { _, _ in focus = .search }
        .onChange(of: visibleKeys) { _, keys in
            if let selected = model.selectedSessionKey, !keys.contains(selected) { model.selectedSessionKey = nil }
        }
    }

    private var searchAndFilters: some View {
        VStack(spacing: T.s2) {
            HStack(spacing: T.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(T.muted)
                TextField(L10n.t("Search projects, agents or branches"), text: $model.sessionSearch)
                    .textFieldStyle(.plain)
                    .font(T.body)
                    .focused($focus, equals: .search)
                    .onSubmit(selectFirstResult)
                    .onKeyPress(.downArrow) { selectFirstResult(); return .handled }
                    .onKeyPress(.escape) {
                        if !model.sessionSearch.isEmpty { model.sessionSearch = "" } else { focus = .list }
                        return .handled
                    }
                if !model.sessionSearch.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", label: L10n.t("Clear search"), tint: T.ctlFg) {
                        model.sessionSearch = ""
                        focus = .search
                    }
                }
            }
            .padding(.horizontal, T.s2)
            .frame(height: T.rowSingle)
            .background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
            .overlay(RoundedRectangle(cornerRadius: T.r).strokeBorder(focus == .search ? T.accent : T.line, lineWidth: 1))

            HStack(spacing: T.s2) {
                InlineSelect(items: SessionGrouping.allCases, label: groupingTitle,
                             header: L10n.t("Group sessions"), selection: $model.sessionGrouping)
                InlineSelect(items: SessionActivityFilter.allCases, label: filterTitle,
                             header: L10n.t("Filter activity"), selection: $model.sessionFilter)
                Spacer(minLength: 0)
                Text("\(visibleSessions.count)/\(model.sessions.count)")
                    .font(T.micro).monospacedDigit().foregroundStyle(T.muted)
                    .accessibilityLabel(L10n.t("%d of %d sessions", visibleSessions.count, model.sessions.count))
                IconButton(symbol: "arrow.clockwise", label: L10n.t("Rescan open sessions"),
                           tint: T.ctlFg, isBusy: model.isRefreshingSessions) {
                    model.refreshSessions()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(T.s3)
    }

    private func selectFirstResult() {
        guard let first = visibleSessions.first else { return }
        model.selectedSessionKey = first.key
        focus = .list
    }

    private func groupHeader(_ group: SessionGroup) -> some View {
        HStack(spacing: T.s2) {
            if let agent = group.agent {
                AgentLogo(agentID: agent.rawValue, mark: agent == .pi ? "π" : String(agent.displayName.prefix(1)), size: 14)
                Text(agent.displayName).font(T.section)
            } else {
                Image(systemName: "folder").font(T.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.projectPath.map { ($0 as NSString).lastPathComponent } ?? L10n.t("Unknown project"))
                        .font(T.section)
                    if let path = group.projectPath {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(T.monoMicro).lineLimit(1).truncationMode(.middle).help(path)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("\(group.sessions.count)").font(T.micro).monospacedDigit()
        }
        .foregroundStyle(T.muted)
        .textCase(nil)
        .padding(.vertical, T.s1)
    }

    private func groupingTitle(_ grouping: SessionGrouping) -> String {
        L10n.t(grouping == .agent ? "By agent" : "By project")
    }

    private func filterTitle(_ filter: SessionActivityFilter) -> String {
        switch filter {
        case .all: return L10n.t("All activity")
        case .active: return L10n.t("Recent activity")
        case .quiet: return L10n.t("No new activity")
        case .unknown: return L10n.t("Activity unknown")
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var model: PanelModel
    let session: Session
    let showsAgent: Bool
    let customTitle: String?

    var body: some View {
        HStack(spacing: T.s2) {
            StatusDot(tone: tone)
                .accessibilityElement()
                .accessibilityLabel(activityLabel)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if showsAgent {
                        AgentLogo(agentID: session.agent.rawValue,
                                  mark: session.agent == .pi ? "π" : String(session.agent.displayName.prefix(1)), size: 14)
                    }
                    Text(customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? (showsAgent ? session.agent.displayName : session.projectName))
                        .font(T.body).lineLimit(1)
                }
                Text(showsAgent ? (session.branch ?? L10n.t("Branch unavailable"))
                     : (session.cwd as NSString).abbreviatingWithTildeInPath + (session.branch.map { " · " + $0 } ?? ""))
                    .font(T.monoMicro).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(session.cwd)
            }
            Spacer(minLength: T.s2)
            VStack(alignment: .trailing, spacing: 1) {
                Text(activityLabel).font(T.micro)
                Text(session.hasTranscript ? session.lastActivityAt : session.startedAt, style: .relative)
                    .font(T.micro).foregroundStyle(.secondary)
            }
            .fixedSize()
            .help(session.isProcessAlive
                  ? L10n.t("Process is present. Activity does not indicate task completion.")
                  : L10n.t("Transcript only. No unique process association was found."))
            IconButton(symbol: "terminal", label: L10n.t("Focus terminal"), tint: .secondary) {
                model.jumpToTerminal(session)
            }
            if session.resumeCommand != nil {
                IconButton(symbol: "arrow.uturn.backward.circle", label: L10n.t("Copy resume command"), tint: .secondary) {
                    model.copyResume(session)
                }
            }
        }
        .frame(minHeight: T.rowDouble)
        .contentShape(Rectangle())
    }

    private var tone: StatusTone {
        switch session.state {
        case .running: return .busy
        case .idle, .ended: return .idle
        case .unknown: return .neutral
        }
    }

    private var activityLabel: String {
        switch session.state {
        case .running: return L10n.t("Recent activity")
        case .idle: return L10n.t("No new activity")
        case .unknown: return L10n.t("Activity unknown")
        case .ended: return L10n.t("Ended")
        }
    }
}
