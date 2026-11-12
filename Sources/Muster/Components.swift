import MusterCore
import MusterProtocol
import SwiftUI

// MARK: - Buttons

/// 胶囊按钮。实心只给主操作，其余是 pill 底 + 发丝线描边，控件文字用 ctlFg 保证对比度。
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill))
            .overlay {
                if kind != .primary {
                    Capsule().strokeBorder(kind == .quiet ? .clear : T.line, lineWidth: 0.5)
                }
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(isEnabled ? 1 : 0.4)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return T.fg2
        case .quiet: return T.ctlFg
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return T.accent
        case .secondary: return T.pill
        case .quiet: return .clear
        }
    }
}

/// 按钮标题 + 弱化的快捷键字符（不画 keycap 方框）
struct ShortcutLabel: View {
    let title: String
    let glyph: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(glyph).opacity(0.6)
        }
    }
}

// MARK: - Segmented control

/// 自绘分段控件。不用系统 `Picker(.segmented)`：轨道深度、圆角和配色都对不上，也放不下计数角标。
struct SegmentedControl<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var badge: (Value) -> Int? = { _ in nil }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let on = selection == item
                Button { selection = item } label: {
                    HStack(spacing: 4) {
                        Text(label(item))
                        if let n = badge(item), n > 0 {
                            Text("\(n)")
                                .font(.system(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(on ? T.fg2 : T.faint)
                        }
                    }
                    .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? T.fg : T.ctlFg)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                                .fill(T.card)
                                .overlay(RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                                    .strokeBorder(T.line, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: T.r, style: .continuous).fill(T.segTrack))
        .animation(.snappy(duration: 0.18), value: selection)
    }
}

/// 面板顶部的 tab 条：就是带计数角标的分段控件，顺序由设置页决定。
struct SegmentedTabs: View {
    @Binding var selection: PanelModel.Tab
    let tabs: [PanelModel.Tab]
    let badges: [PanelModel.Tab: Int]

    var body: some View {
        SegmentedControl(
            items: tabs,
            selection: $selection,
            label: \.title,
            badge: { badges[$0] })
    }
}

// MARK: - 自绘开关

/// 26×15 轨道 + 13pt 白色圆滑块的开关；打开时轨道用近黑/近白。
struct MiniSwitch: View {
    @Binding var isOn: Bool
    var label: String = ""

    var body: some View {
        Capsule()
            .fill(isOn ? T.fg : T.segTrack)
            .frame(width: 26, height: 15)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .padding(1)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .animation(.snappy(duration: 0.16), value: isOn)
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? L10n.t("On") : L10n.t("Off"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isOn.toggle() }
    }
}

// MARK: - 设置页的卡片与行

/// 白卡片：靠底色 + 描边分层，零阴影。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(T.card)
            .clipShape(RoundedRectangle(cornerRadius: T.r, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: T.r, style: .continuous)
                .strokeBorder(T.line, lineWidth: 0.5))
    }
}

/// 「左标签、右控件」的两列行。
struct SettingsRow<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        // 双行行（带说明）控件居中对齐：按第一行基线对齐会明显偏上
        HStack(alignment: .center, spacing: T.s2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(T.body).foregroundStyle(T.fg)
                if let hint {
                    Text(hint).font(T.small).foregroundStyle(T.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: T.s3)
            content
        }
        .padding(.horizontal, T.s3)
        .frame(minHeight: hint == nil ? T.rowSingle : T.rowDouble)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 品牌标

/// 面板左上角的品牌标：直接播放 `manta-glide.gif`（20fps，3.2s 一轮）。
/// 开启「减弱动态效果」时停在首帧；深色模式下用 CIColorInvert 把黑色蝠鲼翻成白色。
struct BrandMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var theme = Theme.shared
    var size: CGFloat = 20

    var body: some View {
        MantaPlayer(size: size, animated: !reduceMotion, invert: theme.isDark)
            .frame(width: size, height: size)
            .clipped()
            .accessibilityHidden(true)
    }
}

// MARK: - 品牌 logo

/// agent 的真 logo：从包里的 `Resources/AgentLogos/<id>.png` 读，读不到就退回单字徽标。
/// 不放 emoji、不放自绘占位图——这是这套设计语言的硬规则。
/// SwiftPM 把资源打进 `Muster_Muster.bundle`，打包脚本把它放到 Contents/Resources。
enum AppResources {
    static var bundles: [Bundle] {
        var urls: [URL] = []
        if let resources = Bundle.main.resourceURL {
            urls.append(resources.appendingPathComponent("Muster_Muster.bundle"))
        }
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Muster_Muster.bundle"))
        return urls.compactMap { Bundle(url: $0) }
    }
}

enum AgentLogos {
    static func image(_ id: String) -> NSImage? {
        for bundle in AppResources.bundles {
            if let url = bundle.url(forResource: id, withExtension: "png") {
                return NSImage(contentsOf: url)
            }
        }
        return nil
    }
}

struct AgentLogo: View {
    let agentID: String
    /// 没有 logo 文件时显示的单字，例如 Pi 的「π」
    let mark: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = AgentLogos.image(agentID) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(T.pill)
                    .overlay(
                        Text(mark)
                            .font(.system(size: size * 0.56, weight: .semibold, design: .rounded))
                            .foregroundStyle(T.fg2)
                    )
                    .frame(width: size, height: size)
            }
        }
    }
}

