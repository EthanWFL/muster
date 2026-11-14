import Foundation

public struct AgentApplication: Sendable {
    public var relativePath: String
    public var bundleIdentifier: String? = nil
}

/// Installation evidence is independent of the registry's supported capabilities.
public enum AgentInstallation {
    public static func detect(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
                              executableDirectories: [String]? = nil, applicationDirectories: [String]? = nil) -> [AgentDescriptor] {
        let binaries = executableDirectories ?? searchDirectories(home: home, environment: environment)
        let applications = applicationDirectories ?? ["/Applications", home + "/Applications"]
        return AgentRegistry.all.filter { agent in
            executablePath(for: agent, directories: binaries) != nil || applicationPath(for: agent, directories: applications) != nil
        }
    }

    static func executablePath(for agent: AgentDescriptor, directories: [String]) -> String? {
        let fm = FileManager.default
        for name in agent.executables + agent.installationExecutables {
            for directory in directories where directory.hasPrefix("/") {
                let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    private static func applicationPath(for agent: AgentDescriptor, directories: [String]) -> String? {
        let fm = FileManager.default
        for candidate in agent.applications {
            for directory in directories where directory.hasPrefix("/") {
                let app = URL(fileURLWithPath: directory).appendingPathComponent(candidate.relativePath)
                guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      info["CFBundlePackageType"] as? String == "APPL",
                      let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
                      candidate.bundleIdentifier.map({ $0 == identifier }) ?? true,
                      let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
                      !executable.contains("/"), executable != ".", executable != ".." else { continue }
                let binary = app.appendingPathComponent("Contents/MacOS/" + executable).path
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: binary, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isExecutableFile(atPath: binary) { return app.path }
            }
        }
        return nil
    }

    static func searchDirectories(home: String, environment: [String: String]) -> [String] {
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += ["/.local/bin", "/.npm-global/bin", "/.bun/bin", "/.volta/bin", "/.asdf/shims",
                  "/.local/share/mise/shims", "/Library/pnpm", "/.cargo/bin"].map { home + $0 }
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let nvm = environment["NVM_DIR"] ?? home + "/.nvm"
        if nvm.hasPrefix("/"), let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm + "/versions/node") {
            paths += versions.sorted().suffix(32).map { nvm + "/versions/node/" + $0 + "/bin" }
        }
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }
}
