import Foundation

public enum DiagnosticFileState: String, Sendable {
    case missing, unreadable, readable, invalid, unsupported
}

public struct AgentDiagnostic: Identifiable, Sendable {
    public let agent: AgentDescriptor
    public let executablePath: String?
    public let configurationPath: String?
    public let configurationState: DiagnosticFileState?
    public let rulesPath: String?
    public let rulesState: DiagnosticFileState?
    public var id: String { agent.id }
}

public enum AgentDiagnostics {
    /// Inspects known paths only. Does not launch agents, open authentication files or contact providers.
    public static func scan(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
                            agentIDs: Set<String>? = nil) -> [AgentDiagnostic] {
        let fm = FileManager.default
        let targets = InstructionTargets.detect(home: home, environment: environment)
        let directories = AgentInstallation.searchDirectories(home: home, environment: environment)
        func fileState(_ path: String) -> DiagnosticFileState {
            guard fm.fileExists(atPath: path) else { return .missing }
            return fm.isReadableFile(atPath: path) ? .readable : .unreadable
        }
        return AgentRegistry.all.filter { agentIDs?.contains($0.id) ?? true }.map { agent in
            let executable = AgentInstallation.executablePath(for: agent, directories: directories)
            let config = agent.configuration?.resolve(home: home, environment: environment)
            var configState = config.map(fileState)
            if let config, configState == .readable, agent.editableConfiguration {
                do {
                    _ = try AgentConfigurationStore().load(AgentConfiguration(id: agent.id, name: agent.name, path: config))
                } catch ConfigurationError.unsupported { configState = .unsupported }
                  catch { configState = .invalid }
            }
            let rules = targets.first { $0.id == agent.id }?.path
            return AgentDiagnostic(agent: agent, executablePath: executable,
                configurationPath: config, configurationState: configState, rulesPath: rules, rulesState: rules.map(fileState))
        }
    }
}
