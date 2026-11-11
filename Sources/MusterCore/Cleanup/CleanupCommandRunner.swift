import Foundation

/// `CommandRunner` 的真实实现：不经 shell，经 `/usr/bin/env` 按 PATH 找可执行文件。
public struct CleanupCommandRunner: CommandRunner {
    public init() {}

    private final class Box: @unchecked Sendable { var data = Data() }

    public func run(_ argv: [String], cwd: String?) throws -> CommandResult {
        guard !argv.isEmpty else { return CommandResult(status: 127, stderr: "empty argv") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // 两个管道并发读取，避免输出过多时子进程阻塞
        let outBox = Box(), errBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outBox.data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self))
    }
}
