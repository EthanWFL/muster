import SwiftUI

struct WheelFlyout: View {
    @ObservedObject var wheel: ProjectWheelController
    @ObservedObject var preferences: WheelPreferences
    let module: WheelModule
    @State private var hovered: Int?

    private struct Row {
        let label: String
        let action: () -> Void
    }

    private var rows: [Row] {
        switch module {
        case .websites where !preferences.websites.isEmpty:
            return preferences.websites.map { url in
                Row(label: url.host ?? url.absoluteString) { wheel.openWebsite(url) }
            }
        case .clipboard where !preferences.clips.isEmpty:
            return preferences.clips.map { text in
                let preview = text.prefix(180).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return Row(label: preview.isEmpty ? L10n.t("Whitespace") : preview) {
                    preferences.restore(text)
                    wheel.collapse()
                }
            }
        case .actions:
            return [Row(label: L10n.t("Wheel configuration"), action: wheel.openConfiguration),
                    Row(label: L10n.t("Hide wheel"), action: wheel.toggle)]
        case .clipboard:
            let label = preferences.recording ? "No copied text yet" : "Enable clipboard history…"
            return [Row(label: L10n.t(label), action: wheel.openConfiguration)]
        default:
            return [Row(label: L10n.t("Add website"), action: wheel.openConfiguration)]
        }
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
                    Text(verbatim: values[index].label).lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 7).frame(maxWidth: .infinity, alignment: .leading).frame(height: 23)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 4).fill(hovered == index ? T.accentSoft : .clear))
                    .onHover { inside in if inside { hovered = index } else if hovered == index { hovered = nil } }
            }
        }.padding(4).font(.system(size: 12)).foregroundStyle(T.fg)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 7).fill(T.card))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(T.line, lineWidth: 1))
        .fixedSize().onHover { wheel.track($0) }
        .onChange(of: size) { _, _ in DispatchQueue.main.async { wheel.positionFlyout() } }
    }
}
