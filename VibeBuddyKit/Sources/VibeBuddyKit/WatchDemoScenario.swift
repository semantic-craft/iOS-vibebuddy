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
    /// The iPhone has never delivered a state.
    case noData

    public var id: String { rawValue }

    public func state(now: Date) -> WatchDashboardState {
        guard self != .noData else { return .noData(observedAt: now) }
        return WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions(now: now), serverTime: now),
            quotas: quotas(now: now),
            relay: .live,
            now: now,
            isDemo: true
        )
    }

    // MARK: sessions

    private func sessions(now: Date) -> [AgentSession] {
        switch self {
        case .normal, .staleQuota, .unavailableQuota:
            return Self.workingAndDone(now: now)
        case .permission:
            return [Self.permissionSession(now: now), Self.questionSession(now: now)]
                + Self.workingAndDone(now: now).prefix(2)
        case .question:
            return [Self.questionSession(now: now)] + Self.workingAndDone(now: now).prefix(3)
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
            statusSince: now.addingTimeInterval(-4 * 60), updatedAt: now.addingTimeInterval(-4 * 60))
    }

    private static func workingAndDone(now: Date) -> [AgentSession] {
        [
            AgentSession(
                id: "demo-watch-tests", agent: .codex, project: "ios-vibebuddy", branch: "main",
                model: "gpt-5-codex", status: .working, summary: "Running the test suite…",
                activeTool: "Bash",
                statusSince: now.addingTimeInterval(-12), updatedAt: now.addingTimeInterval(-12)),
            AgentSession(
                id: "demo-watch-auth", agent: .claudeCode, project: "web-dashboard", branch: "feat/auth",
                model: "claude-opus-4-8", status: .working, summary: "Refactoring the auth middleware…",
                activeTool: "Edit",
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

    /// Sample quota for both providers. The iPhone relays these while it is in
    /// Demo Mode, so the Watch's quota page has something honest-looking to show
    /// before a real provider source exists.
    public func quotas(now: Date) -> [WatchQuota] {
        switch self {
        case .staleQuota:
            return [Self.codex(observedAt: now.addingTimeInterval(-18 * 60), now: now), Self.claude(now: now)]
        case .unavailableQuota:
            return [.unavailable(.codex, reason: "Codex is signed out"), Self.claude(now: now)]
        case .noData:
            return []
        case .normal, .permission, .question, .empty:
            return [Self.codex(observedAt: now.addingTimeInterval(-42), now: now), Self.claude(now: now)]
        }
    }

    private static func codex(observedAt: Date, now: Date) -> WatchQuota {
        WatchQuota(
            provider: .codex,
            weeklyRemainingPercent: 68,
            weeklyResetsAt: now.addingTimeInterval(3 * 86_400 + 8 * 3_600),
            shortWindowRemainingPercent: 84,
            shortWindowResetsAt: now.addingTimeInterval(2 * 3_600 + 10 * 60),
            observedAt: observedAt)
    }

    private static func claude(now: Date) -> WatchQuota {
        WatchQuota(
            provider: .claude,
            weeklyRemainingPercent: 41,
            weeklyResetsAt: now.addingTimeInterval(4 * 86_400 + 2 * 3_600),
            shortWindowRemainingPercent: 72,
            shortWindowResetsAt: now.addingTimeInterval(3_600 + 25 * 60),
            observedAt: now.addingTimeInterval(-70))
    }
}
