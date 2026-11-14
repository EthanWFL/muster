import AppKit
import Observation
import Testing
@testable import Muster

@Suite(.serialized) @MainActor struct AppearanceTests {
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
