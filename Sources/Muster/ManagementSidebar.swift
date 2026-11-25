import SwiftUI

/// Main navigation stays above; settings anchors and their entry stay at the bottom.
struct ManagementSidebar: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var settings = SettingsStore.shared
    @ReducedMotion private var reduceMotion
    @Namespace private var selectionAnimation

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: T.s1) {
                    Text(L10n.t("Workspace"))
                        .font(T.section).foregroundStyle(T.muted)
                        .padding(.horizontal, T.s3).padding(.bottom, T.s2)
                    ForEach(Array(model.orderedTabs.enumerated()), id: \.element) { index, tab in
                        if tab == .agent {
                            AgentSidebarGroup(model: model, workspace: model.agentWorkspace,
                                              shortcut: KeyEquivalent(Character(String(index + 1))),
                                              selectionNamespace: selectionAnimation)
                        } else {
                            SidebarRow(title: tab.title, symbol: symbol(tab),
                                       selected: model.managementPage == .workspace && model.tab == tab,
                                       shortcutHint: "⌘\(index + 1)",
                                       selectionNamespace: selectionAnimation, selectionID: "workspace") {
                                model.showsSettings = false
                                model.tab = tab
                            }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        }
                        if tab == .sessions {
                            SidebarRow(title: L10n.t("Chat"), symbol: "bubble.left",
                                       selected: model.managementPage == .chat,
                                       selectionNamespace: selectionAnimation, selectionID: "workspace") {
                                model.managementPage = .chat
                            }
                        }
                    }
                }
                .padding(.horizontal, T.s3).padding(.top, T.s4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity, alignment: .top)

            if model.managementPage == .wheel {
                anchorMenu(count: WheelSettingsSection.allCases.count) {
                    ForEach(WheelSettingsSection.allCases, id: \.self) { section in
                        anchor(section.title, section.symbol, selected: model.wheelSection == section) {
                            model.showWheelSection(section)
                        }
                    }
                }
            }

            SidebarRow(title: L10n.t("Wheel configuration"), symbol: ProjectWheelToggle.symbol,
                       selected: model.managementPage == .wheel, pinned: true) {
                model.managementPage = model.managementPage == .wheel ? .workspace : .wheel
            }
            .padding(.horizontal, T.s3)

            if model.showsSettings {
                anchorMenu(count: SettingsSection.allCases.count) {
                    ForEach(SettingsSection.allCases) { section in
                        anchor(section.title, section.symbol, selected: model.settingsSection == section) {
                            model.showSettings(section)
                        }
                    }
                }
            }
            SidebarRow(title: L10n.t("Settings"), symbol: "gearshape",
                       selected: model.showsSettings, shortcutHint: "⌘,", pinned: true) {
                model.toggleSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal, T.s3).padding(.bottom, T.s3)
        }
        .frame(width: 170)
        .frame(maxHeight: .infinity)
        .background(T.bg)
        .animation(reduceMotion ? nil : InteractionMotion.selection, value: model.managementPage)
        .animation(reduceMotion ? nil : InteractionMotion.selection, value: model.wheelSection)
        .animation(reduceMotion ? nil : InteractionMotion.selection, value: model.tab)
        .animation(reduceMotion ? nil : InteractionMotion.selection, value: model.settingsSection)
    }

    private func anchorMenu<Rows: View>(count: Int, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: 0) {
            Hairline().padding(.bottom, T.s3)
            ScrollView {
                VStack(spacing: 2, content: rows)
                    .padding(.leading, T.s2)
                    .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 1) }
                    .padding(.leading, 24).padding(.trailing, T.s3)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: CGFloat(count) * (T.rowSingle + 2) + 8)
            .padding(.bottom, T.s3)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func anchor(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        SidebarRow(title: title, symbol: symbol, selected: selected, compact: true,
                   selectionNamespace: selectionAnimation, selectionID: "settings-anchor", action: action)
    }

    private func symbol(_ tab: PanelModel.Tab) -> String {
        switch tab {
        case .projects: return "folder"
        case .sessions: return "bubble.left.and.bubble.right"
        case .environment: return "sparkles"
        case .agent: return "terminal"
        }
    }
}

