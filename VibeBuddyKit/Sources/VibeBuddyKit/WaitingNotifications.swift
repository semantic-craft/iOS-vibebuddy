import Foundation

/// The one name a cue has, wherever it is posted from.
///
/// Two devices can decide to tell you the same thing: the iPhone posts a local
/// notification from the live snapshot stream, and the Mac pushes the same cue
/// over APNs when the phone might not be running. Give both the same identifier
/// — the phone's `UNNotificationRequest` id and the push's `apns-collapse-id` —
/// and iOS keeps one notification instead of two. The Watch mirrors the phone,
/// so one on the phone is exactly one on the wrist.
public enum NotificationIdentity {
    /// APNs rejects a collapse id longer than this, so the identifier both
    /// channels share has to fit it.
    static let maxLength = 64

    /// One identifier per session *and* cue: a fresh permission and the nudge
    /// that follows it are different things to say, and neither should quietly
    /// overwrite the other.
    public static func id(sessionID: String, sound: NotificationSound) -> String {
        let suffix = "-\(sound.rawValue)"
        let room = maxLength - suffix.utf8.count
        // A session id long enough to need trimming keeps its tail: hook ids are
        // prefixed by agent and path, and differ at the end.
        var session = sessionID
        while session.utf8.count > room { session.removeFirst() }
        return session + suffix
    }
}

extension SoundAlert {
    /// What this cue is called on both channels.
    public var notificationID: String {
        NotificationIdentity.id(sessionID: sessionID, sound: sound)
    }
}

/// What the iPhone has told you is waiting, and when that stops being true.
///
/// The routing rule is fixed and has one scheduler: the iPhone posts every
/// notification, and watchOS mirrors it when the phone is not in use. The Watch
/// app schedules nothing of its own — a second scheduler would be a duplicate
/// by construction, and it would have to re-derive a policy (quiet mode, sound
/// preference, the `needsResponse` boundary) that already lives in one place.
///
/// What that rule alone does not cover is a notification outliving its wait.
/// Answer a session on the Mac and the banner is still sitting on the wrist,
/// describing a request nobody is blocked on any more; opening it would show
/// something the Watch's own alert list no longer contains. This ledger
/// remembers what was posted for each waiting session so those identifiers can
/// be taken back the moment the session stops waiting.
public struct WaitingNotificationLedger: Equatable, Sendable {
    private var posted: [String: Set<String>] = [:]

    public init() {}

    /// Identifiers currently believed to be on the phone (and mirrored).
    public var outstanding: Set<String> { Set(posted.values.joined()) }

    /// Record what was just posted. Only waiting cues are tracked: a completion
    /// describes something that already happened and stays true, so withdrawing
    /// it would delete history the user has not read yet.
    public mutating func record(_ alerts: [SoundAlert]) {
        for alert in alerts where alert.sound.isWaitingCue {
            posted[alert.sessionID, default: []].insert(alert.notificationID)
        }
    }

    /// The identifiers to withdraw for this snapshot: everything posted for a
    /// session that is no longer waiting, including sessions that have vanished
    /// from the snapshot entirely.
    public mutating func withdrawals(for sessions: [AgentSession]) -> [String] {
        let waiting = Set(sessions.lazy.filter { $0.status == .needsResponse }.map(\.id))
        let resolved = posted.keys.filter { !waiting.contains($0) }
        return resolved.flatMap { posted.removeValue(forKey: $0) ?? [] }.sorted()
    }
}
