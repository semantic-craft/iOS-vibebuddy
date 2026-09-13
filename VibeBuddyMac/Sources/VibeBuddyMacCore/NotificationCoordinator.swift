import Foundation
import VibeBuddyKit

/// Sink for "play this cue for this session" events. The macOS app's concrete
/// implementation posts a local notification with the cue's sound; tests use a spy.
public protocol AttentionNotifier {
    func notify(_ alert: SoundAlert) async -> LocalNotificationAttempt
    /// Take back notifications whose session is no longer waiting: a banner or
    /// a list entry for an answered approval describes something nobody is
    /// blocked on any more. Identifiers are `SoundAlert.notificationID`.
    func withdraw(_ identifiers: [String]) async
}

/// Feeds each snapshot through the shared `SoundPolicy` and forwards the cues it
/// earns to `notifier`. All the *when to ring* and *how loud* logic lives in
/// `SoundPolicy` (unit-tested in VibeBuddyKit); this type only supplies the
/// ambient context (clock, app-active, Quiet mode, focused terminals), fans the
/// decisions out, records delivery, and hands the same cues back so the push to
/// the phone is built from one decision rather than a second policy.
public final class NotificationCoordinator: @unchecked Sendable {
    private let notifier: AttentionNotifier
    private let policy: SoundPolicy
    private let onEligible: @Sendable (SoundAlert) -> Void
    private let onScheduled: @Sendable (SoundAlert) -> Void
    private let delivery: (any NotificationDeliveryRecording)?
    /// What was posted for each waiting session, so it can be withdrawn the
    /// moment the session stops waiting. Completions are never tracked.
    private var ledger = WaitingNotificationLedger()
    private var speechStartedAt: Date?
    private var speechCompletions: [String: String] = [:]
    private var pendingSpeechCompletions: [String: String] = [:]

    public init(
        notifier: AttentionNotifier,
        policy: SoundPolicy = SoundPolicy(),
        delivery: (any NotificationDeliveryRecording)? = nil,
        onEligible: @escaping @Sendable (SoundAlert) -> Void = { _ in },
        onScheduled: @escaping @Sendable (SoundAlert) -> Void = { _ in }
    ) {
        self.notifier = notifier
        self.policy = policy
        self.delivery = delivery
        self.onEligible = onEligible
        self.onScheduled = onScheduled
    }

    /// Say "finished, still unread" again for a followed session. The same
    /// `agentDone` cue as the completion itself, so the notifier replaces the
    /// earlier banner rather than stacking a new one. Nothing is posted when the
    /// Mac has the completion category off, or when the matrix drops it — Quiet
    /// mode reads the session as `muted`, and a muted completion is dropped.
    /// Returns whether a post was attempted.
    @discardableResult
    public func remind(_ session: AgentSession, now: Date = Date(), quietMode: Bool,
                       categories: NotificationCategoryPrefs = .default) async -> Bool {
        let sound = NotificationSound.agentDone
        let attention: SessionAttention = quietMode ? .muted : session.effectiveAttention
        let level = DeliveryMatrix.level(for: sound, attention: attention)
        guard categories.isEnabled(sound), level != .drop else { return false }
        let alert = SoundAlert(session: session, sound: sound, delivery: level, isReminder: true)
        let attempt = await notifier.notify(alert)
        if attempt.shouldRecord {
            await delivery?.record(NotificationDeliveryRecord(
                channel: .local, outcome: attempt.outcome, sessionID: alert.sessionID,
                sound: alert.sound.rawValue, failureReason: attempt.failureReason, timestamp: now))
        }
        return true
    }