private struct AgentSidebarGroup: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var workspace: AgentWorkspaceModel
    let shortcut: KeyEquivalent
    let selectionNamespace: Namespace.ID
    @State private var expanded = false
    @ReducedMotion private var reduceMotion
    private var active: Bool { model.managementPage == .workspace && model.tab == .agent }

    var body: some View {
        VStack(spacing: T.s1) {
            SidebarRow(title: L10n.t("Agent"), symbol: "terminal",
                       selected: active && !expanded, disclosureExpanded: expanded,
                       selectionNamespace: selectionNamespace, selectionID: "workspace") {
                if active { expanded.toggle() }
                else {
                    expanded = true
                    model.showsSettings = false
                    model.tab = .agent
                }
            }
            .keyboardShortcut(shortcut, modifiers: .command)
            if expanded {
                VStack(spacing: 2) {
                    ForEach(AgentSection.allCases) { section in
                        SidebarRow(title: section.title, symbol: section.symbol,
                                   selected: active && workspace.section == section, compact: true,
                                   selectionNamespace: selectionNamespace, selectionID: "workspace") {
                            model.showsSettings = false
                            model.tab = .agent
                            workspace.selectSection(section)
                        }
                    }
                }
                .padding(.leading, T.s2)
                .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 1) }
                .padding(.leading, T.s3)
                .transition(.opacity)
            }
        }
        .onAppear { if active { expanded = true } }
        .onChange(of: model.tab) { _, tab in if tab == .agent { expanded = true } }
        .onChange(of: model.showsSettings) { _, settings in if !settings && model.tab == .agent { expanded = true } }
        .onChange(of: workspace.section) { _, _ in if active { expanded = true } }
        .animation(reduceMotion ? nil : InteractionMotion.selection, value: expanded)
        .animation(reduceMotion ? nil : InteractionMotion.selection, value: workspace.section)
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    var shortcutHint: String? = nil
    var compact = false
    var pinned = false
    var disclosureExpanded: Bool? = nil
    var selectionNamespace: Namespace.ID? = nil
    var selectionID = ""
    let action: () -> Void
    @State private var hovered = false
    @ReducedMotion private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 8 : 10) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 14 : 16, weight: .regular))
                    .foregroundStyle(selected ? T.fg : T.muted)
                    .frame(width: compact ? 16 : 20)
                    .accessibilityHidden(true)
                Text(title).font((compact ? T.small : T.body).weight(selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if let disclosureExpanded {
                    Image(systemName: disclosureExpanded ? "chevron.down" : "chevron.right")
                        .font(T.glyph).foregroundStyle(T.muted).accessibilityHidden(true)
                } else if let shortcutHint {
                    Text(shortcutHint).font(T.micro).foregroundStyle(T.muted)
                        .opacity(hovered ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? T.fg : T.fg2)
            .padding(.horizontal, compact ? T.s2 : T.s3)
            .frame(height: compact ? T.rowSingle : T.rowSingle + 6)
            .background {
                RoundedRectangle(cornerRadius: 9).fill((hovered || pinned) ? T.card2 : .clear)
                if selected {
                    if let selectionNamespace {
                        selectionBackground.matchedGeometryEffect(id: selectionID, in: selectionNamespace)
                    } else {
                        selectionBackground
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(pinned ? T.line : .clear, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(InteractivePlainButtonStyle(pressedScale: 0.99))
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : InteractionMotion.hover, value: hovered)
        .help(title + (shortcutHint.map { " · " + $0 } ?? ""))
        .accessibilityLabel(title)
        .accessibilityValue(disclosureExpanded.map { L10n.t($0 ? "Expanded" : "Collapsed") } ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var selectionBackground: some View {
        RoundedRectangle(cornerRadius: 9).fill(T.fg.opacity(0.07))
    }
}
