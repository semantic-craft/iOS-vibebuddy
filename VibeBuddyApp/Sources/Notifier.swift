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
    /// Say what became of a decision the phone had to hold: held, delivered,
    /// no longer needed, given up. Mirrored to the Watch, where the tap was
    /// most likely made and where silence used to be the answer (ADR-0032).
    func reportDelivery(_ event: HeldDeliveryEvent, macName: String?)
    /// A waiting cue just arrived and this phone cannot reach the Mac: say so
    /// before the person taps Approve into the void.
    func warnUnreachable(_ reason: ConnectionFailureReason, macName: String?)
    /// A banner tap went out and its receipt was lost. Nothing is held or
    /// retried for it: the Mac may have acted, so the word is "look, do not
    /// tap again" — the same sentence the wrist gets for `unknown`.
    func warnUnconfirmed(_ action: QueuedSessionAction, macName: String?)
    /// A banner tap the Mac could not be given and the phone would not hold
    /// either: the queue is full, or an earlier decision on the same target
    /// is being delivered this instant. Its own notification, so the live
    /// "on hold" banner for that earlier decision is not stood down.
    func warnNotHeld(_ action: QueuedSessionAction, macName: String?)
}

extension AttentionNotifier {
    func reportDelivery(_ event: HeldDeliveryEvent, macName: String?) {}
    func warnUnreachable(_ reason: ConnectionFailureReason, macName: String?) {}
    func warnUnconfirmed(_ action: QueuedSessionAction, macName: String?) {}
    func warnNotHeld(_ action: QueuedSessionAction, macName: String?) {}
}

/// One sentence per missing link, shared by the phone's screens, the toast
/// and the notifications, so the person reads the same diagnosis everywhere.
enum ConnectionFailureCopy {
    static func title(_ reason: ConnectionFailureReason, macName: String?) -> String {
        let mac = macName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? macName! : String(localized: "your Mac")
        switch reason {
        case .tailnetOff: return String(localized: "Tailscale or Surge is off on this iPhone")
        case .macUnreachable(let host): return String(localized: "Can't reach \(mac) at \(host)")
        case .authentication: return String(localized: "Access refused by \(mac)")
        case .invalidAddress: return String(localized: "The saved Mac address is not usable")
        case .dropped: return String(localized: "Connection to \(mac) dropped")
        }
    }

    static func detail(_ reason: ConnectionFailureReason) -> String {
        switch reason {
        case .tailnetOff(let host):
            return String(localized: "\(host) is a private network address. Turn on Tailscale or Surge on this iPhone to reach it.")
        case .macUnreachable:
            return String(localized: "Check that the Mac is awake and VibeBuddy is running on it.")
        case .authentication:
            return String(localized: "Check your pairing token, then reconnect.")
        case .invalidAddress:
            return String(localized: "Pair again with a valid host and port.")
        case .dropped:
            return String(localized: "Reconnecting…")
        }
    }

