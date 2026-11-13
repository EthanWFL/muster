import AppKit
import Testing
import MusterCore
@testable import Muster

@Suite(.serialized) @MainActor struct ManagementWindowControllerTests {
    @Test func reopeningPreservesUserFrameAndMinimumSize() async throws {
        let fixture = WindowFixture()
        defer { fixture.cleanup() }
        let controller = fixture.controller
        controller.open()
        let window = try #require(controller.window)
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
            #expect(window.minSize.width >= 960)
            #expect(window.minSize.height >= 600)
        }

        controller.openSettings(.interface)
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.frame == userFrame)
        #expect(window.minSize.width >= 960 && window.minSize.height >= 600)
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
        #expect(window.frame.width >= 960 && window.frame.height >= 600)
        #expect(window.minSize.width >= 960 && window.minSize.height >= 600)
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
    private let activationPolicy: NSApplication.ActivationPolicy
    let model: PanelModel
    let controller: ManagementWindowController

    init() {
        let app = NSApplication.shared
        activationPolicy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        savedFrame = UserDefaults.standard.object(forKey: frameKey)
        savedTab = UserDefaults.standard.object(forKey: PanelModel.tabKey)
        UserDefaults.standard.removeObject(forKey: frameKey)
        let library = SessionLibraryModel(catalog: SessionCatalog(url: root.appendingPathComponent("library.json")),
                                          historyScanner: { _ in [] })
        model = PanelModel(library: library)
        model.tab = .sessions
        controller = ManagementWindowController(model: model)
    }

    func cleanup() {
        controller.window?.setFrameAutosaveName("")
        controller.close()
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
