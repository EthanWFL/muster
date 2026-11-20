import AppKit
import Testing
import MusterCore
@testable import Muster

@Suite @MainActor struct WheelConfigurationTests {
    @Test func clipboardOptInPrivacyDeduplicationLimitAndRestoration() throws {
        let board = NSPasteboard.withUniqueName()
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally() }
        let prefs = WheelPreferences(defaults: defaults, board: board)
        func copy(_ text: String) { board.clearContents(); board.setString(text, forType: .string); prefs.sample() }
        copy("before enabling")
        #expect(prefs.clips.isEmpty)
        prefs.setRecording(true)
        prefs.sample()
        #expect(prefs.clips.isEmpty)
        for i in 0..<12 { copy("\(i)\nfull original") }
        #expect(prefs.clips.count == 10 && prefs.clips.last == "2\nfull original")
        let last = try #require(prefs.clips.last)
        prefs.restore(last)
        prefs.sample()
        #expect(board.string(forType: .string) == last && prefs.clips.first == last && prefs.clips.count == 10)
        copy(last)
        #expect(prefs.clips.count == 10)
        board.clearContents(); board.setString("private", forType: .string)
        board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")); prefs.sample()
        #expect(!prefs.clips.contains("private"))
        prefs.clear(); prefs.sample(); #expect(prefs.clips.isEmpty)
        copy("last"); prefs.setRecording(false); copy("disabled"); #expect(prefs.clips.isEmpty)
    }

    @Test func websiteAndModuleConfigurationSurviveRestart() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = WheelPreferences(defaults: defaults)
        #expect(!prefs.addWebsite("file:///tmp/test") && !prefs.addWebsite("https://u:p@example.org"))
        for i in 0..<6 { #expect(prefs.addWebsite("example.org/path/\(i)")) }
        #expect(!prefs.addWebsite("example.org/overflow"))
        prefs.removeWebsite(prefs.websites[0]); #expect(!prefs.addWebsite("example.org/path/1"))
        prefs.toggle(.clipboard)
        let next = WheelPreferences(defaults: defaults)
        #expect(next.websites == prefs.websites && next.modules == [.projects,.websites,.actions])
    }

    @Test func outerRingUsesOnlyProjectBand() {
        let d = ProjectWheelController.outerDiameter, inner = ProjectWheelController.diameter
        let center = CGPoint(x: d / 2, y: d / 2)
        for count in 1...6 {
            for index in 0..<count {
                let angle = WheelSector(index: index, count: count).angle
                for r in [inner / 2 + 1, d / 2 - 1] {
                    let p = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
                    #expect(WheelSector.index(at: p, count: count, diameter: d, innerDiameter: inner) == index)
                }
            }
            #expect(WheelSector.index(at: center, count: count, diameter: d, innerDiameter: inner) == nil)
        }
    }

    @Test func wheelConfigurationAndHideActions() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PanelModel(projectDefaults: defaults)
        let wheel = model.projects.wheel
        wheel.onConfigure = { model.managementPage = .wheel }
        defer { wheel.onConfigure = nil; if wheel.isVisible { wheel.toggle() } }
        wheel.toggle()
        wheel.enteredHub(); wheel.activateModule(.actions)
        #expect(wheel.activeModule == .actions)
        wheel.openConfiguration()
        #expect(model.managementPage == .wheel && !model.showsSettings && !wheel.expanded)
        wheel.enteredHub(); wheel.activateModule(.actions); wheel.toggle()
        #expect(!wheel.isVisible && wheel.activeModule == nil)
        model.showsSettings = false
        #expect(model.managementPage == .workspace)
    }

    @Test func projectStoreEnforcesSixMembers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(url: root.appendingPathComponent("p.json"))
        for i in 0..<6 { _ = try await store.setWheelMember("/project/\(i)", true) }
        await #expect(throws: ProjectStoreError.wheelLimit) { try await store.setWheelMember("/project/6", true) }
        _ = try await store.setWheelMember("/project/0", false)
        let snapshot = try await store.setWheelMember("/project/6", true)
        #expect(snapshot.records.filter { $0.wheelMember == true }.count == 6)
    }
}
