import Foundation

public struct RuleScannerConfig: Sendable, Equatable {
    /// Directory to walk. Default `~/Code`.
    public var root: String
    /// Directory names never entered.
    public var excludedDirectories: Set<String>
    /// Levels below `root` that are visited (root itself is level 0).
    public var maxDepth: Int
    /// Rule files larger than this are skipped (bytes).
    public var maxFileSize: Int

    public init(
        root: String = (NSHomeDirectory() as NSString).appendingPathComponent("Code"),
        excludedDirectories: Set<String> = RuleScannerConfig.defaultExcludedDirectories,
        maxDepth: Int = 6,
        maxFileSize: Int = 1_000_000
    ) {
        self.root = (root as NSString).expandingTildeInPath
        self.excludedDirectories = excludedDirectories
        self.maxDepth = maxDepth
        self.maxFileSize = maxFileSize
    }

    public static let defaultExcludedDirectories: Set<String> = [
        "node_modules", ".git", ".build", "DerivedData", ".venv", ".tox", "__pycache__",
    ]
}

/// Walks a root directory for rule files and reports duplicates, stale references and contradictions.
///
/// Read-only (R10): the only file system calls are listing, stat and reading text.
/// Incremental (R11): parsed entries are cached per file by (mtime, size), so an unchanged file is not
/// read again. Reference checks run on every scan because they depend on files outside the rule files.
///
/// Hidden directories are not entered, except `.github` (for `copilot-instructions.md`). Symlinked
/// directories are not followed, and a rule file reachable through several paths is reported once.
public final class RuleScanner: @unchecked Sendable {
    public var config: RuleScannerConfig
    private let fileSystem: RuleFileSystem
    private let duplicateDetector: DuplicateDetector
    private let refChecker: RefChecker
    private let contradictionDetector: ContradictionDetector

    private struct CachedFile {
        var modificationDate: Date
        var size: Int
        var entries: [ParsedRuleEntry]
    }

    private let lock = NSLock()
    private var cache: [String: CachedFile] = [:]

    public init(
        config: RuleScannerConfig = RuleScannerConfig(),
        fileSystem: RuleFileSystem = DefaultRuleFileSystem(),
        duplicateDetector: DuplicateDetector = DuplicateDetector(),
        refChecker: RefChecker? = nil,
        contradictionDetector: ContradictionDetector = ContradictionDetector()
    ) {
        self.config = config
        self.fileSystem = fileSystem
        self.duplicateDetector = duplicateDetector
        self.refChecker = refChecker ?? RefChecker(fileSystem: fileSystem)
        self.contradictionDetector = contradictionDetector
    }

