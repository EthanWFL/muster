import MusterCore
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel
    var presentation: PanelPresentation = .popover
    var surfaceID = UUID()
    var onOpenWindow: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    @ObservedObject var surface = PanelSurfaceState()
    @ObservedObject private var settings = SettingsStore.shared
    @ReducedMotion private var reduceMotion
    @FocusState private var focused: Bool
    private var isShowingSettings: Bool { presentation == .window && model.showsSettings }

    var body: some View {
        VStack(spacing: 0) {
            if presentation == .popover {
                header
                Hairline()
                pageAndFooter
            } else {
                HStack(spacing: 0) {
                    ManagementSidebar(model: model)
                    Hairline(vertical: true)
                    pageAndFooter
                }
            }
        }
        .frame(width: presentation == .popover ? 420 : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.panelPresentation, presentation)
        .environment(\.panelSurfaceVisible, surface.isVisible)
        .background(T.bg.ignoresSafeArea())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = model.tab != .sessions || isShowingSettings }
        .onKeyPress(phases: .down, action: handleKey)
    }

    private var pageAndFooter: some View {
        VStack(spacing: 0) {
            if !isShowingSettings, model.agentSelection.state.hasDetected, model.agentSelection.state.managedIDs.isEmpty {
                HStack {
                    Text(L10n.t("No Agents selected for Muster.")).font(T.small).foregroundStyle(T.muted)
                    Spacer()
                    Button(L10n.t("Choose Agents")) {
                        model.showSettings(.agents)
                        if presentation == .popover { onOpenSettings?() }
                    }.buttonStyle(PillButtonStyle(kind: .secondary))
                }.padding(T.s3)
                Hairline()
            }
            Group {
                if isShowingSettings {
                    SettingsView(store: settings, model: model)
                } else {
                    tabs
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(settings.language.rawValue + "-" + String(settings.comfortableLayout))
            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: isShowingSettings)
            if let notice = model.notice {
                Text(notice)
                    .font(T.small).foregroundStyle(T.muted)
                    .padding(.horizontal, T.s4).padding(.bottom, T.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            footer
        }
    }

    /// 快速面板顶部：品牌、搜索和管理窗口入口。
    private var header: some View {
        HStack(spacing: T.s2) {
            BrandMark()
            Text("Muster")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(T.fg)
            Spacer(minLength: T.s2)
            PanelHeaderActions(model: model, presentation: presentation,
                               onOpenWindow: onOpenWindow, onOpenSettings: onOpenSettings)
        }
        .padding(.horizontal, T.s3)
        .frame(height: 40)
    }

    @ViewBuilder private var tabs: some View {
        VStack(spacing: 0) {
            if presentation == .popover {
                SegmentedTabs(selection: $model.tab, tabs: model.orderedTabs)
                    .padding(.horizontal, T.s3)
                    .padding(.top, T.s3)
                    .padding(.bottom, T.s2)
                Hairline()
            }
            if model.tab == .projects {
                ProjectsView(model: model, projects: model.projects, library: model.library,
                             onOpenWindow: onOpenWindow)
            } else if model.tab == .agent {
                AgentWorkspaceView(workspace: model.agentWorkspace, onOpenWindow: onOpenWindow)
            } else if model.tab == .sessions {
                if presentation == .window {
                    SessionLibraryView(model: model, library: model.library)
                } else {
                    SessionsView(model: model, library: model.library, onOpenLibrary: onOpenWindow)
                }
            } else {
                ScrollView(.vertical) {
                    Group {
                        switch model.tab {
                        case .sessions, .projects, .agent: EmptyView()
                        case .environment: EnvironmentView(model: model, env: model.env, visibilityOwner: surfaceID)
                        }
                    }
                    .padding(presentation == .window ? T.s4 : T.s2)
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.visible)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            if model.isRefreshingSessions {
                Text(L10n.t("Refreshing sessions…")).font(T.small).foregroundStyle(T.muted)
            } else if let date = model.lastSessionRefresh {
                Text(L10n.t("Updated") + " ")
                    .font(T.small).foregroundStyle(T.muted)
                Text(date, style: .relative).font(T.small).foregroundStyle(T.muted)
            }
            Spacer(minLength: T.s2)
            if let onClose, presentation == .window {
                Button(action: onClose) { ShortcutLabel(title: L10n.t("Close"), glyph: "⌘W") }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
                    .keyboardShortcut("w")
            }
            Button { NSApplication.shared.terminate(nil) } label: {
                ShortcutLabel(title: L10n.t("Quit"), glyph: "⌘Q")
            }
            .buttonStyle(PillButtonStyle(kind: .quiet))
            .keyboardShortcut("q")
        }
        .padding(.horizontal, T.s2)
        .frame(height: 40)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers == .command, let number = Int(press.characters),
           model.orderedTabs.indices.contains(number - 1) {
            if presentation == .window { model.showsSettings = false }
            model.tab = model.orderedTabs[number - 1]
            return .handled
        }
        if isShowingSettings, press.key == .escape {
            model.showsSettings = false
            return .handled
        }
        return .ignored
    }
}

/// Shared by the popover header and the management window's titlebar accessory.
struct PanelHeaderActions: View {
    @ObservedObject var model: PanelModel
    var presentation: PanelPresentation = .popover
    var onOpenWindow: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    @ObservedObject private var settings = SettingsStore.shared
    private var isShowingSettings: Bool { presentation == .window && model.showsSettings }

    var body: some View {
        HStack(spacing: T.s2) {
            iconButton("magnifyingglass", help: searchHelp, shortcut: "f") {
                if model.tab == .projects && !isShowingSettings { model.projects.focusSearch() }
                else if model.tab == .agent && !isShowingSettings {
                    if presentation == .popover {
                        model.agentWorkspace.openQuickInWindow(skills: true)
                        onOpenWindow?()
                    }
                    model.agentWorkspace.focusSkills()
                }
                else { model.focusSessionSearch(showInManagementWindow: presentation == .window) }
            }
            if let onOpenWindow {
                iconButton("arrow.up.left.and.arrow.down.right", help: L10n.t("Open management window")) {
                    if presentation == .popover, model.tab == .agent { model.agentWorkspace.openQuickInWindow() }
                    onOpenWindow()
                }
            }
            iconButton("arrow.up.right.square", help: L10n.t("Open the GitHub repository")) {
                model.openRepository()
            }
            if let onOpenSettings {
                iconButton("gearshape", help: L10n.t("Settings…"), shortcut: ",", action: onOpenSettings)
            }
        }
    }

    private var searchHelp: String {
        if !isShowingSettings {
            if model.tab == .projects { return L10n.t("Search projects · ⌘F") }
            if model.tab == .agent { return L10n.t("Search skills · ⌘F") }
        }
        return L10n.t("Search sessions · ⌘F")
    }

    private func iconButton(
        _ symbol: String, help: String,
        shortcut: KeyEquivalent? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(T.ctlFg)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(InteractivePlainButtonStyle(pressedScale: 0.90))
        .help(help)
        .accessibilityLabel(help)
        .modifier(OptionalShortcut(key: shortcut))
    }
}

/// 只在给了键值时挂 ⌘ 快捷键
struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}
