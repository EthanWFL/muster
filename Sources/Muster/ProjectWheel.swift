import AppKit
import Combine
import MusterCore
import SwiftUI

struct ProjectWheelToggle: View {
    static let symbol = "circle.grid.cross"
    @ObservedObject var wheel: ProjectWheelController

    var body: some View {
        IconButton(symbol: wheel.isVisible ? Self.symbol + ".fill" : Self.symbol,
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
    @Published private(set) var notice: String?
    let preferences: WheelPreferences
    var onOpenPage: ((PanelModel.ManagementPage) -> Void)?
    @Published var pointerInFlyout = false
    private var lastModulePoint: CGPoint?
    private var flyout: NSPanel?
    private var noticePanel: NSPanel?
    private var noticeTask: Task<Void, Never>?
    private var allEntries: [WheelProject] = []
    private var selectionTask: Task<Void, Never>?
    private var candidate: WheelModule?
    private var preferenceObservation: AnyCancellable?
    private var orderObservation: AnyCancellable?
    private let defaults: UserDefaults
    private var panel: NSPanel?
    private var anchor: CGPoint = .zero
    private var expandedCenter: CGPoint?
    private var hoverBeforeResize: CGPoint?
    private var observation: AnyCancellable?
    private var press: (mouse: CGPoint, center: CGPoint)?
    private var dragging = false
    private var pendingCollapse: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private static let positionKey = "MusterProjectWheelCenter"
    nonisolated static let hubSize: CGFloat = 48
    nonisolated static let ringWidth: CGFloat = 34
    nonisolated static let diameter = hubSize + 2 * ringWidth
    @Published private(set) var blinkRequest: UUID?
    var visibleEntries: ArraySlice<WheelProject> { entries.prefix(6) }

    private func recomputeEntries(order: [String]? = nil) {
        let order = order ?? preferences.projectOrder
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        entries = allEntries.sorted {
            let lhs = rank[$0.id] ?? Int.max
            let rhs = rank[$1.id] ?? Int.max
            return lhs != rhs ? lhs < rhs : $0.id < $1.id
        }
    }

    init(projects: ProjectsModel, defaults: UserDefaults, board: NSPasteboard = .general) {
        self.defaults = defaults
        preferences = WheelPreferences(defaults: defaults, board: board)
        super.init()
        preferenceObservation = preferences.$modules.dropFirst().sink { [weak self] _ in self?.collapse() }
        observation = projects.$projects.map { projects in
            projects.filter { $0.record?.wheelMember == true }
                .map { WheelProject(id: $0.path, name: $0.name) }
        }.removeDuplicates().sink { [weak self] entries in
            guard let self else { return }
            self.allEntries = entries
            self.preferences.reconcileProjects(entries.map(\.id))
            self.recomputeEntries()
        }
        orderObservation = preferences.$projectOrder.sink { [weak self] order in
            self?.recomputeEntries(order: order)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func toggle() {
        if isVisible {
            pendingCollapse?.cancel()
            expandTask?.cancel()
            noticeTask?.cancel()
            noticePanel?.orderOut(nil)
            noticePanel = nil
            notice = nil
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

    /// Leaving Muster for another app should put the ring away; the hub stays.
    @objc private func applicationActivated(_ notification: Notification) {
        guard isVisible else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        collapse()
    }

    private func layout() {
        guard let screen = screen(at: anchor) else { return }
        let area = screen.visibleFrame
        let resting = Self.frame(center: anchor, diameter: Self.hubSize, within: area)
        anchor = CGPoint(x: resting.midX, y: resting.midY)
        let frame = expanded ? Self.frame(center: expandedCenter ?? anchor, diameter: Self.diameter, within: area) : resting
        expandedCenter = expanded ? CGPoint(x: frame.midX, y: frame.midY) : nil
        if expanded, panel?.frame != frame { hoverBeforeResize = NSEvent.mouseLocation }
        panel?.setFrame(frame, display: true)
        positionFlyout()
    }

    /// Hovering only expands after a short dwell, so passing over the hub is harmless.
    func hoverHub(_ inside: Bool) {
        expandTask?.cancel()
        guard inside, isVisible, !expanded, press == nil else { return }
        hoverModule(nil)
        expandTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            self?.enteredHub()
        }
    }

    func enteredHub() {
        expandTask?.cancel()
        pendingCollapse?.cancel()
        guard isVisible, !expanded, press == nil else { return }
        expanded = true
        layout()
    }

    func toggleExpanded() {
        if expanded { collapse() } else { enteredHub() }
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
        expandTask?.cancel()
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
        if !dragging { resetModule(); expandTask?.cancel() }
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
            // A click is a deterministic expand/collapse, independent of hover.
            toggleExpanded()
        }
    }

    func resetPosition() {
        defaults.removeObject(forKey: Self.positionKey)
        guard let screen = screen(at: NSEvent.mouseLocation) else { return }
        anchor = CGPoint(x: screen.visibleFrame.maxX - 60, y: screen.visibleFrame.midY)
        resetModule()
        expanded = false
        if isVisible { layout() }
    }

    func open(_ entry: WheelProject) {
        blinkRequest = UUID()
        collapse()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.id, isDirectory: &directory), directory.boolValue else {
            showNotice(L10n.t("Project folder unavailable: %@", entry.id)); return
        }
        openURL(URL(fileURLWithPath: entry.id, isDirectory: true),
                bundleID: preferences.projectOpener,
                missingApp: L10n.t("The selected project app is not installed. Opened with the system default."))
    }

    private func resetModule() {
        hoverModule(nil)
        activeModule = nil
        closeFlyout()
    }

    private func closeFlyout() {
        pointerInFlyout = false
        lastModulePoint = nil
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
        let mouse = NSEvent.mouseLocation
        let approaching = flyout.map { popup in
            let f = popup.frame
            func distance(_ p: CGPoint) -> CGFloat {
                return hypot(max(f.minX - p.x, p.x - f.maxX, 0), max(f.minY - p.y, p.y - f.maxY, 0))
            }
            return lastModulePoint.map { distance(mouse) + 0.5 < distance($0) } ?? false
        } ?? false
        lastModulePoint = mouse
        guard candidate != module || (approaching && module != activeModule) else { return }
        selectionTask?.cancel()
        candidate = module
        guard let module, module != activeModule else { return }
        selectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(approaching ? 350 : 150)) } catch { return }
            guard self?.flyout?.frame.contains(NSEvent.mouseLocation) != true else { return }
            self?.activateModule(module)
        }
    }

