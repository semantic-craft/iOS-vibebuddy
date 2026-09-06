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
///
/// This is the *relayed* field: what the iPhone knew about the Mac at the moment
/// it sent. It says nothing about whether the iPhone still reaches this Watch —
/// that is `WatchConnection`, which the Watch derives for itself.
public enum WatchRelayState: String, Codable, Sendable {
    /// The iPhone is connected to the Mac; this state is current.
    case live
    /// The iPhone lost the Mac. The last known state stays on screen, labelled.
    case disconnected
    /// The Watch has never received a state from the iPhone.
    case noData
}

/// Which link in the chain is broken, as the Watch can honestly tell it.
///
/// Three things can go wrong between an agent on the Mac and a number on a
/// wrist, and they need different answers from the person wearing it:
/// restart the daemon, open the phone app, or walk back to the phone. So the
/// Watch never says a flat "disconnected". It combines what the iPhone last
/// told it (`WatchRelayState`) with how old that is and whether the phone is
/// reachable *now*, and names the innermost link it can actually prove is down.
///
/// Derived, never relayed: a verdict computed on the iPhone would itself go
/// stale in the payload.
public enum WatchConnection: String, Sendable, Equatable, CaseIterable {
    /// The iPhone reached the Mac, and this Watch heard it recently.
    case live
    /// A recent relay, but the iPhone has lost the Mac daemon. Everything below
    /// the banner is the last thing the Mac said.
    case macDisconnected
    /// The iPhone is in range, yet nothing has arrived for `staleAfter`. The
    /// phone app is not relaying — closed, or unable to run.
    case phoneDisconnected
    /// The Watch cannot see the iPhone at all, and what is on screen has aged
    /// out. Out of range, or the phone is off.
    case watchUnreachable
    /// Nothing has ever arrived.
    case noData

    /// Whether the numbers on screen are a live reading rather than a memory.
    public var isCurrent: Bool { self == .live }
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
    /// The approval this alert may resolve from the wrist, when the relayed
    /// detail is complete enough to decide on (`WatchApprovalEligibility`).
    /// `nil` — always, for a question — means display-only: read it here,
    /// decide on the iPhone.
    public var approvalId: String?
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
        approvalId: String? = nil,
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
        self.approvalId = approvalId
        self.waitingSince = waitingSince
    }

    /// Whether the wrist may offer Approve / Deny for this alert.
    public var isDecidable: Bool { approvalId != nil }

    public func waitedFor(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(waitingSince))
    }
}

// MARK: - State

public struct WatchDashboardState: Codable, Equatable, Sendable {
    /// A relayed state older than this stops being evidence about the live
    /// world: the iPhone relays on every snapshot, so a quarter of an hour of
    /// silence means the relay itself is down, not that nothing happened. Same
    /// boundary as `ProviderQuota.staleAfter`, so one number ages everything.
    public static let staleAfter: TimeInterval = ProviderQuota.staleAfter

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

    /// Whether what is on screen has aged past the point of being a reading.
    /// Recomputed from the current clock every time, so a state restored from
    /// disk crosses the boundary on its own without a new message arriving.
    public func isStale(now: Date) -> Bool {
        age(now: now) >= Self.staleAfter
    }

    /// A complication with no relayed state must not invent counts. Empty
    /// live zeros are a reading; this is the absence of one.
    public var showsComplicationPlaceholder: Bool { relay == .noData }

    /// Smart Stack score. Zero means "do not rotate to the top"; any waiting
    /// session while the reading is still current raises the rectangular card.
    public func smartStackScore(now: Date) -> Float {
        guard !showsComplicationPlaceholder, !isStale(now: now) else { return 0 }
        return Float(counts.needsResponse)
    }

    /// The innermost broken link the Watch can prove, given its own clock and
    /// its own view of the phone.
    ///
    /// Age is checked before the relayed verdict: once nothing has arrived for
    /// `staleAfter`, "the iPhone was talking to the Mac" is a claim about a
    /// quarter of an hour ago, and the honest answer is that the relay is down.
    /// A fresh state with the phone momentarily out of range is still a
    /// reading, so the link is only named once the data has actually aged.
    public func connection(now: Date, phoneReachable: Bool) -> WatchConnection {
        if relay == .noData { return .noData }
        if isStale(now: now) {
            return phoneReachable ? .phoneDisconnected : .watchUnreachable
        }
        return relay == .disconnected ? .macDisconnected : .live
    }

    /// Sessions whose last turn ended badly. The three buckets hide this; the
    /// wrist should not.
    public var stuck: Int { presentation.error }

    /// Demo Mode only: what a later Mac snapshot would say once this approval
    /// resolved. Sample data then travels the same path as real data — the
    /// alert clears because the world changed, not because a button was tapped.
    public func resolvingApproval(_ approvalId: String) -> WatchDashboardState {
        guard alerts.contains(where: { $0.approvalId == approvalId }) else { return self }
        var resolved = self
        resolved.alerts.removeAll { $0.approvalId == approvalId }
        resolved.counts.needsResponse = max(0, counts.needsResponse - 1)
        resolved.counts.working += 1
        resolved.presentation.requiresInput = max(0, presentation.requiresInput - 1)
        resolved.presentation.thinking += 1
        return resolved
    }

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
            // Present only when the wrist has enough to decide on. A question is
            // never decidable here, and neither is an approval whose real detail
            // stayed on the iPhone.
            approvalId: WatchApprovalEligibility.approvalId(for: session),
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
