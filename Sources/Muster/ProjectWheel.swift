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
    @Published private(set) var activeModule: WheelModule?
    let preferences: WheelPreferences
    var onConfigure: (() -> Void)?
    private var flyout: NSPanel?
    private var selectionTask: Task<Void, Never>?
    private var candidate: WheelModule?
    private var preferenceObservation: AnyCancellable?
    private let defaults: UserDefaults
    private var panel: NSPanel?
    private var anchor: CGPoint = .zero
    private var expandedCenter: CGPoint?
    private var hoverBeforeResize: CGPoint?
    private var observation: AnyCancellable?
    private var press: (mouse: CGPoint, center: CGPoint)?
    private var dragging = false
    private var pendingCollapse: Task<Void, Never>?
    private static let positionKey = "MusterProjectWheelCenter"
    nonisolated static let hubSize: CGFloat = 48
    nonisolated static let ringWidth: CGFloat = 34
    nonisolated static let diameter = hubSize + 2 * ringWidth
    nonisolated static let outerDiameter = diameter + 2 * ringWidth
    var visibleEntries: ArraySlice<WheelProject> { entries.prefix(6) }

    init(projects: ProjectsModel, defaults: UserDefaults, board: NSPasteboard = .general) {
        self.defaults = defaults
        preferences = WheelPreferences(defaults: defaults, board: board)
        super.init()
        preferenceObservation = preferences.$modules.dropFirst().sink { [weak self] _ in self?.collapse() }
        observation = projects.$projects.map { projects in
            projects.filter { $0.record?.wheelMember == true }
                .map { WheelProject(id: $0.path, name: $0.name) }.sorted { $0.id < $1.id }
        }.removeDuplicates().sink { [weak self] entries in
            guard let self else { return }
            self.entries = entries
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func toggle() {
        if isVisible {
            pendingCollapse?.cancel()
            resetModule()
            panel?.orderOut(nil)
            panel?.contentView = nil
            panel = nil
            isVisible = false
            expanded = false
            expandedCenter = nil
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
        window.acceptsMouseMovedEvents = true
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ProjectWheelFace(wheel: self))
        host.sizingOptions = []
        window.contentView = host
        panel = window
        isVisible = true
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
        let diameter = activeModule == .projects ? Self.outerDiameter : Self.diameter
        let frame = expanded ? Self.frame(center: expandedCenter ?? anchor, diameter: diameter, within: area) : resting
        expandedCenter = expanded ? CGPoint(x: frame.midX, y: frame.midY) : nil
        if expanded, panel?.frame != frame { hoverBeforeResize = NSEvent.mouseLocation }
        panel?.setFrame(frame, display: true)
        positionFlyout()
    }

    func enteredHub() {
        pendingCollapse?.cancel()
        guard isVisible, !expanded, press == nil else { return }
        expanded = true
        layout()
    }

    func track(_ inside: Bool) {
        pendingCollapse?.cancel()
        if inside && flyout?.frame.contains(NSEvent.mouseLocation) == true { hoverModule(nil) }
        guard !inside, expanded else { return }
        pendingCollapse = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.press == nil,
                  self.panel?.frame.contains(NSEvent.mouseLocation) == false,
                  self.flyout?.frame.contains(NSEvent.mouseLocation) != true else { return }
            self.collapse()
        }
    }

    func collapse() {
        resetModule()
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
        if !dragging { resetModule() }
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

    private func resetModule() {
        hoverModule(nil)
        activeModule = nil
        closeFlyout()
    }

    private func closeFlyout() {
        flyout?.orderOut(nil)
        flyout?.contentView = nil
        flyout = nil
    }

    func hoverModule(_ module: WheelModule?) {
        if module != nil, let previous = hoverBeforeResize {
            let mouse = NSEvent.mouseLocation
            guard hypot(mouse.x - previous.x, mouse.y - previous.y) > 3 else { return }
            hoverBeforeResize = nil
        }
        guard candidate != module else { return }
        selectionTask?.cancel()
        candidate = module
        guard let module, module != activeModule else { return }
        selectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.activateModule(module)
        }
    }

    func activateModule(_ module: WheelModule) {
        guard expanded, preferences.modules.contains(module), activeModule != module else { return }
        closeFlyout()
        activeModule = module
        layout()
        guard module != .projects else { return }
        let popup = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.backgroundColor = .clear
        popup.isOpaque = false
        popup.hasShadow = true
        popup.level = .floating
        popup.acceptsMouseMovedEvents = true
        popup.hidesOnDeactivate = false
        popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: WheelFlyout(wheel: self, preferences: preferences, module: module))
        host.sizingOptions = []
        popup.contentView = host
        flyout = popup
        positionFlyout()
        popup.orderFrontRegardless()
    }

    func positionFlyout() {
        guard let flyout, let module = activeModule, let disk = panel?.frame,
              let area = screen(at: anchor)?.visibleFrame else { return }
        let size = WheelFlyout(wheel: self, preferences: preferences, module: module).popupSize
        guard size.width > 0, size.height > 0 else { return }
        let left = disk.minX - size.width, right = disk.maxX
        let preferLeft = activeModule == .actions || activeModule == .clipboard
        let useLeft = preferLeft ? left >= area.minX || right + size.width > area.maxX : right + size.width > area.maxX
        let x = max(area.minX, min(useLeft ? left : right, area.maxX - size.width))
        let y = max(area.minY, min(disk.midY - size.height / 2, area.maxY - size.height))
        flyout.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
    }

    func openConfiguration() {
        collapse()
        onConfigure?()
    }

    func openWebsite(_ url: URL) {
        collapse()
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            showError(L10n.t("Install Google Chrome to open websites.")); return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
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
    static func index(at point: CGPoint, count: Int, diameter: CGFloat = ProjectWheelController.diameter,
                      innerDiameter: CGFloat = ProjectWheelController.hubSize) -> Int? {
        let radius = diameter / 2
        let dx = point.x - radius, dy = point.y - radius
        let distance = hypot(dx, dy)
        guard count > 0, distance > innerDiameter / 2, distance <= radius else { return nil }
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
            draw(in: context, size: size)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let middle = (size.width + ProjectWheelController.diameter) / 4
        let direction: CGFloat = sin(angle) > 0.001 ? -1 : 1
        let sweep = min(CGFloat.pi, 2 * CGFloat.pi / CGFloat(count))
        let lines = Self.lines(for: name)
        for (row, line) in lines.enumerated() {
            let radius = lines.count == 1 ? middle : middle + (row == 0 ? -7 : 7)
            let glyphs: [(GraphicsContext.ResolvedText, CGFloat)] = line.map { character in
                let text = Text(verbatim: String(character)).font(T.small.weight(.medium)).foregroundColor(T.fg)
                let glyph = context.resolve(text)
                return (glyph, glyph.measure(in: size).width)
            }
            let width = glyphs.reduce(CGFloat.zero) { $0 + $1.1 }
            guard width > 0 else { continue }
            let available = (radius - 6) * sweep - 2
            let scale = min(1, available / width)
            var offset = -width * scale / 2
            for (glyph, width) in glyphs {
                let advance = width * scale
                let theta = CGFloat(angle) + direction * (offset + advance / 2) / radius
                let x = size.width / 2 + radius * cos(theta)
                let y = size.height / 2 + radius * sin(theta)
                var pen = context
                pen.translateBy(x: x, y: y)
                pen.rotate(by: .radians(Double(theta + direction * .pi / 2)))
                pen.scaleBy(x: scale, y: 1)
                pen.draw(glyph, at: .zero, anchor: .center)
                offset += advance
            }
        }
    }
}

