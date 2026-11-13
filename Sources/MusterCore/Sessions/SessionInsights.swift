import Foundation

public enum SessionInsights {
    /// 目录当前的 git 分支；分离 HEAD 时返回短 hash，不是 git 目录返回 nil。
    /// worktree 的 `.git` 是个文件，指向真正的 gitdir。
    public static func branch(cwd: String) -> String? {
        guard !cwd.isEmpty, !ProtectedFolders.contains(cwd) else { return nil }
        var gitDir = cwd + "/.git"
        if let pointer = try? String(contentsOfFile: gitDir, encoding: .utf8), pointer.hasPrefix("gitdir:") {
            let path = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = path.hasPrefix("/") ? path : cwd + "/" + path
        }
        guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return nil }
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref: refs/heads/") { return String(text.dropFirst("ref: refs/heads/".count)) }
        return text.isEmpty ? nil : String(text.prefix(7))
    }

    /// 上一轮在跑、这一轮停下的会话：值得提醒用户回来看一眼。
    /// 消失的会话（进程退出）不算，那是用户自己关的。
    public static func finished(from previous: [Session], to current: [Session]) -> [Session] {
        let running = Set(previous.filter { $0.state == .running }.map(\.id))
        return current.filter { $0.state == .idle && running.contains($0.id) }
    }
}
