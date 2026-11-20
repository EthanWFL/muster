import AppKit
import Combine
import MusterCore
import SwiftUI

struct ProjectWheelToggle: View {
    @ObservedObject var wheel: ProjectWheelController

    var body: some View {
        IconButton(symbol: wheel.isVisible ? "chart.pie.fill" : "chart.pie",
                   label: L10n.t(wheel.isVisible ? "Close wheel" : "Start wheel"),
                   tint: wheel.isVisible ? T.accent : T.muted) { wheel.toggle() }
            .accessibilityAddTraits(wheel.isVisible ? .isSelected : [])
    }
}

struct WheelProject: Equatable, Identifiable {
    let id: String
    let name: String
}

@MainActor
final class ProjectWheelController: NSObject, ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var expanded = false
    @Published private(set) var entries: [WheelProject] = []
    @Published var page = 0
    private let defaults: UserDefaults
    private var panel: NSPanel?
    private var anchor: CGPoint = .zero
    private var observation: AnyCancellable?
    private var press: (mouse: CGPoint, center: CGPoint)?
    private var dragging = false
    private var pendingCollapse: Task<Void, Never>?
    private static let positionKey = "MusterProjectWheelCenter"
    nonisolated static let hubSize: CGFloat = 48
    nonisolated static let ringWidth: CGFloat = 34
    nonisolated static let diameter = hubSize + 2 * ringWidth
    var pages: Int { max(1, (entries.count + 5) / 6) }
    var visibleEntries: ArraySlice<WheelProject> { entries.dropFirst(page * 6).prefix(6) }

    init(projects: ProjectsModel, defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        observation = projects.$projects.map { projects in
            projects.filter { $0.record?.wheelMember == true }
                .map { WheelProject(id: $0.path, name: $0.name) }.sorted { $0.id < $1.id }
        }.removeDuplicates().sink { [weak self] entries in
            guard let self else { return }
            self.entries = entries
            self.page = min(self.page, self.pages - 1)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func toggle() {
        if isVisible {
            pendingCollapse?.cancel()
            panel?.orderOut(nil)
            panel?.contentView = nil
            panel = nil
            isVisible = false
            expanded = false
            press = nil
            dragging = false
            return
        }
        guard let screen = screen(at: NSEvent.mouseLocation) else { return }
        let saved = defaults.string(forKey: Self.positionKey).map(NSPointFromString)
        anchor = saved.flatMap { point in NSScreen.screens.contains { $0.frame.contains(point) } ? point : nil }
            ?? CGPoint(x: screen.visibleFrame.maxX - 60, y: screen.visibleFrame.midY)
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ProjectWheelFace(wheel: self))
        host.sizingOptions = []
        window.contentView = host
        panel = window
        isVisible = true
        page = 0
        layout()
        window.orderFrontRegardless()
    }

    /// Keep the resting anchor independent from the temporary inward shift of the expanded disk.
    static func frame(center: CGPoint, diameter: CGFloat, within area: CGRect) -> CGRect {
        let x = min(max(center.x - diameter / 2, area.minX), area.maxX - diameter)
        let y = min(max(center.y - diameter / 2, area.minY), area.maxY - diameter)
        return CGRect(x: x, y: y, width: diameter, height: diameter)
    }

    private func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    @objc private func screenChanged() { if isVisible { layout() } }

    private func layout() {
        guard let screen = screen(at: anchor) else { return }
        let area = screen.visibleFrame
        let resting = Self.frame(center: anchor, diameter: Self.hubSize, within: area)
        anchor = CGPoint(x: resting.midX, y: resting.midY)
        let frame = expanded ? Self.frame(center: anchor, diameter: Self.diameter, within: area) : resting
        panel?.setFrame(frame, display: true)
    }

    func enteredHub() {
        pendingCollapse?.cancel()
        guard isVisible, !expanded, press == nil else { return }
        expanded = true
        layout()
    }

    func track(_ inside: Bool) {
        pendingCollapse?.cancel()
        guard !inside, expanded else { return }
        pendingCollapse = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.press == nil,
                  self.panel?.frame.contains(NSEvent.mouseLocation) == false else { return }
            self.collapse()
        }
    }

    private func collapse() {
        pendingCollapse?.cancel()
        expanded = false
        layout()
    }

    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if press == nil, let frame = panel?.frame { press = (mouse, CGPoint(x: frame.midX, y: frame.midY)) }
        guard let press else { return }
        let dx = mouse.x - press.mouse.x, dy = mouse.y - press.mouse.y
        guard dragging || hypot(dx, dy) >= 4 else { return }
        dragging = true
        expanded = false
        anchor = CGPoint(x: press.center.x + dx, y: press.center.y + dy)
        layout()
    }

    func dragEnded() {
        press = nil
        if dragging {
            dragging = false
            defaults.set(NSStringFromPoint(anchor), forKey: Self.positionKey)
        } else if expanded && pages > 1 {
            page = (page + 1) % pages
        } else {
            enteredHub()
        }
    }

    func open(_ entry: WheelProject) {
        collapse()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.id, isDirectory: &directory), directory.boolValue else {
            showError(L10n.t("Project folder unavailable: %@", entry.id)); return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            showError(L10n.t("Install Visual Studio Code to open this project.")); return
        }
        // Submit the folder itself so VS Code can select an existing matching workspace window.
        NSWorkspace.shared.open([URL(fileURLWithPath: entry.id, isDirectory: true)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in self.showError(error.localizedDescription) } }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t("Project wheel")
        alert.informativeText = message
        alert.runModal()
    }
}

