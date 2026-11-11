import Foundation
import Testing
@testable import MusterProtocol

@Suite struct WireCodecTests {
    @Test func requestRoundTrip() throws {
        let req = WireRequest(id: "c1", session: "s1", agent: "claude", tool: "Bash",
                              input: ["command": .string("ls")], cwd: "/x", ts: 1,
                              pid: 4242, pidStartedAt: 1_700_000_000.5)
        let line = try WireCodec.encodeLine(req)
        #expect(line.last == 0x0A)
        let back = try WireCodec.decode(WireRequest.self, line: line.dropLast())
        #expect(back == req)
        #expect(back.pid == 4242)
        #expect(back.pidStartedAt == 1_700_000_000.5)
    }

    @Test func responseUsesSnakeCaseKeys() throws {
        let line = try WireCodec.encodeLine(WireResponse(id: "c1", decision: .allowSimilar, ttlMs: 90000))
        let s = String(decoding: line, as: UTF8.self)
        #expect(s.contains("\"ttl_ms\":90000"))
        #expect(s.contains("\"allow_similar\""))
    }

    @Test func invalidJSONThrows() {
        #expect(throws: (any Error).self) {
            try WireCodec.decode(WireRequest.self, line: Data("nope".utf8))
        }
    }
}