private struct WheelModuleRing: View {
    @ObservedObject var wheel: ProjectWheelController
    @ObservedObject var preferences: WheelPreferences

    var body: some View {
        let modules = preferences.modules
        ZStack {
            Circle().fill(T.card)
            ForEach(Array(modules.enumerated()), id: \.element) { index, module in
                let sector = WheelSector(index: index, count: modules.count)
                let selected = wheel.activeModule == module
                sector.fill(selected ? T.accentSoft : T.card)
                sector.stroke(T.line, lineWidth: 1)
                Image(systemName: module.symbol).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? T.accent : T.ctlFg)
                    .offset(x: 41 * cos(sector.angle), y: 41 * sin(sector.angle))
            }
            if modules.isEmpty {
                Button(L10n.t("Wheel configuration"), action: wheel.openConfiguration).font(T.micro).offset(y: 38)
            }
        }.frame(width: ProjectWheelController.diameter, height: ProjectWheelController.diameter)
        .clipShape(Circle()).contentShape(Circle())
        .onContinuousHover { phase in
            if case .active(let p) = phase, let i = WheelSector.index(at: p, count: modules.count) {
                wheel.hoverModule(modules[i])
            } else { wheel.hoverModule(nil) }
        }
        .onTapGesture(coordinateSpace: .local) { p in
            if let i = WheelSector.index(at: p, count: modules.count) { wheel.activateModule(modules[i]) }
            else if modules.isEmpty { wheel.openConfiguration() }
        }
        .accessibilityRepresentation {
            ForEach(modules) { module in Button(module.title) { wheel.activateModule(module) } }
        }
    }
}

