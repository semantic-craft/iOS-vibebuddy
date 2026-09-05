import Foundation
import VibeBuddyKit

/// One cue shown as a card under the notch. Actionable cards (a wait) stay
/// longer than passive ones (a completion), and are withdrawn early when the
/// wait they announce is over.
public struct GlanceCard: Equatable, Sendable, Identifiable {
    public let alert: SoundAlert
    public let shownAt: Date
    public let duration: TimeInterval

    public var id: String { "\(alert.sessionID)-\(alert.sound.rawValue)" }
    public var session: AgentSession { alert.session }
    public var deadline: Date { shownAt.addingTimeInterval(duration) }
    public var isActionable: Bool { alert.sound.isWaitingCue }
}

/// The glance's event layer: one card at a time, newer cues queued behind it,
/// timeouts and early withdrawal decided here so the view only renders
/// `current`. Pure value type; the model drives it from its poll loop.
public struct GlanceCardQueue: Equatable, Sendable {
    public var actionableDuration: TimeInterval
    public var passiveDuration: TimeInterval
    /// How long a card lingers after the pointer leaves it, so releasing a
    /// hover never snaps the card away mid-read.
    public var releaseGrace: TimeInterval

    public private(set) var current: GlanceCard?
    private var pending: [SoundAlert] = []

    public init(actionableDuration: TimeInterval = 8, passiveDuration: TimeInterval = 2.5,
                releaseGrace: TimeInterval = 1.5) {
        self.actionableDuration = actionableDuration
        self.passiveDuration = passiveDuration
        self.releaseGrace = releaseGrace
    }

    /// Show `alert` now, or queue it behind the current card. A cue already
    /// showing or queued for the same session and sound is not repeated; a
    /// newer cue for a queued session replaces the stale one (the session moved
    /// on, so the old card would announce something that is no longer true).
    public mutating func enqueue(_ alert: SoundAlert, now: Date) {
        if let current, current.alert.sessionID == alert.sessionID, current.alert.sound == alert.sound { return }
        pending.removeAll { $0.sessionID == alert.sessionID }
        if current == nil {
            current = card(for: alert, now: now)
        } else {
            pending.append(alert)
        }
    }

    /// The user acted on (or closed) the current card.
    public mutating func dismissCurrent(now: Date) {
        current = nil
        advance(now: now)
    }

    /// Expire the current card and drop cards whose wait is over. `held` (the
    /// pointer is on the card, or the glance is expanded) pauses the clock; the
    /// deadline is pushed so the card outlives the hover by `releaseGrace`.
    public mutating func tick(now: Date, sessions: [AgentSession], held: Bool) {
        pending.removeAll { !Self.stillApplies($0, in: sessions) }
        guard let card = current else { return }
        if !Self.stillApplies(card.alert, in: sessions) {
            current = nil
            advance(now: now)
            return
        }
        if held {
            if card.deadline < now.addingTimeInterval(releaseGrace) {
                current = GlanceCard(alert: card.alert, shownAt: card.shownAt,
                                     duration: now.addingTimeInterval(releaseGrace).timeIntervalSince(card.shownAt))
            }
            return
        }
        if now >= card.deadline {
            current = nil
            advance(now: now)
        }
    }

    private mutating func advance(now: Date) {
        guard current == nil, !pending.isEmpty else { return }
        current = card(for: pending.removeFirst(), now: now)
    }

    private func card(for alert: SoundAlert, now: Date) -> GlanceCard {
        GlanceCard(alert: alert, shownAt: now,
                   duration: alert.sound.isWaitingCue ? actionableDuration : passiveDuration)
    }

    /// A waiting cue is only worth showing while that exact wait is pending;
    /// a completion or failure is history and runs its course.
    private static func stillApplies(_ alert: SoundAlert, in sessions: [AgentSession]) -> Bool {
        guard alert.sound.isWaitingCue else { return true }
        guard let live = sessions.first(where: { $0.id == alert.sessionID }),
              live.status == .needsResponse else { return false }
        if let approval = alert.session.pendingApproval {
            return live.pendingApproval?.id == approval.id
        }
        return true
    }
}