struct WheelSector: Shape {
    /// SwiftUI local coordinates start at the top left; sector zero is centered at twelve o'clock.
    static func index(at point: CGPoint, count: Int) -> Int? {
        let radius = ProjectWheelController.diameter / 2
        let dx = point.x - radius, dy = point.y - radius
        let distance = hypot(dx, dy)
        guard count > 0, distance > ProjectWheelController.hubSize / 2, distance <= radius else { return nil }
        let turn = 2 * Double.pi
        let angle = atan2(dy, dx) + Double.pi / 2 + turn
        return Int(floor(angle * Double(count) / turn + 0.5)) % count
    }

    let index: Int
    let count: Int
    var angle: Double { 2 * .pi * Double(index) / Double(count) - .pi / 2 }

    func path(in rect: CGRect) -> Path {
        if count == 1 { return Path(ellipseIn: rect) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        let half = Double.pi / Double(count)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .radians(angle - half),
                    endAngle: .radians(angle + half), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct WheelArcLabel: View {
    let name: String
    let angle: Double
    let count: Int

    static func lines(for name: String) -> [String] {
        let first = name.prefix(6)
        let rest = name.dropFirst(first.count)
        guard !rest.isEmpty else { return [String(first)] }
        let second = rest.prefix(7)
        return [String(first), String(second) + (second.endIndex < name.endIndex ? "…" : "")]
    }

    var body: some View {
        Canvas { context, size in
            let middle = (size.width + ProjectWheelController.hubSize) / 4
            let direction: CGFloat = sin(angle) > 0.001 ? -1 : 1
            let lines = Self.lines(for: name)
            for (row, line) in lines.enumerated() {
                let radius = lines.count == 1 ? middle : middle + (row == 0 ? -7 : 7)
                let glyphs = line.map { character in
                    let glyph = context.resolve(Text(verbatim: String(character)).font(T.small.weight(.medium)).foregroundColor(T.fg))
                    return (glyph, glyph.measure(in: size).width)
                }
                let width = glyphs.reduce(0) { $0 + $1.1 }
                guard width > 0 else { continue }
                let available = (radius - 6) * min(.pi, 2 * .pi / Double(count)) - 2
                let scale = min(1, available / width)
                var offset = -width * scale / 2
                for (glyph, width) in glyphs {
                    let advance = width * scale
                    let theta = angle + direction * (offset + advance / 2) / radius
                    var pen = context
                    pen.translateBy(x: size.width / 2 + radius * cos(theta), y: size.height / 2 + radius * sin(theta))
                    pen.rotate(by: .radians(theta + direction * .pi / 2))
                    pen.scaleBy(x: scale, y: 1)
                    pen.draw(glyph, at: .zero, anchor: .center)
                    offset += advance
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ProjectWheelFace: View {
    @ObservedObject var wheel: ProjectWheelController
    @ReducedMotion private var reduceMotion
    @State private var hovered: String?

    var body: some View {
        ZStack {
            if wheel.expanded {
                let projects = Array(wheel.visibleEntries)
                ZStack {
                    Circle().fill(T.card)
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, entry in
                        let sector = WheelSector(index: index, count: projects.count)
                        ZStack {
                            sector.fill(hovered == entry.id ? T.accentSoft : T.card)
                            sector.stroke(T.line, lineWidth: 1)
                            WheelArcLabel(name: entry.name, angle: sector.angle, count: projects.count)
                        }

                    }
                    if projects.isEmpty {
                        WheelArcLabel(name: L10n.t("Select projects in Projects"), angle: .pi / 2, count: 1)
                    }
                }.frame(width: ProjectWheelController.diameter, height: ProjectWheelController.diameter)
                .clipShape(Circle()).contentShape(Circle())
                .onContinuousHover { phase in
                    if case .active(let p) = phase, let i = WheelSector.index(at: p, count: projects.count) {
                        hovered = projects[i].id
                    } else { hovered = nil }
                }
                .onTapGesture(coordinateSpace: .local) { p in
                    if let i = WheelSector.index(at: p, count: projects.count) { wheel.open(projects[i]) }
                }
                .onDisappear { hovered = nil }
                .help(hovered ?? "")
                .accessibilityRepresentation {
                    ForEach(projects) { entry in Button(entry.name) { wheel.open(entry) } }
                }
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            ZStack {
                Circle().fill(T.card)
                Circle().strokeBorder(AngularGradient(colors: [.cyan, .indigo, .pink, .cyan], center: .center), lineWidth: 3)
                Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.6)
                Image(nsImage: MenuBarIcon.image).renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(T.fg).frame(width: 28, height: 28)
                if wheel.expanded && wheel.pages > 1 {
                    Text("\(wheel.page + 1)/\(wheel.pages)").font(.system(size: 9)).offset(y: 15)
                }
            }.frame(width: ProjectWheelController.hubSize, height: ProjectWheelController.hubSize).contentShape(Circle())
            .onHover { if $0 { wheel.enteredHub() } }
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in wheel.dragChanged() }.onEnded { _ in wheel.dragEnded() })
            .accessibilityLabel(L10n.t("Project wheel"))
            .help(L10n.t("Drag to move. Click the center to change page."))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { wheel.track($0) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: wheel.expanded)
    }
}
