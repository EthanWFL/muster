import Foundation

public struct RuleDirectoryEntry: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool

    public init(name: String, isDirectory: Bool, isSymlink: Bool) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
    }
}

public struct RuleFileStat: Sendable, Equatable {
    public var modificationDate: Date
    public var size: Int

    public init(modificationDate: Date, size: Int) {
        self.modificationDate = modificationDate
        self.size = size
    }
}

/// Read-only file system access for the rules feature (R10: there is deliberately no write API).
public protocol RuleFileSystem: Sendable {
    func listDirectory(atPath path: String) throws -> [RuleDirectoryEntry]
    /// Stat of a regular file (symlinks followed); nil when missing or not a regular file.
    func stat(atPath path: String) -> RuleFileStat?
    func readText(atPath path: String) throws -> String
    func exists(atPath path: String) -> Bool
    func isExecutable(atPath path: String) -> Bool
    func realPath(_ path: String) -> String
}

public struct DefaultRuleFileSystem: RuleFileSystem {
    public init() {}

    public func listDirectory(atPath path: String) throws -> [RuleDirectoryEntry] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [])
        return urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return RuleDirectoryEntry(
                name: u.lastPathComponent,
                isDirectory: v?.isDirectory ?? false,
                isSymlink: v?.isSymbolicLink ?? false)
        }
    }

    public func stat(atPath path: String) -> RuleFileStat? { posixRegularFileStat(path) }

    public func readText(atPath path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return String(decoding: data, as: UTF8.self)
    }

    public func exists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isExecutable(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    public func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// File-level so the C `stat` function is not shadowed by the `stat(atPath:)` method name.
private func posixRegularFileStat(_ path: String) -> RuleFileStat? {
    var st = stat()
    guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    let ts = st.st_mtimespec
    let date = Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    return RuleFileStat(modificationDate: date, size: Int(st.st_size))
}
