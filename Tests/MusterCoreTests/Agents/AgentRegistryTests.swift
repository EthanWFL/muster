import Foundation
import Testing
@testable import MusterCore

@Suite struct AgentRegistryTests {
    @Test func capabilitiesMatchExistingIntegrations() {
        #expect(Set(AgentRegistry.all.map(\.id)).count == AgentRegistry.all.count)
        #expect(Set(AgentRegistry.all.compactMap(\.kind)) == Set(AgentKind.allCases))
        #expect(Set(AgentRegistry.all.filter(\.tracksActivity).map(\.id)) == ["claude", "codex", "pi"])
        #expect(Set(AgentRegistry.all.filter(\.editableConfiguration).map(\.id)) == ["codex", "pi"])
        #expect(AgentRegistry.all.filter(\.resumesSessions).allSatisfy { $0.tracksActivity })
        #expect(AgentRegistry.kind(forArgs: ["node", "/npm/@openai/codex/bin/codex.js"]) == .codex)
        #expect(AgentRegistry.kind(forArgs: ["node", "my-codex-server.js"]) == nil)
    }

    @Test func customHomesAreSharedByConfigurationRulesAndTranscripts() throws {
        let home = "/test/home"
        let environment = ["CODEX_HOME": "~/work/codex", "PI_CODING_AGENT_DIR": "/custom/pi"]
        let codex = try #require(AgentRegistry.agent("codex"))
        #expect(codex.transcript?.resolve(home: home, environment: environment) == "/test/home/work/codex/sessions")
        let configurations = AgentConfiguration.detect(home: home, environment: environment, exists: { _ in true })
        #expect(configurations.map(\.id) == ["codex", "pi", "claude", "hermes", "cursor", "warp", "magpie"])
        #expect(configurations.first?.path == "/test/home/work/codex/config.toml")
        let rules = InstructionTargets.detect(home: home, environment: environment,
            exists: { $0 == "/test/home/work/codex/AGENTS.md" })
        #expect(rules.first { $0.id == "codex" }?.path == "/test/home/work/codex/AGENTS.md")
    }

    @Test func homeDirectoryAloneDoesNotMarkCursorInstalled() {
        let targets = InstructionTargets.detect(home: "/home/test", environment: [:], exists: { $0 == "/home/test" })
        #expect(targets.first { $0.id == "cursor" }?.installed == false)
    }

    @Test func diagnosticsReadFilesWithoutExecutingAgentsOrChangingThem() throws {
        let tree = try TempTree()
        let config = #"{"defaultProvider":"p","defaultModel":"m"}"#
        try tree.write(".pi/agent/settings.json", config)
        try tree.write(".pi/agent/AGENTS.md", "rules")
        try tree.write(".codex/config.toml", "model = 42")
        let executable = try tree.write("bin/pi", "#!/bin/sh\ntouch '" + tree.path("executed") + "'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        let reports = AgentDiagnostics.scan(home: tree.root, environment: ["PATH": tree.path("bin")])
        let pi = try #require(reports.first { $0.id == "pi" })
        #expect(pi.executablePath == executable)
        #expect(pi.configurationState == .readable)
        #expect(pi.rulesState == .readable)
        #expect(reports.first { $0.id == "codex" }?.configurationState == .unsupported)
        #expect(reports.first { $0.id == "hermes" }?.configurationState == .missing)
        #expect(!FileManager.default.fileExists(atPath: tree.path("executed")))
        #expect(try String(contentsOfFile: tree.path(".pi/agent/settings.json"), encoding: .utf8) == config)
        try tree.write(".pi/agent/settings.json", "{broken}")
        #expect(AgentDiagnostics.scan(home: tree.root, environment: [:]).first { $0.id == "pi" }?.configurationState == .invalid)
    }
}
