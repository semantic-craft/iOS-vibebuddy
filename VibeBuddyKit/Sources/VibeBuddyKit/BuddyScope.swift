import Foundation

/// Which sessions the voice companion is allowed to see. Pure and unit-tested so
/// the privacy rule lives in one place, independent of either platform's model.
public enum BuddyScope {
    /// The sessions the buddy should be grounded in: those whose `id` is in
    /// `selectedIDs`, in their original order. If that intersection is empty —
    /// nothing selected, or every selected session has vanished — the buddy sees
    /// *all* `sessions`. This one rule preserves the all-by-default behaviour and
    /// covers "none selected = all" and "all selected vanished = all".
    public static func included(from sessions: [AgentSession],
                                selectedIDs: Set<String>) -> [AgentSession] {
        let scoped = sessions.filter { selectedIDs.contains($0.id) }
        return scoped.isEmpty ? sessions : scoped
    }

    /// Drop any selected ID that no longer matches a live session, so the set never
    /// keeps a stale id and "all selected vanished → all" engages cleanly.
    public static func pruned(_ selectedIDs: Set<String>,
                              toLive sessions: [AgentSession]) -> Set<String> {
        selectedIDs.intersection(sessions.map(\.id))
    }
}
