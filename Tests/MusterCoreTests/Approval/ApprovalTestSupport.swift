import Foundation
import MusterProtocol
@testable import MusterCore

/// 手动推进的时钟，测试里不 sleep。
final class ApprovalTestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }

    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

func bashInput(_ command: String) -> [String: JSONValue] { ["command": .string(command)] }

let sharedClassifier = RiskClassifier()

func risk(_ command: String) -> Risk {
    sharedClassifier.classify(tool: "Bash", input: bashInput(command))
}

@discardableResult
func submitBash(
    _ store: ApprovalStore, id: String, session: String = "s1", command: String
) -> SubmitOutcome {
    store.submit(
        requestID: id, sessionID: session, agent: .claude, tool: "Bash",
        input: bashInput(command), cwd: "/tmp/proj")
}

@discardableResult
func submitTool(
    _ store: ApprovalStore, id: String, session: String = "s1", tool: String,
    input: [String: JSONValue]
) -> SubmitOutcome {
    store.submit(requestID: id, sessionID: session, agent: .claude, tool: tool, input: input, cwd: "/tmp/proj")
}
