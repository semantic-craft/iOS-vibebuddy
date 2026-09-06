import Foundation

/// The Watch's inbox: the one place that decides whether a payload — freshly
/// relayed, or restored from disk on a cold launch — is good enough to replace
/// what is on screen.
///
/// Keeping the decision here rather than in the WatchConnectivity delegate means
/// corrupt data, an out-of-order delivery, and a first launch can all be tested
/// without a paired device, and the delegate is left with nothing but I/O.
public struct WatchStateInbox: Equatable, Sendable {
    /// The single application-context key both sides agree on.
    public static let contextKey = "vibebuddy.watchState"

    /// The last payload that was worth showing. `nil` means no-data: the Watch
    /// has never been told anything it could understand.
    public private(set) var state: WatchDashboardState?

    public init(state: WatchDashboardState? = nil) {
        self.state = state
    }

    public static func encode(_ state: WatchDashboardState) -> Data? {
        try? JSONEncoder().encode(state)
    }

    /// Take a payload. Returns whether it replaced what was on screen.
    ///
    /// Anything missing, truncated, or written by an incompatible build is
    /// rejected and the last known good state stays up — a decode failure is a
    /// reason to keep showing honest old data, not to blank the screen. The iPhone
    /// assigns persistent revisions across Mac/epoch changes. Mac clocks are
    /// unrelated and cannot establish message order. Missing revisions are rejected.
    @discardableResult
    public mutating func accept(_ data: Data?) -> Bool {
        guard let data,
              let incoming = try? JSONDecoder().decode(WatchDashboardState.self, from: data)
        else { return false }
        guard incoming.relayRevision > 0 else { return false }
        if let current = state {
            guard incoming.relayRevision >= current.relayRevision else { return false }
            if incoming.relayRevision == current.relayRevision {
                guard incoming.sourceID == current.sourceID,
                      incoming.pairingEpoch == current.pairingEpoch,
                      incoming.observedAt == current.observedAt else { return false }
            }
        }
        // A phone cold launch knows its pairing before it has a Mac snapshot.
        // Preserve that epoch's last content and age while recording disconnect.
        if let current = state, current.sourceID != nil, incoming.sourceID == nil,
           current.pairingEpoch == incoming.pairingEpoch {
            var disconnected = current
            disconnected.relay = .disconnected
            disconnected.relayRevision = incoming.relayRevision
            state = disconnected
        } else {
            state = incoming
        }
        return true
    }
}
