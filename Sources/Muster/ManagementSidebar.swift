import SwiftUI

/// Workspace and configuration share one scroll view so expanded groups cannot cover other rows.
struct ManagementSidebar: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var settings = SettingsStore.shared
    @ReducedMotion private var reduceMotion
    @Namespace private var selectionAnimation

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: T.s1) {
                    Text(L10n.t("Workspace"))
                        .font(T.section).foregroundStyle(T.muted)
                        .padding(.horizontal, T.s2).padding(.bottom, T.s2)
                    workspace
                    Hairline().padding(.vertical, T.s2)
                    configuration
                }
                .padding(T.s3).padding(.top, T.s1)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.managementPage, initial: true) { _, page in
                switch page {
                case .workspace: scroll.scrollTo(model.tab)
                case .chat: scroll.scrollTo(page)
                case .wheel: scroll.scrollTo(model.wheelSection, anchor: .bottom)
                case .settings: scroll.scrollTo(model.settingsSection, anchor: .bottom)
                }
            }
            .onChange(of: model.tab) { _, tab in
                if model.managementPage == .workspace { scroll.scrollTo(tab) }
            }
            .onChange(of: model.settingsScrollRequest) { scroll.scrollTo(model.settingsSection) }
            .onChange(of: model.wheelScrollRequest) { scroll.scrollTo(model.wheelSection) }
        }
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(T.bg)
        .animation(reduceMotion ? nil : InteractionMotion.selection, value: model.tab)
    }

    private var workspace: some View {
        ForEach(Array(model.orderedTabs.enumerated()), id: \.element) { index, tab in
            let shortcut = KeyEquivalent(Character(String(index + 1)))
            if tab == .agent {
                AgentSidebarGroup(model: model, workspace: model.agentWorkspace,
                                  shortcut: shortcut, selectionNamespace: selectionAnimation)
            } else {
                SidebarRow(title: tab == .sessions ? L10n.t("Session history") : tab.title, symbol: symbol(tab),
                           selected: model.managementPage == .workspace && model.tab == tab,
                           shortcutHint: "⌘\(index + 1)",
                           selectionNamespace: selectionAnimation, selectionID: "workspace") {
                    model.showsSettings = false
                    model.tab = tab
                }
                .keyboardShortcut(shortcut, modifiers: .command)
                .id(tab)
            }
            if tab == .sessions {
                SidebarRow(title: L10n.t("AI chat"), symbol: "bubble.left",
                           selected: model.managementPage == .chat,
                           selectionNamespace: selectionAnimation, selectionID: "workspace") {
                    model.managementPage = .chat
                }
                .id(PanelModel.ManagementPage.chat)
            }
        }
    }

    @ViewBuilder private var configuration: some View {
        let wheelOpen = model.managementPage == .wheel
        SidebarRow(title: L10n.t("Wheel setup"), symbol: ProjectWheelToggle.symbol,
                   selected: false, disclosureExpanded: wheelOpen) {
            model.managementPage = wheelOpen ? .workspace : .wheel
        }
        if wheelOpen {
            SidebarChildren {
                ForEach(WheelSettingsSection.allCases, id: \.self) { section in
                    anchor(section.title, section.symbol, selected: model.wheelSection == section) {
                        model.showWheelSection(section)
                    }
                    .id(section)
                }
            }
            .animation(reduceMotion ? nil : InteractionMotion.selection, value: model.wheelSection)
        }

        SidebarRow(title: L10n.t("Settings"), symbol: "gearshape",
                   selected: false, shortcutHint: "⌘,", disclosureExpanded: model.showsSettings) {
            model.toggleSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        if model.showsSettings {
            SidebarChildren {
                ForEach(SettingsSection.allCases) { section in
                    anchor(section.title, section.symbol, selected: model.settingsSection == section) {
                        model.showSettings(section)
                    }
                    .id(section)
                }
            }
            .animation(reduceMotion ? nil : InteractionMotion.selection, value: model.settingsSection)
        }
    }

    private func anchor(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        SidebarRow(title: title, symbol: symbol, selected: selected, compact: true,
                   selectionNamespace: selectionAnimation, selectionID: "settings-anchor", action: action)
    }

    private func symbol(_ tab: PanelModel.Tab) -> String {
        switch tab {
        case .projects: return "folder"
        case .sessions: return "clock"
        case .environment: return "sparkles"
        case .agent: return "terminal"
        }
    }
}

private struct SidebarChildren<Rows: View>: View {
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(spacing: T.s1) { rows }
            .padding(.leading, T.s2)
            .overlay(alignment: .leading) { Hairline(vertical: true) }
            .padding(.leading, T.s3)
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
            .id(PanelModel.Tab.agent)
            if expanded {
                SidebarChildren {
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
    var disclosureExpanded: Bool? = nil
    var selectionNamespace: Namespace.ID? = nil
    var selectionID = ""
    let action: () -> Void
    @State private var hovered = false
    @ReducedMotion private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: T.s2) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(selected ? T.fg : T.muted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .font((compact ? T.small : T.body).weight(selected ? .medium : .regular))
                    .lineLimit(1)
                    .layoutPriority(1)
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
            .padding(.horizontal, T.s2)
            .frame(height: compact ? T.rowCompact : T.rowSingle)
            .background {
                if selected {
                    if let selectionNamespace {
                        selectionBackground.matchedGeometryEffect(id: selectionID, in: selectionNamespace)
                    } else {
                        selectionBackground
                    }
                } else if hovered {
                    RoundedRectangle(cornerRadius: 9).fill(T.card2)
                }
            }
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
