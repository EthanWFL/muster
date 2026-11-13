import Foundation

/// Observed activity followed by sustained silence merits a reminder, never a completion claim.
public struct SessionActivityMonitor {
    private var armed: Set<String> = []
    public let quietInterval: TimeInterval

    public init(quietInterval: TimeInterval = 60) { self.quietInterval = quietInterval }

    public mutating func newlyQuiet(_ sessions: [Session], now: Date) -> [Session] {
        let observed = sessions.filter { $0.isProcessAlive && $0.hasTranscript && $0.state != .ended }
        armed.formIntersection(observed.map(\.key))
        var quiet: [Session] = []
        for session in observed {
            if session.state == .running { armed.insert(session.key) }
            if session.state == .idle, armed.contains(session.key),
               now.timeIntervalSince(session.lastActivityAt) >= quietInterval {
                armed.remove(session.key)
                quiet.append(session)
            }
        }
        return quiet
    }
}
