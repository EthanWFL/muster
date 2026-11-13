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
    public static func scan(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [AgentDiagnostic] {
        let fm = FileManager.default
        let targets = InstructionTargets.detect(home: home, environment: environment)
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home + "/.local/bin", home + "/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        func fileState(_ path: String) -> DiagnosticFileState {
            guard fm.fileExists(atPath: path) else { return .missing }
            return fm.isReadableFile(atPath: path) ? .readable : .unreadable
        }
        return AgentRegistry.all.map { agent in
            let executable = agent.executables.lazy.flatMap { name in
                directories.filter { $0.hasPrefix("/") }.map { $0 + "/" + name }
            }.first { path in
                var directory: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && fm.isExecutableFile(atPath: path)
            }
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
