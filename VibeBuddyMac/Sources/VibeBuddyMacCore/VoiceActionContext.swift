import Foundation
import VibeBuddyKit

/// The source and rounds actually returned to a voice status request. UI polling
/// and the coordinator's scope check must never refresh this action binding.
public struct VoiceActionContext: Sendable {
    private var sourceID: String?
    private var sessions: [AgentSession] = []
    private var requests: [SessionActionRequest] = []

    public init() {}

    public mutating func observe(sourceID: String?, sessions: [AgentSession]) {
        if self.sourceID != sourceID { requests.removeAll() }
        self.sourceID = sourceID
        self.sessions = sessions
    }

    /// Match in both the observed and current scope, retaining the session ID.
    /// A replacement session with the same project never inherits an action.
    public func target(_ project: String, sourceID: String?, currentScope: [AgentSession]) -> AgentSession? {
        guard let sourceID, !sourceID.isEmpty, sourceID == self.sourceID,
              let observed = VoiceSessionMatch.match(project, in: sessions),
              let current = VoiceSessionMatch.match(project, in: currentScope),
              current.id == observed.id else { return nil }
        return observed
    }

    public func completionRequest(for observed: AgentSession, current: AgentSession) -> CompletionReadRequest? {
        guard let sourceID, observed.id == current.id,
              observed.status == .done, current.status == .done,
              observed.failed != true, current.failed != true,
              observed.historyOnly != true, current.historyOnly != true,
              let completionID = observed.completionID, !completionID.isEmpty,
              completionID == current.completionID else { return nil }
        return CompletionReadRequest(sourceID: sourceID, sessionID: observed.id, completionID: completionID)
    }

    /// Explicit intent and original question/turn identity are sent through the
    /// existing dispatcher. Repeated delivery of the same spoken request keeps
    /// its request ID, including after an unknown receipt, for this voice call.
    public mutating func instructionRequest(for observed: AgentSession, current: AgentSession,
                                            text: String, answerOnly: Bool = false) -> SessionActionRequest? {
        let originalSupport = SessionActionSupport.resolve(for: observed)
        let support = SessionActionSupport.resolve(for: current)
        guard observed.id == current.id, observed.status == current.status,
              observed.historyOnly != true, current.historyOnly != true,
              observed.statusSince == current.statusSince,
              observed.pendingQuestion?.id == current.pendingQuestion?.id,
              observed.completionID == current.completionID,
              ControlChannel.infer(for: observed) == ControlChannel.infer(for: current),
              originalSupport.isAvailable, support.isAvailable,
              originalSupport.intent == support.intent,
              !answerOnly || support.intent == .answer,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let request = SessionActionRequest(sessionID: observed.id, intent: support.intent,
            questionID: observed.pendingQuestion?.id,
            expectedStatusSince: observed.statusSince.timeIntervalSince1970, text: text)
        if let previous = requests.first(where: {
            $0.sessionID == request.sessionID && $0.intent == request.intent && $0.questionID == request.questionID
                && $0.expectedStatusSince == request.expectedStatusSince && $0.text == request.text
        }) { return previous }
        // Bound a single call's mutation history; refuse further new actions
        // instead of evicting an unknown request and risking its retransmission.
        guard requests.count < 64 else { return nil }
        requests.append(request)
        return request
    }
}
