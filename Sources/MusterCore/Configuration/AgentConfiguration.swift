import Foundation

public struct AgentConfiguration: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public var editable: Bool { AgentRegistry.agent(id)?.editableConfiguration ?? false }
    public var providerKey: String { AgentRegistry.agent(id)?.providerKey ?? "model_provider" }
    public var modelKey: String { AgentRegistry.agent(id)?.modelKey ?? "model" }

    public static func detect(home: String = NSHomeDirectory(),
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Self] {
        AgentRegistry.all.sorted { $0.configurationOrder < $1.configurationOrder }.compactMap { agent in
            guard let location = agent.configuration else { return nil }
            let path = location.resolve(home: home, environment: environment)
            guard exists(path) else { return nil }
            return Self(id: agent.id, name: agent.name, path: path)
        }
    }
}

public struct ConfigurationModelChoice: Hashable {
    public let provider: String
    public let model: String
    public var label: String { provider + " / " + model }
    public init(provider: String, model: String) { self.provider = provider; self.model = model }
}

public enum ConfigurationError: String, LocalizedError {
    case invalid = "Invalid configuration. Open the original file to fix it."
    case unsupported = "This TOML layout cannot be safely edited here. Open the original file."
    case changed = "The file changed outside Muster. Reload it before saving."
    case invalidValue = "Provider and model must be nonempty single-line values."
    case noBackup = "No matching backup is available."
    public var errorDescription: String? { rawValue }
}

public struct ConfigurationSnapshot {
    public let target: AgentConfiguration
    public let data: Data
    public let resolvedPath: String
    public let provider: String
    public let model: String
}

/// Only changes the two startup defaults; never loads or edits authentication files.
public struct AgentConfigurationStore {
    public let backupDirectory: URL
    public init(backupDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Muster/configuration-backups")) {
        self.backupDirectory = backupDirectory
    }

    public func load(_ target: AgentConfiguration) throws -> ConfigurationSnapshot {
        let path = URL(fileURLWithPath: target.path).resolvingSymlinksInPath().path
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fields = try ConfigurationDocument(data: data, json: AgentRegistry.agent(target.id)?.jsonConfiguration == true,
                                               keys: [target.providerKey, target.modelKey])
        return ConfigurationSnapshot(target: target, data: data, resolvedPath: path,
            provider: fields.values[target.providerKey] ?? (target.id == "codex" ? "openai" : ""),
            model: fields.values[target.modelKey] ?? "")
    }

    public func proposed(_ snapshot: ConfigurationSnapshot, provider: String, model: String) throws -> Data {
        guard snapshot.target.editable else { throw ConfigurationError.unsupported }
        let values = [snapshot.target.providerKey: provider, snapshot.target.modelKey: model]
        let previous = [snapshot.target.providerKey: snapshot.provider, snapshot.target.modelKey: snapshot.model]
        guard values.allSatisfy({ key, value in value == previous[key] ||
            (!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })) })
        else { throw ConfigurationError.invalidValue }
        let document = try ConfigurationDocument(data: snapshot.data, json: AgentRegistry.agent(snapshot.target.id)?.jsonConfiguration == true, keys: Array(values.keys))
        // Leave an absent default untouched when the user only edits the other field.
        var changes: [String: String] = [:]
        if provider != snapshot.provider { changes[snapshot.target.providerKey] = provider }
        if model != snapshot.model { changes[snapshot.target.modelKey] = model }
        return try document.replacing(changes)
    }

    public func save(_ snapshot: ConfigurationSnapshot, provider: String, model: String) throws {
        let data = try proposed(snapshot, provider: provider, model: model)
        try checkUnchanged(snapshot)
        guard data != snapshot.data else { return }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let backup = Backup(path: snapshot.resolvedPath, before: snapshot.data, after: data)
        try atomicWrite(JSONEncoder().encode(backup), to: backupURL(snapshot.target), permissions: 0o600)
        try checkUnchanged(snapshot)
        try writeConfiguration(data, snapshot: snapshot)
    }

    public func canRestore(_ snapshot: ConfigurationSnapshot) -> Bool {
        guard let backup = try? readBackup(snapshot.target) else { return false }
        return backup.path == snapshot.resolvedPath && backup.after == snapshot.data
    }

    public func restore(_ snapshot: ConfigurationSnapshot) throws {
        let backup = try readBackup(snapshot.target)
        guard backup.path == snapshot.resolvedPath, backup.after == snapshot.data else { throw ConfigurationError.noBackup }
        try checkUnchanged(snapshot)
        try writeConfiguration(backup.before, snapshot: snapshot)
    }

    public func choices(_ snapshot: ConfigurationSnapshot) -> [ConfigurationModelChoice] {
        var choices: [ConfigurationModelChoice] = []
        if !snapshot.model.isEmpty { choices.append(.init(provider: snapshot.provider, model: snapshot.model)) }
        let directory = URL(fileURLWithPath: snapshot.target.path).deletingLastPathComponent()
        if snapshot.target.id == "pi",
           let data = try? Data(contentsOf: directory.appendingPathComponent("models.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let providers = object["providers"] as? [String: [String: Any]] {
            for (provider, value) in providers {
                for model in value["models"] as? [[String: Any]] ?? [] {
                    if let id = model["id"] as? String { choices.append(.init(provider: provider, model: id)) }
                }
            }
        } else if snapshot.target.id == "codex", snapshot.provider == "openai",
                  let data = try? Data(contentsOf: directory.appendingPathComponent("models_cache.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for model in object["models"] as? [[String: Any]] ?? [] {
                if let id = model["slug"] as? String { choices.append(.init(provider: "openai", model: id)) }
            }
        }
        return Array(Set(choices)).sorted { $0.label < $1.label }
    }

    private struct Backup: Codable { let path: String; let before: Data; let after: Data }
    private func backupURL(_ target: AgentConfiguration) -> URL { backupDirectory.appendingPathComponent(target.id + ".json") }
    private func readBackup(_ target: AgentConfiguration) throws -> Backup {
        try JSONDecoder().decode(Backup.self, from: Data(contentsOf: backupURL(target)))
    }
    private func checkUnchanged(_ snapshot: ConfigurationSnapshot) throws {
        let current = URL(fileURLWithPath: snapshot.target.path).resolvingSymlinksInPath()
        guard current.path == snapshot.resolvedPath,
              try Data(contentsOf: current) == snapshot.data else { throw ConfigurationError.changed }
    }
    private func writeConfiguration(_ data: Data, snapshot: ConfigurationSnapshot) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.resolvedPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try atomicWrite(data, to: URL(fileURLWithPath: snapshot.resolvedPath), permissions: permissions)
    }
    private func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".muster-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
