import Foundation

/// Transcript activity windows, overridable in tests.
public struct SessionPolicy: Equatable, Sendable {
    public static let defaultRetention: TimeInterval = 24 * 60 * 60
    public static let defaultDiskRunningWindow: TimeInterval = 30
    public static let defaultEndedAfterInactivity: TimeInterval = 30 * 60

    public var retention: TimeInterval
    public var diskRunningWindow: TimeInterval
    public var endedAfterInactivity: TimeInterval

    public init(
        retention: TimeInterval = SessionPolicy.defaultRetention,
        diskRunningWindow: TimeInterval = SessionPolicy.defaultDiskRunningWindow,
        endedAfterInactivity: TimeInterval = SessionPolicy.defaultEndedAfterInactivity
    ) {
        self.retention = retention
        self.diskRunningWindow = diskRunningWindow
        self.endedAfterInactivity = endedAfterInactivity
    }

    public static let standard = SessionPolicy()
}
