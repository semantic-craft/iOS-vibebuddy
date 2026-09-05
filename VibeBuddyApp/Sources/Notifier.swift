import Foundation
import UserNotifications
import VibeBuddyKit

/// Stable identifiers for the app's own notifications.
enum NotificationID {
    static let pairSuccess = "pair-success"
}

/// Fires a local notification carrying the sound pack's cue. Injectable so the
/// dashboard's notify logic can be driven by a fake in tests. *Which* cue and
/// *when* is decided by the shared `SoundPolicy`; this only renders it.
protocol AttentionNotifier: Sendable {
    func requestAuthorization()
    /// Post the cue. Returns whether a notification was actually posted: a
    /// waiting cue a push already delivered is left to it (ADR-0012), and then
    /// nothing else — no tap, no buddy reaction — should act as if it rang.
    func notify(_ alert: SoundAlert) async -> Bool
    /// Take back notifications whose session is no longer waiting. They are
    /// mirrored on the Watch, where a banner for an answered request is worse
    /// than no banner: it opens onto a session the wrist no longer lists.
    func withdraw(_ identifiers: [String])
    func confirmPairing()
}

/// Runs notification-center work strictly in the order it was asked for. A
/// post now looks in Notification Center before it adds, which takes a moment;
/// a withdrawal asked for right after must still land after it.
private final class SerialTaskChain: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Task<Void, Never>?

    @discardableResult
    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> Task<T, Never> {
        lock.withLock {
            let previous = last
            let task = Task<T, Never> {
                await previous?.value
                return await operation()
            }
            last = Task { _ = await task.value }
            return task
        }
    }
}

struct LocalNotifier: AttentionNotifier {
    private static let chain = SerialTaskChain()

    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Post the cue — unless, for a waiting cue, the Mac's push for this very
    /// wait has already been delivered here (ADR-0012). Either way the Mac is
    /// told: a receipt for what was posted lets it drop the push it is holding,
    /// and a note of what was left to the push keeps the delivery log honest.
    func notify(_ alert: SoundAlert) async -> Bool {
        let (title, body) = Self.copy(for: alert)
        let cue = NotifiedPayload.Cue(identifier: alert.notificationID, since: alert.session.statusSince)
        let sound = alert.sound
        let delivery = alert.delivery
        let sessionID = alert.sessionID
        let posted = Self.chain.enqueue { () -> Bool in
            if sound.isWaitingCue, await PushCoverage.shared.covers(cue.identifier, since: cue.since) {
                await PushRegistration.shared.report(coveredByPush: [cue])
                return false
            }
            do {
                try await Self.post(title: title, body: body, sound: sound, delivery: delivery,
                                    id: cue.identifier, sessionID: sessionID)
            } catch {
                return false   // nothing shown, so nothing for the Mac to stand down for
            }
            await PushRegistration.shared.report(posted: [cue])
            return true
        }
        return await posted.value
    }

    func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        Self.chain.enqueue {
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            await PushCoverage.shared.forget(identifiers)
        }
    }

    /// A fresh pairing just succeeded — the one chrome cue not tied to a session.
    func confirmPairing() {
        let title = String(localized: "Connected")
        let body = String(localized: "VibeBuddy is watching your sessions.")
        Self.chain.enqueue {
            try? await Self.post(title: title, body: body, sound: .pairSuccess,
                                 id: NotificationID.pairSuccess)
        }
    }

    private static func post(title: String, body: String, sound: NotificationSound,
                             delivery: DeliveryLevel = .bannerSound,
                             id: String, sessionID: String? = nil) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = delivery.makesSound && soundOn
            ? UNNotificationSound(named: UNNotificationSoundName(rawValue: sound.fileName))
            : nil
        // A list-only cue is filed in Notification Center without a banner.
        if delivery == .list { content.interruptionLevel = .passive }
        // Everything said about one session groups and opens as that session,
        // on the phone and on the wrist alike.
        if let sessionID {
            content.threadIdentifier = sessionID
            content.targetContentIdentifier = sessionID
            content.userInfo = ["sessionId": sessionID]
        }
        try await UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Sound on by default. Mute = sound off.
    private static var soundOn: Bool { SoundPrefs.playSound }

    /// Banner copy per cue.
    private static func copy(for alert: SoundAlert) -> (title: String, body: String) {
        let s = alert.session
        switch alert.sound {
        case .needsApproval:
            return (String(localized: "\(s.project) needs permission"),
                    s.pendingApproval?.commandPreview ?? s.summary ?? String(localized: "Approve or deny"))
        case .needsAnswer:
            return (String(localized: "\(s.project) needs you"),
                    s.summary ?? String(localized: "Waiting for your input"))
        case .longWaitNudge:
            return (String(localized: "\(s.project) is still waiting"),
                    s.summary ?? String(localized: "Waiting for your input"))
        case .agentDone:
            return (String(localized: "\(s.project) is done"),
                    s.summary ?? String(localized: "Task complete"))
        case .agentStuck:
            return (String(localized: "\(s.project) stopped"),
                    s.summary ?? String(localized: "Might need a look"))
        case .pairSuccess:
            return (String(localized: "Connected"),
                    String(localized: "VibeBuddy is watching your sessions."))
        }
    }
}
