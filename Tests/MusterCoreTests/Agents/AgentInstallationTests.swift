import Foundation
import Testing
@testable import MusterCore

@Suite struct AgentInstallationTests {
    @Test func emptyHomeAndResidualConfigurationAreNotInstalledAgents() throws {
        let tree = try TempTree()
        #expect(AgentInstallation.detect(home: tree.root, environment: [:], executableDirectories: [], applicationDirectories: []).isEmpty)
        try tree.write(".claude/settings.json", "{}")
        try tree.write(".codex/config.toml", "model = \"old\"")
        try tree.write(".agents/skills/test/SKILL.md", "left behind")
        try tree.write(".pi/agent/settings.json", "{}")
        #expect(AgentInstallation.detect(home: tree.root, environment: [:], executableDirectories: [], applicationDirectories: []).isEmpty)
    }

    @Test func onlyExecutableCLIsAreListedWithoutRunningThem() throws {
        let tree = try TempTree()
        let claude = try tree.write("bin/claude", "#!/bin/sh\ntouch \"" + tree.path("ran") + "\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude)
        try tree.write("bin/pi", "not executable")
        try FileManager.default.createSymbolicLink(atPath: tree.path("bin/codex"), withDestinationPath: tree.path("missing"))
        let found = AgentInstallation.detect(home: tree.root, environment: [:], executableDirectories: [tree.path("bin")], applicationDirectories: [])
        #expect(found.map(\.id) == ["claude"])
        #expect(!FileManager.default.fileExists(atPath: tree.path("ran")))
    }
}

extension AgentInstallationTests {
    @Test func applicationRequiresValidMetadataAndItsExecutable() throws {
        let tree = try TempTree()
        let app = "apps/Warp.app/Contents/"
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "dev.warp.Warp-Stable", "CFBundleExecutable": "stable"]
        _ = try tree.write(app + "Info.plist", "")
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: tree.path(app + "Info.plist")))
        #expect(AgentInstallation.detect(home: tree.root, environment: [:], executableDirectories: [], applicationDirectories: [tree.path("apps")]).isEmpty)
        let binary = try tree.write(app + "MacOS/stable", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary)
        #expect(AgentInstallation.detect(home: tree.root, environment: [:], executableDirectories: [], applicationDirectories: [tree.path("apps")]).map(\.id) == ["warp"])
        try FileManager.default.removeItem(atPath: binary)
        #expect(AgentInstallation.detect(home: tree.root, environment: [:], executableDirectories: [], applicationDirectories: [tree.path("apps")]).isEmpty)
    }

    @Test func codexBundledInsideChatGPTDoesNotRequireShellPATH() throws {
        let tree = try TempTree()
        let prefix = "apps/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/"
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.openai.codex.cli", "CFBundleExecutable": "codex"]
        _ = try tree.write(prefix + "Info.plist", "")
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: tree.path(prefix + "Info.plist")))
        let binary = try tree.write(prefix + "MacOS/codex", "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary)
        #expect(AgentInstallation.detect(home: tree.root, environment: ["PATH": "/empty"], executableDirectories: [], applicationDirectories: [tree.path("apps")]).map(\.id) == ["codex"])
    }
}
