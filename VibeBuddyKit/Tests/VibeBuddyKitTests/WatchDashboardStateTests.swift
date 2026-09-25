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

    @Test("normal working sessions have an openable Watch task, without being followed")
    func normalWorkingTaskIsOpenable() {
        let state = project([session(id: "normal-running", status: .working)])
        #expect(state.followedTasks.isEmpty)
        #expect(state.task("normal-running")?.presentation == .thinking)
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

    @Test("a failed session counts under Needs you, as it does on every other surface")
    func failedSessionIsNeedsYou() {
        var broke = session(id: "broke", status: .done)
        broke.failed = true
        let state = project([broke, session(id: "run", status: .working)])
        #expect(state.counts == WatchSessionCounts(needsResponse: 1, working: 1, done: 0))
        #expect(state.stuck == 1)
        #expect(CompanionCopy.needsYou(state.presentation) == state.counts.needsResponse)
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

    @Test("Resolving the top alert promotes the next one, in the shared queue order")
    func resolvingTheTopAlertPromotesTheNext() throws {
        let approval = PendingApproval(id: "ap", tool: "Bash", commandPreview: "swift test")
        let question = PendingQuestion(id: "q", prompt: "Which style?")
        // A question outranks an approval on every surface (`PendingTasks`),
        // whatever order the snapshot lists them in.
        let waitingBoth = [
            session(id: "first", status: .needsResponse, waitKind: .permission, approval: approval),
            session(id: "second", status: .needsResponse, waitKind: .question, question: question),
            session(id: "busy", status: .working),
        ]
        #expect(project(waitingBoth).alerts.map(\.sessionId) == ["second", "first"])
        #expect(project(waitingBoth).topAlert?.sessionId == "second")

        // The Mac took the answer; the same session is now working.
        let afterAnswer = [
            session(id: "first", status: .needsResponse, waitKind: .permission, approval: approval),
            session(id: "second", status: .working),
            session(id: "busy", status: .working),
        ]
        let promoted = project(afterAnswer)
        #expect(promoted.alerts.map(\.sessionId) == ["first"])
        #expect(promoted.topAlert?.waitKind == .permission)
        #expect(promoted.counts.working == 2)
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

    // MARK: demo scenarios

    @Test("Every demo scenario is marked as sample data")
    func demoScenariosAreMarked() {
        for scenario in WatchDemoScenario.allCases {
            #expect(scenario.state(now: now).isDemo || scenario == .noData)
        }
    }

    // MARK: what the wrist may end

    /// A running Codex turn the app-server connection is actually carrying —
    /// the only shape a stop exists for.
    private func running(agent: AgentKind = .codex,
                         status: SessionStatus = .working,
                         source: ObservationSource? = .appserver,
                         health: ObservationHealth = .healthy,
                         attention: SessionAttention = .followed) -> AgentSession {
        AgentSession(
            id: "s-run", agent: agent, project: "vibebuddy", branch: "main",
            model: "gpt-5-codex", status: status, summary: "Running the test suite…",
            observations: source.map { [ObservationEvidence(source: $0, lastObservedAt: now, health: health)] },
            attention: attention,
            statusSince: now.addingTimeInterval(-30), updatedAt: now)
    }

    private func followed(_ session: AgentSession) -> WatchFollowedTask? {
        project([session]).followedTasks.first { $0.sessionID == session.id }
    }

    @Test("A running Codex turn the Mac is carrying is the only one the wrist may end")
    func stopIsOfferedOnlyForACarriedCodexTurn() throws {
        #expect(followed(running())?.stop == .offered)

        // Claude Code has no remote interrupt contract; say where to go instead.
        #expect(followed(running(agent: .claudeCode))?.stop == .blocked(.macOnly))
        #expect(followed(running(agent: .grok))?.stop == .blocked(.agentUnsupported))
        // Codex seen only through the rollout tailer cannot be interrupted at all.
        #expect(followed(running(source: .rollout))?.stop == .blocked(.macNotConnected))
        #expect(followed(running(health: .eventsMissing))?.stop == .blocked(.macNotConnected))
        #expect(followed(running(source: nil))?.stop != .offered)
    }

    @Test("The reason travels as a code and is worded where it is read")
    func stopReasonIsWordedOnTheDisplayDevice() throws {
        // The wording must match what the daemon would refuse with, so the
        // wrist and the Mac never explain the same fact differently.
        for session in [running(agent: .claudeCode), running(agent: .grok),
                        running(source: .rollout)] {
            let block = try #require(followed(session)?.stop?.block)
            #expect(block.message(agent: session.agent)
                    == SessionActionSupport.resolveStop(for: session).unsupportedReason)
        }
        // The code is what crosses the wire — not a sentence in the phone's language.
        let json = try #require(String(data: JSONEncoder().encode(WatchStopOffer.blocked(.macOnly)),
                                       encoding: .utf8))
        #expect(json.contains("macOnly"))
        #expect(!json.contains("your Mac"))
    }

    @Test("A session that is not running says nothing about stopping")
    func stopIsSilentWhenThereIsNoTurn() {
        // Not a button *and* not a sentence: "this already finished" under a
        // finished task is noise, and the daemon's wording for it is for the
        // client that asked anyway, not for a wrist that did not.
        #expect(followed(running(status: .done))?.stop == nil)
        #expect(followed(running(status: .needsResponse))?.stop == nil)
    }

    @Test("An older relay's task offers no Stop rather than an unguarded one")
    func stopIsAbsentInAnOlderRelay() throws {
        let state = project([running()])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var tasks = try #require(json["followedTasks"] as? [[String: Any]])
        #expect(tasks[0]["stop"] != nil)
        tasks[0].removeValue(forKey: "stop")
        json["followedTasks"] = tasks
        let restored = try JSONDecoder().decode(WatchDashboardState.self,
                                                from: JSONSerialization.data(withJSONObject: json))
        let task = try #require(restored.followedTasks.first)
        #expect(task.stop == nil)
        var action = WatchSessionActionState()
        #expect(action.begin(stop: task, attemptId: "tap") == nil)
    }

    @Test("A complication carries no stop offer and no reason to show one")
    func complicationDropsTheStopOffer() throws {
        let task = try #require(followed(running()))
        #expect(task.complicationTask.stop == nil)
        let snapshot = WatchComplicationSnapshot(state: project([running()]))
        #expect(snapshot.tasks.allSatisfy { $0.stop == nil })
    }

    @Test("Demo Mode's sample stop ends the turn the way the Mac would")
    func demoStopMirrorsTheRealEnding() throws {
        let demo = WatchDemoScenario.normal.state(now: now)
        let task = try #require(WatchDemoScenario.stoppableTask.task(in: demo))
        #expect(task.stop == .offered)

        let stopped = demo.resolvingStop(task.sessionID)
        let after = try #require(WatchDemoScenario.stoppableTask.task(in: stopped))
        #expect(after.stop == nil)
        // An acknowledged user stop is idle, without a false failure cue.
        #expect(after.presentation == .idle)
        #expect(stopped.counts.working == demo.counts.working - 1)
        #expect(stopped.counts.done == demo.counts.done + 1)
        #expect(stopped.presentation.error == demo.presentation.error)
        #expect(stopped.presentation.idle == demo.presentation.idle + 1)
        #expect(demo.resolvingStop("no-such-session") == demo)

        // The unsupported agent is rehearsable too, and its Stop never resolves.
        let claude = try #require(WatchDemoScenario.unstoppableTask.task(in: demo))
        #expect(claude.stop == .blocked(.macOnly))
        #expect(demo.resolvingStop(claude.sessionID) == demo)
    }

}

