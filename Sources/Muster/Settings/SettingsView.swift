import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, notifications, interface, diagnostics, about
    var id: Self { self }
    var title: String {
        switch self {
        case .general: return L10n.t("General")
        case .notifications: return L10n.t("Notifications")
        case .interface: return L10n.t("Interface")
        case .diagnostics: return L10n.t("Diagnostics")
        case .about: return L10n.t("About")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .notifications: return "bell"
        case .interface: return "rectangle.3.group"
        case .diagnostics: return "waveform.path.ecg"
        case .about: return "info.circle"
        }
    }
}

/// 设置连续排列；侧栏负责锚点跳转，滚动位置负责同步选中项。
/// 和主面板同一套语言——灰底、白卡片、发丝线、一个强调色。
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var model: PanelModel
    @ObservedObject private var updates = SettingsCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var webhookResult: String?
    @State private var hasPositionedInitialSection = false

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(SettingsSection.allCases) { section in
                            sectionContent(section)
                                .padding(.top, 24)
                                .padding(.bottom, section == .about ? 24 : 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Leave enough trailing space to align even the last anchor at the top.
                                .frame(minHeight: section == .about ? viewport.size.height : nil, alignment: .top)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: SettingsSectionFrames.self,
                                        value: [section: geometry.frame(in: .named("settings-scroll"))])
                                })
                                .id(section)
                                .zIndex(section == .interface ? 1 : 0)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: "settings-scroll")
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.visible)
                .onPreferenceChange(SettingsSectionFrames.self) { frames in
                    guard frames.count == SettingsSection.allCases.count else { return }
                    if !hasPositionedInitialSection {
                        hasPositionedInitialSection = true
                        proxy.scrollTo(model.settingsSection, anchor: .top)
                    } else if let visible = SettingsSection.allCases.last(where: { (frames[$0]?.minY ?? .infinity) <= 1 }),
                              model.settingsSection != visible {
                        // Updating the highlight must not issue another scroll request.
                        model.settingsSection = visible
                    }
                }
                .onChange(of: model.settingsScrollRequest) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        proxy.scrollTo(model.settingsSection, anchor: .top)
                    }
                }
            }
        }
        .clipped()
    }

    @ViewBuilder private func sectionContent(_ section: SettingsSection) -> some View {
        switch section {
        case .general: general
        case .notifications: notifications
        case .interface: interface
        case .diagnostics: DiagnosticsView(model: model.diagnostics)
        case .about: aboutAndUpdates
        }
    }

    // MARK: 分区

    /// 开机启动 + 全局热键：一次启动设置，合成一张卡
    private var general: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("General"))
            Card {
                SettingsRow(label: L10n.t("Launch at login")) {
                    MiniSwitch(isOn: $store.launchAtLogin)
                }
                if let error = store.loginItemError {
                    Hairline()
                    notice(error, tone: .danger)
                }
                Hairline()
                SettingsRow(label: L10n.t("Enable global hotkey")) {
                    MiniSwitch(isOn: $store.hotKeyEnabled)
                }
                if store.hotKeyEnabled {
                    Hairline()
                    SettingsRow(label: L10n.t("Global hotkey")) {
                        Text("⌃⌥A").font(T.mono).foregroundStyle(T.fg2)
                    }
                }
                if let error = store.hotKeyError {
                    Hairline()
                    notice(error, tone: .danger)
                }
            }
        }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Notifications"))
            Card {
                SettingsRow(label: L10n.t("Notify after activity pauses"),
                            hint: L10n.t("Remind after 60 seconds without new activity. This does not mean the task finished.")) {
                    MiniSwitch(isOn: $store.notificationsEnabled)
                }
                Hairline()
                SettingsRow(label: L10n.t("Feishu bot webhook"), hint: L10n.t("Optional custom bot URL.")) {
                    HStack(spacing: T.s2) {
                        MiniField(placeholder: "…/bot/v2/hook/…",
                                  text: $store.feishuWebhook, width: 150)
                        Button(L10n.t("Test")) {
                            Task {
                                webhookResult = await NotificationService.sendFeishu("Muster · " + L10n.t("Test message"))
                                    ?? L10n.t("Sent.")
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .disabled(store.feishuWebhook.isEmpty)
                    }
                }
                if let webhookResult {
                    Hairline()
                    notice(webhookResult, tone: .quiet)
                }
            }
        }
    }

    /// 语言 + 标签顺序：都只影响界面本身
    private var interface: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("Interface"))
            Card {
                SettingsRow(label: L10n.t("Language")) {
                    InlineSelect(
                        items: L10n.Language.allCases.map(\.rawValue),
                        label: { code in L10n.Language(rawValue: code)?.title ?? code },
                        selection: Binding(
                            get: { store.language.rawValue },
                            set: { store.language = L10n.Language(rawValue: $0) ?? .system }))
                }
                Hairline()
                SettingsRow(label: L10n.t("Comfortable layout"),
                            hint: L10n.t("Larger text and roomier rows.")) {
                    MiniSwitch(isOn: $store.comfortableLayout)
                }
                Hairline()
                VStack(alignment: .leading, spacing: T.s2) {
                    Text(L10n.t("Drag the tabs to reorder them."))
                        .font(T.small)
                        .foregroundStyle(T.muted)
                    TabOrderChips(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, T.s3)
                .padding(.vertical, T.s2)
            }
        }
        .zIndex(1)
    }

    /// 版本、更新与源码入口：挤成一行
    private var aboutAndUpdates: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            SectionTitle(text: L10n.t("About"))
            Card {
                HStack(spacing: T.s2) {
                    Text("Muster " + store.appVersion)
                        .font(T.small).monospacedDigit().foregroundStyle(T.fg2)
                    Spacer(minLength: T.s2)
                    IconButton(symbol: "arrow.triangle.2.circlepath", label: L10n.t("Check for Updates…"), tint: T.ctlFg) {
                        updates.checkForUpdates()
                    }
                    .disabled(updates.updateBusy)
                }
                .padding(.horizontal, T.s3)
                .frame(height: T.rowSingle)
                if updates.updateState != .idle {
                    Hairline()
                    updateStatus
                }
            }
        }
    }

    /// 检查结果直接显示在关于页。
    private var updateStatus: some View {
        HStack(spacing: T.s2) {
            VStack(alignment: .leading, spacing: T.s1) {
                Text(updateMessage)
                    .font(T.small)
                    .foregroundStyle(updateTone)
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading(let progress) = updates.updateState {
                    if let fraction = progress.fraction { ProgressView(value: fraction).progressViewStyle(.linear) }
                    Text(ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file))
                        .font(T.micro).foregroundStyle(T.muted)
                }
            }
            Spacer(minLength: T.s2)
            switch updates.updateState {
            case .available(let release):
                if release.asset != nil && updates.hasTrustedUpdateKey {
                    Button(L10n.t("Download and Install")) { updates.installAvailableUpdate() }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                } else {
                    Button(L10n.t("Open Releases")) { NSWorkspace.shared.open(release.url) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
            case .downloading:
                Button(L10n.t("Cancel")) { updates.cancelDownload() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            case .failed:
                Button(L10n.t("Open Releases")) { NSWorkspace.shared.open(updates.releasesURL) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, T.s3)
        .padding(.vertical, T.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updateMessage: String {
        switch updates.updateState {
        case .idle: return ""
        case .checking: return L10n.t("Checking…")
        case .upToDate: return L10n.t("Muster is up to date.")
        case .available(let release):
            let title = L10n.t("Version %@ is available.", release.version)
            return release.asset != nil && updates.hasTrustedUpdateKey ? title
                : title + " " + L10n.t("Automatic installation is unavailable. Download from Releases.")
        case .downloading: return L10n.t("Downloading update…")
        case .installing: return L10n.t("Verifying and installing…")
        case .failed(let message): return message
        }
    }

    private var updateTone: Color {
        switch updates.updateState {
        case .failed: return T.red
        case .available: return T.fg2
        default: return T.muted
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

}

private struct SettingsSectionFrames: PreferenceKey {
    static var defaultValue: [SettingsSection: CGRect] = [:]

    static func reduce(value: inout [SettingsSection: CGRect], nextValue: () -> [SettingsSection: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
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
        .pointerCursor(.openHand)
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