// MARK: - 下拉选择

/// 面板内的下拉：点开后在按钮下方就地展开一列选项，白卡片 + 发丝线 + 勾选，跟着 token 走。
/// 不用系统 `Menu`——它在 popover 里是原生灰白面板，和我们这套语言不一致。
struct InlineSelect<Item: Hashable, Footer: View>: View {
    let items: [Item]
    let label: (Item) -> String
    var header: String?
    var width: CGFloat = 168
    @Binding var selection: Item
    @ViewBuilder var footer: () -> Footer

    @State private var open = false

    var body: some View {
        VStack(alignment: .trailing, spacing: T.s1) {
            Button {
                withAnimation(.snappy(duration: 0.16)) { open.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(label(selection)).font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(T.glyph)
                }
                .foregroundStyle(T.fg2)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(T.pill))
                .overlay(Capsule().strokeBorder(T.line, lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            if open { list }
        }
        .zIndex(open ? 1 : 0)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(T.micro)
                    .foregroundStyle(T.muted)
                    .padding(.horizontal, T.s2)
                    .padding(.top, T.s1)
                    .padding(.bottom, 2)
            }
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                    withAnimation(.snappy(duration: 0.16)) { open = false }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(T.glyph)
                            .foregroundStyle(T.fg2)
                            .opacity(item == selection ? 1 : 0)
                        Text(label(item)).font(T.body).foregroundStyle(T.fg).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, T.s2)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                    .hoverHighlight()
                }
                .buttonStyle(.plain)
            }
            footer()
        }
        .padding(.vertical, T.s1)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: T.r, style: .continuous).fill(T.card))
        .overlay(RoundedRectangle(cornerRadius: T.r, style: .continuous)
            .strokeBorder(T.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

extension InlineSelect where Footer == EmptyView {
    init(items: [Item], label: @escaping (Item) -> String, header: String? = nil,
         width: CGFloat = 168, selection: Binding<Item>) {
        self.init(items: items, label: label, header: header, width: width,
                  selection: selection, footer: { EmptyView() })
    }
}

// MARK: - 空状态

/// 一行说明 + 一个 accent 文字按钮。不插画、不大图标。
struct EmptyState: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: T.s1) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(T.fg2)
            if let message {
                Text(message)
                    .font(T.small)
                    .foregroundStyle(T.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, T.s4)
    }
}

// MARK: - 折叠行

/// 卡片底部的「显示其余 N 条」：先给几条，剩下的折起来。
struct CollapseRow: View {
    let hiddenCount: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.16)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? L10n.t("Show less") : L10n.t("Show %d more", hiddenCount))
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(T.glyph)
                Spacer(minLength: 0)
            }
            .font(T.small)
            .foregroundStyle(T.muted)
            .padding(.horizontal, T.s3)
            .frame(height: T.rowCompact)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 列表块

/// 分区小标题：全大写 + 字距 + muted；右侧可挂一个 faint 计数。
struct SectionTitle: View {
    let text: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(T.section)
                .tracking(0.4)
                .foregroundStyle(T.muted)
            if let count {
                Text("\(count)").font(T.micro).monospacedDigit().foregroundStyle(T.faint)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.s3)
        .padding(.top, T.s2)
        .padding(.bottom, 2)
    }
}

/// 列表行悬停：只改底色，不加边框、不放大。
struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: T.r, style: .continuous)
                .fill(hovering ? T.card2 : .clear))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

// MARK: - Code block

struct DetailLine: Identifiable {
    enum Kind { case plain, add, remove, context }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// 展开行里的命令原文 / 差异预览。内容只用于显示，不落盘。
enum ToolDetail {
    private static let maxLines = 6
    private static let maxLineLength = 200

    static func lines(for call: ToolCall) -> [DetailLine] {
        let input = call.input
        if let command = input["command"]?.stringValue {
            return clipped(command, kind: .plain, prefix: "")
        }
        if let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue {
            return clipped(old, kind: .remove, prefix: "- ") + clipped(new, kind: .add, prefix: "+ ")
        }
        if let content = input["content"]?.stringValue {
            return clipped(content, kind: .add, prefix: "+ ")
        }
        return [DetailLine(kind: .plain, text: ToolSummary.line(tool: call.tool, input: input, cwd: call.cwd, maxLength: 400))]
    }

    private static func clipped(_ text: String, kind: DetailLine.Kind, prefix: String) -> [DetailLine] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out = all.prefix(maxLines).map { line -> DetailLine in
            let s = line.count > maxLineLength ? String(line.prefix(maxLineLength)) + "…" : String(line)
            return DetailLine(kind: kind, text: prefix + s)
        }
        if all.count > maxLines { out.append(DetailLine(kind: .context, text: "  … " + L10n.t("%d more lines", all.count - maxLines))) }
        return out
    }
}

struct CodeBlock: View {
    let lines: [DetailLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(T.mono)
                    .foregroundStyle(color(line.kind))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, T.s2)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: T.rInner, style: .continuous).fill(T.card2))
        .overlay(RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
            .strokeBorder(T.line, lineWidth: 0.5))
    }

    private func color(_ kind: DetailLine.Kind) -> Color {
        switch kind {
        case .plain: return T.fg2
        case .add: return T.green
        case .remove: return T.red
        case .context: return T.muted
        }
    }
}
