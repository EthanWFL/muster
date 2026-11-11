import Foundation

/// Answers "is there an executable called `name` on PATH?". Injectable so tests need no real tools.
public protocol CommandLookup: Sendable {
    func isAvailable(_ name: String) -> Bool
}

/// Looks a command up in the PATH directories (like `which`), without spawning a process.
/// GUI apps start with a minimal PATH, so common tool directories are appended.
public final class PATHCommandLookup: CommandLookup, @unchecked Sendable {
    public static let extraDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    private let directories: [String]
    private let fileSystem: RuleFileSystem
    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    public init(fileSystem: RuleFileSystem = DefaultRuleFileSystem(), searchPath: [String]? = nil) {
        self.fileSystem = fileSystem
        if let searchPath {
            self.directories = searchPath
        } else {
            let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            let home = NSHomeDirectory()
            let user = ["\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin", "\(home)/go/bin"]
            var seen = Set<String>()
            self.directories = (env + user + Self.extraDirectories).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    public func isAvailable(_ name: String) -> Bool {
        lock.lock()
        if let hit = cache[name] { lock.unlock(); return hit }
        lock.unlock()
        let found = directories.contains { fileSystem.isExecutable(atPath: "\($0)/\(name)") }
        lock.lock()
        cache[name] = found
        lock.unlock()
        return found
    }
}

/// Tunable heuristics for `RefChecker`. Plain data, so they can be adjusted without touching code.
public struct RefCheckerConfig: Sendable, Equatable {
    /// A single lowercase word in backticks is only treated as a command when one of these words
    /// appears shortly before it ("run `pnpm`", "运行 `make`").
    public var commandCuesBefore: [String]
    /// ... or one of these shortly after it ("the `pnpm` command", "`make` 命令").
    public var commandCuesAfter: [String]
    /// Path segments that signal an illustrative path rather than a real one.
    public var placeholderSegments: Set<String>
    /// Words never looked up as commands.
    public var ignoredCommands: Set<String>
    /// How many characters around the span are searched for a cue.
    public var cueWindow: Int

    public init(
        commandCuesBefore: [String], commandCuesAfter: [String], placeholderSegments: Set<String>,
        ignoredCommands: Set<String>, cueWindow: Int = 24
    ) {
        self.commandCuesBefore = commandCuesBefore
        self.commandCuesAfter = commandCuesAfter
        self.placeholderSegments = placeholderSegments
        self.ignoredCommands = ignoredCommands
        self.cueWindow = cueWindow
    }

    public static let `default` = RefCheckerConfig(
        commandCuesBefore: [
            "run", "runs", "running", "execute", "executing", "invoke", "install", "installed", "via",
            "运行", "执行", "调用", "安装",
        ],
        commandCuesAfter: ["command", "cli", "binary", "命令", "工具"],
        placeholderSegments: [
            "foo", "bar", "baz", "xxx", "yyy", "xyz", "example", "your-project", "your_project",
            "project-name", "project_name", "my-project", "my_project", "myproject", "name",
        ],
        ignoredCommands: ["true", "false", "null", "none", "nil", "yes", "no", "this", "that", "it"]
    )
}

/// Finds backtick references in rule entries that point at nothing: paths that do not exist and
/// commands that are not installed.
///
/// It prefers false negatives. Anything that is not clearly a path or a command is skipped:
/// `foo.bar`, expressions with spaces, `<placeholder>`, globs, URLs, flags, absolute and `~` paths,
/// `..` paths, and bare words without a command-like context.
public struct RefChecker: Sendable {
    public var fileSystem: RuleFileSystem
    public var commands: CommandLookup
    public var config: RefCheckerConfig

    public init(
        fileSystem: RuleFileSystem = DefaultRuleFileSystem(),
        commands: CommandLookup? = nil,
        config: RefCheckerConfig = .default
    ) {
        self.fileSystem = fileSystem
        self.commands = commands ?? PATHCommandLookup(fileSystem: fileSystem)
        self.config = config
    }

    public func findStaleReferences(in entries: [RuleEntry]) -> [StaleReference] {
        var result: [StaleReference] = []
        for entry in entries { result.append(contentsOf: check(entry)) }
        return result
    }

    public func check(_ entry: RuleEntry) -> [StaleReference] {
        let chars = Array(entry.text)
        var out: [StaleReference] = []
        var seen = Set<String>()

        for span in Self.backtickSpans(chars) {
            let line = entry.line + span.lineOffset
            switch Self.classify(span.content, config: config) {
            case .none:
                continue
            case .path(let path, let isDirectory):
                guard !isIllustrative(path) else { continue }
                let tried = candidateLocations(for: path, entry: entry)
                if tried.contains(where: { fileSystem.exists(atPath: $0) }) { continue }
                _ = isDirectory
                guard seen.insert("p:\(path):\(line)").inserted else { continue }
                out.append(StaleReference(
                    entry: entry, reference: span.content, kind: .path, line: line, checkedPaths: tried))
            case .command(let name):
                guard !config.ignoredCommands.contains(name), commandContext(chars, span) else { continue }
                // A word that is also a file or folder in the repo is more likely a path than a command.
                if fileSystem.exists(atPath: "\(entry.repoRoot)/\(name)") { continue }
                if commands.isAvailable(name) { continue }
                guard seen.insert("c:\(name):\(line)").inserted else { continue }
                out.append(StaleReference(
                    entry: entry, reference: span.content, kind: .command, line: line, checkedPaths: []))
            }
        }
        return out
    }

    // MARK: Paths

    private func candidateLocations(for path: String, entry: RuleEntry) -> [String] {
        let fileDir = (entry.filePath as NSString).deletingLastPathComponent
        var list = ["\(entry.repoRoot)/\(path)"]
        let sibling = "\(fileDir)/\(path)"
        if !list.contains(sibling) { list.append(sibling) }
        return list
    }

    private func isIllustrative(_ path: String) -> Bool {
        let segments = path.split(separator: "/").map { $0.lowercased() }
        for (i, s) in segments.enumerated() {
            if config.placeholderSegments.contains(s) { return true }
            if s.hasPrefix("your-") || s.hasPrefix("your_") || s == "your" { return true }
            if s == "path", i + 1 < segments.count, segments[i + 1] == "to" { return true }
        }
        return false
    }

    // MARK: Commands

    private func commandContext(_ chars: [Character], _ span: Span) -> Bool {
        let beforeStart = max(0, span.start - config.cueWindow)
        var before = Array(chars[beforeStart..<span.start]).map { Character($0.lowercased()) }
        if let cut = before.lastIndex(where: { Self.clauseSeparators.contains($0) }) {
            before = Array(before[(cut + 1)...])
        }
        for cue in config.commandCuesBefore where Self.contains(cue, in: before) { return true }

        let afterEnd = min(chars.count, span.end + config.cueWindow)
        var after = Array(chars[span.end..<afterEnd]).map { Character($0.lowercased()) }
        if let cut = after.firstIndex(where: { Self.clauseSeparators.contains($0) }) {
            after = Array(after[..<cut])
        }
        for cue in config.commandCuesAfter where Self.contains(cue, in: after) { return true }
        return false
    }

    private static let clauseSeparators: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "\n", "\u{FF0C}", "\u{3002}", "\u{FF1B}", "\u{FF1A}",
    ]

    private static func contains(_ cue: String, in hay: [Character]) -> Bool {
        let needle = Array(cue)
        guard let first = needle.first, let last = needle.last, hay.count >= needle.count else { return false }
        for i in 0...(hay.count - needle.count) where hay[i] == first {
            guard hay[i..<(i + needle.count)].elementsEqual(needle) else { continue }
            let leftOK = !isASCIIAlnum(first) || i == 0 || !isASCIIAlnum(hay[i - 1])
            let r = i + needle.count
            let rightOK = !isASCIIAlnum(last) || r >= hay.count || !isASCIIAlnum(hay[r])
            if leftOK && rightOK { return true }
        }
        return false
    }

    private static func isASCIIAlnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    // MARK: Classification

    enum Classification: Equatable {
        case none
        case path(String, isDirectory: Bool)
        case command(String)
    }

    /// Decides what a backtick span looks like. Conservative: `.none` unless it is clearly one or the other.
    static func classify(_ raw: String, config: RefCheckerConfig) -> Classification {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 200 else { return .none }
        if s.contains(where: { $0.isWhitespace }) { return .none }
        if s.hasPrefix("-") || s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix("@") || s.hasPrefix("$") {
            return .none
        }

        // `Sources/Foo.swift:42` and `Sources/Foo.swift:42:7` are still paths.
        if let r = s.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { s.removeSubrange(r) }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+/")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return .none }

        if s.contains("/") {
            if s.contains("..") && s.split(separator: "/").contains("..") { return .none }
            if s.contains("//") || s.contains("...") { return .none }
            var path = s
            while path.hasPrefix("./") { path.removeFirst(2) }
            let isDirectory = path.hasSuffix("/")
            while path.hasSuffix("/") { path.removeLast() }
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 1, !parts.contains("."), !parts.contains("..") else { return .none }
            // Looks like a host name (github.com/foo) or a version (v1.2/x).
            if let first = parts.first, let dot = first.firstIndex(of: "."), dot != first.startIndex { return .none }
            guard isDirectory || hasFileExtension(parts[parts.count - 1]) else { return .none }
            return .path(parts.joined(separator: "/"), isDirectory: isDirectory)
        }

        if s.range(of: #"^[a-z][a-z0-9_-]{1,31}$"#, options: .regularExpression) != nil {
            return .command(s)
        }
        return .none
    }

    private static func hasFileExtension(_ component: String) -> Bool {
        guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { return false }
        let ext = component[component.index(after: dot)...]
        return (1...10).contains(ext.count) && ext.contains(where: { $0.isLetter })
    }

    // MARK: Backtick spans

    struct Span {
        var content: String
        /// Character index of the opening backtick and one past the closing one.
        var start: Int
        var end: Int
        /// Newlines before the span, i.e. the source line offset inside the entry.
        var lineOffset: Int
    }

    /// Inline code spans, with CommonMark-style matching of equal-length backtick runs.
    static func backtickSpans(_ chars: [Character]) -> [Span] {
        var spans: [Span] = []
        var i = 0
        var newlines = 0
        while i < chars.count {
            if chars[i] == "\n" { newlines += 1 }
            guard chars[i] == "`" else { i += 1; continue }

            var n = 0
            while i + n < chars.count, chars[i + n] == "`" { n += 1 }
            var j = i + n
            var closed: Int?
            while j < chars.count {
                if chars[j] == "`" {
                    var m = 0
                    while j + m < chars.count, chars[j + m] == "`" { m += 1 }
                    if m == n { closed = j; break }
                    j += m
                } else {
                    j += 1
                }
            }
            guard let close = closed else { i += n; continue }
            let content = String(chars[(i + n)..<close])
            if !content.contains("\n") {
                spans.append(Span(content: content, start: i, end: close + n, lineOffset: newlines))
            }
            newlines += content.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            i = close + n
        }
        return spans
    }
}
