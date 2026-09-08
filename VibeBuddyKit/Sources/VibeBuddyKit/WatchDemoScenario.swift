import Foundation

/// Deterministic Watch states for Demo Mode, App Review, and simulator QA.
///
/// Every scenario is a pure function of the clock it is given, so the same
/// launch input always produces the same screen. Sessions reuse the iPhone demo
/// projects so the two surfaces tell one story.
public enum WatchDemoScenario: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Nobody is waiting: agents are working and finished work is unread.
    case normal
    /// The highest-priority session is blocked on a permission.
    case permission
    /// The highest-priority session asked a question.
    case question
    /// Connected, with no sessions at all.
    case empty
    /// Codex quota was last read long enough ago to read as stale.
    case staleQuota
    /// The Codex source produced nothing usable.
    case unavailableQuota
    /// The iPhone is relaying, but it has lost the Mac daemon.
    case macDisconnected
    /// The iPhone is in range and has stopped relaying: the last state has aged
    /// past the stale boundary.
    case phoneDisconnected
    /// The Watch has lost the iPhone entirely and the last state has aged out.
    case watchUnreachable
    /// The iPhone has never delivered a state.
    case noData

    public var id: String { rawValue }

    /// The sample Mac and pairing every scenario relays as. They are here so a
    /// `vibebuddy://watch-task` link resolves in Demo Mode exactly as it does
    /// against a real relay — a task detail (and the Stop on it) that only
    /// exists when paired is a flow nobody can rehearse.
    public static let sourceID = "demo-mac"
    public static let pairingEpoch = "demo-epoch"
    /// The sample Mac's display name. Present so the send-confirmation page
    /// rehearses the caption it will really show — "which Mac am I about to
    /// talk to" is the question that page exists to answer, and a sample that
    /// falls back to a generic "Mac" never asks it.
    public static let macName = "Demo Mac"

    public func state(now: Date) -> WatchDashboardState {
        guard self != .noData else { return .noData(observedAt: now) }
        var state = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions(now: now), serverTime: now,
                               sourceID: Self.sourceID),
            quotas: quotas(now: now),
            relay: self == .macDisconnected ? .disconnected : .live,
            now: now.addingTimeInterval(-observedAgo),
            isDemo: true
        )
        state.pairingEpoch = Self.pairingEpoch
        state.macName = Self.macName
        return state
    }

    /// The sample task a Stop can be rehearsed on, as a link the Watch opens
    /// the same way it opens one from a complication.
    public static let stoppableTask = WatchTaskLink(
        sourceID: sourceID, pairingEpoch: pairingEpoch,
        sessionID: "demo-watch-tests", completionID: nil)

    /// The sample task whose agent cannot be stopped from a wrist, so the
    /// "here is why there is no button" branch is rehearsable too.
    public static let unstoppableTask = WatchTaskLink(
        sourceID: sourceID, pairingEpoch: pairingEpoch,
        sessionID: "demo-watch-auth", completionID: nil)

    /// How long ago the iPhone is pretending to have sent this. The two relay
    /// failures are only visible once the state has aged, and nobody is going
    /// to sit in front of a simulator for a quarter of an hour to see it.
    private var observedAgo: TimeInterval {
        switch self {
        case .phoneDisconnected, .watchUnreachable: return WatchDashboardState.staleAfter + 3 * 60
        default: return 0
        }
    }

    /// Whether the Watch can see the phone in this scenario. Only the last link
    /// distinguishes "the phone stopped talking" from "the phone is gone".
    public var phoneReachable: Bool { self != .watchUnreachable }

    // MARK: sessions

    private func sessions(now: Date) -> [AgentSession] {
        switch self {
        case .normal, .staleQuota, .unavailableQuota,
             .phoneDisconnected, .watchUnreachable:
            return Self.workingAndDone(now: now)
        case .macDisconnected:
            // A waiting question is in here on purpose: a broken link is only
            // interesting next to something the wrist would otherwise act on,
            // and "the buttons are gone and here is why" is the branch worth
            // rehearsing.
            return [Self.openQuestionSession(now: now)] + Self.workingAndDone(now: now)
        case .permission:
            return [Self.permissionSession(now: now), Self.questionSession(now: now)]
                + Self.workingAndDone(now: now).prefix(2)
        case .question:
            // Both shapes of question, because the wrist answers them
            // differently: an open one takes the fixed phrases, one with
            // choices takes the agent's own. The open one leads so the home
            // takeover rehearses the phrases; the other is a task detail away
            // (`VIBEBUDDY_WATCH_TASK=demo-watch-question`).
            return [Self.openQuestionSession(now: now), Self.questionSession(now: now)]
                + Self.workingAndDone(now: now).prefix(3)
        case .empty, .noData:
            return []
        }
    }

    private static func permissionSession(now: Date) -> AgentSession {
        AgentSession(
            id: "demo-watch-permission", agent: .claudeCode, project: "ios-vibebuddy",
            branch: "feat/watch-01", model: "claude-opus-4-8",
            status: .needsResponse, waitKind: .permission,
            pendingApproval: PendingApproval(
                id: "demo-watch-approval", tool: "Bash",
                commandPreview: "xcodebuild -scheme VibeBuddyWatch…",
                command: "xcodebuild -scheme VibeBuddyWatch -destination 'platform=watchOS Simulator' build"),
            summary: "Build the Watch app",
            statusSince: now.addingTimeInterval(-38), updatedAt: now.addingTimeInterval(-38))
    }

    /// The sample question with no choices attached: the fixed phrases are the
    /// only quick answers, and dictation is the way past them.
    public static let openQuestionTask = WatchTaskLink(
        sourceID: sourceID, pairingEpoch: pairingEpoch,
        sessionID: "demo-watch-open-question", completionID: nil)

    /// The sample question the agent offered choices for: the choices replace
    /// the phrases, and "Something else" is the way past them.
    public static let optionQuestionTask = WatchTaskLink(
        sourceID: sourceID, pairingEpoch: pairingEpoch,
        sessionID: "demo-watch-question", completionID: nil)

    private static func openQuestionSession(now: Date) -> AgentSession {
        AgentSession(
            id: "demo-watch-open-question", agent: .codex, project: "ios-vibebuddy",
            branch: "feat/watch-03", model: "gpt-5-codex",
            status: .needsResponse, waitKind: .question,
            pendingQuestion: PendingQuestion(
                id: "demo-watch-open-prompt",
                prompt: "The migration touches two schemas. Should I keep going?"),
            summary: "Waiting on a go-ahead",
            attention: .followed,
            statusSince: now.addingTimeInterval(-6 * 60), updatedAt: now.addingTimeInterval(-6 * 60))
    }

    private static func questionSession(now: Date) -> AgentSession {
        AgentSession(
            id: "demo-watch-question", agent: .codex, project: "docs-review",
            model: "gpt-5-codex", status: .needsResponse, waitKind: .question,
            pendingQuestion: PendingQuestion(
                id: "demo-watch-prompt",
                prompt: "Which revision style should I use?",
                options: [
                    QuestionOption(id: "tight", label: "Tighten"),
                    QuestionOption(id: "plain", label: "Plain language"),
                ]),
            summary: "Waiting on a revision style",
            attention: .followed,
            statusSince: now.addingTimeInterval(-4 * 60), updatedAt: now.addingTimeInterval(-4 * 60))
    }

    private static func workingAndDone(now: Date) -> [AgentSession] {
        [
            // Followed, Codex, and carried by the app-server connection: the one
            // shape a running turn can be ended from the wrist in. Everything
            // the Stop button needs is on this session, so Demo Mode rehearses
            // the real rule rather than a relaxed one.
            AgentSession(
                id: "demo-watch-tests", agent: .codex, project: "ios-vibebuddy", branch: "main",
                model: "gpt-5-codex", status: .working, summary: "Running the test suite…",
                activeTool: "Bash",
                observations: [ObservationEvidence(source: .appserver,
                                                   lastObservedAt: now.addingTimeInterval(-12),
                                                   health: .healthy)],
                attention: .followed,
                statusSince: now.addingTimeInterval(-12), updatedAt: now.addingTimeInterval(-12)),
            // Followed and running, but Claude Code: the wrist says where to go
            // instead of offering a button that would be refused.
            AgentSession(
                id: "demo-watch-auth", agent: .claudeCode, project: "web-dashboard", branch: "feat/auth",
                model: "claude-opus-4-8", status: .working, summary: "Refactoring the auth middleware…",
                activeTool: "Edit",
                observations: [ObservationEvidence(source: .hook,
                                                   lastObservedAt: now.addingTimeInterval(-95),
                                                   health: .healthy)],
                attention: .followed,
                statusSince: now.addingTimeInterval(-95), updatedAt: now.addingTimeInterval(-95)),
            AgentSession(
                id: "demo-watch-docs", agent: .claudeCode, project: "docs-site",
                model: "claude-haiku-4-5", status: .done, summary: "Deployed to production.",
                hasUnreadCompletion: true,
                statusSince: now.addingTimeInterval(-300), updatedAt: now.addingTimeInterval(-300)),
            AgentSession(
                id: "demo-watch-release", agent: .codex, project: "release-check",
                model: "gpt-5-codex", status: .done, summary: "Build failed with two signing errors.",
                failed: true,
                statusSince: now.addingTimeInterval(-420), updatedAt: now.addingTimeInterval(-420)),
            AgentSession(
                id: "demo-watch-notes", agent: .claudeCode, project: "api-notes",
                model: "claude-sonnet-4-5", status: .done, summary: "No unread updates.",
                statusSince: now.addingTimeInterval(-900), updatedAt: now.addingTimeInterval(-900)),
            AgentSession(
                id: "demo-watch-todo", agent: .claudeCode, project: "todo-app", branch: "feat/reminders",
                model: "claude-opus-4-8", status: .done, summary: "Sorted reminders by due date.",
                statusSince: now.addingTimeInterval(-1_500), updatedAt: now.addingTimeInterval(-1_500)),
        ]
    }

    // MARK: quota

    /// Sample quota for all supported providers. The iPhone relays these while it is in
    /// Demo Mode, so the Watch's quota page has something honest-looking to show
    /// before a real provider source exists.
    public func quotas(now: Date) -> [ProviderQuota] {
        let base = baseQuotas(now: now)
        guard self != .noData, self != .empty else { return base }
        let observed = now.addingTimeInterval(self == .staleQuota ? -18 * 60 : -max(42, observedAgo))
        let cursor = ProviderQuota(provider: .cursor, otherWindows: [
            QuotaWindow(remainingPercent: 74, durationMinutes: 43200,
                        resetsAt: now.addingTimeInterval(12 * 86400), observedAt: observed, label: "Cursor Models"),
            QuotaWindow(remainingPercent: 31, durationMinutes: 43200,
                        resetsAt: now.addingTimeInterval(12 * 86400), observedAt: observed, label: "Other Models")
        ], observedAt: observed)
        let grok = ProviderQuota(provider: .grok, weeklyRemainingPercent: self == .unavailableQuota ? nil : 23,
                                 weeklyResetsAt: now.addingTimeInterval(2 * 86400), weeklyWindowDurationMinutes: 10080,
                                 observedAt: observed)
        let bot: ProviderQuota = self == .unavailableQuota
            ? .unavailable(.grokBot, reason: "Shared enterprise allowance; personal percentage unavailable")
            : ProviderQuota(provider: .grokBot, weeklyRemainingPercent: 56,
                            weeklyResetsAt: now.addingTimeInterval(3 * 86400), weeklyWindowDurationMinutes: 10080,
                            observedAt: observed)
        return base + [cursor, grok, bot]
    }

    private func baseQuotas(now: Date) -> [ProviderQuota] {
        switch self {
        case .staleQuota:
            return [Self.codex(observedAt: now.addingTimeInterval(-18 * 60), now: now),
                    Self.claude(observedAt: now.addingTimeInterval(-70), now: now)]
        case .unavailableQuota:
            return [.unavailable(.codex, reason: "Codex is signed out"),
                    Self.claude(observedAt: now.addingTimeInterval(-70), now: now)]
        case .noData:
            return []
        case .phoneDisconnected, .watchUnreachable:
            // The whole relay stopped, so both readings aged with it. A live
            // quota next to a stale dashboard would be a contradiction.
            let observed = now.addingTimeInterval(-observedAgo)
            return [Self.codex(observedAt: observed, now: now),
                    Self.claude(observedAt: observed, now: now)]
        case .normal, .permission, .question, .empty, .macDisconnected:
            return [Self.codex(observedAt: now.addingTimeInterval(-42), now: now),
                    Self.claude(observedAt: now.addingTimeInterval(-70), now: now)]
        }
    }

    private static func codex(observedAt: Date, now: Date) -> ProviderQuota {
        ProviderQuota(
            provider: .codex,
            weeklyRemainingPercent: 68,
            weeklyResetsAt: now.addingTimeInterval(3 * 86_400 + 8 * 3_600),
            weeklyWindowDurationMinutes: 10080,
            shortWindowRemainingPercent: 84,
            shortWindowResetsAt: now.addingTimeInterval(2 * 3_600 + 10 * 60),
            shortWindowDurationMinutes: 300,
            observedAt: observedAt)
    }

    private static func claude(observedAt: Date, now: Date) -> ProviderQuota {
        ProviderQuota(
            provider: .claude,
            weeklyRemainingPercent: 41,
            weeklyResetsAt: now.addingTimeInterval(4 * 86_400 + 2 * 3_600),
            weeklyWindowDurationMinutes: 10080,
            shortWindowRemainingPercent: 72,
            shortWindowResetsAt: now.addingTimeInterval(3_600 + 25 * 60),
            shortWindowDurationMinutes: 300,
            observedAt: observedAt)
    }
}
