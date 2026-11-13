import Foundation

public struct ConfigurationPreset: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let agentID: String
    public let provider: String
    public let model: String

    public init(id: UUID = UUID(), name: String, agentID: String, provider: String, model: String) {
        self.id = id; self.name = name; self.agentID = agentID; self.provider = provider; self.model = model
    }
}

public enum PresetError: String, LocalizedError {
    case invalid = "Preset name, provider and model must be nonempty single-line values."
    case duplicate = "A preset with this name already exists for this agent."
    case unsupported = "This agent does not support model presets."
    public var errorDescription: String? { rawValue }
}

/// Presets contain startup defaults only, never authentication data or entire config files.
public struct ConfigurationPresetStore {
    public let url: URL
    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Muster/configuration-presets.json")) { self.url = url }

    public func load() throws -> [ConfigurationPreset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ConfigurationPreset].self, from: Data(contentsOf: url))
    }

    public func save(_ preset: ConfigurationPreset) throws {
        guard AgentRegistry.agent(preset.agentID)?.editableConfiguration == true else { throw PresetError.unsupported }
        guard [preset.name, preset.provider, preset.model].allSatisfy({ value in
            !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw PresetError.invalid }
        var presets = try load() // A damaged store is never replaced with an empty one.
        guard !presets.contains(where: { $0.id != preset.id && $0.agentID == preset.agentID
            && $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }) else { throw PresetError.duplicate }
        presets.removeAll { $0.id == preset.id }
        presets.append(preset)
        try write(presets)
    }

    public func remove(_ id: UUID) throws {
        var presets = try load()
        presets.removeAll { $0.id == id }
        try write(presets)
    }

    private func write(_ presets: [ConfigurationPreset]) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".presets-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(presets)
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }
}
