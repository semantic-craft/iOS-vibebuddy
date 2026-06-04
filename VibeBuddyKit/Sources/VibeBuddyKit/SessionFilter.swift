import Foundation

/// Pure filtering for the dashboard: by status, by agent, and a text query over
/// project/summary. nil status/agent = no filter; empty query = match all.
public enum SessionFilter {
    public static func apply(_ sessions: [AgentSession], status: SessionStatus?,
                             agent: AgentKind?, query: String) -> [AgentSession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return sessions.filter { s in
            if let status, s.status != status { return false }
            if let agent, s.agent != agent { return false }
            if !q.isEmpty {
                let hay = (s.project + " " + (s.summary ?? "")).lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    /// Distinct agents present in the snapshot, in stable CaseIterable order.
    public static func presentAgents(_ sessions: [AgentSession]) -> [AgentKind] {
        let present = Set(sessions.map(\.agent))
        return AgentKind.allCases.filter { present.contains($0) }
    }
}
