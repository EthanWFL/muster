import MusterCore
import SwiftUI

// MARK: - Buttons

/// 胶囊按钮。实心只给主操作，其余是 pill 底 + 发丝线描边，控件文字用 ctlFg 保证对比度。
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, danger }
    let kind: Kind
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @ReducedMotion private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.seg.weight(.medium))
            .padding(.horizontal, 8)
            .frame(height: T.controlHeight)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill))
            .overlay {
                if kind == .danger {
                    Capsule().strokeBorder(T.red.opacity(0.35), lineWidth: 0.5)
                } else if kind != .primary {
                    Capsule().strokeBorder(kind == .quiet ? .clear : T.line, lineWidth: 0.5)
                }
            }
            .overlay(Capsule().fill(T.fg.opacity(hovering && isEnabled ? 0.06 : 0)))
            .animation(reduceMotion ? nil : InteractionMotion.hover, value: hovering && isEnabled)
            .modifier(ButtonPressFeedback(isPressed: configuration.isPressed))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
            .pointerCursor()
    }

    private var foreground: Color {
        switch kind {
        case .primary: return T.onAccent
        case .secondary: return T.fg2
        case .quiet: return T.ctlFg
        case .danger: return T.red
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return T.accent
        case .secondary: return T.pill
        case .quiet: return .clear
        case .danger: return T.red.opacity(0.10)
        }
    }
}

/// 图标按钮随布局密度调整点击区；悬停提示同时作为无障碍标签。
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color = T.ctlFg
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActivitySymbol(symbol: symbol, isActive: isBusy)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: T.iconHitSize, height: T.iconHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(InteractivePlainButtonStyle(pressedScale: 0.90))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isBusy ? L10n.t("Working…") : "")
        .disabled(isBusy)
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

/// 卡片里的小输入框：和胶囊按钮同一套高度、圆角、发丝线。
struct MiniField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat?

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(T.mono)
            .foregroundStyle(T.fg2)
            .focused($focused)
            .padding(.horizontal, 8)
            .frame(width: width, height: T.controlHeight)
            .background(RoundedRectangle(cornerRadius: T.rInner, style: .continuous).fill(T.card2))
            .overlay(RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                .strokeBorder(focused ? T.accent : T.line, lineWidth: 0.5))
            .accessibilityLabel(placeholder)
    }
}

// MARK: - Segmented control

/// 自绘分段控件，沿用面板的轨道、圆角和配色。
struct SegmentedControl<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    var shortcut: ((Value) -> KeyEquivalent?)? = nil
    let label: (Value) -> String
    @Namespace private var selectionAnimation
    @ReducedMotion private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let on = selection == item
                Button { selection = item } label: {
                    Text(label(item))
                    .font(T.seg.weight(on ? .semibold : .regular))
                    .foregroundStyle(on ? T.fg : T.ctlFg)
                    .frame(maxWidth: .infinity, minHeight: T.controlHeight)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                                .fill(T.card)
                                .overlay(RoundedRectangle(cornerRadius: T.rInner, style: .continuous)
                                    .strokeBorder(T.line, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                                .matchedGeometryEffect(id: "selection", in: selectionAnimation)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(InteractivePlainButtonStyle(pressedScale: 1))
                .modifier(OptionalShortcut(key: shortcut?(item)))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: T.r, style: .continuous).fill(T.segTrack))
        .animation(reduceMotion ? nil : InteractionMotion.selection, value: selection)
    }
}

/// 面板顶部的 tab 条，顺序由设置页决定。
struct SegmentedTabs: View {
    @Binding var selection: PanelModel.Tab
    let tabs: [PanelModel.Tab]

    var body: some View {
        SegmentedControl(
            items: tabs,
            selection: $selection,
            shortcut: { tab in tabs.firstIndex(of: tab).map { KeyEquivalent(Character(String($0 + 1))) } },
            label: \.title)
    }
}

// MARK: - 开关

/// Native switch preserves keyboard focus and accessibility semantics.
struct MiniSwitch: View {
    @Binding var isOn: Bool
    var label: String = ""

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel(label)
    }
}

// MARK: - 设置页的卡片与行

/// 白卡片：靠底色 + 描边分层，零阴影。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            // 圆角只作用在背景上（不 clip 子树），下拉浮层才能溢出卡片边界
            .background(
                RoundedRectangle(cornerRadius: T.r, style: .continuous).fill(T.card))
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
            content.accessibilityLabel(label)
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
    @ReducedMotion private var reduceMotion
    private let theme = Theme.shared
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

/// Keep the compact label, while AppKit owns menu focus, scrolling and keyboard navigation.
struct InlineSelect<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    var header: String? = nil
    @Binding var selection: Item
    var customAction: (() -> Void)? = nil

    var body: some View {
        Menu {
            if let header { Text(header) }
            ForEach(items, id: \.self) { item in
                Button { selection = item } label: {
                    if item == selection {
                        Label(label(item), systemImage: "checkmark")
                    } else {
                        Text(label(item))
                    }
                }
            }
            if let customAction {
                Divider()
                Button(L10n.t("Custom…"), action: customAction)
            }
        } label: {
            CompactMenuLabel(title: label(selection))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(header ?? label(selection))
        .accessibilityValue(label(selection))
    }
}

/// Shared menu label; native menus retain focus, scrolling and keyboard navigation.
struct CompactMenuLabel: View {
    let title: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: T.s1) {
            if let symbol { Image(systemName: symbol).font(T.seg) }
            Text(title).font(T.seg).lineLimit(1)
            Image(systemName: "chevron.down").font(T.glyph)
        }
        .foregroundStyle(T.ctlFg)
        .padding(.horizontal, T.s2)
        .frame(height: T.controlHeight)
        .background(Capsule().fill(T.pill))
        .pointerCursor()
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
                Text("\(count)").font(T.micro).monospacedDigit().foregroundStyle(T.muted)
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
    @Environment(\.isEnabled) private var isEnabled
    @ReducedMotion private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: T.r, style: .continuous)
                .fill(hovering && isEnabled ? T.card2 : .clear))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : InteractionMotion.hover, value: hovering && isEnabled)
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
