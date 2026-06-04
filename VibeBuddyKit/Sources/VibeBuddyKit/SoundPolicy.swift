import Foundation

/// A decision to play one cue for one session at a state boundary.
public struct SoundAlert: Equatable, Sendable {
    public let session: AgentSession
    public let sound: NotificationSound
    public var sessionID: String { session.id }

    public init(session: AgentSession, sound: NotificationSound) {
        self.session = session
        self.sound = sound
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
    /// Quiet / Focus mode: only approvals ring.
    public var quietMode: Bool

    public init(sessions: [AgentSession], now: Date, appActive: Bool, quietMode: Bool) {
        self.sessions = sessions
        self.now = now
        self.appActive = appActive
        self.quietMode = quietMode
    }
}

/// Turns the live snapshot stream into a stream of sound cues, applying every
/// rule in one tested place:
///   - only state *boundaries* ring; starting work and plain refreshes stay silent;
///   - a waiting cue fires once per fresh wait and debounces re-entries;
///   - completion rings only when the task actually ran (> `doneMinRuntime`) and
///     you're not already watching the app;
///   - a failed / aborted ending rings the duller `agentStuck` instead;
///   - one gentle `longWaitNudge` after a wait drags past the threshold;
///   - Quiet / Focus mode keeps only approvals.
/// Shared by the Mac menu bar and the iOS app so both behave identically.
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
            if let alert = boundaryAlert(prev: previous[session.id], now: session, input: input) {
                alerts.append(alert)
            }
        }
        return input.quietMode ? alerts.filter { $0.sound.survivesQuietMode } : alerts
    }

    /// The cue earned by `session` given its prior state, before Quiet filtering.
    private func boundaryAlert(prev: AgentSession?, now session: AgentSession,
                               input: SoundPolicyInput) -> SoundAlert? {
        switch session.status {
        case .needsResponse: return waitingAlert(prev: prev, now: session, input: input)
        case .done:          return completionAlert(prev: prev, now: session, input: input)
        case .working:       return nil   // starting work is process noise — never rings
        }
    }

    private func waitingAlert(prev: AgentSession?, now session: AgentSession,
                              input: SoundPolicyInput) -> SoundAlert? {
        let enteringWait = prev?.status != .needsResponse
        guard enteringWait else {
            // Same wait, still unanswered: one gentle nudge once it drags on.
            return longWaitAlert(now: session, input: input)
        }
        // Fresh wait: ring once, debounced against this session's last waiting cue.
        if let last = lastWaitingSoundAt[session.id],
           input.now.timeIntervalSince(last) < config.debounce {
            return nil
        }
        lastWaitingSoundAt[session.id] = input.now
        let sound: NotificationSound = session.waitKind == .permission ? .needsApproval : .needsAnswer
        return SoundAlert(session: session, sound: sound)
    }

    private func longWaitAlert(now session: AgentSession, input: SoundPolicyInput) -> SoundAlert? {
        guard input.now.timeIntervalSince(session.statusSince) >= config.longWaitThreshold,
              nudgedWaitSince[session.id] != session.statusSince else { return nil }
        nudgedWaitSince[session.id] = session.statusSince
        return SoundAlert(session: session, sound: .longWaitNudge)
    }

    private func completionAlert(prev: AgentSession?, now session: AgentSession,
                                 input: SoundPolicyInput) -> SoundAlert? {
        // Only a real transition into done that we watched, and only when you're
        // not already looking at the result.
        guard let prev, prev.status != .done, !input.appActive else { return nil }

        // Real signal first (a tool/turn error reported by the hook), then the
        // prose heuristic as a fallback. Either way failures ring regardless of runtime.
        if session.isStuck || FailureHeuristic.looksFailed(session.summary) {
            return SoundAlert(session: session, sound: .agentStuck)
        }
        guard input.now.timeIntervalSince(prev.statusSince) >= config.doneMinRuntime else { return nil }
        return SoundAlert(session: session, sound: .agentDone)
    }
}