    func activateModule(_ module: WheelModule) {
        guard expanded, preferences.modules.contains(module), activeModule != module else { return }
        closeFlyout()
        activeModule = module
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
        let modules = preferences.modules
        guard let index = modules.firstIndex(of: module) else { return }
        let angle = WheelSector(index: index, count: modules.count).angle
        flyout.setFrame(Self.flyoutFrame(disk: disk, size: size, area: area, angle: angle), display: true)
    }

    static func flyoutFrame(disk: CGRect, size: CGSize, area: CGRect, angle: CGFloat) -> CGRect {
        // SwiftUI angles increase clockwise; screen coordinates increase upwards.
        let dx = cos(angle), dy = -sin(angle)
        let anchor = CGPoint(x: disk.midX + dx * disk.width / 2, y: disk.midY + dy * disk.height / 2)
        let x = max(area.minX, min(anchor.x - size.width / 2, area.maxX - size.width))
        let y = max(area.minY, min(anchor.y - size.height / 2, area.maxY - size.height))
        let options: [(CGFloat, CGPoint)] = [
            (dx, CGPoint(x: disk.maxX, y: y)), (-dx, CGPoint(x: disk.minX - size.width, y: y)),
            (dy, CGPoint(x: x, y: disk.maxY)), (-dy, CGPoint(x: x, y: disk.minY - size.height))
        ]
        let frames = options.sorted { $0.0 > $1.0 }.map { CGRect(origin: $0.1, size: size) }
        if let fit = frames.first(where: area.contains) { return fit }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    func openConfiguration() {
        openPage(.wheel)
    }

    func openPage(_ page: PanelModel.ManagementPage) {
        collapse()
        onOpenPage?(page)
    }

    func openWebsite(_ url: URL) {
        collapse()
        openURL(url, bundleID: preferences.websiteOpener,
                missingApp: L10n.t("The selected browser is not installed. Opened with the system default."))
    }

    private func openURL(_ url: URL, bundleID: String, missingApp: String) {
        guard !bundleID.isEmpty else {
            NSWorkspace.shared.open(url)
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            showNotice(missingApp)
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.showNotice(error.localizedDescription) } }
        }
    }

    private func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticePanel?.orderOut(nil)
        noticePanel = nil

        guard let disk = panel?.frame, let area = screen(at: anchor)?.visibleFrame else {
            scheduleNoticeClear()
            return
        }
        let width = min(max((message as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]).width + 24, 160), 320)
        let size = CGSize(width: width, height: 44)
        let x = min(max(disk.midX - width / 2, area.minX), area.maxX - width)
        let y = disk.minY - size.height - 8 >= area.minY ? disk.minY - size.height - 8 : disk.maxY + 8

        let popup = NSPanel(contentRect: CGRect(origin: CGPoint(x: x, y: y), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.level = .floating
        popup.hidesOnDeactivate = false
        popup.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: WheelNotice(message: message).frame(width: size.width, height: size.height))
        host.sizingOptions = []
        popup.contentView = host
        noticePanel = popup
        popup.orderFrontRegardless()
        scheduleNoticeClear()
    }

    private func scheduleNoticeClear() {
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
            self?.noticePanel?.orderOut(nil)
            self?.noticePanel = nil
        }
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

