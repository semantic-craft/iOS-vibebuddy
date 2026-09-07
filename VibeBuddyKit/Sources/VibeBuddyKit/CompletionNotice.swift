import Foundation

/// Mac-owned wording decision; never contains the original completion result.
public struct CompletionNotice: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, plain, summary, cancelled }
    public var id: String
    public var deadline: Date
    public var state: State
    public var text: String?
    public init(id: String, deadline: Date, state: State = .pending, text: String? = nil) {
        self.id = id; self.deadline = deadline; self.state = state; self.text = text
    }
}


extension AgentSession {
    /// Discard notices from another source or completion before projecting UI/voice.
    public func validatingCompletionNotice(sourceID: String?) -> Self {
        var result = self
        guard let sourceID, let completionID,
              completionNotice?.id == sourceID + "/" + id + "/" + completionID else {
            result.completionNotice = nil
            return result
        }
        return result
    }

    /// A completed result remains readable after acknowledgement. Starting a new
    /// turn must never attach its predecessor's wording to current work.
    public var displaySummary: String? { completionSummary ?? summary }

    public var completionSummary: String? {
        guard status == .done, !isStuck, let completionID,
              let notice = completionNotice, notice.state == .summary,
              notice.id.hasSuffix("/" + id + "/" + completionID),
              let text = notice.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 180 else { return nil }
        return text
    }
    /// APNs already uses the hash of source/session/completion as its identifier.
    /// Carry that existing identity through notification taps, without requiring
    /// a new server payload or guessing a round from the currently selected row.
    public func matchesCompletionNotification(_ notificationID: String, sourceID: String?) -> Bool {
        let current = validatingCompletionNotice(sourceID: sourceID)
        guard current.status == .done, let notice = current.completionNotice,
              notice.state == .summary || notice.state == .plain else { return false }
        return SoundAlert(session: current, sound: .agentDone).notificationID == notificationID
    }

    /// Legacy ordinary notices identify a session, not a completion round.
    /// They may open current detail but cannot acknowledge it implicitly.
    public func isUnboundCompletionNotification(_ notificationID: String) -> Bool {
        notificationID == NotificationIdentity.id(sessionID: id, sound: .agentDone)
    }

}