    /// Where a tap should go to fix it, when one tap can.
    static var vpnHint: String { String(localized: "Turn on Tailscale or Surge") }
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
        Self.registerCategories()
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Approve / Deny on permission banners; a text field on questions.
    /// Same identifiers the Mac registers and APNs puts in `aps.category`.
    ///
    /// Every action is a *foreground* action (ADR-0033). Apple runs a
    /// background action on the device the notification was sent to — this
    /// phone, even when the button was tapped on the mirrored copy on the
    /// wrist — so a background Approve from the Watch ran here, in a pocket,
    /// and when its POST failed nothing anywhere said so. A foreground action
    /// runs where it was tapped: on the Watch it goes through the Watch app's
    /// own send path with its own sentence and tap; here it opens this app on
    /// the session, where the outcome is on screen. The Watch registers the
    /// same set (`WatchAppDelegate.categories`). One exception on the wrist:
    /// watchOS 27 opens the app for Reply without its words, so there Reply
    /// lands on the answer card (ADR-0033, WR-09 amendment).
    static func registerCategories() {
        let approve = UNNotificationAction(
            identifier: NotificationActionID.approve.rawValue,
            title: String(localized: "Approve"),
            options: [.authenticationRequired, .foreground])
        let deny = UNNotificationAction(
            identifier: NotificationActionID.deny.rawValue,
            title: String(localized: "Deny"),
            options: [.destructive, .foreground])
        let approval = UNNotificationCategory(
            identifier: NotificationCategoryID.approval.rawValue,
            actions: [approve, deny],
            intentIdentifiers: [])
        let reply = UNTextInputNotificationAction(
            identifier: NotificationActionID.answer.rawValue,
            title: String(localized: "Reply"),
            options: [.foreground],
            textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "Answer"))
        let question = UNNotificationCategory(
            identifier: NotificationCategoryID.question.rawValue,
            actions: [reply],
            intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([approval, question])
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
        // The Mac is told off this path: the answer is what was posted, not
        // whether the report round trip finished, and the dashboard behind
        // `apply` should not wait on the network for it.
        let posted = Self.chain.enqueue { () -> Bool in
            if (sound.isWaitingCue || (sound == .agentDone && alert.session.completionNotice != nil)), await PushCoverage.shared.covers(cue.identifier, since: cue.since) {
                Task { await PushRegistration.shared.report(coveredByPush: [cue]) }
                return false
            }
            guard await CompletionNoticePhoneContext.valid(alert) else { return false }
            if sound == .agentDone, let notice = alert.session.completionNotice,
               !(await CompletionNoticeAttempts.shared.claim(notice, recipient: "phone-local")) { return false }
            do {
                try await Self.post(title: title, body: body, sound: sound, delivery: delivery,
                                    id: cue.identifier, sessionID: sessionID,
                                    approvalId: alert.session.pendingApproval?.id,
                                    questionId: alert.session.pendingQuestion?.id,
                                    timeSensitive: alert.isTimeSensitive, category: alert.actionCategory)
            } catch {
                return false   // nothing shown, so nothing for the Mac to stand down for
            }
            Task { await PushRegistration.shared.report(posted: [cue]) }
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

    /// One notification per held decision, replaced in place as it moves:
    /// "holding" becomes "delivered" under the same identifier, so the wrist
    /// and the phone show the latest word and never a stack of them.
    func reportDelivery(_ event: HeldDeliveryEvent, macName: String?) {
        let action = event.action
        let id = "held-" + action.targetKey
        let mac = macName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? macName! : String(localized: "your Mac")
        let project = action.project?.isEmpty == false ? action.project! : String(localized: "a task")
        let what: String = switch action.action {
        case .approval(_, .allow): String(localized: "Approve")
        case .approval(_, .deny): String(localized: "Deny")
        case .answer, .answerAll: String(localized: "Answer")
        case .stop: String(localized: "Stop")
        }
        let title: String
        let body: String
        var sound: NotificationSound? = nil
        switch event {
        case .held(_, let reason):
            title = String(localized: "\(what) for \(project) is on hold")
            let why = reason.map { ConnectionFailureCopy.title($0, macName: macName) }
                ?? String(localized: "Can't reach \(mac)")
            body = why + " " + String(localized: "Your iPhone will send it as soon as it can reach \(mac).")
            sound = .needsApproval
        case .stillHeld:
            return
        case .superseded:
            return
        case .delivered:
            title = String(localized: "\(what) delivered to \(mac)")
            body = String(localized: "\(project) has your decision.")
        case .gone:
            title = String(localized: "\(what) for \(project) no longer needed")
            body = String(localized: "The request was resolved before your iPhone could send it. Nothing was applied.")
        case .uncertain:
            title = String(localized: "\(what) for \(project) could not be confirmed")
            body = String(localized: "Your iPhone sent it, lost the receipt, and the request is now gone. Check the task on \(mac).")
            sound = .needsApproval
        case .dropped:
            title = String(localized: "\(what) for \(project) was not delivered")
            body = String(localized: "\(mac) stayed unreachable. Open VibeBuddy to decide again.")
            sound = .needsApproval
        case .cancelled:
            Self.chain.enqueue {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
            }
            return
        }
        let sessionID = action.sessionId
        let delivery: DeliveryLevel = sound == nil ? .list : .bannerSound
        let cue = sound ?? .agentDone
        let urgent = sound != nil
        Self.chain.enqueue {
            try? await Self.post(title: title, body: body, sound: cue, delivery: delivery,
                                 id: id, sessionID: sessionID, timeSensitive: urgent)
        }
    }

    /// Wait until every notification asked for so far has been handed to the
    /// system. A background wake ends the moment its completion handler runs;
    /// what is still queued here at that point may never be posted.
    static func settle() async {
        await chain.enqueue { }.value
    }

    func warnUnconfirmed(_ action: QueuedSessionAction, macName: String?) {
        let mac = macName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? macName! : String(localized: "your Mac")
        let project = action.project?.isEmpty == false ? action.project! : String(localized: "a task")
        let what: String = switch action.action {
        case .approval(_, .allow): String(localized: "Approve")
        case .approval(_, .deny): String(localized: "Deny")
        case .answer, .answerAll: String(localized: "Answer")
        case .stop: String(localized: "Stop")
        }
        let title = String(localized: "\(what) for \(project) could not be confirmed")
        let body = String(localized: "Your iPhone sent it and lost the receipt. Check the task on \(mac) before deciding again.")
        let id = "held-" + action.targetKey
        let sessionID = action.sessionId
        Self.chain.enqueue {
            try? await Self.post(title: title, body: body, sound: .needsApproval, delivery: .bannerSound,
                                 id: id, sessionID: sessionID, timeSensitive: true)
        }
    }

    func warnNotHeld(_ action: QueuedSessionAction, macName: String?) {
        let mac = macName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? macName! : String(localized: "your Mac")
        let project = action.project?.isEmpty == false ? action.project! : String(localized: "a task")
        let what: String = switch action.action {
        case .approval(_, .allow): String(localized: "Approve")
        case .approval(_, .deny): String(localized: "Deny")
        case .answer, .answerAll: String(localized: "Answer")
        case .stop: String(localized: "Stop")
        }
        let title = String(localized: "\(what) for \(project) was not taken")
        let body = String(localized: "Can't reach \(mac), and an earlier decision for this request is already on its way or the hold list is full. Nothing was applied; decide again in VibeBuddy once it is settled.")
        let id = "nothold-" + action.targetKey
        let sessionID = action.sessionId
        Self.chain.enqueue {
            try? await Self.post(title: title, body: body, sound: .needsApproval, delivery: .bannerSound,
                                 id: id, sessionID: sessionID, timeSensitive: true)
        }
    }

    /// Posted once per outage, replaced in place, withdrawn on reconnect.
    static let unreachableID = "connection-unreachable"

    func warnUnreachable(_ reason: ConnectionFailureReason, macName: String?) {
        let title = ConnectionFailureCopy.title(reason, macName: macName)
        let body = ConnectionFailureCopy.detail(reason) + " "
            + String(localized: "Decisions you make from here will be held on this iPhone until then.")
        Self.chain.enqueue {
            try? await Self.post(title: title, body: body, sound: .needsApproval, delivery: .bannerSound,
                                 id: Self.unreachableID, timeSensitive: true)
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
                             id: String, sessionID: String? = nil,
                             approvalId: String? = nil, questionId: String? = nil,
                             timeSensitive: Bool = false,
                             category: NotificationCategoryID? = nil) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = delivery.makesSound && soundOn
            ? UNNotificationSound(named: UNNotificationSoundName(rawValue: sound.fileName))
            : nil
        if let category {
            content.categoryIdentifier = category.rawValue
        }
        if timeSensitive {
            content.interruptionLevel = .timeSensitive
        } else if delivery == .list {
            content.interruptionLevel = .passive
        }
        // Everything said about one session groups and opens as that session,
        // on the phone and on the wrist alike.
        if let sessionID {
            content.threadIdentifier = sessionID
            content.targetContentIdentifier = sessionID
            content.userInfo = NotificationUserInfoKey.make(sessionId: sessionID, approvalId: approvalId,
                                                            questionId: questionId)
        }
        let center = UNUserNotificationCenter.current()
        // Simulator QA (`VIBEBUDDY_SKIP_NOTIFICATIONS=1`) must not raise the
        // permission prompt, and on a fresh install adding a request raises it
        // just as asking would. Once permission is settled, cues post as usual.
        if ProcessInfo.processInfo.environment["VIBEBUDDY_SKIP_NOTIFICATIONS"] == "1",
           await center.notificationSettings().authorizationStatus == .notDetermined {
            throw CancellationError()
        }
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Sound on by default. Mute = sound off.
    private static var soundOn: Bool { SoundPrefs.playSound }

    /// Banner copy per cue.
    private static func copy(for alert: SoundAlert) -> (title: String, body: String) {
        let s = alert.session
        switch alert.sound {
        case .needsApproval:
            return (String(localized: "\(s.project) needs permission"),
                    s.pendingApproval?.notificationBody ?? s.summary ?? String(localized: "Approve or deny"))
        case .needsAnswer:
            return (String(localized: "\(s.project) needs you"),
                    s.summary ?? String(localized: "Waiting for your input"))
        case .longWaitNudge:
            return (String(localized: "\(s.project) is still waiting"),
                    s.summary ?? String(localized: "Waiting for your input"))
        case .agentDone:
            return (String(localized: "\(s.displayTitle) is done"),
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

/// Latest received source state, checked after the serialized notification queue.
@MainActor
enum CompletionNoticePhoneContext {
    static var sessions: [AgentSession] = []
    static func valid(_ alert: SoundAlert) -> Bool {
        guard alert.sound == .agentDone, let notice = alert.session.completionNotice else { return true }
        guard let current = sessions.first(where: { $0.id == alert.sessionID }) else { return false }
        return current.completionNotice?.permitsDelivery(of: notice) == true && current.status == .done
            && current.hasUnreadCompletion && !current.isStuck && current.effectiveAttention == .followed
            && !SoundPrefs.effectiveQuiet() && SoundPrefs.categories.isEnabled(NotificationSound.agentDone)
    }
}
