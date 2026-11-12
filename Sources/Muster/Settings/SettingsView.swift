import AppKit
import SwiftUI

/// 设置页：并进面板里的一屏（不再是独立窗口）。
/// 和主面板同一套语言——灰底、白卡片、发丝线、一个强调色。
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: T.s4) {
                    startup
                    appearance
                    tabOrder
                    shortcuts
                    approvals
                    aboutAndUpdates
                }
                .padding(.horizontal, T.s3)
                .padding(.bottom, T.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            .padding(.bottom, T.s3)
        }
    }

    // MARK: 分区

    private var startup: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Startup"))
            Card {
                SettingsRow(label: L10n.t("Launch at login")) {
                    MiniSwitch(isOn: $store.launchAtLogin)
                }
                if let error = store.loginItemError {
                    Hairline()
                    notice(error, tone: .danger)
                }
                if store.launchAtLogin == false, store.loginItemError != nil {
                    Hairline()
                    notice(L10n.t("Launch at login requires the packaged app."), tone: .quiet)
                }
            }
        }
        .padding(.top, T.s2)
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Appearance"))
            Card {
                SettingsRow(label: L10n.t("Language"), hint: L10n.t("Restart Muster to apply the language.")) {
                    InlineSelect(
                        items: L10n.Language.allCases.map(\.rawValue),
                        label: { code in L10n.Language(rawValue: code)?.title ?? code },
                        selection: Binding(
                            get: { store.language.rawValue },
                            set: { store.language = L10n.Language(rawValue: $0) ?? .system }))
                }
            }
        }
    }

    private var tabOrder: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Tab order"))
            Card {
                VStack(alignment: .leading, spacing: T.s2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("Drag to reorder")).font(T.body).foregroundStyle(T.fg)
                        Text(L10n.t("The panel shows tabs in this order."))
                            .font(T.small)
                            .foregroundStyle(T.muted)
                    }
                    TabOrderChips(model: model)
                }
                .padding(.horizontal, T.s3)
                .padding(.vertical, T.s2)
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Shortcuts"))
            Card {
                SettingsRow(label: L10n.t("Enable global hotkey")) {
                    MiniSwitch(isOn: $store.hotKeyEnabled)
                }
                Hairline()
                SettingsRow(label: L10n.t("Global hotkey")) {
                    Text("⌃⌥A").font(T.mono).foregroundStyle(T.fg2)
                }
                if let error = store.hotKeyError {
                    Hairline()
                    notice(error, tone: .danger)
                }
            }
        }
    }

    private var approvals: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Approvals"))
            Card {
                SettingsRow(label: L10n.t("Approval timeout")) {
                    Text(L10n.t("%ds", Int(model.approvalTimeout.rounded())))
                        .font(T.small).monospacedDigit().foregroundStyle(T.fg2)
                }
                Hairline()
                SettingsRow(label: L10n.t("Show a notification when a new approval arrives")) {
                    MiniSwitch(isOn: $store.notificationsEnabled)
                }
            }
        }
    }

    /// 版本、Hook、设置文件、源码合并成一组，压在最后
    private var aboutAndUpdates: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("About & updates"))
            Card {
                SettingsRow(label: "Muster", hint: L10n.t("Updates are checked against GitHub releases.")) {
                    Text(store.appVersion).font(T.small).monospacedDigit().foregroundStyle(T.fg2)
                }
                Hairline()
                SettingsRow(label: L10n.t("Check for Updates…")) {
                    Button(L10n.t("Check now")) { SettingsCoordinator.shared.checkForUpdates() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Hairline()
                SettingsRow(label: L10n.t("Hook")) {
                    if let installed = model.hookInstalled {
                        Button(installed ? L10n.t("Uninstall hook") : L10n.t("Install hook")) {
                            model.requestHook(installed ? .uninstall : .install)
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    } else {
                        Text(L10n.t("Unknown")).font(T.small).foregroundStyle(T.faint)
                    }
                }
                Hairline()
                SettingsRow(label: L10n.t("Settings file")) {
                    Button(L10n.t("Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.settingsPath)])
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Hairline()
                SettingsRow(label: L10n.t("Source code")) {
                    linkLabel("GitHub", "https://github.com/EthanWFL/muster")
                }
            }
        }
    }

    // MARK: 小件

    private enum Tone { case danger, quiet }

    private func notice(_ text: String, tone: Tone) -> some View {
        Text(text)
            .font(T.small)
            .foregroundStyle(tone == .danger ? T.red : T.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, T.s3)
            .padding(.vertical, T.s1)
    }

    private func linkLabel(_ text: String, _ url: String) -> some View {
        Link(text, destination: URL(string: url)!)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(T.accent)
    }
}

/// 标签顺序：一行胶囊，直接拖动换位
struct TabOrderChips: View {
    @ObservedObject var model: PanelModel
    @State private var dragging: PanelModel.Tab?

    var body: some View {
        HStack(spacing: T.s2) {
            ForEach(model.orderedTabs, id: \.self) { tab in
                chip(tab)
                    .onDrag {
                        dragging = tab
                        return NSItemProvider(object: tab.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabChipDrop(item: tab, model: model, dragging: $dragging))
            }
        }
    }

    private func chip(_ tab: PanelModel.Tab) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(T.faint)
            Text(tab.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(dragging == tab ? T.fg : T.fg2)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(dragging == tab ? T.accentSoft : T.pill))
        .overlay(Capsule().strokeBorder(T.line, lineWidth: 0.5))
        .opacity(dragging == tab ? 0.7 : 1)
        .contentShape(Capsule())
        .help(L10n.t("Drag to reorder"))
        .accessibilityLabel(tab.title)
        .accessibilityHint(L10n.t("Drag to reorder"))
    }
}

private struct TabChipDrop: DropDelegate {
    let item: PanelModel.Tab
    let model: PanelModel
    @Binding var dragging: PanelModel.Tab?

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let dragging, dragging != item,
                  let from = model.orderedTabs.firstIndex(of: dragging),
                  let to = model.orderedTabs.firstIndex(of: item) else { return }
            withAnimation(.snappy(duration: 0.16)) { model.moveTab(from: from, to: to) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { dragging = nil }
        return true
    }
}
