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
/// surface uses: the Companion's attention groups (`StateGroups`), so a failed
/// session counts under Needs you here exactly as it does on the phone's list
/// and in the mood line. The wire names keep their status spelling.
public struct WatchSessionCounts: Codable, Equatable, Sendable {
    public var needsResponse: Int
    public var working: Int
    public var done: Int

    public init(needsResponse: Int = 0, working: Int = 0, done: Int = 0) {
        self.needsResponse = needsResponse
        self.working = working
        self.done = done
    }

    /// Status-based, kept for callers that only know `SessionGroups`.
    public init(_ groups: SessionGroups) {
        self.init(needsResponse: groups.needsResponse.count,
                  working: groups.working.count,
                  done: groups.done.count)
    }

    /// Attention-based: what the Watch shows, matching every other surface.
    public init(_ groups: StateGroups) {
        self.init(needsResponse: groups.needsYou.count,
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
    /// `nil` — always, for a question — means display-only. `handling` names
    /// the verified destination; absence never promises another device can act.
    public var approvalId: String?
    /// Question only: the pending question's own id, so an answer sent from the
    /// wrist binds to *this* question rather than to whatever is being asked
    /// when it lands. Absent for a permission — `approvalId` is that binding —
    /// and absent in relays that predate the shared action contract.
    public var pendingId: String?
    public var handling: WaitHandling?
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
        pendingId: String? = nil,
        handling: WaitHandling? = nil,
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
        self.pendingId = pendingId
        self.handling = handling
        self.waitingSince = waitingSince
    }

    /// Whether the wrist may offer Approve / Deny for this alert.
    public var isDecidable: Bool {
        handling == .watchApproval && waitKind == .permission && agent != .grokBot
            && approvalId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Whether a question on this alert could be answered remotely at all. The
    /// wrist's input for it is ticket 03; the rule lives here so the projection
    /// and the iPhone's gate cannot disagree about which questions qualify.
    public var isAnswerable: Bool {
        handling == .remoteAvailable && waitKind == .question
            && pendingId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

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
    public var sourceID: String?
    /// The paired Mac's own name, as the pairing QR carried it. Present so a
    /// send from the wrist can name where it is going — "My Mac · docs-review ·
    /// Codex" rather than a generic "Mac" — which is the point of a
    /// confirmation page for someone with more than one Mac. It is a label, not
    /// an address: no host, no port and no token ever cross to the Watch.
    /// Absent in relays that predate the wrist being able to send anything.
    public var macName: String?
    public var pairingEpoch: String?
    /// Persistent iPhone publication order; never derived from the Mac clock.
    public var relayRevision: UInt64
    public var followedTasks: [WatchFollowedTask]
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
    /// The phone's notification switches, mirrored so the wrist's own haptics
    /// obey them (`WatchHaptics`). Optional: a relay from a build that predates
    /// this reads as the phone default. The Watch has no settings of its own —
    /// one notification switch, honoured on both devices.
    public var categories: NotificationCategoryPrefs?
    /// The phone's Quiet settings, relayed as settings rather than as a verdict
    /// so the Watch can decide against its own clock.
    public var quiet: WatchQuietSettings?
    public var relay: WatchRelayState
    /// When the backing state was observed (the live phone relay passes the Mac snapshot time).
    public var observedAt: Date
    /// Sample data, so the Watch can say so out loud.
    public var isDemo: Bool

    public init(
        sourceID: String? = nil,
        macName: String? = nil,
        pairingEpoch: String? = nil,
        relayRevision: UInt64 = 0,
        followedTasks: [WatchFollowedTask] = [],
        counts: WatchSessionCounts = WatchSessionCounts(),
        presentation: TaskPresentationSummary = TaskPresentationSummary(),
        alerts: [WatchAlert] = [],
        quotas: [ProviderQuota] = [],
        categories: NotificationCategoryPrefs? = nil,
        quiet: WatchQuietSettings? = nil,
        relay: WatchRelayState,
        observedAt: Date,
        isDemo: Bool = false
    ) {
        self.sourceID = sourceID
        self.macName = macName
        self.pairingEpoch = pairingEpoch
        self.relayRevision = relayRevision
        self.followedTasks = followedTasks
        self.counts = counts
        self.presentation = presentation
        self.alerts = alerts
        self.quotas = quotas
        self.categories = categories
        self.quiet = quiet
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

    /// Demo Stop mirrors the Mac's acknowledged user stop, without error or unread completion.
    public func resolvingStop(_ sessionID: String) -> WatchDashboardState {
        guard let index = followedTasks.firstIndex(where: {
            $0.sessionID == sessionID && $0.stop?.isOffered == true
        }) else { return self }
        var resolved = self
        resolved.followedTasks[index].stop = nil
        resolved.followedTasks[index].presentation = .idle
        // The Mac's own wording for an interrupted turn, verbatim: a summary is
        // data the Mac wrote, not copy this app translates.
        resolved.followedTasks[index].summary = "Turn interrupted"
        resolved.counts.working = max(0, counts.working - 1)
        resolved.counts.done += 1
        resolved.presentation.thinking = max(0, presentation.thinking - 1)
        resolved.presentation.idle += 1
        return resolved
    }

    /// Demo Mode only: what a later Mac snapshot would say once this answer
    /// reached the agent. The question is gone and the session is running
    /// again, which is exactly what makes the reply's card disappear — the
    /// world changed, not the button.
    public func resolvingAnswer(_ pendingId: String) -> WatchDashboardState {
        guard let index = alerts.firstIndex(where: { $0.isAnswerable && $0.pendingId == pendingId })
        else { return self }
        var resolved = self
        let sessionId = resolved.alerts[index].sessionId
        resolved.alerts.remove(at: index)
        resolved.counts.needsResponse = max(0, counts.needsResponse - 1)
        resolved.counts.working += 1
        resolved.presentation.requiresInput = max(0, presentation.requiresInput - 1)
        resolved.presentation.thinking += 1
        if let task = resolved.followedTasks.firstIndex(where: { $0.sessionID == sessionId }) {
            resolved.followedTasks[task].presentation = .thinking
            resolved.followedTasks[task].waitKind = nil
            resolved.followedTasks[task].pendingID = nil
        }
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
        mine.relayRevision = other.relayRevision
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
        let sessions = snapshot.sessions.map { $0.validatingCompletionNotice(sourceID: snapshot.sourceID) }
        // The wrist counts what is current (`SessionCurrency`), the same rule
        // as the phone's summary line; a followed task stays listed because the
        // person chose it, and every alert is current by definition.
        let current = SessionCurrency.current(sessions, now: now)
        let groups = SessionGroups(current)
        return WatchDashboardState(
            sourceID: snapshot.sourceID,
            followedTasks: sessions.filter { $0.effectiveAttention == .followed }.map(WatchFollowedTask.init),
            counts: WatchSessionCounts(StateGroups(current)),
            presentation: TaskPresentationSummary(sessions: current),
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
            // Only for a question one string can finish. A multi-part or
            // multi-select wait keeps `handling` (the iPhone can answer it) and
            // loses the identity, because the wrist has no identity here it
            // could act on: it would answer one question out of three.
            pendingId: waitKind == .question
                ? session.pendingQuestion.flatMap { $0.isSinglePart ? $0.id : nil } : nil,
            handling: WatchApprovalEligibility.approvalId(for: session) != nil
                ? .watchApproval : WaitHandling.resolve(for: session),
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
