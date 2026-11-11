import Foundation
import Testing
@testable import MusterCore

/// Every test works on a settings file inside a temp directory. The real ~/.claude/settings.json is never used.
@Suite("ClaudeHookInstaller")
struct ClaudeHookInstallerTests {
    let hookPath = "/opt/muster/muster-hook"

    struct Env {
        let dir: URL
        let settings: URL
        let backups: URL
    }

    func makeEnv() throws -> Env {
        let dir = try makeSessionsTempDir("hooks")
        return Env(
            dir: dir, settings: dir.appendingPathComponent("claude/settings.json"),
            backups: dir.appendingPathComponent("backups"))
    }

    func installer(_ env: Env, log: DiagnosticSink? = nil) -> ClaudeHookInstaller {
        ClaudeHookInstaller(
            settingsURL: env.settings, backupRoot: env.backups, hookExecutable: hookPath,
            clock: SessionsTestClock(), log: log ?? { _ in })
    }

    func write(_ json: String, to env: Env) throws {
        try FileManager.default.createDirectory(
            at: env.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: env.settings)
    }

    func parse(_ url: URL) throws -> NSDictionary {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func preToolUseGroups(_ env: Env) throws -> [[String: Any]] {
        let root = try parse(env.settings)
        let hooks = root["hooks"] as? [String: Any]
        return (hooks?["PreToolUse"] as? [[String: Any]]) ?? []
    }

    static let userSettings = """
    {
      "theme": "dark",
      "env": {"FOO": "bar"},
      "hooks": {
        "PreToolUse": [
          {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/user-guard"}]}
        ],
        "PostToolUse": [
          {"matcher": "*", "hooks": [{"type": "command", "command": "/usr/local/bin/user-post"}]}
        ]
      }
    }
    """

    @Test func installThenUninstallRestoresSemanticContent() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        try write(Self.userSettings, to: env)
        let before = try parse(env.settings)

        let inst = installer(env)
        try inst.install()
        #expect(try inst.isInstalled())
        #expect(!(try parse(env.settings)).isEqual(to: before as! [AnyHashable: Any]))

        try inst.uninstall()
        #expect(try !inst.isInstalled())
        #expect(try parse(env.settings).isEqual(to: before as! [AnyHashable: Any]))
    }