private struct ProjectWheelFace: View {
    @ObservedObject var wheel: ProjectWheelController
    @ReducedMotion private var reduceMotion
    @State private var hovered: String?
    @State private var blinkRequest: UUID?
    @State private var blinkFrame: NSImage?

    private var direction: CGPoint {
        let entries = wheel.visibleEntries
        if !reduceMotion, wheel.expanded, hovered == nil, let active = wheel.activeModule,
           let index = wheel.preferences.modules.firstIndex(of: active) {
            let angle = WheelSector(index: index, count: wheel.preferences.modules.count).angle
            return CGPoint(x: cos(angle), y: sin(angle))
        }
        guard !reduceMotion, wheel.expanded, let index = entries.firstIndex(where: { $0.id == hovered }) else { return .zero }
        let angle = WheelSector(index: index - entries.startIndex, count: entries.count).angle
        return CGPoint(x: cos(angle), y: sin(angle))
    }

    private func select(_ entry: WheelProject) {
        hovered = nil
        if !reduceMotion { blinkRequest = UUID() }
        wheel.open(entry)
    }

    private func mark(_ image: NSImage, tint: Color = T.fg) -> some View {
        Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().foregroundStyle(tint)
    }

    @ViewBuilder private var panda: some View {
        let layers = MenuBarIcon.wheelLayers
        if reduceMotion || layers.count != 3 || blinkFrame != nil {
            mark((reduceMotion ? nil : blinkFrame) ?? MenuBarIcon.image)
        } else {
            ZStack {
                mark(layers[0])
                ZStack {
                    mark(layers[1], tint: T.card)
                    mark(layers[2])
                }
                .rotationEffect(.degrees(10 * direction.x), anchor: UnitPoint(x: 0.5, y: 0.67))
                .offset(x: 1.6 * direction.x, y: 2.3 * direction.y)
                .animation(.easeOut(duration: 0.12), value: direction)
            }
        }
    }

    var body: some View {
        ZStack {
            if wheel.expanded && wheel.activeModule == .projects {
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
                }.frame(width: ProjectWheelController.outerDiameter, height: ProjectWheelController.outerDiameter)
                .clipShape(Circle()).contentShape(Circle())
                .onContinuousHover { phase in
                    if case .active(let p) = phase, let i = WheelSector.index(at: p, count: projects.count, diameter: ProjectWheelController.outerDiameter, innerDiameter: ProjectWheelController.diameter) {
                        wheel.hoverModule(nil)
                        hovered = projects[i].id
                    } else { hovered = nil }
                }
                .onTapGesture(coordinateSpace: .local) { p in
                    if let i = WheelSector.index(at: p, count: projects.count, diameter: ProjectWheelController.outerDiameter, innerDiameter: ProjectWheelController.diameter) { select(projects[i]) }
                }
                .onDisappear { hovered = nil }
                .help(hovered ?? "")
                .accessibilityRepresentation {
                    ForEach(projects) { entry in Button(entry.name) { select(entry) } }
                }
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            if wheel.expanded { WheelModuleRing(wheel: wheel, preferences: wheel.preferences) }
            ZStack {
                Circle().fill(T.card)
                Circle().strokeBorder(AngularGradient(colors: [.cyan, .indigo, .pink, .cyan], center: .center), lineWidth: 3)
                Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.6)
                panda.frame(width: 28, height: 28).accessibilityHidden(true)
            }.frame(width: ProjectWheelController.hubSize, height: ProjectWheelController.hubSize).contentShape(Circle())
            .onHover { if $0 { hovered = nil; wheel.hoverModule(nil); wheel.enteredHub() } }
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in wheel.dragChanged() }.onEnded { _ in wheel.dragEnded() })
            .accessibilityLabel(L10n.t("Project wheel"))
            .help(L10n.t("Drag to move the wheel."))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { inside in
            if !inside { hovered = nil }
            wheel.track(inside)
        }
        .onChange(of: wheel.activeModule) { _, _ in hovered = nil }
        .onChange(of: reduceMotion) { _, reduced in if reduced { blinkRequest = nil } }
        .task(id: blinkRequest) {
            blinkFrame = nil
            guard blinkRequest != nil, !reduceMotion else { return }
            for frame in MenuBarIcon.frames.dropLast() {
                blinkFrame = frame
                do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
            }
            blinkFrame = nil
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: wheel.expanded)
    }
}
