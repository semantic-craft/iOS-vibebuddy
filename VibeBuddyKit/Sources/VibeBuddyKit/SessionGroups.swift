import Foundation

/// Splits a (server-sorted) session list into the three dashboard buckets.
/// Shared by the Mac menu bar and the iOS app so both group identically.
public struct SessionGroups: Equatable, Sendable {
    public let needsResponse: [AgentSession]
    public let working: [AgentSession]
    public let done: [AgentSession]

    public init(_ sessions: [AgentSession]) {
        needsResponse = sessions.filter { $0.status == .needsResponse }
        working = sessions.filter { $0.status == .working }
        done = sessions.filter { $0.status == .done }
    }

    public var isEmpty: Bool {
        needsResponse.isEmpty && working.isEmpty && done.isEmpty
    }
}
