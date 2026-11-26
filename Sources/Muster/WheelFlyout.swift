import AppKit
import SwiftUI

struct WheelFlyout: View {
    @ObservedObject var wheel: ProjectWheelController
    @ObservedObject var preferences: WheelPreferences
    let module: WheelModule
    @State private var hovered: Int?

    private struct Row {
        let label: String
        var help: String?
        var symbol = "circle"
        var isLink = false
        var path: String?
        var link: URL?
        let action: () -> Void
    }

    private var rows: [Row] {
        switch module {
        case .projects:
            guard !wheel.visibleEntries.isEmpty else {
                return [Row(label: L10n.t("Wheel configuration"), symbol: "gearshape", action: wheel.openConfiguration)]
            }
            return wheel.visibleEntries.map { entry in
                Row(label: entry.name, help: entry.id, symbol: "folder", path: entry.id) { wheel.open(entry) }
            }
        case .websites where !preferences.websites.isEmpty:
            return preferences.websites.map { url in
                Row(label: url.host ?? url.absoluteString, help: url.absoluteString, symbol: "globe", link: url) {
                    wheel.openWebsite(url)
                }
            }
        case .clipboard where !preferences.clips.isEmpty:
            return preferences.clips.map { text in
                let preview = Self.clipPreview(text)
                return Row(label: preview.label, help: text, symbol: preview.isLink ? "link" : "doc.on.doc",
                           isLink: preview.isLink) {
                    preferences.restore(text)
                    wheel.collapse()
                }
            }
        case .actions:
            return [Row(label: L10n.t("Chat"), symbol: "bubble.left") { wheel.openPage(.chat) },
                    Row(label: L10n.t("Wheel configuration"), symbol: ProjectWheelToggle.symbol,
                        action: wheel.openConfiguration),
                    Row(label: L10n.t("Hide wheel"), symbol: "eye.slash", action: wheel.toggle)]
        case .clipboard:
            let label = preferences.recording ? "No copied text yet" : "Enable clipboard history…"
            return [Row(label: L10n.t(label), symbol: "clipboard", action: wheel.openConfiguration)]
        case .websites:
            return [Row(label: L10n.t("Add website"), symbol: "plus", action: wheel.openConfiguration)]
        }
    }

    static func clipPreview(_ text: String) -> (label: String, isLink: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = trimmed.prefix(while: { $0 != ":" }).lowercased()
        if ["http", "https"].contains(scheme), !trimmed.contains(where: \.isWhitespace),
           var url = URLComponents(string: trimmed), let host = url.host, !host.isEmpty {
            url.user = nil
            url.password = nil
            if let address = url.string, let scheme = address.range(of: "://") {
                return (String(address[scheme.upperBound...]), true)
            }
        }
        let preview = text.prefix(180).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (preview.isEmpty ? L10n.t("Whitespace") : preview, false)
    }

    var popupSize: CGSize {
        let values = rows
        let font = NSFont.systemFont(ofSize: 12)
        let width = values.map { ($0.label as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return CGSize(width: min(ceil(width) + 44, module == .websites ? 176 : 244),
                      height: CGFloat(values.count * 28 + 8 + 23))
    }

    var body: some View {
        let values = rows
        let size = popupSize
        VStack(alignment: .leading, spacing: 0) {
            Text(module.title)
                .font(T.section)
                .foregroundStyle(T.muted)
                .padding(.horizontal, 7)
                .frame(height: 22, alignment: .leading)
            Hairline()
            ForEach(values.indices, id: \.self) { index in
                if values[index].path != nil || values[index].link != nil {
                    rowButton(index, values[index])
                        .contextMenu {
                            if let path = values[index].path {
                                Button(L10n.t("Reveal in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                                Button(L10n.t("Copy path")) { copy(path) }
                            }
                            if let link = values[index].link {
                                Button(L10n.t("Copy link")) { copy(link.absoluteString) }
                            }
                        }
                } else {
                    rowButton(index, values[index])
                }
            }
        }.padding(4).font(T.seg).foregroundStyle(T.fg)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 7).fill(T.card))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(T.line, lineWidth: 1))
        .fixedSize().onHover { inside in
            wheel.pointerInFlyout = inside
            wheel.track(inside)
        }
        .onChange(of: size) { _, _ in DispatchQueue.main.async { wheel.positionFlyout() } }
    }

    @ViewBuilder private func rowButton(_ index: Int, _ row: Row) -> some View {
        Button(action: row.action) {
            HStack(spacing: 7) {
                Image(systemName: row.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovered == index ? T.accent : T.muted)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(verbatim: row.label)
                    .lineLimit(1)
                    .truncationMode(row.isLink ? .middle : .tail)
                    .foregroundStyle(hovered == index ? T.accent : T.fg)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.help ?? row.label)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovered == index ? T.accentSoft : .clear))
        .onHover { inside in if inside { hovered = index } else if hovered == index { hovered = nil } }
    }

    private func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
