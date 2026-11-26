import AppKit
import SwiftUI
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

    @Test func wheelProjectOrderIsManualAndPersists() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = WheelPreferences(defaults: defaults)
        prefs.reconcileProjects(["b", "a", "c"])
        #expect(prefs.projectOrder == ["b", "a", "c"])
        prefs.moveProject("c", by: -1)
        #expect(prefs.projectOrder == ["b", "c", "a"])
        prefs.moveProject("b", by: 1)
        #expect(prefs.projectOrder == ["c", "b", "a"])
        prefs.reconcileProjects(["a", "c"])
        #expect(prefs.projectOrder == ["c", "a"])
        #expect(WheelPreferences(defaults: defaults).projectOrder == ["c", "a"])
    }

    @Test func wheelOpenerPreferencesSurviveRestart() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = WheelPreferences(defaults: defaults)
        #expect(prefs.projectOpener.isEmpty && prefs.websiteOpener.isEmpty)
        prefs.setProjectOpener("com.apple.finder")
        prefs.setWebsiteOpener("com.apple.Safari")
        let next = WheelPreferences(defaults: defaults)
        #expect(next.projectOpener == "com.apple.finder")
        #expect(next.websiteOpener == "com.apple.Safari")
        #expect(WheelPreferences.installed(WheelPreferences.projectOpeners).first?.id == "")
    }

    @Test func flyoutsFollowSectorDirectionAndFitScreenCorners() {
        let area = CGRect(x: -800, y: 50, width: 800, height: 700)
        let disk = CGRect(x: -450, y: 300, width: 116, height: 116)
        let size = CGSize(width: 200, height: 238)
        func frame(_ angle: CGFloat, _ disk: CGRect) -> CGRect {
            ProjectWheelController.flyoutFrame(disk: disk, size: size, area: area, angle: angle)
        }
        #expect(frame(0, disk).minX == disk.maxX)
        #expect(frame(.pi / 2, disk).maxY == disk.minY)
        #expect(frame(.pi, disk).maxX == disk.minX)
        #expect(frame(-.pi / 2, disk).minY == disk.maxY)
        for x in [area.minX, area.maxX - disk.width] {
            for y in [area.minY, area.maxY - disk.height] {
                let corner = CGRect(origin: CGPoint(x: x, y: y), size: disk.size)
                for i in 0..<4 {
                    let popup = frame(CGFloat(i) * .pi / 2, corner)
                    #expect(area.contains(popup))
                    #expect(popup.intersection(corner).width * popup.intersection(corner).height == 0)
                }
            }
        }
    }

    @Test func clipboardURLPresentationKeepsEndOfLinkAndDistinguishesPlainText() {
        let preview = WheelFlyout.clipPreview("https://example.com:8443/projects/path/report?q=1#section")
        #expect(preview.isLink && preview.label == "example.com:8443/projects/path/report?q=1#section")
        let plain = WheelFlyout.clipPreview("https://example.com followed by text")
        #expect(!plain.isLink && plain.label.hasPrefix("https://"))
    }

    @Test func projectSectorOpensAnAdjacentFlyoutWithoutGrowingTheWheel() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PanelModel(projectDefaults: defaults)
        let wheel = model.projects.wheel
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        wheel.toggle()
        defer { if wheel.isVisible { wheel.toggle() } }
        wheel.enteredHub()
        let disk = try #require(NSApplication.shared.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.isVisible && $0.frame.width == ProjectWheelController.diameter })
        let frame = disk.frame
        wheel.activateModule(.projects)
        let popup = try #require(NSApplication.shared.windows.first {
            guard let host = $0.contentView as? NSHostingView<WheelFlyout> else { return false }
            return $0.isVisible && host.rootView.wheel === wheel && host.rootView.module == .projects
        })
        #expect(disk.frame == frame)
        #expect(!popup.frame.intersects(frame.insetBy(dx: 1, dy: 1)))
        wheel.collapse()
        #expect(!popup.isVisible)
    }

    @Test func wheelAnchorsRememberTheirSectionIndependentlyOfSettings() {
        let model = PanelModel()
        model.showSettings(.interface)
        model.showWheelSection(.websites)
        let firstRequest = model.wheelScrollRequest
        model.showWheelSection(.websites)
        #expect(model.managementPage == .wheel && model.wheelScrollRequest == firstRequest + 1)
        model.wheelSection = .clipboard  // Manual scrolling only moves the sidebar highlight.
        #expect(model.wheelScrollRequest == firstRequest + 1)
        model.showSettings(.interface)
        #expect(model.wheelSection == .clipboard && model.settingsSection == .interface)
    }

    @Test func wheelConfigurationChatAndHideActions() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PanelModel(projectDefaults: defaults)
        let wheel = model.projects.wheel
        wheel.onOpenPage = { model.managementPage = $0 }
        defer { wheel.onOpenPage = nil; if wheel.isVisible { wheel.toggle() } }
        wheel.toggle()
        wheel.enteredHub(); wheel.activateModule(.actions)
        #expect(wheel.activeModule == .actions)
        wheel.openConfiguration()
        #expect(model.managementPage == .wheel && !model.showsSettings && !wheel.expanded)
        wheel.enteredHub(); wheel.activateModule(.actions)
        wheel.openPage(.chat)
        #expect(model.managementPage == .chat && !wheel.expanded && wheel.activeModule == nil)
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

extension WheelConfigurationTests {
    @Test func wheelSectorsKeepFixedSlotsWhenModulesChange() {
        #expect(WheelModule.allCases == [.projects, .websites, .clipboard, .actions])
        let d = ProjectWheelController.diameter
        func slot(_ x: CGFloat, _ y: CGFloat) -> Int? {
            WheelSector.index(at: CGPoint(x: x, y: y), count: WheelModule.allCases.count)
        }
        #expect(slot(d / 2, 1) == 0)
        #expect(slot(d - 1, d / 2) == 1)
        #expect(slot(d / 2, d - 1) == 2)
        #expect(slot(1, d / 2) == 3)
    }

    @Test func clickTogglesWheelExpansion() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PanelModel(projectDefaults: defaults)
        let wheel = model.projects.wheel
        wheel.toggle()
        defer { if wheel.isVisible { wheel.toggle() } }
        wheel.enteredHub()
        #expect(wheel.expanded)
        wheel.toggleExpanded()
        #expect(!wheel.expanded)
        wheel.toggleExpanded()
        #expect(wheel.expanded)
    }

    @Test func resettingWheelPositionClearsTheSavedAnchor() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(NSStringFromPoint(NSPoint(x: 10, y: 10)), forKey: "MusterProjectWheelCenter")
        let model = PanelModel(projectDefaults: defaults)
        model.projects.wheel.resetPosition()
        #expect(defaults.object(forKey: "MusterProjectWheelCenter") == nil)
    }
}
