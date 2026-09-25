import Foundation

public struct WatchRefreshRequest: Codable, Sendable, Equatable {
    public static let messageKey = "vibebuddy.watch.refresh"
    public let id: UUID
    public let sourceID: String
    public let pairingEpoch: String
    public init(id: UUID = UUID(), sourceID: String, pairingEpoch: String) {
        self.id = id; self.sourceID = sourceID; self.pairingEpoch = pairingEpoch
    }
    public func accepts(_ state: WatchDashboardState) -> Bool {
        !sourceID.isEmpty && !pairingEpoch.isEmpty && state.sourceID == sourceID && state.pairingEpoch == pairingEpoch
    }
}
public struct WatchRefreshReply: Codable, Sendable {
    public static let messageKey = "vibebuddy.watch.refreshReply"
    public let id: UUID
    public let state: WatchDashboardState?
    public init(id: UUID, state: WatchDashboardState?) { self.id = id; self.state = state }
    public func snapshot(for request: WatchRefreshRequest) -> WatchDashboardState? {
        guard id == request.id, let state, request.accepts(state) else { return nil }
        return state
    }
}

/// When the wrist asks the iPhone for a snapshot on its own, rather than from a
/// task detail's refresh (WR-12).
///
/// The application context only moves when the iPhone writes it, and a locked
/// iPhone has no stream to the Mac, so it writes nothing: a task started after
/// the lock never reached the wrist, however often the app was opened. A
/// `sendMessage` from the Watch does wake the locked iPhone, which then reads
/// the Mac over HTTP. That wakes the phone and costs a request to the Mac, so it
/// is paced: one at a time, and a new one no sooner than `interval` after the
/// last one was sent if it came back, `retryInterval` if it did not.
public struct WatchActivationRefreshPolicy: Sendable, Equatable {
    public static let interval: TimeInterval = 15
    public static let retryInterval: TimeInterval = 3
    public private(set) var inFlight: UUID?
    private var lastSent: Date?
    private var lastSucceeded = false

    public init() {}

    /// Claims the slot for `id` when a request may go out now.
    public mutating func begin(_ id: UUID, now: Date) -> Bool {
        guard inFlight == nil, retryDelay(now: now) == nil else { return false }
        if let lastSent, lastSucceeded,
           now.timeIntervalSince(lastSent) < Self.interval { return false }
        inFlight = id
        lastSent = now
        return true
    }

    /// How long until a failed request may be retried, when that is what is
    /// holding the next one back. A good reply's pace is not waited out: the
    /// list is fresh, and the next activation will ask again.
    public func retryDelay(now: Date) -> TimeInterval? {
        guard inFlight == nil, !lastSucceeded, let lastSent else { return nil }
        let left = Self.retryInterval - now.timeIntervalSince(lastSent)
        return left > 0 ? left : nil
    }

    /// Releases the slot. False for a reply to an attempt that is no longer the
    /// one in flight, which the caller then ignores.
    public mutating func finish(_ id: UUID, succeeded: Bool) -> Bool {
        guard inFlight == id else { return false }
        inFlight = nil
        lastSucceeded = succeeded
        return true
    }
}
