import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("Watch dashboard state")
struct WatchDashboardStateTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        id: String,
        status: SessionStatus,
        waitKind: WaitKind? = nil,
        approval: PendingApproval? = nil,
        question: PendingQuestion? = nil,
        project: String = "vibebuddy",
        secondsWaiting: TimeInterval = 30
    ) -> AgentSession {
        AgentSession(
            id: id, agent: .claudeCode, project: project, branch: "main",
            model: "claude-opus-4-8", status: status, waitKind: waitKind,
            pendingApproval: approval, pendingQuestion: question,
            terminalRef: TerminalRef(termProgram: "iTerm.app", tty: "/dev/ttys004"),
            summary: "wrote section 2", tokens: 12_345,
            statusSince: now.addingTimeInterval(-secondsWaiting),
            updatedAt: now)
    }

    private func project(_ sessions: [AgentSession],
                         quotas: [ProviderQuota] = [],
                         relay: WatchRelayState = .live) -> WatchDashboardState {
        WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions, serverTime: now),
            quotas: quotas, relay: relay, now: now)
    }

    // MARK: counts + ordering

    @Test("Counts come from the same buckets as every other surface")
    func countsMatchSessionGroups() {
        let sessions = [
            session(id: "a", status: .needsResponse, waitKind: .question),
            session(id: "b", status: .working),
            session(id: "c", status: .working),
            session(id: "d", status: .done),
        ]
        let state = project(sessions)
        let groups = SessionGroups(sessions)
        #expect(state.counts == WatchSessionCounts(groups))
        #expect(state.counts == WatchSessionCounts(needsResponse: 1, working: 2, done: 1))
        #expect(state.counts.total == 4)
    }

    @Test("No sessions is an empty, connected state — not a no-data state")
    func emptyIsNotNoData() {
        let state = project([])
        #expect(state.counts.isEmpty)
        #expect(state.alerts.isEmpty)
        #expect(state.relay == .live)
        #expect(state.topAlert == nil)
    }

    @Test("The top alert keeps the dashboard's own order")
    func topAlertUsesExistingOrdering() {
        let sessions = [
            session(id: "working", status: .working),
            session(id: "first", status: .needsResponse, waitKind: .question, secondsWaiting: 10),
            session(id: "second", status: .needsResponse, waitKind: .permission, secondsWaiting: 600),
        ]
        let state = project(sessions)
        #expect(state.alerts.map(\.sessionId) == ["first", "second"])
        #expect(state.topAlert?.sessionId == "first")
    }

    // MARK: alert content

    @Test("A permission alert carries the full command, not the preview")
    func permissionAlertPrefersTheFullCommand() throws {
        let approval = PendingApproval(
            id: "ap-1", tool: "Bash", commandPreview: "swift test…",
            command: "swift test --filter WatchDashboardStateTests")
        let state = project([session(id: "a", status: .needsResponse, waitKind: .permission, approval: approval)])
        let alert = try #require(state.topAlert)
        #expect(alert.waitKind == .permission)
        #expect(alert.tool == "Bash")
        #expect(alert.request == "swift test --filter WatchDashboardStateTests")
        #expect(alert.waitedFor(now: now) == 30)
    }

    @Test("A file permission falls back to the target path, then the preview")
    func permissionFallsBackToPathThenPreview() {
        let path = PendingApproval(id: "ap", tool: "Write", commandPreview: "src/app.ts…",
                                   filePath: "src/app.ts")
        let previewOnly = PendingApproval(id: "ap", tool: "Write", commandPreview: "src/app.ts…")
        #expect(project([session(id: "a", status: .needsResponse, waitKind: .permission, approval: path)])
            .topAlert?.request == "src/app.ts")
        #expect(project([session(id: "a", status: .needsResponse, waitKind: .permission, approval: previewOnly)])
            .topAlert?.request == "src/app.ts…")
    }

    @Test("A question alert carries the prompt and stays a question")
    func questionAlertCarriesThePrompt() throws {
        let question = PendingQuestion(id: "q", prompt: "Which revision style?",
                                       options: [QuestionOption(id: "t", label: "Tighten")])
        let state = project([session(id: "a", status: .needsResponse, waitKind: .question, question: question)])
        let alert = try #require(state.topAlert)
        #expect(alert.waitKind == .question)
        #expect(alert.tool == nil)
        #expect(alert.request == "Which revision style?")
    }

    @Test("A waiting session with no wait kind reads as a question, never a permission")
    func missingWaitKindDegradesToQuestion() {
        let state = project([session(id: "a", status: .needsResponse)])
        #expect(state.topAlert?.waitKind == .question)
        #expect(state.topAlert?.tool == nil)
    }

    @Test("A question with no structured prompt falls back to what the agent said")
    func questionFallsBackToTheSessionSummary() {
        let state = project([session(id: "a", status: .needsResponse, waitKind: .question)])
        #expect(state.topAlert?.request == "wrote section 2")
    }

    @Test("Question option labels reach the wrist; their values never do")
    func questionOptionsAreLabelsOnly() throws {
        let question = PendingQuestion(id: "q", prompt: "Which revision style?", options: [
            QuestionOption(id: "t", label: "Tighten", value: "Tighten it without changing the argument."),
            QuestionOption(id: "p", label: "Plain language", value: "Make it plainer."),
        ])
        let state = project([session(id: "a", status: .needsResponse, waitKind: .question, question: question)])
        #expect(state.topAlert?.options == ["Tighten", "Plain language"])

        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!json.contains("without changing the argument"))
        #expect(!json.contains("Make it plainer"))
    }

    @Test("A permission carries no option labels")
    func permissionsHaveNoOptions() {
        let approval = PendingApproval(id: "ap", tool: "Bash", commandPreview: "ls")
        let state = project([session(id: "a", status: .needsResponse, waitKind: .permission, approval: approval)])
        #expect(state.topAlert?.options.isEmpty == true)
    }

    // MARK: live promotion and removal

    @Test("Working and done sessions never become alerts")
    func onlyWaitingSessionsAlert() {
        var failed = session(id: "broken", status: .done)
        failed.failed = true
        let state = project([
            session(id: "w", status: .working),
            session(id: "d", status: .done),
            failed,
        ])
        #expect(state.alerts.isEmpty)
        #expect(state.counts.working == 1)
        #expect(state.stuck == 1)
    }

    @Test("Resolving the top alert promotes the next one, in the same order")
    func resolvingTheTopAlertPromotesTheNext() throws {
        let approval = PendingApproval(id: "ap", tool: "Bash", commandPreview: "swift test")
        let question = PendingQuestion(id: "q", prompt: "Which style?")
        let waitingBoth = [
            session(id: "first", status: .needsResponse, waitKind: .permission, approval: approval),
            session(id: "second", status: .needsResponse, waitKind: .question, question: question),
            session(id: "busy", status: .working),
        ]
        #expect(project(waitingBoth).topAlert?.sessionId == "first")

        // The Mac resolved the permission; the same session is now working.
        let afterDecision = [
            session(id: "first", status: .working),
            session(id: "second", status: .needsResponse, waitKind: .question, question: question),
            session(id: "busy", status: .working),
        ]
        let promoted = project(afterDecision)
        #expect(promoted.alerts.map(\.sessionId) == ["second"])
        #expect(promoted.topAlert?.waitKind == .question)
        #expect(promoted.counts.working == 2)
    }

    @Test("A removed session leaves no alert behind")
    func removingASessionClearsItsAlert() {
        let approval = PendingApproval(id: "ap", tool: "Bash", commandPreview: "swift test")
        let waiting = project([session(id: "gone", status: .needsResponse, waitKind: .permission, approval: approval)])
        #expect(waiting.alerts.count == 1)

        let afterSessionEnd = project([])
        #expect(afterSessionEnd.alerts.isEmpty)
        #expect(afterSessionEnd.counts.isEmpty)
    }

    @Test("Several waiting sessions all reach the Alerts page in dashboard order")
    func everyWaitingSessionIsListed() {
        let question = PendingQuestion(id: "q", prompt: "Which style?")
        let state = project([
            session(id: "a", status: .needsResponse, waitKind: .question, question: question),
            session(id: "b", status: .working),
            session(id: "c", status: .needsResponse, waitKind: .question, question: question),
            session(id: "d", status: .needsResponse, waitKind: .question, question: question),
        ])
        #expect(state.alerts.map(\.sessionId) == ["a", "c", "d"])
        #expect(state.counts.needsResponse == 3)
    }

    // MARK: security boundary

    @Test("Encoded Watch state carries no token, host, terminal, or diff")
    func encodedStateLeaksNothing() throws {
        let approval = PendingApproval(
            id: "ap", tool: "Edit", commandPreview: "src/app.ts",
            filePath: "src/app.ts",
            oldText: "todos.sort((a, b) => a.id - b.id)",
            newText: "todos.sort((a, b) => a.dueDate - b.dueDate)")
        let state = project([session(id: "a", status: .needsResponse, waitKind: .permission, approval: approval)])
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)

        for secret in ["ttys004", "iTerm.app", "a.dueDate", "a.id - b.id", "12345"] {
            #expect(!json.contains(secret), "Watch state leaked \(secret)")
        }
        // The pairing payload has no representation here at all.
        #expect(!json.contains("token"))
        #expect(!json.contains("host"))
    }

    @Test("Watch state round-trips")
    func stateRoundTrips() throws {
        let state = WatchDemoScenario.permission.state(now: now)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(WatchDashboardState.self, from: data) == state)
    }

    // MARK: quota

    @Test("Weekly freshness flips exactly at 15 minutes")
    func quotaFreshnessBoundary() {
        func quota(ageSeconds: TimeInterval) -> ProviderQuota {
            ProviderQuota(provider: .codex, weeklyRemainingPercent: 68,
                       observedAt: now.addingTimeInterval(-ageSeconds))
        }
        #expect(quota(ageSeconds: 899).freshness(now: now) == .live)
        #expect(quota(ageSeconds: 900).freshness(now: now) == .stale)
        #expect(quota(ageSeconds: 901).freshness(now: now) == .stale)
    }

    @Test("A source that never produced a weekly value is unavailable, not zero")
    func missingWeeklyIsUnavailable() {
        let noValue = ProviderQuota(provider: .claude, observedAt: now)
        let noObservation = ProviderQuota(provider: .claude, weeklyRemainingPercent: 41)
        #expect(noValue.freshness(now: now) == .unavailable)
        #expect(noValue.weeklyRemainingPercent == nil)
        #expect(noObservation.freshness(now: now) == .unavailable)
        #expect(ProviderQuota.unavailable(.codex, reason: "signed out").unavailableReason == "signed out")
    }

    @Test("Invalid percentages and absent values stay unknown")
    func invalidPercentagesStayUnknown() {
        let quota = ProviderQuota(provider: .codex, weeklyRemainingPercent: 140,
                               shortWindowRemainingPercent: -20, observedAt: now)
        #expect(quota.weeklyRemainingPercent == nil)
        #expect(quota.shortWindowRemainingPercent == nil)
        #expect(ProviderQuota(provider: .codex, observedAt: now).shortWindowRemainingPercent == nil)
    }

    @Test("Providers keep independent freshness")
    func providersAreIndependent() {
        let state = project([], quotas: [
            ProviderQuota(provider: .codex, weeklyRemainingPercent: 68, observedAt: now.addingTimeInterval(-1_800)),
            ProviderQuota(provider: .claude, weeklyRemainingPercent: 41, observedAt: now),
        ])
        #expect(state.quota(.codex)?.freshness(now: now) == .stale)
        #expect(state.quota(.claude)?.freshness(now: now) == .live)
    }

    @Test("Two unavailable providers each keep their own reason and stay separate rows")
    func bothProvidersUnavailableKeepTheirOwnReason() {
        let state = project([], quotas: [
            .unavailable(.codex, reason: "Codex CLI is unavailable"),
            .unavailable(.claude, reason: "Claude is not signed in"),
        ])
        // Two rows, never merged into one "quota is down" line.
        #expect(state.quotas.map(\.provider) == [.codex, .claude])
        #expect(state.quota(.codex)?.unavailableReason == "Codex CLI is unavailable")
        #expect(state.quota(.claude)?.unavailableReason == "Claude is not signed in")
        #expect(state.quotas.allSatisfy { $0.freshness(now: now) == .unavailable })
        #expect(state.quotas.allSatisfy { $0.weeklyRemainingPercent == nil })
    }

    @Test("A Claude value survives the wire the Watch actually receives")
    func claudeQuotaRoundTripsToTheWatch() throws {
        let sent = project([], quotas: [
            ProviderQuota(provider: .codex, weeklyRemainingPercent: 68, observedAt: now),
            ProviderQuota(provider: .claude, weeklyRemainingPercent: 42,
                          weeklyResetsAt: now.addingTimeInterval(86_400),
                          shortWindowRemainingPercent: 57, observedAt: now),
        ])
        let received = try JSONDecoder().decode(
            WatchDashboardState.self, from: JSONEncoder().encode(sent))
        #expect(received.quota(.claude)?.weeklyRemainingPercent == 42)
        #expect(received.quota(.claude)?.shortWindowRemainingPercent == 57)
        #expect(received.quota(.claude)?.freshness(now: now) == .live)
        #expect(received.quota(.codex)?.weeklyRemainingPercent == 68)
    }

    // MARK: relay

    @Test("A disconnected relay keeps the last state and reports its age")
    func disconnectedKeepsTheLastState() {
        let state = project([session(id: "a", status: .working)], relay: .disconnected)
        #expect(state.relay == .disconnected)
        #expect(state.counts.working == 1)
        #expect(state.age(now: now.addingTimeInterval(120)) == 120)
    }

    // MARK: five-state parity

    @Test("The Watch carries the same five-state aggregate as every other surface")
    func presentationMatchesTheSharedSummary() {
        let sessions = [
            session(id: "a", status: .needsResponse, waitKind: .permission),
            session(id: "b", status: .working),
            session(id: "c", status: .done),
        ]
        let state = project(sessions)
        #expect(state.presentation == TaskPresentationSummary(sessions: sessions))
        #expect(state.presentation.requiresInput == 1)
        #expect(state.presentation.thinking == 1)
        #expect(state.presentation.idle == 1)
    }

    @Test("A failed session is the signal the three buckets cannot carry")
    func stuckSurvivesTheThreeBuckets() {
        var failed = session(id: "a", status: .working)
        failed.failed = true
        let state = project([failed, session(id: "b", status: .working)])
        #expect(state.counts.working == 2)          // the bucket still says working
        #expect(state.stuck == 1)                   // the five-state view says why it matters
        #expect(state.presentation.thinking == 1)
    }

    // MARK: coalescing

    @Test("Only the observation time may differ for two states to be equivalent")
    func equivalenceIgnoresObservationTimeAlone() {
        let sessions = [session(id: "a", status: .working)]
        let first = project(sessions)
        var later = first
        later.observedAt = now.addingTimeInterval(600)
        #expect(first.isEquivalent(to: later))
        #expect(first != later)
    }

    @Test("Every meaningful change breaks equivalence")
    func meaningfulChangesBreakEquivalence() {
        let base = project([session(id: "a", status: .working)])

        #expect(!base.isEquivalent(to: project([session(id: "a", status: .working),
                                                session(id: "b", status: .working)])))
        #expect(!base.isEquivalent(to: project([session(id: "a", status: .needsResponse,
                                                        waitKind: .question)])))
        #expect(!base.isEquivalent(to: project([session(id: "a", status: .working)],
                                               relay: .disconnected)))
        #expect(!base.isEquivalent(to: project([session(id: "a", status: .working)],
                                               quotas: [ProviderQuota(provider: .codex,
                                                                   weeklyRemainingPercent: 68,
                                                                   observedAt: now)])))
        var demo = base
        demo.isDemo = true
        #expect(!base.isEquivalent(to: demo))

        var stuck = base
        stuck.presentation.error = 1
        #expect(!base.isEquivalent(to: stuck))
    }

    // MARK: buddy mood

    @Test("The buddy's mood follows what the Watch actually knows")
    func buddyStateFollowsTheState() {
        let permission = PendingApproval(id: "ap", tool: "Bash", commandPreview: "ls")
        #expect(project([session(id: "a", status: .needsResponse, waitKind: .permission, approval: permission)])
            .buddyState == .approval)
        #expect(project([session(id: "a", status: .needsResponse, waitKind: .question)]).buddyState == .question)
        #expect(project([session(id: "a", status: .working)]).buddyState == .working)
        #expect(project([session(id: "a", status: .done)]).buddyState == .idle)
        #expect(project([]).buddyState == .sleeping)
    }

    // MARK: demo scenarios

    @Test("Every demo scenario is marked as sample data")
    func demoScenariosAreMarked() {
        for scenario in WatchDemoScenario.allCases {
            #expect(scenario.state(now: now).isDemo || scenario == .noData)
        }
    }

    @Test("normal has work in flight and nobody waiting")
    func normalScenario() {
        let state = WatchDemoScenario.normal.state(now: now)
        #expect(state.counts.needsResponse == 0)
        #expect(state.counts.working == 2)
        #expect(state.counts.done == 4)
        #expect(state.alerts.isEmpty)
        #expect(state.quotas.allSatisfy { $0.freshness(now: now) == .live })
    }

    @Test("permission takes over with a complete command")
    func permissionScenario() throws {
        let state = WatchDemoScenario.permission.state(now: now)
        let alert = try #require(state.topAlert)
        #expect(alert.waitKind == .permission)
        #expect(alert.tool == "Bash")
        #expect(alert.request?.hasPrefix("xcodebuild -scheme VibeBuddyWatch") == true)
        #expect(state.counts.needsResponse == 2)
    }

    @Test("question takes over and stays display-only")
    func questionScenario() throws {
        let state = WatchDemoScenario.question.state(now: now)
        let alert = try #require(state.topAlert)
        #expect(alert.waitKind == .question)
        #expect(alert.request == "Which revision style should I use?")
    }

    @Test("empty is connected with nothing running")
    func emptyScenario() {
        let state = WatchDemoScenario.empty.state(now: now)
        #expect(state.relay == .live)
        #expect(state.counts.isEmpty)
        #expect(state.quotas.count == 2)
    }

    @Test("staleQuota ages one provider only")
    func staleQuotaScenario() {
        let state = WatchDemoScenario.staleQuota.state(now: now)
        #expect(state.quota(.codex)?.freshness(now: now) == .stale)
        #expect(state.quota(.codex)?.weeklyRemainingPercent == 68)
        #expect(state.quota(.claude)?.freshness(now: now) == .live)
    }

    @Test("unavailableQuota explains itself and keeps the other provider")
    func unavailableQuotaScenario() {
        let state = WatchDemoScenario.unavailableQuota.state(now: now)
        #expect(state.quota(.codex)?.freshness(now: now) == .unavailable)
        #expect(state.quota(.codex)?.weeklyRemainingPercent == nil)
        #expect(state.quota(.codex)?.unavailableReason == "Codex is signed out")
        #expect(state.quota(.claude)?.freshness(now: now) == .live)
    }

    @Test("noData shows nothing rather than a placeholder account")
    func noDataScenario() {
        let state = WatchDemoScenario.noData.state(now: now)
        #expect(state.relay == .noData)
        #expect(state.counts.isEmpty)
        #expect(state.quotas.isEmpty)
        #expect(state.alerts.isEmpty)
    }

    @Test("A scenario is a pure function of its clock")
    func scenariosAreDeterministic() {
        #expect(WatchDemoScenario.permission.state(now: now) == WatchDemoScenario.permission.state(now: now))
    }
}
