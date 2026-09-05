import Foundation

/// What a phone tells the Mac after deciding a cue's notification itself
/// (`POST /notified`).
///
/// Two devices can say the same thing about one session: the phone posts a
/// local notification from the live stream, and the Mac pushes the same cue
/// over APNs for when the phone is not running. iOS does not merge a local and
/// a remote notification even when they share an identifier, so one of the two
/// has to stay quiet. This is the phone's side of that: the cues it posted, so
/// the Mac can drop the push it is holding for them, and the waiting cues it
/// declined because a push had already delivered them (ADR-0012).
public struct NotifiedPayload: Codable, Sendable, Equatable {
    /// One cue about one session: the notification identifier both channels
    /// share (`NotificationIdentity`) and the wait — or completion — it
    /// announced, as the Mac's own clock reported it in the snapshot. The Mac
    /// matches on both, so a receipt for one wait can never silence the push
    /// for the next wait of the same session.
    public struct Cue: Codable, Sendable, Equatable {
        public var identifier: String
        public var since: Date

        public init(identifier: String, since: Date) {
            self.identifier = identifier
            self.since = since
        }
    }

    /// The phone's APNs device token: the name the Mac's push registry knows it by.
    public var token: String
    /// Cues this phone just posted as local notifications.
    public var posted: [Cue]
    /// Waiting cues this phone did not post because a push with the same
    /// identifier had already been delivered for that wait.
    public var coveredByPush: [Cue]
    /// `active` / `inactive` / `background`: where the phone was when it
    /// decided. Diagnostic only; it lands in the Mac's delivery log.
    public var appState: String?

    public init(token: String, posted: [Cue] = [], coveredByPush: [Cue] = [], appState: String? = nil) {
        self.token = token
        self.posted = posted
        self.coveredByPush = coveredByPush
        self.appState = appState
    }
}