@Suite("Verified wait destinations")
struct WaitDestinationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(agent: AgentKind = .codex, approval: PendingApproval? = nil,
                         question: PendingQuestion? = nil) -> AgentSession {
        AgentSession(id: "task", agent: agent, project: "Project", status: .needsResponse,
                     waitKind: approval == nil ? .question : .permission,
                     pendingApproval: approval, pendingQuestion: question,
                     statusSince: now, updatedAt: now)
    }

    private func projection(_ session: AgentSession, relay: WatchRelayState = .live) throws -> WatchDashboardState {
        let state = WatchDashboardProjection.make(snapshot: Snapshot(sessions: [session], serverTime: now),
                                                  quotas: [], relay: relay, now: now)
        return try JSONDecoder().decode(WatchDashboardState.self, from: JSONEncoder().encode(state))
    }

    @Test("Only remotely answerable requests point to the phone after transport")
    func verifiedTargets() throws {
        let short = PendingApproval(id: "approval", tool: "Bash", commandPreview: "ls", command: "ls")
        let diff = PendingApproval(id: "approval", tool: "Edit", commandPreview: "change", filePath: "a.swift", oldText: "a", newText: "b")
        let readOnly = PendingApproval(id: "approval", tool: "Bash", commandPreview: "ls", command: "ls", answerable: false)
        let cases: [(AgentSession, WaitHandling, Bool)] = [
            (session(approval: short), .watchApproval, true),
            (session(approval: diff), .remoteAvailable, false),
            (session(approval: readOnly), .macNativePrompt, false),
            (session(question: PendingQuestion(id: "q", prompt: "Choose")), .remoteAvailable, false),
            (session(question: PendingQuestion(id: "q", prompt: "Choose", answerable: false)), .macNativePrompt, false),
            (session(question: PendingQuestion(id: " ", prompt: "Choose")), .unavailable, false),
            (session(), .macNativePrompt, false)
        ]
        for (input, destination, actionable) in cases {
            let alert = try #require(projection(input).topAlert)
            #expect(alert.handling == destination)
            #expect(alert.isDecidable == actionable)
        }
    }

    @Test("Connection is independent and capability changes replace the destination")
    func updates() throws {
        let q = PendingQuestion(id: "q", prompt: "Choose")
        let current = try projection(session(question: q))
        let offline = try projection(session(question: q), relay: .disconnected)
        #expect(offline.topAlert?.handling == .remoteAvailable)
        #expect(offline.connection(now: now, phoneReachable: true) == .macDisconnected)
        #expect(current.connection(now: now, phoneReachable: true) == .live)
        let changed = try projection(session(question: PendingQuestion(id: "q", prompt: "Choose", answerable: false)))
        #expect(!current.isEquivalent(to: changed))
        #expect(changed.topAlert?.handling == .macNativePrompt)
        #expect(changed.topAlert?.approvalId == nil)
    }

    @Test("A cached approval without capability semantics cannot offer or send a decision")
    func missingSemantics() throws {
        let input = session(approval: PendingApproval(id: "approval", tool: "Bash", commandPreview: "ls", command: "ls"))
        let state = try projection(input)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var alerts = try #require(json["alerts"] as? [[String: Any]])
        alerts[0].removeValue(forKey: "handling")
        json["alerts"] = alerts
        let restored = try JSONDecoder().decode(WatchDashboardState.self, from: JSONSerialization.data(withJSONObject: json))
        let alert = try #require(restored.topAlert)
        #expect(alert.handling == nil)
        #expect(!alert.isDecidable)
        var action = WatchSessionActionState()
        #expect(action.begin(alert: alert, choice: .allow, attemptId: "tap") == nil)
    }
}