    /// Two axes: `categories` is this Mac's own switch set (a cue the user
    /// turned off is not posted here), and the policy has already reduced each
    /// cue through `DeliveryMatrix` from the session's attention level, with
    /// Quiet mode reading every session as `muted`.
    ///
    /// Returns every cue the policy earned, *before* this Mac's switches: the
    /// caller pushes from that list so each phone applies its own switches. A
    /// category the Mac turned off must not silence a phone that wants it.
    @discardableResult
    public func observe(_ sessions: [AgentSession], now: Date = Date(),
                        appActive: Bool, quietMode: Bool,
                        focusedSessionIDs: Set<String> = [],
                        viewedSessionIDs: Set<String> = [],
                        categories: NotificationCategoryPrefs = .default) async -> [SoundAlert] {
        let input = SoundPolicyInput(sessions: sessions, now: now,
                                     appActive: false, quietMode: quietMode,
                                     focusedSessionIDs: focusedSessionIDs)
        let earned = policy.evaluate(input)
        // Completion speech is driven by the existing round identity, not the
        // cue sound's 30-second noise threshold or whether polling saw Working.
        // The first snapshot is a baseline; historical results never auto-play.
        if let startedAt = speechStartedAt {
            for session in sessions where session.status == .done {
                guard let id = session.completionID, session.statusSince >= startedAt,
                      session.probeRetired != true, session.userStopped != true else { continue }
                if speechCompletions[session.id] != id { pendingSpeechCompletions[session.id] = id }
            }
        } else { speechStartedAt = now }
        speechCompletions = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            session.completionID.map { (session.id, $0) }
        })
        let current = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        for (sessionID, identity) in pendingSpeechCompletions.sorted(by: {
            let left = current[$0.key]?.statusSince ?? now, right = current[$1.key]?.statusSince ?? now
            return left == right ? $0.key < $1.key : left < right
        }) {
            guard let session = current[sessionID], session.status == .done,
                  session.completionID == identity else { pendingSpeechCompletions[sessionID] = nil; continue }
            pendingSpeechCompletions[sessionID] = nil
            let sound: NotificationSound = session.isStuck ? .agentStuck : .agentDone
            // Reading can cancel a pending summary notice; the same current
            // completed round still speaks using its available result text.
            guard !quietMode,
                  categories.isEnabled(sound), session.effectiveAttention != .muted else { continue }
            onEligible(SoundAlert(session: session, sound: sound, delivery: .list))
        }
        let alerts = categories.filter(earned)
        // A cue this Mac's switches dropped is a decision, not an absence: say so,
        // the same way the push path says why a phone heard nothing.
        for dropped in earned where !alerts.contains(where: { $0.sessionID == dropped.sessionID
                                                             && $0.sound == dropped.sound }) {
            await delivery?.record(NotificationDeliveryRecord(
                channel: .local, outcome: .skipped, sessionID: dropped.sessionID,
                sound: dropped.sound.rawValue, failureReason: CueSkipReason.category.rawValue,
                timestamp: now))
        }
        // Withdraw before posting: a session that left one wait and entered
        // another in the same snapshot keeps only the new cue.
        let stale = ledger.withdrawals(for: sessions)
        if !stale.isEmpty { await notifier.withdraw(stale) }
        ledger.record(alerts)
        for alert in alerts {
            if alert.sound == .agentDone, let notice = alert.session.completionNotice,
               !(await CompletionNoticeAttempts.shared.claim(notice, recipient: "mac-local")) { continue }
            // Speech is an independent eligible channel, including a list-only cue.
            if alert.session.completionID == nil || (alert.sound != .agentDone && alert.sound != .agentStuck) { onEligible(alert) }
            let localAlert = alert.sound == .agentDone && viewedSessionIDs.contains(alert.sessionID)
                ? SoundAlert(session: alert.session, sound: alert.sound, delivery: .list) : alert
            let attempt = await notifier.notify(localAlert)
            if attempt.outcome == .scheduled { onScheduled(alert) }
            guard attempt.shouldRecord else { continue }
            await delivery?.record(NotificationDeliveryRecord(
                channel: .local,
                outcome: attempt.outcome,
                sessionID: alert.sessionID,
                sound: alert.sound.rawValue,
                failureReason: attempt.failureReason,
                timestamp: now
            ))
        }
        return earned
    }
}
