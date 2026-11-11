import Foundation

public struct WorktreeInfo: Equatable, Sendable {
    /// 主 worktree 路径，即 `git worktree prune` 要在其中执行的仓库
    public var repoRoot: String
    public var path: String
    public var head: String?
    /// 短分支名（去掉 refs/heads/）；detached 时为 nil
    public var branch: String?
    public var isMain: Bool
    public var isBare: Bool
    public var isLocked: Bool
    public var directoryMissing: Bool
    /// 分支已并入主 worktree 的分支，且分支头与基线不同（刚建的空分支不算「已合并」）
    public var branchMerged: Bool

    /// 主 worktree、bare、locked 一律不是清理对象
    public var isStale: Bool {
        !isMain && !isBare && !isLocked && (directoryMissing || branchMerged)
    }
}

public enum WorktreeScanError: Error, Equatable {
    case gitFailed(status: Int32, stderr: String)
}

/// 只读：只跑 `git worktree list` / `git branch --merged`，不修改仓库。
public struct WorktreeScanner: Sendable {
    public let runner: CommandRunner
    public let fileSystem: CleanupFileSystem

    public init(runner: CommandRunner, fileSystem: CleanupFileSystem = SystemCleanupFileSystem()) {
        self.runner = runner
        self.fileSystem = fileSystem
    }

    public func scan(repoAt cwd: String) throws -> [WorktreeInfo] {
        let list = try runner.run(["git", "worktree", "list", "--porcelain"], cwd: cwd)
        guard list.status == 0 else {
            throw WorktreeScanError.gitFailed(status: list.status, stderr: list.stderr)
        }
        var entries = Self.parsePorcelain(list.stdout)
        guard let main = entries.first else { return [] }

        var mergedBranches: Set<String> = []
        if let base = main.branch {
            let merged = try? runner.run(
                ["git", "branch", "--merged", base, "--format=%(refname:short)"], cwd: main.path)
            if let merged, merged.status == 0 {
                mergedBranches = Set(merged.stdout.split(whereSeparator: \.isNewline).map {
                    $0.trimmingCharacters(in: .whitespaces)
                })
            }
        }

        for i in entries.indices {
            entries[i].repoRoot = main.path
            entries[i].isMain = (i == 0)
            entries[i].directoryMissing = !fileSystem.directoryExists(entries[i].path)
            if i > 0, let branch = entries[i].branch, branch != main.branch,
               mergedBranches.contains(branch), let head = entries[i].head, head != main.head {
                entries[i].branchMerged = true
            }
        }
        return entries
    }

    /// 扫描多个项目目录；同一仓库只出现一次，非仓库或出错的目录跳过。
    public func scanAll(projects: [String]) -> [WorktreeInfo] {
        var seenRepos: Set<String> = []
        var result: [WorktreeInfo] = []
        for project in projects {
            guard let found = try? scan(repoAt: project), let root = found.first?.repoRoot,
                  seenRepos.insert(root).inserted else { continue }
            result.append(contentsOf: found)
        }
        return result
    }

    static func parsePorcelain(_ output: String) -> [WorktreeInfo] {
        var result: [WorktreeInfo] = []
        var current: WorktreeInfo?
        func flush() {
            if let c = current { result.append(c) }
            current = nil
        }
        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.isEmpty { flush(); continue }
            let (key, value) = Self.split(line)
            if key == "worktree" {
                flush()
                current = WorktreeInfo(
                    repoRoot: value, path: value, head: nil, branch: nil, isMain: false, isBare: false,
                    isLocked: false, directoryMissing: false, branchMerged: false)
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "HEAD": current?.head = value
            case "branch":
                let prefix = "refs/heads/"
                current?.branch = value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
            case "bare": current?.isBare = true
            case "locked": current?.isLocked = true
            default: break
            }
        }
        flush()
        return result
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}
