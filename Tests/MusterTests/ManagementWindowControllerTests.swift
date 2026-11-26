import AppKit
import Testing
import MusterCore
@testable import Muster

@Suite(.serialized) @MainActor struct ManagementWindowControllerTests {
    @Test func reopeningWindowReplaysTitlebarMark() async throws {
        let fixture = WindowFixture()
        let previous = SettingsStore.shared.reduceMotion
        defer { fixture.cleanup(); SettingsStore.shared.reduceMotion = previous }
        SettingsStore.shared.reduceMotion = .off
        for _ in 0..<2 {
            fixture.controller.open()
            let view = try #require(fixture.controller.window?.titlebarAccessoryViewControllers.first?.view)
            var samples = Set<Data>()
            for _ in 0..<14 {
                try await Task.sleep(for: .milliseconds(40))
                view.layoutSubtreeIfNeeded()
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                samples.insert(try #require(rep.representation(using: .png, properties: [:])))
            }
            #expect(samples.count >= 3)
            fixture.controller.close()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func reopeningPreservesUserFrameAndMinimumSize() async throws {
        let fixture = WindowFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller
        controller.open()
        let window = try #require(controller.window)
        #expect(window.collectionBehavior.contains(.moveToActiveSpace))
        window.setFrameAutosaveName("")
        let userFrame = try fixture.resizedFrame(for: window)
        window.setFrame(userFrame, display: false)
        #expect(window.frame == userFrame)

        for _ in 0..<3 {
            window.performClose(nil)
            #expect(window.contentViewController == nil)
            controller.open()
            try await Task.sleep(for: .milliseconds(150))
            #expect(controller.window === window)
            #expect(window.frame == userFrame)
            #expect(window.minSize.width == 880)
            #expect((560..<600).contains(window.minSize.height))
        }

        controller.openSettings(.interface)
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.frame == userFrame)
        #expect(window.minSize.width == 880 && (560..<600).contains(window.minSize.height))
    }

    @Test func openingRepairsAnAlreadyCollapsedWindow() async throws {
        let fixture = WindowFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller
        controller.open()
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        window.performClose(nil)
        // Simulate the invalid frame left by a previous app version.
        window.setFrame(NSRect(x: 300, y: 500, width: 420, height: 92), display: false)
        controller.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.frame.width >= 880 && window.frame.height >= 560)
        #expect(window.minSize.width == 880 && (560..<600).contains(window.minSize.height))
    }

    @Test func compactDefaultAndMinimumFrameSurviveReopening() async throws {
        let fixture = WindowFixture()
        defer { fixture.cleanup() }
        fixture.controller.open()
        let window = try #require(fixture.controller.window)
        window.setFrameAutosaveName("")
        #expect(window.frame.size == NSSize(width: 1000, height: 680))
        try await Task.sleep(for: .milliseconds(150))
        var compact = window.frame
        // Native toolbar/safe-area insets may add a few points to the effective minimum.
        compact.size = window.minSize
        window.setFrame(compact, display: false)
        window.performClose(nil)
        fixture.controller.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.frame == compact)
    }

