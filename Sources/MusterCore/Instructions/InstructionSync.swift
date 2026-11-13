import Foundation

/// Muster 自己的文件都在这里：共享指令正文、同步状态、写入前的备份。
public struct InstructionPaths: Sendable, Equatable {
    public var support: String

    public init(support: String) { self.support = support }

    public static func standard(home: String = NSHomeDirectory()) -> InstructionPaths {
        InstructionPaths(support: home + "/Library/Application Support/Muster")
    }

    public var sharedText: String { support + "/instructions.md" }

    /// 每套指令各一个文件；默认那套沿用 `instructions.md`。
    public func setFile(_ id: String) -> String {
        id == InstructionSet.defaultID ? sharedText : support + "/instruction-sets/" + id + ".md"
    }
    public var stateFile: String { support + "/instructions.json" }
    public var backups: String { support + "/backups" }
}

/// 哪些 agent 开着同步、上次写进去的指纹。
///
/// 指纹只用来判断「文件里的段被别人改过」；没有它，一次自动写入就会把手改的内容盖掉。
/// 一套共享指令。默认那套的 `name` 空着，界面自己翻译成「默认」。
public struct InstructionSet: Codable, Sendable, Equatable, Identifiable {
    public static let defaultID = "default"

    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static var fallback: InstructionSet { InstructionSet(id: defaultID, name: "") }
}

public struct InstructionSyncState: Codable, Sendable, Equatable {
    public var enabled: [String: Bool] = [:]
    public var writtenHash: [String: String] = [:]
    /// 最近浏览的草稿；实际写入状态由每个 Agent 的 writtenHash 表示。
    public var activeSet: String = InstructionSet.defaultID
    /// 除默认以外的套
    public var sets: [InstructionSet] = []

    public init(
        enabled: [String: Bool] = [:], writtenHash: [String: String] = [:],
        activeSet: String = InstructionSet.defaultID, sets: [InstructionSet] = []
    ) {
        self.enabled = enabled
        self.writtenHash = writtenHash
        self.activeSet = activeSet
        self.sets = sets
    }

    // 老的状态文件没有这两项，别让它整体解码失败把开关和指纹一起丢掉
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode([String: Bool].self, forKey: .enabled)) ?? [:]
        writtenHash = (try? c.decode([String: String].self, forKey: .writtenHash)) ?? [:]
        activeSet = (try? c.decode(String.self, forKey: .activeSet)) ?? InstructionSet.defaultID
        sets = (try? c.decode([InstructionSet].self, forKey: .sets)) ?? []
    }

    /// 默认那套 + 用户建的套；`activeSet` 指向不存在的套时退回默认。
    public var allSets: [InstructionSet] { [.fallback] + sets }

    public func setNamed(_ id: String) -> InstructionSet? { allSets.first { $0.id == id } }

    public var resolvedActiveSet: String {
        setNamed(activeSet) == nil ? InstructionSet.defaultID : activeSet
    }
}

public enum InstructionAction: Sendable, Equatable {
    case create
    case update
    case remove
    case unchanged
    /// 不做任何事情的说明，例如共享指令为空、文件读不到、agent 没装
    case skipped(String)
}

public struct InstructionPlan: Sendable, Equatable {
    public var target: InstructionTarget
    public var action: InstructionAction
    /// 文件里现在的那段（没有就是 nil）
    public var existingBlock: String?
    /// 这次要写进去的那段
    public var newBlock: String
    /// 用户自有内容行数，写入不会动它
    public var ownLineCount: Int
    /// 写完之后整个文件的样子
    public var resultingFile: String
    /// 写前备份的位置，`apply` 之后才有值
    public var backupPath: String?
    /// 生成预览时的文件，用于拒绝覆盖预览之后的外部编辑。
    public var originalFile: String?
}

/// 写前留下的那份原文件，用来回滚。
public struct InstructionBackup: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var agentID: String
    public var createdAt: Date
    /// 备份文件的绝对路径
    public var path: String
    /// 它原来在哪（写入前那个文件的位置）
    public var originalPath: String
}

