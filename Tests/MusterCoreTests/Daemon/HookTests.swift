import MusterProtocol
import Darwin
import Foundation
import Testing

@testable import MusterCore

@Suite struct HookOutputTests {
    @Test func allowWritesPermissionDecisionJSON() throws {
        for d in [WireDecision.allow, .allowSimilar] {
            let out = HookOutput.make(decision: d, reason: nil)
            #expect(out.exitCode == 0)
            #expect(out.stderr.isEmpty)
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(out.stdout.utf8))
            #expect(json["hookSpecificOutput"]?["permissionDecision"]?.stringValue == "allow")
        }
    }

    /// M0（E6/h3）：JSON deny 能阻止执行，模型看到的正好是 reason 文本，没有额外前缀。
    @Test func denyWritesPermissionDecisionJSON() throws {
        let out = HookOutput.make(decision: .deny, reason: "too risky")
        #expect(out.exitCode == 0)
        #expect(out.stderr.isEmpty)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(out.stdout.utf8))
        #expect(json["hookSpecificOutput"]?["permissionDecision"]?.stringValue == "deny")
        #expect(json["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue == "too risky")
        #expect(json["hookSpecificOutput"]?["hookEventName"]?.stringValue == "PreToolUse")
    }

    /// 空的 deny 原因也必须给出非空 reason（R3）
    @Test func denyWithoutReasonStillCarriesText() throws {
        let out = HookOutput.make(decision: .deny, reason: "")
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(out.stdout.utf8))
        #expect(json["hookSpecificOutput"]?["permissionDecisionReason"]?.stringValue?.isEmpty == false)
    }

    @Test func noDecisionAndFailureProduceNothing() {
        #expect(HookOutput.make(decision: .noDecision, reason: "x") == .noDecision)
        #expect(HookOutput.make(decision: nil, reason: nil) == .noDecision)
        #expect(HookOutput.noDecision.exitCode == 0)
        #expect(HookOutput.noDecision.stdout.isEmpty)
    }
}

@Suite struct HookRequestBuilderTests {
    private func stdin(_ obj: [String: JSONValue]) -> Data {
        (try? JSONEncoder().encode(JSONValue.object(obj))) ?? Data()
    }

    @Test func buildsRequestFromPreToolUse() throws {
        let data = stdin([
            "hook_event_name": .string("PreToolUse"), "session_id": .string("s9"),
            "cwd": .string("/work"), "tool_name": .string("Bash"),
            "tool_input": .object(["command": .string("ls")]),
        ])
        let req = try #require(HookRequestBuilder.build(stdin: data, id: "abc"))
        #expect(req.id == "abc")
        #expect(req.session == "s9")
        #expect(req.tool == "Bash")
        #expect(req.cwd == "/work")
        #expect(req.input["command"]?.stringValue == "ls")
        #expect(req.truncated == nil)
    }

    @Test func truncatesHugeStrings() throws {
        let big = String(repeating: "a", count: Wire.maxContentBytes * 3)
        let data = stdin([
            "session_id": .string("s"), "tool_name": .string("Write"),
            "tool_input": .object(["content": .string(big), "file_path": .string("/x")]),
        ])
        let req = try #require(HookRequestBuilder.build(stdin: data))
        #expect(req.truncated == true)
        #expect(req.input["content"]?.stringValue?.utf8.count == Wire.maxContentBytes)
        #expect(req.input["file_path"]?.stringValue == "/x")
    }

    @Test func truncationKeepsMultibyteCharactersIntact() throws {
        let big = String(repeating: "界", count: Wire.maxContentBytes)
        let data = stdin(["tool_name": .string("Write"), "tool_input": .object(["content": .string(big)])])
        let req = try #require(HookRequestBuilder.build(stdin: data))
        let s = try #require(req.input["content"]?.stringValue)
        #expect(s.utf8.count <= Wire.maxContentBytes)
        #expect(s.allSatisfy { $0 == "界" })
    }

    @Test func rejectsGarbage() {
        #expect(HookRequestBuilder.build(stdin: Data("not json".utf8)) == nil)
        #expect(HookRequestBuilder.build(stdin: Data()) == nil)
        #expect(HookRequestBuilder.build(stdin: Data("[1,2]".utf8)) == nil)
        #expect(HookRequestBuilder.build(stdin: stdin(["session_id": .string("s")])) == nil)
    }
}

@Suite struct SocketPathTests {
    @Test func resolvePrefersEnvironment() {
        #expect(SocketPath.resolve(environment: ["MUSTER_SOCK": "/tmp/x.sock"]) == "/tmp/x.sock")
        #expect(
            SocketPath.resolve(environment: ["HOME": "/Users/u"])
                == "/Users/u/Library/Application Support/Muster/agentd.sock")
    }

    @Test func addressLengthLimit() {
        #expect(SocketPath.makeAddress(path: "/" + String(repeating: "a", count: 102)) != nil)
        #expect(SocketPath.makeAddress(path: "/" + String(repeating: "a", count: 103)) == nil)
        #expect(SocketPath.makeAddress(path: "") == nil)
    }
}

