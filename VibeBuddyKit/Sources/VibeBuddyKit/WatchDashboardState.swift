import Foundation

/// Everything the Apple Watch is allowed to know, and nothing else.
///
/// The Mac stays the source of truth and the iPhone stays the only authenticated
/// LAN client; the Watch receives this compact, purpose-built value over
/// WatchConnectivity. It deliberately carries no pairing host/port, no bearer
/// token, no terminal reference, no transcript, and no full session list — losing
/// the Watch must not hand anyone access to the daemon.
///
/// Freshness is *not* stored as a verdict. Only observation times are stored, so
/// a state restored after a restart recomputes staleness against the current
/// clock instead of presenting an old value as live.

// MARK: - Relay

/// How the Watch's copy of the state relates to the live world.
public enum WatchRelayState: String, Codable, Sendable {
    /// The iPhone is connected to the Mac; this state is current.
    case live
    /// The iPhone lost the Mac. The last known state stays on screen, labelled.
    case disconnected
    /// The Watch has never received a state from the iPhone.
    case noData
}

// MARK: - Counts

/// The three canonical dashboard buckets, in the same vocabulary every other
/// surface uses. Built from `SessionGroups` so the Watch cannot invent a second
/// grouping rule.
public struct WatchSessionCounts: Codable, Equatable, Sendable {
    public var needsResponse: Int
    public var working: Int
    public var done: Int

    public init(needsResponse: Int = 0, working: Int = 0, done: Int = 0) {
        self.needsResponse = needsResponse
        self.working = working
        self.done = done
    }

    public init(_ groups: SessionGroups) {
        self.init(needsResponse: groups.needsResponse.count,
                  working: groups.working.count,
                  done: groups.done.count)
    }

    public var total: Int { needsResponse + working + done }
    public var isEmpty: Bool { total == 0 }
}

// MARK: - Alerts

/// One waiting session, reduced to what a wrist can show. The rich Edit/Write
/// pre- and post-image never reaches the Watch: a diff cannot be reviewed here.
public struct WatchAlert: Codable, Equatable, Sendable, Identifiable {
    public var sessionId: String
    public var agent: AgentKind
    public var project: String
    public var waitKind: WaitKind
    /// The session's own one-line summary, as shown on the iPhone.
    public var summary: String?
    /// Permission only: the tool the agent wants to run.
    public var tool: String?
    /// Permission: the command or target. Question: the prompt.
    public var request: String?
    /// Question only: the labels of any predefined answers, so the wrist can
    /// show what is being asked. Labels only — an option's `value` is text that
    /// would be typed into someone's terminal, and the Watch cannot send it.
    public var options: [String]
    public var waitingSince: Date

    public var id: String { sessionId }

    public init(
        sessionId: String,
        agent: AgentKind,
        project: String,
        waitKind: WaitKind,
        summary: String? = nil,
        tool: String? = nil,
        request: String? = nil,
        options: [String] = [],
        waitingSince: Date
    ) {
        self.sessionId = sessionId
        self.agent = agent
        self.project = project
        self.waitKind = waitKind
        self.summary = summary
        self.tool = tool
        self.request = request
        self.options = options
        self.waitingSince = waitingSince
    }

    public func waitedFor(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(waitingSince))
    }
}

// MARK: - State

public struct WatchDashboardState: Codable, Equatable, Sendable {
    /// The three buckets the Watch renders. The wrist has room for three lines,
    /// and this is the split the prototype validated.
    public var counts: WatchSessionCounts
    /// The app's five-state aggregate, shared with the Mac, the iPhone list,
    /// the Live Activity and the widget. It is a different partition, not a
    /// finer one: a failed session reads as `error` whatever bucket it is in,
    /// which is the one signal the three buckets cannot express.
    public var presentation: TaskPresentationSummary
    /// Waiting sessions in the dashboard's own order; the first one takes over
    /// the home screen.
    public var alerts: [WatchAlert]
    public var quotas: [ProviderQuota]
    public var relay: WatchRelayState
    /// When the iPhone produced this state.
    public var observedAt: Date
    /// Sample data, so the Watch can say so out loud.
    public var isDemo: Bool

