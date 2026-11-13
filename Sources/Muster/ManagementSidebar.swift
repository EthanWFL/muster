import SwiftUI

/// Main navigation stays above; settings anchors and their entry stay at the bottom.
struct ManagementSidebar: View {
    @ObservedObject var model: PanelModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var theme = Theme.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: T.s1) {
                    Text(L10n.t("Workspace"))
                        .font(T.section).foregroundStyle(T.muted)
                        .padding(.horizontal, T.s3).padding(.bottom, T.s2)
                    ForEach(Array(model.orderedTabs.enumerated()), id: \.element) { index, tab in
                        SidebarRow(title: tab.title, symbol: symbol(tab),
                                   selected: !model.showsSettings && model.tab == tab,
                                   shortcutHint: "⌘\(index + 1)") {
                            model.showsSettings = false
                            model.tab = tab
                        }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    }
                }
                .padding(.horizontal, T.s3).padding(.top, T.s4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity, alignment: .top)

            if model.showsSettings {
                Hairline().padding(.bottom, T.s3)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(SettingsSection.allCases) { section in
                            SidebarRow(title: section.title, symbol: section.symbol,
                                       selected: model.settingsSection == section, compact: true) {
                                model.showSettings(section)
                            }
                        }
                    }
                    .padding(.leading, T.s2)
                    .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 1) }
                    .padding(.leading, 24).padding(.trailing, T.s3)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: settings.comfortableLayout ? 208 : 188)
                .padding(.bottom, T.s3)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            SidebarRow(title: L10n.t("Settings"), symbol: "gearshape",
                       selected: model.showsSettings, shortcutHint: "⌘,", pinned: true) {
                model.toggleSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal, T.s3).padding(.bottom, T.s3)
        }
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(T.bg)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: model.showsSettings)
    }

    private func symbol(_ tab: PanelModel.Tab) -> String {
        switch tab {
        case .sessions: return "bubble.left.and.bubble.right"
        case .environment: return "sparkles"
        case .instructions: return "text.book.closed"
        case .configuration: return "slider.horizontal.3"
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    var shortcutHint: String? = nil
    var compact = false
    var pinned = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 14 : 16, weight: .regular))
                    .foregroundStyle(selected ? T.fg : T.muted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title).font(T.body.weight(selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if let shortcutHint {
                    Text(shortcutHint).font(T.micro).foregroundStyle(T.muted)
                        .opacity(hovered ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? T.fg : T.fg2)
            .padding(.horizontal, T.s3)
            .frame(height: compact ? T.rowSingle : T.rowSingle + 6)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? T.fg.opacity(0.07) : ((hovered || pinned) ? T.card2 : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(pinned ? T.line : .clear, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(InteractivePlainButtonStyle())
        .onHover { hovered = $0 }
        .help(title + (shortcutHint.map { " · " + $0 } ?? ""))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