// MARK: - Results: what is worth a look without waiting on you

@Suite("Watch results")
struct WatchResultsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ status: SessionStatus = .done,
                         failed: Bool? = nil, unread: Bool = false,
                         attention: SessionAttention? = nil,
                         agoSeconds: TimeInterval = 60) -> AgentSession {
        var s = AgentSession(id: id, agent: .codex, project: id, status: status,
                             failed: failed, hasUnreadCompletion: unread, attention: attention,
                             statusSince: now.addingTimeInterval(-agoSeconds),
                             updatedAt: now.addingTimeInterval(-agoSeconds))
        s.completionID = unread ? "\(id)-round" : nil
        return s
    }

    private func project(_ sessions: [AgentSession]) -> WatchDashboardState {
        WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions, serverTime: now, sourceID: "mac-a"),
            quotas: [], relay: .live, now: now)
    }

    @Test("unread completions of ordinary sessions reach the wrist, newest first")
    func unreadCompletionsAreResults() {
        let state = project([
            session("older", unread: true, agoSeconds: 600),
            session("read"),
            session("newer", unread: true, agoSeconds: 30),
            session("running", .working),
        ])
        #expect(state.unreadResults.map(\.sessionID) == ["newer", "older"])
        #expect(state.stuckTasks.isEmpty)
        #expect(state.followedTasks.isEmpty)
        #expect(state.unreadResults.first?.presentation == .completeUnread)
        #expect(state.unreadResults.first?.completionID == "newer-round")
    }

    @Test("a session that ended badly is listed before any completion")
    func stuckLeads() {
        let state = project([
            session("done", unread: true, agoSeconds: 10),
            session("broke", failed: true, agoSeconds: 900),
        ])
        #expect(state.results?.map(\.sessionID) == ["broke", "done"])
        #expect(state.stuckTasks.map(\.sessionID) == ["broke"])
        #expect(state.stuckTasks.first?.presentation == .error)
    }

    @Test("a muted session's result is left off, as its completion cue is everywhere else")
    func mutedIsLeftOff() {
        let state = project([session("quiet", unread: true, attention: .muted),
                             session("loud", unread: true, attention: .normal)])
        #expect(state.unreadResults.map(\.sessionID) == ["loud"])
    }

    @Test("the list is bounded and a waiting session is never a result")
    func boundedAndNoWaiting() {
        var many = (0..<10).map { session("done-\($0)", unread: true, agoSeconds: TimeInterval($0)) }
        many.append(session("asked", .needsResponse))
        let state = project(many)
        #expect(state.results?.count == WatchDashboardState.maxResults)
        #expect(state.results?.contains { $0.sessionID == "asked" } == false)
        #expect(state.alerts.map(\.sessionId) == ["asked"])
    }

    @Test("a link opens a result the same way it opens a followed task, and marks it read")
    func linkResolvesResults() {
        var state = project([session("done", unread: true)])
        state.pairingEpoch = "epoch-1"
        let link = WatchTaskLink(sourceID: "mac-a", pairingEpoch: "epoch-1",
                                 sessionID: "done", completionID: "done-round")
        #expect(link.task(in: state)?.sessionID == "done")
        #expect(link.alert(in: state) == nil)
        var queue = WatchCompletionQueue()
        queue.markRead(link, state: state)
        #expect(queue.links == [link])
        // The list cannot establish why a normal result disappeared. Only
        // the exact daemon receipt retires the pending delivery in that case.
        var read = project([session("done", unread: false)])
        read.pairingEpoch = "epoch-1"
        queue.reconcile(with: read)
        #expect(queue.links == [link])
        queue.received(.accepted, for: link)
        #expect(queue.links.isEmpty)
        #expect(read.results?.isEmpty == true)
    }

    @Test("a link to a waiting session finds its alert, not a task")
    func linkResolvesAlerts() {
        var state = project([session("asked", .needsResponse)])
        state.pairingEpoch = "epoch-1"
        let link = WatchTaskLink(sourceID: "mac-a", pairingEpoch: "epoch-1", sessionID: "asked", completionID: nil)
        #expect(link.alert(in: state)?.sessionId == "asked")
        #expect(link.task(in: state) == nil)
        #expect(state.knows("asked"))
        #expect(!state.knows("stranger"))
    }

    @Test("a relay or cache from before results existed still decodes")
    func decodesWithoutResults() throws {
        var state = project([session("done", unread: true)])
        state.results = nil
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WatchDashboardState.self, from: data)
        #expect(decoded.results == nil)
        #expect(decoded.unreadResults.isEmpty)
    }

    @Test("a result entering the wrist's list earns the completion tap; refreshing it does not")
    func resultsFeelOnce() {
        var transitions = WatchHapticTransitions()
        var first = project([session("run", .working)])
        first.pairingEpoch = "e"
        _ = transitions.advance(to: first, now: now)
        var done = project([session("run", unread: true)])
        done.pairingEpoch = "e"
        #expect(transitions.advance(to: done, now: now) == [.agentDone])
        #expect(transitions.advance(to: done, now: now).isEmpty)
    }
}