    public init(
        counts: WatchSessionCounts = WatchSessionCounts(),
        presentation: TaskPresentationSummary = TaskPresentationSummary(),
        alerts: [WatchAlert] = [],
        quotas: [ProviderQuota] = [],
        relay: WatchRelayState,
        observedAt: Date,
        isDemo: Bool = false
    ) {
        self.counts = counts
        self.presentation = presentation
        self.alerts = alerts
        self.quotas = quotas
        self.relay = relay
        self.observedAt = observedAt
        self.isDemo = isDemo
    }

    /// Nothing has ever arrived from the iPhone.
    public static func noData(observedAt: Date) -> WatchDashboardState {
        WatchDashboardState(relay: .noData, observedAt: observedAt)
    }

    /// The session that takes over the home screen, if any.
    public var topAlert: WatchAlert? { alerts.first }

    public func quota(_ provider: AccountUsageProvider) -> ProviderQuota? {
        quotas.first { $0.provider == provider }
    }

    public func age(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(observedAt))
    }

    /// Sessions whose last turn ended badly. The three buckets hide this; the
    /// wrist should not.
    public var stuck: Int { presentation.error }

    /// Whether two projections say the same thing about the world.
    ///
    /// Only the observation time may differ: the Watch derives every age and
    /// freshness from its own clock, so re-sending an identical payload one
    /// second later would cost radio and change nothing on screen.
    public func isEquivalent(to other: WatchDashboardState) -> Bool {
        var mine = self
        mine.observedAt = other.observedAt
        return mine == other
    }

    /// The companion's mood, from what the Watch actually knows. It deliberately
    /// never claims `.done`: unread-completion truth stays on the Mac and does
    /// not reach the wrist.
    public var buddyState: BuddyState {
        if let alert = topAlert {
            return alert.waitKind == .permission ? .approval : .question
        }
        if counts.working > 0 { return .working }
        return counts.isEmpty ? .sleeping : .idle
    }
}

// MARK: - Projection

/// The one pure seam every Watch-visible behavior is tested through: the Mac's
/// snapshot, normalized quota, the iPhone's connection state and a clock in;
/// exactly what the Watch renders out. No I/O, no platform frameworks, no
/// hidden clock.
public enum WatchDashboardProjection {
    public static func make(
        snapshot: Snapshot,
        quotas: [ProviderQuota],
        relay: WatchRelayState,
        now: Date,
        isDemo: Bool = false
    ) -> WatchDashboardState {
        let groups = SessionGroups(snapshot.sessions)
        return WatchDashboardState(
            counts: WatchSessionCounts(groups),
            presentation: TaskPresentationSummary(sessions: snapshot.sessions),
            alerts: groups.needsResponse.map(alert(for:)),
            quotas: quotas,
            relay: relay,
            observedAt: now,
            isDemo: isDemo
        )
    }

    private static func alert(for session: AgentSession) -> WatchAlert {
        let waitKind = session.waitKind ?? .question
        return WatchAlert(
            sessionId: session.id,
            agent: session.agent,
            project: session.project,
            waitKind: waitKind,
            summary: session.summary,
            tool: session.pendingApproval?.tool,
            request: request(for: session, waitKind: waitKind),
            options: waitKind == .question
                ? (session.pendingQuestion?.options.map(\.label) ?? [])
                : [],
            waitingSince: session.statusSince
        )
    }

    /// The single line that says what is blocked. A permission shows the full
    /// command or the target path; the truncated preview is the last resort.
    /// An Edit/Write diff is deliberately left behind on the iPhone.
    private static func request(for session: AgentSession, waitKind: WaitKind) -> String? {
        switch waitKind {
        case .permission:
            guard let approval = session.pendingApproval else { return nil }
            return approval.command ?? approval.filePath ?? approval.commandPreview
        case .question:
            // Most waiting sessions have no structured question — the agent just
            // said what it needs. That message is the prompt, so use it rather
            // than leaving the row blank.
            return session.pendingQuestion?.prompt ?? session.summary
        }
    }
}
