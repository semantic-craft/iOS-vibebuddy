import Foundation

/// Local menu presentation only. Never acknowledges or mutates a Session.
public struct MenuSessionPreferences: Codable, Equatable, Sendable {
    public static let states: Set<TaskPresentationState> = [.error, .requiresInput, .thinking, .completeUnread, .idle]
    public var selectedStates: Set<TaskPresentationState> = Self.states
    public var selectedAgents: Set<AgentKind> = Set(AgentKind.allCases)
    public var collapsedGroups: Set<String> = ["done"]
    private var cleared: Set<Completion> = []

    private struct Completion: Codable, Hashable, Sendable {
        let source: String
        let session: String
        let agent: AgentKind
        let completionID: String?
        let statusSince: Date?
        let roundID: String?
    }

    public init() {}

    public var isFiltering: Bool {
        selectedStates != Self.states || selectedAgents != Set(AgentKind.allCases)
    }

    public func filtered(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { selectedStates.contains($0.presentationState) && selectedAgents.contains($0.agent) }
    }

    public func visible(_ sessions: [AgentSession], sourceID: String?, roundIDs: [String: String] = [:]) -> [AgentSession] {
        filtered(sessions).filter { session in
            guard let identity = identity(session, sourceID: sourceID, roundIDs: roundIDs) else { return true }
            return !cleared.contains(identity)
        }
    }

    public mutating func clear(_ sessions: [AgentSession], sourceID: String?, roundIDs: [String: String] = [:]) {
        clear(sessions, currentSessions: sessions, sourceID: sourceID, roundIDs: roundIDs, currentRoundIDs: roundIDs)
    }

    public mutating func clear(_ targets: [AgentSession], currentSessions: [AgentSession], sourceID: String?,
                               roundIDs: [String: String] = [:], currentRoundIDs: [String: String] = [:]) {
        let current = Set(currentSessions.compactMap { identity($0, sourceID: sourceID, roundIDs: currentRoundIDs) })
        for session in filtered(targets) {
            if let identity = identity(session, sourceID: sourceID, roundIDs: roundIDs), current.contains(identity) {
                // A newer cleared round replaces this session's previous record.
                cleared = cleared.filter {
                    $0.source != identity.source || $0.session != identity.session || $0.agent != identity.agent
                }
                cleared.insert(identity)
            }
        }
    }

    private func identity(_ session: AgentSession, sourceID: String?, roundIDs: [String: String]) -> Completion? {
        guard let sourceID, session.presentationState == .completeUnread || session.presentationState == .idle else { return nil }
        let roundID = session.completionID == nil ? roundIDs[session.id] : nil
        return Completion(source: sourceID, session: session.id, agent: session.agent,
                          completionID: session.completionID,
                          statusSince: session.completionID == nil && roundID == nil ? session.statusSince : nil,
                          roundID: roundID)
    }
}
