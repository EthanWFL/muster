import AppKit
import Observation
import SwiftUI
import Testing
@testable import Muster

@Suite(.serialized) @MainActor struct AppearanceTests {
    @Test func menuBarUsesTheOpenEyedPandaFrame() {
        let frames = MenuBarIcon.frames
        #expect(frames.count == 7)
        #expect(frames.allSatisfy { $0.isTemplate && $0.size == NSSize(width: 18, height: 18) })
        #expect(frames.last === MenuBarIcon.image)
    }

    @Test func visibleBrandMarkMovesOnEachOpeningThenSettles() async throws {
        struct Header: View {
            @ObservedObject var surface: PanelSurfaceState
            var body: some View { BrandMark(isPanelOpen: surface.isVisible) }
        }
        let previous = SettingsStore.shared.reduceMotion
        defer { SettingsStore.shared.reduceMotion = previous }
        SettingsStore.shared.reduceMotion = .off
        let surface = PanelSurfaceState()
        surface.isVisible = false
        let host = NSHostingView(rootView: Header(surface: surface))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 24, height: 24),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func pixels() throws -> Data {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.coderInvalidValue) }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
            return png
        }
        try await Task.sleep(for: .milliseconds(100))
        let settled = try pixels()
        for _ in 0..<2 {
            surface.isVisible = true
            var samples = Set<Data>()
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(100))
                samples.insert(try pixels())
            }
            #expect(samples.count >= 3)
            try await Task.sleep(for: .milliseconds(200))
            #expect(try pixels() == settled)
            surface.isVisible = false
            try await Task.sleep(for: .milliseconds(80))
        }
        SettingsStore.shared.reduceMotion = .on
        surface.isVisible = true
        try await Task.sleep(for: .milliseconds(180))
        #expect(try pixels() == settled)
    }

    @Test func appearanceDefaultsToSystemAndIgnoresUnknownSavedValues() throws {
        let suite = "MusterTests.Appearance." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SettingsStore(defaults: defaults).appearance == .system)
        defaults.set("unknown", forKey: "MusterAppearance")
        #expect(SettingsStore(defaults: defaults).appearance == .system)
    }

    @Test func selectingAppearanceUpdatesNativeAndCustomColorsAndPersists() throws {
        let suite = "MusterTests.Appearance." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = NSApplication.shared
        let original = app.appearance
        defer {
            defaults.removePersistentDomain(forName: suite)
            app.appearance = original
            Theme.shared.refresh()
        }
        let store = SettingsStore(defaults: defaults)

        for choice in [AppAppearance.dark, .light, .system] {
            store.appearance = choice
            #expect(SettingsStore(defaults: defaults).appearance == choice)
            switch choice {
            case .dark:
                #expect(app.appearance?.name == .darkAqua)
                #expect(Theme.shared.isDark)
            case .light:
                #expect(app.appearance?.name == .aqua)
                #expect(!Theme.shared.isDark)
            case .system:
                #expect(app.appearance == nil)
                #expect(Theme.shared.isDark == (app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua))
            }
        }
    }

    @Test func savedAppearanceAppliesBeforeCreatingAWindow() throws {
        let suite = "MusterTests.Appearance." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = NSApplication.shared
        let original = app.appearance
        defer {
            defaults.removePersistentDomain(forName: suite)
            app.appearance = original
            Theme.shared.refresh()
        }
        defaults.set(AppAppearance.dark.rawValue, forKey: "MusterAppearance")
        app.appearance = NSAppearance(named: .aqua)

        Theme.shared.apply(SettingsStore(defaults: defaults).appearance)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(Theme.shared.isDark)
    }

    @Test func followsEffectiveAppearanceWithoutActivationOrDistributedNotification() async throws {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original; Theme.shared.refresh() }
        app.appearance = NSAppearance(named: .aqua)
        Theme.shared.refresh()
        #expect(!Theme.shared.isDark)

        app.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Theme.shared.isDark)
        app.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!Theme.shared.isDark)
    }

    @Test func nestedViewsReadingTokensAreInvalidatedWhenAppearanceChanges() async {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original; Theme.shared.refresh() }
        app.appearance = NSAppearance(named: .aqua)
        Theme.shared.refresh()

        await confirmation("A view that only reads color tokens must observe their appearance dependency") { changed in
            withObservationTracking {
                _ = T.card
                _ = T.fg
            } onChange: {
                changed()
            }
            app.appearance = NSAppearance(named: .darkAqua)
            Theme.shared.refresh()
        }
    }
}
