import Foundation

public enum SessionResumeError: String, LocalizedError {
    case unavailable = "This session has no supported resume command."
    case folderMissing = "The project folder is no longer available. Copy the resume command to choose another folder."
    case automation = "Terminal could not be opened. The resume command was copied; paste it into your terminal."
    public var errorDescription: String? { rawValue }
}

/// Opens a fresh Terminal window. No process is inferred from a historical working directory.
public struct SessionResumer: Sendable {
    private let runner: CommandRunner
    public init(runner: CommandRunner = CleanupCommandRunner()) { self.runner = runner }

    public func resume(_ session: Session) throws {
        guard let command = session.resumeCommand else { throw SessionResumeError.unavailable }
        if !session.cwd.isEmpty {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &directory), directory.boolValue
            else { throw SessionResumeError.folderMissing }
        }
        // Pass the command as an argv value, never interpolate it into AppleScript source.
        let script = """
        on run argv
            tell application "Terminal"
                do script (item 1 of argv)
                activate
            end tell
        end run
        """
        guard let result = try? runner.run(["osascript", "-e", script, "--", command], cwd: nil), result.status == 0
        else { throw SessionResumeError.automation }
    }
}
