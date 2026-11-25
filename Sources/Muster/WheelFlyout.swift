import SwiftUI

struct WheelFlyout: View {
    @ObservedObject var wheel: ProjectWheelController
    @ObservedObject var preferences: WheelPreferences
    let module: WheelModule
    @State private var hovered: Int?

    private struct Row {
        let label: String
        var help: String?
        var isLink = false
        let action: () -> Void
    }

    private var rows: [Row] {
        switch module {
        case .projects:
            guard !wheel.visibleEntries.isEmpty else {
                return [Row(label: L10n.t("Wheel configuration"), action: wheel.openConfiguration)]
            }
            return wheel.visibleEntries.map { entry in
                Row(label: entry.name, help: entry.id) { wheel.open(entry) }
            }
        case .websites where !preferences.websites.isEmpty:
            return preferences.websites.map { url in
                Row(label: url.host ?? url.absoluteString) { wheel.openWebsite(url) }
            }
        case .clipboard where !preferences.clips.isEmpty:
            return preferences.clips.map { text in
                let preview = Self.clipPreview(text)
                return Row(label: preview.label, isLink: preview.isLink) {
                    preferences.restore(text)
                    wheel.collapse()
                }
            }
        case .actions:
            return [Row(label: L10n.t("Chat")) { wheel.openPage(.chat) },
                    Row(label: L10n.t("Wheel configuration"), action: wheel.openConfiguration),
                    Row(label: L10n.t("Hide wheel"), action: wheel.toggle)]
        case .clipboard:
            let label = preferences.recording ? "No copied text yet" : "Enable clipboard history…"
            return [Row(label: L10n.t(label), action: wheel.openConfiguration)]
        case .websites:
            return [Row(label: L10n.t("Add website"), action: wheel.openConfiguration)]
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
        return CGSize(width: min(ceil(width) + 24, module == .websites ? 142 : 208), height: CGFloat(values.count * 23 + 8))
    }

    var body: some View {
        let values = rows
        let size = popupSize
        VStack(alignment: .leading, spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                Button(action: values[index].action) {
                    Text(verbatim: values[index].label).lineLimit(1).truncationMode(values[index].isLink ? .middle : .tail)
                        .foregroundStyle(hovered == index ? T.accent : T.fg)
                        .padding(.horizontal, 7).frame(maxWidth: .infinity, alignment: .leading).frame(height: 23)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(values[index].help ?? values[index].label)
                    .background(RoundedRectangle(cornerRadius: 4).fill(hovered == index ? T.accentSoft : .clear))
                    .onHover { inside in if inside { hovered = index } else if hovered == index { hovered = nil } }
            }
        }.padding(4).font(.system(size: 12)).foregroundStyle(T.fg)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 7).fill(T.card))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(T.line, lineWidth: 1))
        .fixedSize().onHover { inside in
            wheel.pointerInFlyout = inside
            wheel.track(inside)
        }
        .onChange(of: size) { _, _ in DispatchQueue.main.async { wheel.positionFlyout() } }
    }
}
