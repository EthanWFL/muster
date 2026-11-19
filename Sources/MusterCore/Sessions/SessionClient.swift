import Foundation

/// The current GUI host of an Agent process, not its model or historical launch origin.
public struct SessionClient: Equatable, Sendable {
    public let name: String
    public let bundlePath: String
    public private(set) var paneURL: URL?

    public init(name: String, bundlePath: String) {
        self.name = name
        self.bundlePath = bundlePath
    }

    private static let names: [String: String] = [
        "Warp.app": "Warp", "WarpPreview.app": "Warp Preview",
        "Terminal.app": "Terminal", "iTerm.app": "iTerm", "iTerm2.app": "iTerm2",
        "Codex.app": "Codex", "ChatGPT.app": "ChatGPT", "Claude.app": "Claude",
        "Visual Studio Code.app": "VS Code", "Visual Studio Code - Insiders.app": "VS Code Insiders",
        "Cursor.app": "Cursor", "DeepSeek Harness.app": "DeepSeek Harness", "magpie.app": "Magpie",
        "Ghostty.app": "Ghostty", "Alacritty.app": "Alacritty", "kitty.app": "Kitty", "WezTerm.app": "WezTerm"
    ]

    public static func detect(for process: ProcessRecord, warpPaneDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Muster/warp-panes"), record: (Int32) -> ProcessRecord?) -> SessionClient? {
        var shells: [ProcessIdentity] = []
        var child = process
        var seen: Set<Int32> = [process.pid]
        // Start at the parent: a binary shipped inside an app can still be launched from a terminal.
        for _ in 0..<64 {
            guard child.ppid > 1, seen.insert(child.ppid).inserted,
                  let parent = record(child.ppid), parent.pid == child.ppid else { return nil }
            if let childStart = child.startTime, let parentStart = parent.startTime,
               parentStart > childStart.addingTimeInterval(1) { return nil }
            if let path = parent.executablePath {
                let executable = URL(fileURLWithPath: path).lastPathComponent
                // A detached multiplexer/server's original parent is not the current viewer.
                if ["tmux", "screen", "sshd"].contains(executable) { return nil }
                if executable == "zsh", let shell = parent.identity { shells.append(shell) }
                if var client = fromExecutable(path) {
                    if client.name == "Warp" {
                        for shell in shells {
                            let file = warpPaneDirectory.appendingPathComponent("\(shell.pid).\(Int(shell.startTime.timeIntervalSince1970))")
                            guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                                  info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == 32,
                                  let value = try? String(contentsOf: file, encoding: .utf8), value.utf8.count == 32,
                                  value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
                            client.paneURL = URL(string: "warp://session/" + value)
                            break
                        }
                    }
                    return client
                }
            }
            child = parent
        }
        return nil
    }

    private static func fromExecutable(_ path: String) -> SessionClient? {
        guard path.hasPrefix("/") else { return nil }
        let components = (path as NSString).pathComponents
        for index in components.indices {
            guard let name = names[components[index]], index + 3 < components.count,
                  components[index + 1] == "Contents",
                  ["MacOS", "Frameworks"].contains(components[index + 2]) else { continue }
            // Resources may contain a standalone Agent binary; that alone is not host evidence.
            let bundle = NSString.path(withComponents: Array(components[...index]))
            return SessionClient(name: name, bundlePath: bundle)
        }
        return nil
    }
}
