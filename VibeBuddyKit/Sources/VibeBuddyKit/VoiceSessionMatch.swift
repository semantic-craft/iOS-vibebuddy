import Foundation

/// Resolves a spoken / model-supplied project name to exactly one live session.
///
/// Because approve/deny run real commands, matching is deliberately conservative:
/// an exact (case-insensitive, trimmed) name wins; failing that, a *unique*
/// substring hit; an ambiguous (>1) or absent match returns `nil` so a
/// consequential action is never applied to a guessed or wrong target. The model
/// is given the exact project names in its prompt, so exact match is the common
/// path and the substring fallback only forgives a partial spoken name.
public enum VoiceSessionMatch {
    public static func match(_ query: String, in sessions: [AgentSession]) -> AgentSession? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }

        let exact = sessions.filter { $0.project.lowercased() == q }
        if exact.count == 1 { return exact.first }
        if exact.count > 1 { return nil }          // duplicate names → refuse to guess

        // No exact hit: a project name that contains the query, but only if unique.
        // (The reverse — query contains project — is intentionally dropped; it let a
        // one-character project name match almost any utterance.)
        let partial = sessions.filter { $0.project.lowercased().contains(q) }
        return partial.count == 1 ? partial.first : nil
    }
}