    /// Number of files currently held in the mtime cache.
    public var cachedFileCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache.count
    }

    /// Forgets all cached parse results, so the next scan reads every file again.
    public func invalidateCache() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }

    /// Runs a scan on a background task (never on the caller's actor). `progress` is called from that
    /// background task, so a UI must hop to the main actor itself. Throws `CancellationError` when cancelled.
    public func scan(progress: (@Sendable (RuleScanProgress) -> Void)? = nil) async throws -> RuleReport {
        let snapshot = config
        let work = Task.detached(priority: .utility) { [self] in
            try performScan(config: snapshot, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: Scan

    private struct Found {
        var path: String
        var kind: RuleFileKind
        var repoRoot: String
    }

    private func performScan(config: RuleScannerConfig, progress: (@Sendable (RuleScanProgress) -> Void)?) throws -> RuleReport {
        let started = ProcessInfo.processInfo.systemUptime
        var stats = RuleScanStats()

        let found = try discover(config: config, progress: progress)
        stats.filesFound = found.count

        var files: [RuleFile] = []
        var seen = Set<String>()
        for (i, item) in found.enumerated() {
            try Task.checkCancellation()
            progress?(RuleScanProgress(phase: .parsing, completed: i, total: found.count, currentPath: item.path))
            guard let st = fileSystem.stat(atPath: item.path), st.size <= config.maxFileSize else { continue }

            let parsed: [ParsedRuleEntry]
            if let hit = cachedEntries(for: item.path, stat: st) {
                parsed = hit
                stats.filesFromCache += 1
            } else {
                guard let text = try? fileSystem.readText(atPath: item.path) else { continue }
                parsed = RuleParser.parse(text)
                store(parsed, for: item.path, stat: st)
                stats.filesParsed += 1
                stats.reparsedPaths.append(item.path)
            }
            seen.insert(item.path)
            let entries = parsed.map {
                RuleEntry(filePath: item.path, repoRoot: item.repoRoot, kind: item.kind, line: $0.line, text: $0.text)
            }
            files.append(RuleFile(
                path: item.path, kind: item.kind, repoRoot: item.repoRoot,
                modificationDate: st.modificationDate, size: st.size, entries: entries))
        }
        prune(keeping: seen)

        try Task.checkCancellation()
        let all = files.flatMap(\.entries)
        stats.entryCount = all.count

        progress?(RuleScanProgress(phase: .analyzing, completed: 0, total: 3, currentPath: nil))
        let duplicates = duplicateDetector.findDuplicates(in: all)
        try Task.checkCancellation()
        progress?(RuleScanProgress(phase: .analyzing, completed: 1, total: 3, currentPath: nil))
        let stale = refChecker.findStaleReferences(in: all)
        try Task.checkCancellation()
        progress?(RuleScanProgress(phase: .analyzing, completed: 2, total: 3, currentPath: nil))
        let contradictions = contradictionDetector.findContradictions(in: all)

        stats.duration = ProcessInfo.processInfo.systemUptime - started
        progress?(RuleScanProgress(phase: .done, completed: found.count, total: found.count, currentPath: nil))
        return RuleReport(
            root: config.root, files: files, duplicates: duplicates, staleReferences: stale,
            contradictions: contradictions, stats: stats)
    }

    // MARK: Discovery

    private func discover(config: RuleScannerConfig, progress: (@Sendable (RuleScanProgress) -> Void)?) throws -> [Found] {
        struct Dir { var path: String; var repo: String?; var depth: Int }

        var result: [Found] = []
        var realPaths = Set<String>()
        var stack = [Dir(path: config.root, repo: nil, depth: 0)]
        var visited = 0

        while let dir = stack.popLast() {
            try Task.checkCancellation()
            guard let listing = try? fileSystem.listDirectory(atPath: dir.path) else { continue }
            visited += 1
            if visited % 50 == 0 {
                progress?(RuleScanProgress(phase: .discovering, completed: visited, total: 0, currentPath: dir.path))
            }

            let repo = listing.contains { $0.name == ".git" } ? dir.path : dir.repo
            let parentName = (dir.path as NSString).lastPathComponent
            let sorted = listing.sorted { $0.name < $1.name }

            var children: [Dir] = []
            for entry in sorted {
                if entry.isDirectory {
                    guard !entry.isSymlink, dir.depth < config.maxDepth,
                          !config.excludedDirectories.contains(entry.name) else { continue }
                    if entry.name.hasPrefix(".") && entry.name != ".github" { continue }
                    children.append(Dir(
                        path: (dir.path as NSString).appendingPathComponent(entry.name),
                        repo: repo ?? (entry.name == ".github" ? dir.path : nil),
                        depth: dir.depth + 1))
                } else if let kind = RuleFileKind.kind(forFileName: entry.name, parentName: parentName) {
                    let path = (dir.path as NSString).appendingPathComponent(entry.name)
                    guard realPaths.insert(fileSystem.realPath(path)).inserted else { continue }
                    result.append(Found(path: path, kind: kind, repoRoot: repo ?? dir.path))
                }
            }
            // Reversed so the stack pops children in name order.
            stack.append(contentsOf: children.reversed())
        }
        return result.sorted { $0.path < $1.path }
    }

    // MARK: Cache

    private func cachedEntries(for path: String, stat: RuleFileStat) -> [ParsedRuleEntry]? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache[path], c.modificationDate == stat.modificationDate, c.size == stat.size else { return nil }
        return c.entries
    }

    private func store(_ entries: [ParsedRuleEntry], for path: String, stat: RuleFileStat) {
        lock.lock(); defer { lock.unlock() }
        cache[path] = CachedFile(modificationDate: stat.modificationDate, size: stat.size, entries: entries)
    }

    private func prune(keeping seen: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for key in cache.keys where !seen.contains(key) { cache.removeValue(forKey: key) }
    }
}