/// 运行真实的 muster-hook 可执行文件。
@Suite(.serialized) struct HookBinaryTests {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// 与测试 bundle 同目录（.build/<config>/）。
    static func hookBinaryPath() -> String? {
        if let p = ProcessInfo.processInfo.environment["MUSTER_HOOK_BIN"] { return p }
        var dirs: [String] = []
        for b in Bundle.allBundles where b.bundlePath.hasSuffix(".xctest") {
            dirs.append((b.bundlePath as NSString).deletingLastPathComponent)
        }
        for a in CommandLine.arguments where a.contains(".xctest") {
            let bundle = a.components(separatedBy: ".xctest").first! + ".xctest"
            dirs.append((bundle as NSString).deletingLastPathComponent)
        }
        for d in dirs {
            let p = d + "/muster-hook"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func run(sock: String, stdin: String, timeoutMs: Int? = nil) throws -> Result {
        let bin = try #require(hookBinaryPath(), "muster-hook binary not found next to the test bundle")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        var env = ProcessInfo.processInfo.environment
        env["MUSTER_SOCK"] = sock
        if let t = timeoutMs { env["MUSTER_HOOK_TIMEOUT_MS"] = String(t) }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(
            status: p.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self))
    }

    static let payload = """
        {"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}
        """

    @Test func noServerMeansNoDecision() throws {
        let tmp = TempSocket()
        let r = try Self.run(sock: tmp.path, stdin: Self.payload)
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.isEmpty)
    }

    @Test func badStdinMeansNoDecision() throws {
        let tmp = TempSocket()
        let server = SocketServer(path: tmp.path, handler: ClosureRequestHandler(onRequest: { WireResponse(id: $0.id, decision: .allow) }))
        try server.start()
        defer { server.stop(); tmp.cleanup() }
        let r = try Self.run(sock: tmp.path, stdin: "this is not json")
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
    }

    @Test func allowIsForwarded() throws {
        let tmp = TempSocket()
        let log = EventLog()
        let server = SocketServer(
            path: tmp.path,
            handler: ClosureRequestHandler(onRequest: { req in
                log.began(req.id)
                defer { log.ended() }
                #expect(req.tool == "Bash")
                #expect(req.session == "s1")
                return WireResponse(id: req.id, decision: .allow, ttlMs: 90_000)
            }))
        try server.start()
        defer { server.stop(); tmp.cleanup() }
        let r = try Self.run(sock: tmp.path, stdin: Self.payload)
        #expect(r.status == 0)
        #expect(r.stdout.contains("\"permissionDecision\":\"allow\""))
        #expect(log.handledIDs.count == 1)
    }

    @Test func denyCarriesReasonInJSON() throws {
        let tmp = TempSocket()
        let server = SocketServer(
            path: tmp.path,
            handler: ClosureRequestHandler(onRequest: {
                WireResponse(id: $0.id, decision: .deny, reason: "use a safer command")
            }))
        try server.start()
        defer { server.stop(); tmp.cleanup() }
        let r = try Self.run(sock: tmp.path, stdin: Self.payload)
        #expect(r.status == 0)
        #expect(r.stderr.isEmpty)
        #expect(r.stdout.contains("\"permissionDecision\":\"deny\""))
        #expect(r.stdout.contains("use a safer command"))
    }

    @Test func localTimeoutFallsBackToNoDecision() throws {
        let tmp = TempSocket()
        let log = EventLog()
        let server = SocketServer(
            path: tmp.path,
            handler: ClosureRequestHandler(
                onRequest: { req in
                    log.began(req.id)
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    return WireResponse(id: req.id, decision: .allow)
                },
                onCancel: { log.didCancel($0.id) }))
        try server.start()
        defer { server.stop(); tmp.cleanup() }
        let r = try Self.run(sock: tmp.path, stdin: Self.payload, timeoutMs: 300)
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        // 钩子退出后连接断开，服务端必须收到取消回调。
        #expect(log.waitForCancel())
    }

    @Test func serverNoDecisionIsSilent() throws {
        let tmp = TempSocket()
        let server = SocketServer(
            path: tmp.path,
            handler: ClosureRequestHandler(onRequest: { WireResponse(id: $0.id, decision: .noDecision) }))
        try server.start()
        defer { server.stop(); tmp.cleanup() }
        let r = try Self.run(sock: tmp.path, stdin: Self.payload)
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.isEmpty)
    }
}
