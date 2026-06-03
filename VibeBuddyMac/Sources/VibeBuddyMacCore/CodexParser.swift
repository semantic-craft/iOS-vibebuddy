import Foundation
import VibeBuddyKit

/// Parses a Codex CLI `notify` payload (Codex passes the event JSON as an
/// argument; our helper forwards it here). Currently Codex emits
/// `agent-turn-complete`, which we map to a `done` session.
public enum CodexParser {
    public static func parse(_ data: Data, receivedAt: Date) -> HookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              let sessionID = (obj["thread-id"] as? String) ?? (obj["turn-id"] as? String)
        else { return nil }

        switch type {
        case "agent-turn-complete":
            return HookEvent(
                kind: .stop,
                sessionID: sessionID,
                agent: .codex,
                cwd: obj["cwd"] as? String,
                message: obj["last-assistant-message"] as? String,
                timestamp: receivedAt
            )
        default:
            return nil
        }
    }
}