private struct WheelModuleRing: View {
    @ObservedObject var wheel: ProjectWheelController
    @ObservedObject var preferences: WheelPreferences

    /// Angles follow the declaration order, so toggling a module never moves the others.
    private let slots = WheelModule.allCases

    var body: some View {
        let modules = preferences.modules
        ZStack {
            Circle().fill(T.card)
            ForEach(modules) { module in
                if let slot = slots.firstIndex(of: module) {
                    let sector = WheelSector(index: slot, count: slots.count)
                    let selected = wheel.activeModule == module
                    sector.fill(selected && !wheel.pointerInFlyout ? T.accentSoft : T.card)
                        .contentShape(sector)
                        .help(module.title)
                        .pointerCursor()
                    sector.stroke(T.line, lineWidth: 1)
                    Image(systemName: module.symbol).font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selected ? T.accent : T.ctlFg)
                        .offset(x: 41 * cos(sector.angle), y: 41 * sin(sector.angle))
                        .help(module.title)
                        .accessibilityHidden(true)
                }
            }
            if modules.isEmpty {
                Button(L10n.t("Wheel configuration"), action: wheel.openConfiguration).font(T.micro).offset(y: 38)
            }
        }.frame(width: ProjectWheelController.diameter, height: ProjectWheelController.diameter)
        .clipShape(Circle()).contentShape(Circle())
        .onContinuousHover { phase in
            if case .active(let point) = phase, let module = module(at: point, modules: modules) {
                wheel.hoverModule(module)
            } else { wheel.hoverModule(nil) }
        }
        .onTapGesture(coordinateSpace: .local) { point in
            if let module = module(at: point, modules: modules) {
                wheel.activateModule(module)
            } else if modules.isEmpty {
                wheel.openConfiguration()
            }
        }
        .accessibilityRepresentation {
            ForEach(modules) { module in Button(module.title) { wheel.activateModule(module) } }
        }
    }

    private func module(at point: CGPoint, modules: [WheelModule]) -> WheelModule? {
        guard let slot = WheelSector.index(at: point, count: slots.count),
              slots.indices.contains(slot), modules.contains(slots[slot]) else { return nil }
        return slots[slot]
    }
}

private struct ProjectWheelFace: View {
    @ObservedObject var wheel: ProjectWheelController
    @ReducedMotion private var reduceMotion
    @State private var blinkFrame: NSImage?

    private var direction: CGPoint {
        guard !reduceMotion, wheel.expanded, let active = wheel.activeModule,
              let index = wheel.preferences.modules.firstIndex(of: active) else { return .zero }
        let angle = WheelSector(index: index, count: wheel.preferences.modules.count).angle
        return CGPoint(x: cos(angle), y: sin(angle))
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
            if wheel.expanded { WheelModuleRing(wheel: wheel, preferences: wheel.preferences) }
            ZStack {
                Circle().fill(T.card)
                Circle().strokeBorder(AngularGradient(colors: [T.accent, T.accent.opacity(0.55), T.accent], center: .center), lineWidth: 3)
                Circle().strokeBorder(T.line, lineWidth: 0.6)
                panda.frame(width: 28, height: 28).accessibilityHidden(true)
            }.frame(width: ProjectWheelController.hubSize, height: ProjectWheelController.hubSize).contentShape(Circle())
            .pointerCursor()
            .onHover { wheel.hoverHub($0) }
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in wheel.dragChanged() }.onEnded { _ in wheel.dragEnded() })
            .contextMenu {
                Button(L10n.t("Wheel configuration")) { wheel.openConfiguration() }
                Button(L10n.t(wheel.isVisible ? "Hide wheel" : "Start wheel")) { wheel.toggle() }
                Divider()
                Button(L10n.t("Reset position")) { wheel.resetPosition() }
            }
            .accessibilityLabel(L10n.t("Project wheel"))
            .help(L10n.t("Click to open · Drag to move."))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { wheel.track($0) }
        .task(id: wheel.blinkRequest) {
            blinkFrame = nil
            guard wheel.blinkRequest != nil, !reduceMotion else { return }
            for frame in MenuBarIcon.frames.dropLast() {
                blinkFrame = frame
                do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
            }
            blinkFrame = nil
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: wheel.expanded)
    }
}

private struct WheelNotice: View {
    let message: String

    var body: some View {
        Text(message)
            .font(T.micro)
            .foregroundStyle(T.red)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: T.r).fill(T.card))
            .overlay(RoundedRectangle(cornerRadius: T.r).strokeBorder(T.line, lineWidth: 1))
    }
}
