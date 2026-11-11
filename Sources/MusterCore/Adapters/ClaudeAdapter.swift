import Foundation

/// Claude Code adapter. Session inference and hook installation are delegated to
/// `ClaudeTranscriptScanner` and `ClaudeHookInstaller`; every path is injected.
public struct ClaudeAdapter: AgentAdapter {
    public let kind: AgentKind = .claude
    public let scanner: ClaudeTranscriptScanner
    public let installer: ClaudeHookInstaller

    public init(scanner: ClaudeTranscriptScanner, installer: ClaudeHookInstaller) {
        self.scanner = scanner
        self.installer = installer
    }

    public init(
        projectsRoot: URL, settingsURL: URL, backupRoot: URL, hookExecutable: String,
        clock: Clock = SystemClock(), log: @escaping DiagnosticSink = Diagnostics.default
    ) {
        self.init(
            scanner: ClaudeTranscriptScanner(projectsRoot: projectsRoot, clock: clock, log: log),
            installer: ClaudeHookInstaller(
                settingsURL: settingsURL, backupRoot: backupRoot, hookExecutable: hookExecutable,
                clock: clock, log: log))
    }

    /// Read-only. Only the head and tail of each transcript are read.
    public func sessions() throws -> [Session] { try scanner.scan() }

    public func installHooks() throws { try installer.install() }

    public func uninstallHooks() throws { try installer.uninstall() }

    /// Claude decisions travel through the hook's socket connection, not through files.
    public func decide(_ call: ToolCall, _ decision: Decision) throws {
        throw AdapterError.unsupported("Claude decisions are sent over the hook socket")
    }
}
