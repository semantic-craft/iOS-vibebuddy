import Foundation

/// App and widget recover from one atomic, privacy-minimized document.
/// Approval details are live-only: a cached command is never actionable.
public struct WatchStoredState: Codable, Equatable, Sendable {
    public var state: WatchDashboardState
    public var queue: WatchCompletionQueue
    public var complication: WatchComplicationSnapshot

    public init(state: WatchDashboardState, queue: WatchCompletionQueue,
                previous: WatchComplicationSnapshot? = nil) {
        var cached = state
        cached.alerts = state.alerts.map { alert in
            var redacted = alert
            redacted.request = nil
            redacted.summary = nil
            redacted.options = []
            redacted.approvalId = nil
            // The same rule for a question: without the text there is nothing
            // to answer, and an id kept past its words is an actionable card
            // nobody can read.
            redacted.pendingId = nil
            redacted.questions = nil
            return redacted
        }
        self.state = cached
        self.queue = queue
        complication = WatchComplicationSnapshot(state: cached, previous: previous)
        complication.pendingCompletionIDs = queue.links.filter {
            $0.sourceID == state.sourceID && $0.pairingEpoch == state.pairingEpoch
        }.compactMap(\.completionID)
    }

    public static func decode(_ data: Data) -> Self? {
        guard let value = try? JSONDecoder().decode(Self.self, from: data),
              value.state.relayRevision > 0,
              value.state.observedAt == value.complication.observedAt,
              value.state.sourceID == value.complication.sourceID,
              value.state.pairingEpoch == value.complication.pairingEpoch,
              value.state.followedTasks.map(\.complicationTask) == value.complication.tasks else { return nil }
        return value
    }
}
