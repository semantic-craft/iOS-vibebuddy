import Foundation

/// A decision to say one thing about one session at a state boundary, and how
/// loudly to say it.
public struct SoundAlert: Equatable, Sendable {
    public let session: AgentSession
    public let sound: NotificationSound
    /// How this cue reaches you, already reduced through `DeliveryMatrix`,
    /// Quiet mode and the focused-terminal cap. Never `.drop`: a dropped cue is
    /// not emitted at all.
    public let delivery: DeliveryLevel
    public var sessionID: String { session.id }

    public init(session: AgentSession, sound: NotificationSound,
                delivery: DeliveryLevel = .bannerSound) {
        self.session = session
        self.sound = sound
        self.delivery = delivery
    }

    /// Time Sensitive only for a loud approval or question. A muted session
    /// (and Quiet mode, which reads as muted) lands at `.banner`, so it stays
    /// ordinary. Q23 / PRD decision 8.
    public var isTimeSensitive: Bool {
        delivery == .bannerSound && (sound == .needsApproval || sound == .needsAnswer)
    }
}

/// Thresholds for the sounding rules. Defaults match the product spec.
public struct SoundPolicyConfig: Sendable, Equatable {
    /// A task must have run at least this long for its completion to ring.
    public var doneMinRuntime: TimeInterval
    /// A session won't re-ring its waiting cue within this window.
    public var debounce: TimeInterval
    /// How long a wait must sit unanswered before one gentle nudge.
    public var longWaitThreshold: TimeInterval

    public init(doneMinRuntime: TimeInterval = 30,
                debounce: TimeInterval = 90,
                longWaitThreshold: TimeInterval = 180) {
        self.doneMinRuntime = doneMinRuntime
        self.debounce = debounce
        self.longWaitThreshold = longWaitThreshold
    }
}

/// One snapshot plus the ambient context the rules need.
public struct SoundPolicyInput: Sendable {
    public var sessions: [AgentSession]
    public var now: Date
    /// True when the user is actively looking at the app (front window / active
    /// scene). Completion stays silent when it's already on screen.
    public var appActive: Bool
    /// Quiet / Focus mode: every session is treated as `muted`.
    public var quietMode: Bool
    /// IDs of sessions whose own terminal window is currently frontmost — the user
    /// is already looking at them, and the native prompt is right there, so
    /// nothing about them interrupts: every cue is capped to the list. The Mac
    /// fills this from the frontmost terminal app; iOS leaves it empty.
    public var focusedSessionIDs: Set<String>

    public init(sessions: [AgentSession], now: Date, appActive: Bool, quietMode: Bool,
                focusedSessionIDs: Set<String> = []) {
        self.sessions = sessions
        self.now = now
        self.appActive = appActive
        self.quietMode = quietMode
        self.focusedSessionIDs = focusedSessionIDs
    }
}

/// Turns the live snapshot stream into a stream of cues, applying every rule in
/// one tested place:
///   - only state *boundaries* ring; starting work and plain refreshes stay silent;
///   - a waiting cue fires once per fresh wait and debounces re-entries;
///   - completion rings only when the task actually ran (> `doneMinRuntime`) and
///     you're not already watching the app;
///   - a failed / aborted ending rings the duller `agentStuck` instead;
///   - one gentle `longWaitNudge` after a wait drags past the threshold;
///   - then `DeliveryMatrix` decides how loud each cue is from the session's
///     attention level, Quiet mode reads every session as `muted`, a focused
///     terminal caps its session to the list, and a `drop` is never emitted.
/// Shared by the Mac menu bar, the Mac's push to the phone, and the iOS app so
/// all three behave identically.
public final class SoundPolicy {
    private let config: SoundPolicyConfig
    private var seenFirstSnapshot = false
    private var previous: [String: AgentSession] = [:]
    private var lastWaitingSoundAt: [String: Date] = [:]
    /// `statusSince` of the wait we've already nudged, keyed by session id.
    private var nudgedWaitSince: [String: Date] = [:]

    public init(config: SoundPolicyConfig = .init()) {
        self.config = config
    }

    /// Evaluate one snapshot; returns the cues to play right now (possibly none).
    public func evaluate(_ input: SoundPolicyInput) -> [SoundAlert] {
        defer {
            previous = Dictionary(uniqueKeysWithValues: input.sessions.map { ($0.id, $0) })
            seenFirstSnapshot = true
        }
        // Never ring the backlog already waiting when we first connect.
        guard seenFirstSnapshot else { return [] }

        var alerts: [SoundAlert] = []
        for session in input.sessions {
            guard let sound = boundarySound(prev: previous[session.id], now: session, input: input)
            else { continue }
            let attention: SessionAttention = input.quietMode ? .muted : session.effectiveAttention
            var level = DeliveryMatrix.level(for: sound, attention: attention)
            if input.focusedSessionIDs.contains(session.id) { level = min(level, .list) }
            guard level != .drop else { continue }
            alerts.append(SoundAlert(session: session, sound: sound, delivery: level))
        }
        return alerts
    }

    /// The cue earned by `session` given its prior state, before the matrix.
    private func boundarySound(prev: AgentSession?, now session: AgentSession,
                               input: SoundPolicyInput) -> NotificationSound? {
        switch session.status {
        case .needsResponse: return waitingSound(prev: prev, now: session, input: input)
        case .done:          return completionSound(prev: prev, now: session, input: input)
        case .working:       return nil   // starting work is process noise — never rings
        }
    }

    private func waitingSound(prev: AgentSession?, now session: AgentSession,
                              input: SoundPolicyInput) -> NotificationSound? {
        let enteringWait = prev?.status != .needsResponse
        guard enteringWait else {
            // Same wait, still unanswered: one gentle nudge once it drags on.
            return longWaitSound(now: session, input: input)
        }
        // Fresh wait: ring once, debounced against this session's last waiting cue.
        if let last = lastWaitingSoundAt[session.id],
           input.now.timeIntervalSince(last) < config.debounce {
            return nil
        }
        lastWaitingSoundAt[session.id] = input.now
        return session.waitKind == .permission ? .needsApproval : .needsAnswer
    }

    private func longWaitSound(now session: AgentSession, input: SoundPolicyInput) -> NotificationSound? {
        guard input.now.timeIntervalSince(session.statusSince) >= config.longWaitThreshold,
              nudgedWaitSince[session.id] != session.statusSince else { return nil }
        nudgedWaitSince[session.id] = session.statusSince
        return .longWaitNudge
    }

    private func completionSound(prev: AgentSession?, now session: AgentSession,
                                 input: SoundPolicyInput) -> NotificationSound? {
        // Only a real transition into done that we watched, and only when you're
        // not already looking at the result in VibeBuddy itself (`appActive`).
        // A focused terminal is handled by the list cap in `evaluate`.
        guard let prev, prev.status != .done, !input.appActive else { return nil }
        if session.probeRetired == true { return nil }

        // Real signal first (a tool/turn error reported by the hook), then the
        // prose heuristic as a fallback. Either way failures ring regardless of runtime.
        if session.isStuck || FailureHeuristic.looksFailed(session.summary) {
            return .agentStuck
        }
        guard input.now.timeIntervalSince(prev.statusSince) >= config.doneMinRuntime else { return nil }
        return .agentDone
    }
}
