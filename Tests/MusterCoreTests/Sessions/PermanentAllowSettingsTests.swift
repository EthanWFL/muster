import Foundation
import Testing
@testable import MusterCore

@Suite struct PermanentAllowSettingsTests {
    let hookPath = "/opt/muster/muster-hook"

    struct Env {
        let dir: URL
        let settings: URL
        let backups: URL
    }

    func makeEnv(json: String? = nil) throws -> Env {
        let dir = try makeSessionsTempDir("permanent")
        let settings = dir.appendingPathComponent("claude/settings.json")
        if let json {
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: settings)
        }
        return Env(dir: dir, settings: settings, backups: dir.appendingPathComponent("backups"))
    }

    func installer(_ env: Env) -> ClaudeHookInstaller {
        ClaudeHookInstaller(
            settingsURL: env.settings, backupRoot: env.backups, hookExecutable: hookPath,
            clock: SessionsTestClock(), log: { _ in })
    }

    func root(_ env: Env) throws -> NSDictionary {
        let data = try Data(contentsOf: env.settings)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func readsExistingRulesInFileOrder() throws {
        let env = try makeEnv(json: """
        {"theme": "dark", "permissions": {"allow": ["Bash(git status)", "Read(/tmp/x)"]}}
        """)
        defer { removeSessionsTempDir(env.dir) }
        #expect(try installer(env).allowRules() == ["Bash(git status)", "Read(/tmp/x)"])
    }

    @Test func missingPermissionsMeansNoRules() throws {
        let env = try makeEnv(json: "{\"theme\": \"dark\"}")
        defer { removeSessionsTempDir(env.dir) }
        #expect(try installer(env).allowRules().isEmpty)
    }

    @Test func appendsRuleWithBackupAndPreservesOtherKeys() throws {
        let env = try makeEnv(json: """
        {"theme": "dark", "permissions": {"allow": ["Bash(git status)"], "deny": ["Bash(rm)"]}}
        """)
        defer { removeSessionsTempDir(env.dir) }
        let inst = installer(env)

        let backup = try #require(try inst.addAllowRule("Bash(touch out.txt)"))
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try inst.allowRules() == ["Bash(git status)", "Bash(touch out.txt)"])

        let root = try root(env)
        #expect(root["theme"] as? String == "dark")
        let permissions = try #require(root["permissions"] as? NSDictionary)
        #expect((permissions["deny"] as? [String]) == ["Bash(rm)"])
    }

    @Test func addingTheSameRuleTwiceIsANoOp() throws {
        let env = try makeEnv(json: """
        {"permissions": {"allow": ["Bash(touch out.txt)"]}}
        """)
        defer { removeSessionsTempDir(env.dir) }
        let inst = installer(env)
        let before = try Data(contentsOf: env.settings)

        #expect(try inst.addAllowRule("  Bash(touch out.txt)  ") == nil)
        #expect(try Data(contentsOf: env.settings) == before)
        #expect(try inst.allowRules() == ["Bash(touch out.txt)"])
    }

    @Test func createsPermissionsWhenMissing() throws {
        let env = try makeEnv(json: "{}")
        defer { removeSessionsTempDir(env.dir) }
        let inst = installer(env)
        try inst.addAllowRule("Bash(ls)")
        #expect(try inst.allowRules() == ["Bash(ls)"])
    }

    @Test func refusesUnknownShapesWithoutWriting() throws {
        let cases = [
            "{\"permissions\": \"nope\"}",
            "{\"permissions\": {\"allow\": \"nope\"}}",
            "{\"permissions\": {\"allow\": [1]}}",
        ]
        for text in cases {
            let env = try makeEnv(json: text)
            defer { removeSessionsTempDir(env.dir) }
            let inst = installer(env)
            #expect(throws: AdapterError.self) { try inst.allowRules() }
            #expect(throws: AdapterError.self) { try inst.addAllowRule("Bash(ls)") }
            #expect(try Data(contentsOf: env.settings) == Data(text.utf8))
        }
    }
}