/// 把一份共享指令写进各 agent 的用户级指令文件，只写两行标记之间的部分。
///
/// 三条安全线（都是 magpie 踩过的坑）：
/// - 共享指令为空时**绝不**自动撤掉已经写进去的段（库被重置不该清空 agent 的配置）；
/// - 文件读不到视为「未知」，不写；
/// - 每次写前先备份原文件，写入是原子的。
public struct InstructionSync: Sendable {
    public let paths: InstructionPaths
    private let keepBackups = 10

    public init(paths: InstructionPaths = .standard()) { self.paths = paths }

    // MARK: 自己的文件

    public func text(_ setID: String) -> String {
        (try? String(contentsOfFile: paths.setFile(setID), encoding: .utf8)) ?? ""
    }

    public func saveText(_ text: String, setID: String) throws {
        let file = paths.setFile(setID)
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// 删掉一套：连文件一起删；调用方负责改 state 并存盘。
    public func deleteSet(_ id: String) throws {
        guard id != InstructionSet.defaultID else { return }
        let file = paths.setFile(id)
        if FileManager.default.fileExists(atPath: file) {
            try FileManager.default.removeItem(atPath: file)
        }
    }

    /// 新建一套空的共享指令；调用方负责写进 state 并切换。
    public func createSet(named name: String) throws -> InstructionSet {
        let set = InstructionSet(id: String(UUID().uuidString.prefix(8)).lowercased(), name: name)
        try saveText("", setID: set.id)
        return set
    }

    public func state() -> InstructionSyncState {
        guard let data = FileManager.default.contents(atPath: paths.stateFile),
              let state = try? JSONDecoder().decode(InstructionSyncState.self, from: data) else {
            return InstructionSyncState()
        }
        return state
    }

    public func save(_ state: InstructionSyncState) throws {
        try FileManager.default.createDirectory(atPath: paths.support, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: URL(fileURLWithPath: paths.stateFile), options: .atomic)
    }

    // MARK: 计划（只读）

    /// 算出要把共享指令写进这个 agent 会发生什么，不写任何文件。
    public func plan(
        for target: InstructionTarget, sharedText: String, state: InstructionSyncState
    ) -> InstructionPlan {
        let newBlock = sharedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = readFile(target.path)

        func result(_ action: InstructionAction, _ current: String?, _ own: Int, _ next: String) -> InstructionPlan {
            InstructionPlan(
                target: target, action: action, existingBlock: current, newBlock: newBlock,
                ownLineCount: own, resultingFile: next, backupPath: nil, originalFile: file)
        }

        guard let file else {
            if FileManager.default.fileExists(atPath: target.path) {
                return result(.skipped("unreadable"), nil, 0, "")
            }
            guard target.installed, newBlock.isEmpty == false else {
                return result(.skipped(target.installed ? "empty" : "not installed"), nil, 0, "")
            }
            let next = InstructionBlock.withBlock("", newBlock)
            return result(.create, nil, 0, next)
        }

        let parts = InstructionBlock.split(file)
        let own = InstructionBlock.ownLineCount(file)
        let next = InstructionBlock.withBlock(file, newBlock)

        guard let current = parts?.block, current.isEmpty == false else {
            // 文件里还没有 Muster 的段
            guard newBlock.isEmpty == false else { return result(.unchanged, nil, own, file) }
            return result(.create, nil, own, next)
        }
        if newBlock.isEmpty {
            // 共享指令空着而文件里有段：多半是库被重置，撤掉就把唯一一份内容删了
            return result(.skipped("empty"), current, own, file)
        }
        if current == newBlock { return result(.unchanged, current, own, file) }

        // 文件里的段被手改过，而共享指令自上次写入后没变：保留手改
        if let recorded = state.writtenHash[target.id],
           InstructionBlock.hash(current) != recorded,
           InstructionBlock.hash(newBlock) == recorded {
            return result(.skipped("edited in the file"), current, own, file)
        }
        return result(.update, current, own, next)
    }

    /// 关掉开关时用：只撤 Muster 那段，用户自有内容不动。
    public func planRemoval(for target: InstructionTarget) -> InstructionPlan {
        let file = readFile(target.path)
        guard let file, let current = InstructionBlock.split(file)?.block else {
            return InstructionPlan(
                target: target, action: .unchanged, existingBlock: nil, newBlock: "",
                ownLineCount: file.map(InstructionBlock.ownLineCount) ?? 0,
                resultingFile: file ?? "", backupPath: nil, originalFile: file)
        }
        return InstructionPlan(
            target: target, action: .remove, existingBlock: current, newBlock: "",
            ownLineCount: InstructionBlock.ownLineCount(file),
            resultingFile: InstructionBlock.withBlock(file, ""), backupPath: nil, originalFile: file)
    }

    // MARK: 执行

    /// 按计划写文件。写前把原文件备份一份，写入是原子的。
    @discardableResult
    public func apply(_ plan: InstructionPlan) throws -> InstructionPlan {
        switch plan.action {
        case .unchanged, .skipped:
            return plan
        case .create, .update, .remove:
            break
        }
        var done = plan
        guard readFile(plan.target.path) == plan.originalFile,
              plan.originalFile != nil || !FileManager.default.fileExists(atPath: plan.target.path) else {
            throw InstructionWriteError.fileChanged
        }
        if FileManager.default.fileExists(atPath: plan.target.path) {
            done.backupPath = try backup(plan.target)
        } else {
            let dir = (plan.target.path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // 撤块后文件为空时保留一个空文件：agent 会去读这个路径
        try done.resultingFile.write(toFile: plan.target.path, atomically: true, encoding: .utf8)
        return done
    }

    private func backup(_ target: InstructionTarget) throws -> String? {
        guard let data = FileManager.default.contents(atPath: target.path) else { return nil }
        let now = Date()
        // 同一秒内可能连写两次，目录名带上毫秒并按名字仍可排序
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        var dir = paths.backups + "/" + stamp + "/" + target.id
        while FileManager.default.fileExists(atPath: dir) {
            stamp += "-" + String(UUID().uuidString.prefix(4)).lowercased()
            dir = paths.backups + "/" + stamp + "/" + target.id
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/" + (target.path as NSString).lastPathComponent
        try data.write(to: URL(fileURLWithPath: file), options: .atomic)
        // 记住它原来在哪、什么时候备的，恢复时不用猜
        let manifest = [
            "originalPath": target.path,
            "agent": target.id,
            "createdAt": String(now.timeIntervalSince1970),
        ]
        if let json = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try? json.write(to: URL(fileURLWithPath: dir + "/manifest.json"), options: .atomic)
        }
        pruneBackups()
        return file
    }

    // MARK: 备份

    /// 某个 agent 最近的几次备份，新的在前。
    public func backups(for agentID: String, limit: Int = 5) -> [InstructionBackup] {
        let fm = FileManager.default
        guard let stamps = try? fm.contentsOfDirectory(atPath: paths.backups) else { return [] }
        var found: [InstructionBackup] = []
        for stamp in stamps.sorted(by: >) {
            let dir = paths.backups + "/" + stamp + "/" + agentID
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let manifest = readManifest(dir + "/manifest.json")
            for name in files.sorted() where name != "manifest.json" {
                found.append(InstructionBackup(
                    agentID: agentID,
                    createdAt: manifest?.createdAt ?? Date.distantPast,
                    path: dir + "/" + name,
                    originalPath: manifest?.originalPath ?? ""))
            }
            if found.count >= limit { break }
        }
        return Array(found.prefix(limit))
    }

    /// 把某次备份写回去。**当前文件会先备份一次**，所以恢复本身也能撤销。
    @discardableResult
    public func restore(_ backup: InstructionBackup, to target: InstructionTarget) throws -> String? {
        guard let data = FileManager.default.contents(atPath: backup.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let previous = try self.backup(target)
        try data.write(to: URL(fileURLWithPath: target.path), options: .atomic)
        return previous
    }

    private func readManifest(_ path: String) -> (originalPath: String, createdAt: Date)? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let original = object["originalPath"] else { return nil }
        let created = object["createdAt"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return (original, created ?? Date.distantPast)
    }

    private func pruneBackups() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: paths.backups) else { return }
        let sorted = entries.sorted(by: >)
        for stale in sorted.dropFirst(keepBackups) {
            try? fm.removeItem(atPath: paths.backups + "/" + stale)
        }
    }

    /// 读文件；不存在返回 nil，存在但读不出来也返回 nil（调用方用 fileExists 区分）。
    private func readFile(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum InstructionWriteError: LocalizedError {
    case fileChanged
    public var errorDescription: String? {
        "The file changed after the preview. Review the refreshed preview before applying again."
    }
}
