import Foundation

/// Fallback failure detection for when there is no explicit error signal — a
/// completion whose prose reads like a failure. Used as a secondary cue behind
/// the real `AgentSession.failed` flag. Shared by the reducer (Mac) and the
/// sound policy (both platforms) so "what counts as stuck" lives in one place.
public enum FailureHeuristic {
    public static let markers = [
        "fail", "crash", "abort", "panic", "fatal", "exception",
        "timed out", "timeout", "interrupted", "stuck", "killed",
    ]

    public static func looksFailed(_ text: String?) -> Bool {
        guard let s = text?.lowercased() else { return false }
        return markers.contains { s.contains($0) }
    }
}
