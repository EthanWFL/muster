import Foundation

/// Capabilities are separate contracts so a new Agent integration only has to
/// provide the parts it actually supports. The registry stays a static table.

public protocol AgentTranscriptSource: Sendable {
    var id: String { get }
    var kind: AgentKind? { get }
    var transcriptLocation: AgentLocation? { get }
    var transcriptScanDepth: Int { get }
}

public protocol AgentConfigurationSource: Sendable {
    var id: String { get }
    var configurationLocation: AgentLocation? { get }
    var configurationOrder: Int { get }
    var configurationIsEditable: Bool { get }
    var configurationIsJSON: Bool { get }
    var configurationProviderKey: String { get }
    var configurationModelKey: String { get }
}

public protocol AgentSkillSource: Sendable {
    var id: String { get }
    var skillDirectory: AgentLocation? { get }
    var skillDiscoveryDirectories: [AgentLocation] { get }
    var skillSharedReaders: [String] { get }
}

public protocol AgentProcessSource: Sendable {
    var id: String { get }
    var executables: [String] { get }
    var installationExecutables: [String] { get }
    var nodePackages: [String] { get }
    var applications: [AgentApplication] { get }
}

extension AgentDescriptor: AgentTranscriptSource {
    public var transcriptLocation: AgentLocation? { transcript }
    public var transcriptScanDepth: Int { transcriptDepth }
}

extension AgentDescriptor: AgentConfigurationSource {
    public var configurationLocation: AgentLocation? { configuration }
    public var configurationIsEditable: Bool { editableConfiguration }
    public var configurationIsJSON: Bool { jsonConfiguration }
    public var configurationProviderKey: String { providerKey }
    public var configurationModelKey: String { modelKey }
}

extension AgentDescriptor: AgentSkillSource {
    public var skillDirectory: AgentLocation? { skills?.directory }
    public var skillDiscoveryDirectories: [AgentLocation] { skills?.additionalDiscovery ?? [] }
    public var skillSharedReaders: [String] { skills?.sharedReaders ?? [] }
}

extension AgentDescriptor: AgentProcessSource {}