    @Test func everyManagementPageKeepsScrollableContentBelowTheTitlebar() async throws {
        let fixture = WindowFixture()
        defer { fixture.cleanup() }
        fixture.controller.open()
        let window = try #require(fixture.controller.window)
        window.setFrameAutosaveName("")
        fixture.model.agentSelection.setManaged("pi", true)
        let records = (0..<50).map { Session(id: "layout-\($0)", agent: .pi, cwd: "/tmp/layout-project", startedAt: Date()) }
        fixture.model.library.observe(transcripts: records, live: [])
        await fixture.model.library.observationTask?.value
        var pages: [(PanelModel.Tab, AgentSection?)] = [(.projects, nil), (.sessions, nil), (.environment, nil)]
        pages += AgentSection.allCases.map { (.agent, $0) }
        for (tab, section) in pages {
            fixture.model.showsSettings = false
            fixture.model.tab = tab
            if let section { fixture.model.agentWorkspace.selectSection(section) }
            try await Task.sleep(for: .milliseconds(150))
            let host = try #require(window.contentViewController?.view)
            host.layoutSubtreeIfNeeded()
            let frame = host.convert(host.bounds, to: nil)
            #expect(frame.maxY <= window.contentLayoutRect.maxY + 1)
            if tab == .projects { #expect(fixture.model.projects.selected != nil) }
            let scrolls = scrollViews(in: host)
            if tab == .projects || tab == .sessions { #expect(!scrolls.isEmpty) }
            for scroll in scrolls {
                guard let document = scroll.documentView else { continue }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            #expect(host.convert(host.bounds, to: nil).maxY <= window.contentLayoutRect.maxY + 1)
            if tab == .projects, let output = ProcessInfo.processInfo.environment["MUSTER_LAYOUT_CAPTURE"],
               let frameView = window.contentView?.superview,
               let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            }
        }
        fixture.controller.openSettings(.general)
        try await Task.sleep(for: .milliseconds(150))
        let host = try #require(window.contentViewController?.view)
        #expect(host.convert(host.bounds, to: nil).maxY <= window.contentLayoutRect.maxY + 1)
    }

    @Test func managementSidebarUsesOneListAndReachesEveryDestination() async throws {
        let fixture = WindowFixture()
        defer { fixture.cleanup() }
        fixture.controller.open()
        let window = try #require(fixture.controller.window)
        window.setFrameAutosaveName("")
        var frame = window.frame
        frame.size = window.minSize
        window.setFrame(frame, display: false)
        try await Task.sleep(for: .milliseconds(150))

        let destinations: [PanelModel.Destination] = [
            .workspace(.agent), .workspace(.sessions), .wheel, .settings
        ]
        for destination in destinations {
            fixture.model.select(destination)
            try await Task.sleep(for: .milliseconds(150))
            #expect(fixture.model.destination == destination)
            let host = try #require(window.contentViewController?.view)
            host.layoutSubtreeIfNeeded()
            let sidebarScrolls = scrollViews(in: host).filter { host.convert($0.bounds, from: $0).maxX < host.bounds.midX }
            #expect(sidebarScrolls.count == 1)
            let scroll = try #require(sidebarScrolls.first)
            #expect(scroll.frame.height >= host.bounds.height - 1)
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    @Test func openingRestoresSavedFrameAcrossControllers() async throws {
        let fixture = WindowFixture()
        defer { fixture.cleanup() }
        fixture.controller.open()
        let window = try #require(fixture.controller.window)
        window.setFrame(try fixture.resizedFrame(for: window), display: false)
        let savedFrame = window.frame
        window.saveFrame(usingName: "MusterManagementWindow")
        window.setFrameAutosaveName("")
        window.performClose(nil)

        let restored = ManagementWindowController(model: fixture.model)
        defer {
            restored.window?.setFrameAutosaveName("")
            restored.close()
        }
        restored.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(restored.window?.frame == savedFrame)
    }
}

@MainActor private final class WindowFixture {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let frameKey = "NSWindow Frame MusterManagementWindow"
    private let savedFrame: Any?
    private let savedTab: Any?
    private let savedAgentSection: Any?
    private let workspaceKeys = ["MusterSelectedAgent", "MusterQuickRulesAgent", "MusterQuickConfigurationAgent", "MusterAgentNavigationV1"]
    private var savedWorkspaceDefaults: [String: Any] = [:]
    private let defaults: UserDefaults
    private let suite = "window-fixture-" + UUID().uuidString
    private let activationPolicy: NSApplication.ActivationPolicy
    let model: PanelModel
    let controller: ManagementWindowController

    init() {
        let app = NSApplication.shared
        activationPolicy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        savedFrame = UserDefaults.standard.object(forKey: frameKey)
        savedTab = UserDefaults.standard.object(forKey: PanelModel.tabKey)
        savedAgentSection = UserDefaults.standard.object(forKey: "MusterAgentSection")
        savedWorkspaceDefaults = Dictionary(uniqueKeysWithValues: workspaceKeys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        defaults = UserDefaults(suiteName: suite)!
        UserDefaults.standard.removeObject(forKey: frameKey)
        let library = SessionLibraryModel(catalog: SessionCatalog(url: root.appendingPathComponent("library.json")),
                                          historyScanner: { _ in [] })
        model = PanelModel(library: library, projectStore: ProjectStore(url: root.appendingPathComponent("projects.json")),
            projectDefaults: defaults,
            instructionsModel: InstructionsModel(sync: InstructionSync(paths: InstructionPaths(support: root.appendingPathComponent("rules").path)), detectTargets: { [] }),
            configurationModel: ConfigurationModel(presetStore: ConfigurationPresetStore(url: root.appendingPathComponent("presets.json")), detectTargets: { [] }),
            skillsModel: SkillsModel(library: SkillLibrary(root: root.appendingPathComponent("skills")), targets: []),
            detectInstalledAgents: { [] }, settingsStore: SettingsStore(defaults: defaults))
        model.tab = .sessions
        controller = ManagementWindowController(model: model)
    }

    func cleanup() {
        controller.window?.setFrameAutosaveName("")
        controller.close()
        model.stop()
        UserDefaults.standard.set(savedAgentSection, forKey: "MusterAgentSection")
        for key in workspaceKeys { UserDefaults.standard.set(savedWorkspaceDefaults[key], forKey: key) }
        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.set(savedFrame, forKey: frameKey)
        UserDefaults.standard.set(savedTab, forKey: PanelModel.tabKey)
        NSApplication.shared.setActivationPolicy(activationPolicy)
        try? FileManager.default.removeItem(at: root)
    }

    func resizedFrame(for window: NSWindow) throws -> NSRect {
        let screen = try #require(window.screen ?? NSScreen.main)
        let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let size = NSSize(width: min(1180, available.width).rounded(.down),
                          height: min(760, available.height).rounded(.down))
        try #require(size.width >= window.minSize.width && size.height >= window.minSize.height)
        // CI has a smaller screen; an off-screen fixture would exercise macOS clipping.
        return NSRect(x: (available.midX - size.width / 2).rounded(.down),
                      y: (available.midY - size.height / 2).rounded(.down),
                      width: size.width, height: size.height)
    }
}
