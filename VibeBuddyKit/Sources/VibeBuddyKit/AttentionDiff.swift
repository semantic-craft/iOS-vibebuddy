import Foundation

/// Computes which sessions just crossed into `needsResponse`, so the phone
/// notifies once per transition rather than on every poll.
public enum AttentionDiff {
    public static func newlyNeedingResponse(
        old: [AgentSession], new: [AgentSession]
    ) -> [AgentSession] {
        let alreadyWaiting = Set(
            old.filter { $0.status == .needsResponse }.map(\.id)
        )
        return new.filter { $0.status == .needsResponse && !alreadyWaiting.contains($0.id) }
    }
}