    @Test func installThenUninstallOnEmptyObject() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        try write("{}", to: env)
        let inst = installer(env)
        try inst.install()
        try inst.uninstall()
        #expect(try parse(env.settings).count == 0)
    }

    @Test func existingUserHooksArePreserved() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        try write(Self.userSettings, to: env)
        try installer(env).install()

        let groups = try preToolUseGroups(env)
        let commands = groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
        #expect(commands.contains("/usr/local/bin/user-guard"))
        #expect(commands.contains(where: { $0.contains(ClaudeHookInstaller.marker) }))

        let root = try parse(env.settings)
        #expect(root["theme"] as? String == "dark")
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(hooks["PostToolUse"] != nil)
    }

    @Test func uninstallRemovesOnlyOurEntryFromSharedGroup() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        // A user group that also contains a hook of ours (for example added by hand).
        try write("""
        {"hooks": {"PreToolUse": [{"matcher": "*", "hooks": [
          {"type": "command", "command": "/usr/local/bin/user-guard"},
          {"type": "command", "command": "/opt/muster/muster-hook"}
        ]}]}}
        """, to: env)
        try installer(env).uninstall()
        let groups = try preToolUseGroups(env)
        #expect(groups.count == 1)
        let inner = groups[0]["hooks"] as? [[String: Any]]
        #expect(inner?.count == 1)
        #expect(inner?.first?["command"] as? String == "/usr/local/bin/user-guard")
    }

    @Test func installTwiceDoesNotDuplicate() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        try write(Self.userSettings, to: env)
        let inst = installer(env)
        try inst.install()
        try inst.install()
        let ours = try preToolUseGroups(env)
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter { ClaudeHookInstaller.isOurs($0) }
        #expect(ours.count == 1)
    }

    @Test func invalidJSONIsRefusedAndFileUntouched() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        let broken = "{ \"hooks\": { oops "
        try write(broken, to: env)
        let inst = installer(env)

        #expect(throws: AdapterError.self) { try inst.install() }
        #expect(throws: AdapterError.self) { try inst.uninstall() }
        #expect(try String(contentsOf: env.settings, encoding: .utf8) == broken)
        #expect(!FileManager.default.fileExists(atPath: env.backups.path))
    }

    @Test func unknownSchemaIsRefused() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        let cases = [
            "[1, 2, 3]",
            "{\"hooks\": \"nope\"}",
            "{\"hooks\": {\"PreToolUse\": {\"a\": 1}}}",
            "{\"hooks\": {\"PreToolUse\": [42]}}",
            "{\"hooks\": {\"PreToolUse\": [{\"matcher\": \"*\", \"hooks\": \"x\"}]}}",
        ]
        for text in cases {
            try write(text, to: env)
            #expect(throws: AdapterError.self) { try installer(env).install() }
            #expect(try String(contentsOf: env.settings, encoding: .utf8) == text)
        }
    }

    @Test func backupIsWrittenBeforeChange() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        try write(Self.userSettings, to: env)
        let original = try Data(contentsOf: env.settings)

        let backupDir = try #require(try installer(env).install())
        let copy = try Data(contentsOf: backupDir.appendingPathComponent("settings.json"))
        #expect(copy == original)
        #expect(backupDir.path.hasPrefix(env.backups.path))
    }

    @Test func missingFileIsCreatedWithoutBackup() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        let backup = try installer(env).install()
        #expect(backup == nil)
        #expect(try installer(env).isInstalled())
        #expect(!FileManager.default.fileExists(atPath: env.backups.path))
    }

    @Test func uninstallWithoutOurEntryChangesNothing() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        try write(Self.userSettings, to: env)
        let before = try Data(contentsOf: env.settings)
        let backup = try installer(env).uninstall()
        #expect(backup == nil)
        #expect(try Data(contentsOf: env.settings) == before)
    }

    @Test func noTempFilesLeftBehind() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        try write("{}", to: env)
        try installer(env).install()
        let names = try FileManager.default.contentsOfDirectory(atPath: env.settings.deletingLastPathComponent().path)
        #expect(names == ["settings.json"])
    }

    @Test func hookExecutableWithoutMarkerIsRejected() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        let bad = ClaudeHookInstaller(settingsURL: env.settings, backupRoot: env.backups, hookExecutable: "/bin/true")
        #expect(throws: AdapterError.self) { try bad.install() }
        #expect(!FileManager.default.fileExists(atPath: env.settings.path))
    }

    @Test func pathWithSpacesIsQuotedInCommand() {
        let command = ClaudeHookInstaller.shellQuoted("/Users/a b/Muster/muster-hook")
        #expect(command == "'/Users/a b/Muster/muster-hook'")
        #expect(ClaudeHookInstaller.isOurs(["command": command] as [String: Any]))
    }

    @Test func adapterRoundTripUsesInjectedPaths() throws {
        let env = try makeEnv()
        defer { removeSessionsTempDir(env.dir) }
        try write(Self.userSettings, to: env)
        let before = try parse(env.settings)
        let adapter = ClaudeAdapter(
            projectsRoot: env.dir.appendingPathComponent("projects"), settingsURL: env.settings,
            backupRoot: env.backups, hookExecutable: hookPath, clock: SessionsTestClock(), log: { _ in })
        try adapter.installHooks()
        try adapter.uninstallHooks()
        #expect(try parse(env.settings).isEqual(to: before as! [AnyHashable: Any]))
        #expect(try adapter.sessions().isEmpty)
    }
}
