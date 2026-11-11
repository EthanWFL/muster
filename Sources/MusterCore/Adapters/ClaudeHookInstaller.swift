import Foundation
import Darwin

/// Installs and removes the Muster `PreToolUse` hook in a Claude Code settings file.
///
/// Rules (IMPLEMENTATION.md section 6):
/// - back up the existing file before any write;
/// - write atomically (temp file in the same directory, fsync, rename);
/// - only touch entries whose hook command contains `marker`; uninstall removes only those;
/// - refuse (throw `AdapterError.unrecognizedConfig`) when the file is not valid JSON or its
///   `hooks` structure has an unexpected shape. Nothing is repaired.
///
/// The settings path and the backup directory are always injected. There are no defaults here,
/// so a test can never reach the real `~/.claude/settings.json` by accident.
public struct ClaudeHookInstaller: Sendable {
    /// A hook command containing this text is considered ours.
    public static let marker = "muster-hook"
    /// Hook timeout written into our entry.
    /// 单位是秒（M0 实测：`timeout: 10` 会让 30s 的 hook 在 9.8s 被杀）。
    /// 不设 timeout 时 hook 存活超过 103s 仍未被杀，默认上限未测出，所以必须显式写：
    /// 120 秒 > app 侧 90 秒的 TTL，给 IPC 留出余量。
    public static let hookTimeoutSeconds = 120

    public let settingsURL: URL
    public let backupRoot: URL
    public let hookExecutable: String
    public let clock: Clock
    public let log: DiagnosticSink

    public init(
        settingsURL: URL, backupRoot: URL, hookExecutable: String,
        clock: Clock = SystemClock(), log: @escaping DiagnosticSink = Diagnostics.default
    ) {
        self.settingsURL = settingsURL
        self.backupRoot = backupRoot
        self.hookExecutable = hookExecutable
        self.clock = clock
        self.log = log
    }

    typealias JSONObject = [String: Any]

    // MARK: - Hook entry shape (isolated on purpose)

    /// The JSON for our matcher group inside `hooks.PreToolUse`.
    /// 形状已由 M0 实测确认（settings.json 里 `hooks.PreToolUse[].hooks[].{type,command,timeout}`）。
    /// 仍集中在这一个函数里：`isOurs` 只认 `command` 里的标记，改形状不影响卸载。
    static func hookEntry(command: String) -> JSONObject {
        [
            "matcher": "*",
            "hooks": [
                [
                    "type": "command",
                    "command": command,
                    "timeout": hookTimeoutSeconds,
                ] as JSONObject
            ],
        ]
    }

    /// True for a single hook object (an element of a group's `hooks` array) that we wrote.
    static func isOurs(_ hook: Any) -> Bool {
        guard let object = hook as? JSONObject, let command = object["command"] as? String else { return false }
        return command.contains(marker)
    }

    // MARK: - Public API

    /// Adds our entry. Returns the backup directory when a backup was made (nil if the file did not exist
    /// or nothing changed).
    @discardableResult
    public func install() throws -> URL? {
        guard hookExecutable.contains(Self.marker) else {
            throw AdapterError.unsupported("hook executable path must contain '\(Self.marker)'")
        }
        let command = Self.shellQuoted(hookExecutable)
        return try mutate { root in
            var hooks = try Self.object(root["hooks"], name: "hooks")
            var groups = try Self.array(hooks["PreToolUse"], name: "hooks.PreToolUse")
            groups = try Self.strippingOurs(from: groups).groups
            groups.append(Self.hookEntry(command: command))
            hooks["PreToolUse"] = groups
            root["hooks"] = hooks
        }
    }

    /// Removes only our entries. Containers that become empty because of the removal are dropped.
    @discardableResult
    public func uninstall() throws -> URL? {
        try mutate { root in
            guard root["hooks"] != nil else { return }
            var hooks = try Self.object(root["hooks"], name: "hooks")
            guard hooks["PreToolUse"] != nil else { return }
            let groups = try Self.array(hooks["PreToolUse"], name: "hooks.PreToolUse")
            let stripped = try Self.strippingOurs(from: groups)
            guard stripped.removed > 0 else { return }
            if stripped.groups.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = stripped.groups }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
    }

    /// Whether our entry is currently present. Throws on unreadable or unrecognized files.
    public func isInstalled() throws -> Bool {
        let (root, _) = try load()
        guard root["hooks"] != nil else { return false }
        let hooks = try Self.object(root["hooks"], name: "hooks")
        let groups = try Self.array(hooks["PreToolUse"], name: "hooks.PreToolUse")
        return try Self.strippingOurs(from: groups).removed > 0
    }

    // MARK: - Permanent allow (R4)

    /// Current `permissions.allow` entries, in file order. Missing container means empty.
    public func allowRules() throws -> [String] {
        let (root, _) = try load()
        guard root["permissions"] != nil else { return [] }
        let permissions = try Self.object(root["permissions"], name: "permissions")
        let allow = try Self.array(permissions["allow"], name: "permissions.allow")
        return try allow.map { value in
            guard let text = value as? String else {
                throw AdapterError.unrecognizedConfig("'permissions.allow' contains a non-string")
            }
            return text
        }
    }

    /// Appends one rule to `permissions.allow`. Returns the backup directory when the file changed.
    /// Duplicates are a no-op (nil). The caller is responsible for validating the rule text.
    @discardableResult
    public func addAllowRule(_ rule: String) throws -> URL? {
        let text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AdapterError.unsupported("empty allow rule") }
        return try mutate { root in
            var permissions = try Self.object(root["permissions"], name: "permissions")
            var allow = try Self.array(permissions["allow"], name: "permissions.allow")
            for value in allow where !(value is String) {
                throw AdapterError.unrecognizedConfig("'permissions.allow' contains a non-string")
            }
            guard !allow.contains(where: { ($0 as? String) == text }) else { return }
            allow.append(text)
            permissions["allow"] = allow
            root["permissions"] = permissions
        }
    }

    // MARK: - Schema helpers

    static func object(_ value: Any?, name: String) throws -> JSONObject {
        guard let value else { return [:] }
        guard let object = value as? JSONObject else {
            throw AdapterError.unrecognizedConfig("'\(name)' is not an object")
        }
        return object
    }

    static func array(_ value: Any?, name: String) throws -> [Any] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw AdapterError.unrecognizedConfig("'\(name)' is not an array")
        }
        return array
    }

    /// Removes our hook objects from every matcher group. A group left without hooks because of
    /// that removal is dropped. Groups that held none of ours are returned untouched.
    static func strippingOurs(from groups: [Any]) throws -> (groups: [Any], removed: Int) {
        var result: [Any] = []
        var removed = 0
        for element in groups {
            guard var group = element as? JSONObject else {
                throw AdapterError.unrecognizedConfig("an entry in 'hooks.PreToolUse' is not an object")
            }
            guard group["hooks"] != nil else { result.append(group); continue }
            let inner = try array(group["hooks"], name: "hooks.PreToolUse[].hooks")
            let kept = inner.filter { !isOurs($0) }
            let delta = inner.count - kept.count
            if delta == 0 { result.append(group); continue }
            removed += delta
            if kept.isEmpty { continue }
            group["hooks"] = kept
            result.append(group)
        }
        return (result, removed)
    }

    /// Single-quote the path when it has characters a shell would interpret.
    static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@:")
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Read, back up, write

    private var target: URL { settingsURL.resolvingSymlinksInPath() }

    func load() throws -> (root: JSONObject, original: Data?) {
        let url = target
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], nil) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw AdapterError.io("cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: data, options: []) } catch {
            log("refuse \(url.lastPathComponent): invalid JSON")
            throw AdapterError.unrecognizedConfig("\(url.lastPathComponent) is not valid JSON; fix it manually")
        }
        guard let root = parsed as? JSONObject else {
            throw AdapterError.unrecognizedConfig("\(url.lastPathComponent) top level is not an object")
        }
        return (root, data)
    }

    private func mutate(_ change: (inout JSONObject) throws -> Void) throws -> URL? {
        let (root, original) = try load()
        var updated = root
        try change(&updated)
        if NSDictionary(dictionary: root).isEqual(to: updated) { return nil }

        let backup = try original.map { try makeBackup($0) }
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw AdapterError.io("cannot serialize settings: \(error.localizedDescription)")
        }
        let url = target
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.atomicWrite(data + Data("\n".utf8), to: url, mode: Self.existingMode(of: url) ?? 0o600)
        log("updated \(url.lastPathComponent)")
        return backup
    }

    private func makeBackup(_ original: Data) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: clock.now()) + "-" + String(UUID().uuidString.prefix(6))
        let dir = backupRoot.appendingPathComponent(stamp, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try original.write(to: dir.appendingPathComponent(target.lastPathComponent), options: .atomic)
        } catch {
            // No backup, no write.
            throw AdapterError.io("backup failed: \(error.localizedDescription)")
        }
        return dir
    }

    private static func existingMode(of url: URL) -> mode_t? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    /// temp file in the same directory -> write -> fsync -> rename -> fsync directory.
    static func atomicWrite(_ data: Data, to url: URL, mode: mode_t) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).muster-\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw AdapterError.io("cannot create temp file: \(String(cString: strerror(errno)))") }
        var fdOpen = true
        var renamed = false
        defer {
            if fdOpen { close(fd) }
            if !renamed { unlink(tmp.path) }
        }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, base + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AdapterError.io("write failed: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
        _ = fchmod(fd, mode)
        guard fsync(fd) == 0 else { throw AdapterError.io("fsync failed: \(String(cString: strerror(errno)))") }
        fdOpen = false
        guard close(fd) == 0 else { throw AdapterError.io("close failed: \(String(cString: strerror(errno)))") }
        guard rename(tmp.path, url.path) == 0 else {
            throw AdapterError.io("rename failed: \(String(cString: strerror(errno)))")
        }
        renamed = true
        let dirFD = open(dir.path, O_RDONLY)
        if dirFD >= 0 {
            _ = fsync(dirFD)
            close(dirFD)
        }
    }
}
