import XCTest
@testable import VibeBuddyKit

/// The security boundary of the wrist: what may be offered, what the iPhone will
/// act on, and what the Watch is allowed to claim happened.
final class WatchApprovalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: helpers

    private func permission(
        id: String = "s-build",
        approvalId: String = "ap-1",
        tool: String = "Bash",
        command: String? = "swift test",
        filePath: String? = nil,
        oldText: String? = nil,
        newText: String? = nil,
        project: String = "ios-vibebuddy",
        status: SessionStatus = .needsResponse
    ) -> AgentSession {
        AgentSession(
            id: id, agent: .claudeCode, project: project,
            status: status, waitKind: status == .needsResponse ? .permission : nil,
            pendingApproval: PendingApproval(id: approvalId, tool: tool,
                                             commandPreview: "swift test…",
                                             command: command, filePath: filePath,
                                             oldText: oldText, newText: newText),
            statusSince: now, updatedAt: now)
    }

    private func question(id: String = "s-ask") -> AgentSession {
        AgentSession(id: id, agent: .codex, project: "docs", status: .needsResponse,
                     waitKind: .question,
                     pendingQuestion: PendingQuestion(id: "q", prompt: "Which tone?"),
                     statusSince: now, updatedAt: now)
    }

    private func state(_ sessions: [AgentSession],
                       relay: WatchRelayState = .live) -> WatchDashboardState {
        WatchDashboardProjection.make(snapshot: Snapshot(sessions: sessions, serverTime: now),
                                      quotas: [], relay: relay, now: now)
    }

    // MARK: eligibility

    func testACompletePermissionIsDecidableFromTheWrist() {
        XCTAssertEqual(WatchApprovalEligibility.approvalId(for: permission()), "ap-1")
        XCTAssertEqual(state([permission()]).topAlert?.approvalId, "ap-1")
    }

    func testAPathTargetIsAlsoEnough() {
        let session = permission(tool: "Read", command: nil, filePath: "/tmp/notes.md")
        XCTAssertEqual(WatchApprovalEligibility.approvalId(for: session), "ap-1")
    }

    func testAQuestionIsNeverDecidableFromTheWrist() {
        XCTAssertNil(WatchApprovalEligibility.approvalId(for: question()))
        XCTAssertEqual(state([question()]).topAlert?.isDecidable, false)
    }

    func testAPreviewWithoutACommandOrPathStaysDisplayOnly() {
        // Only `commandPreview` survived — a label, not the thing being approved.
        let session = permission(command: nil, filePath: nil)
        XCTAssertNil(WatchApprovalEligibility.approvalId(for: session))
        XCTAssertNotNil(state([session]).topAlert?.request, "it is still shown, just not actionable")
    }

    func testARichEditDiffStaysDisplayOnly() {
        let session = permission(tool: "Edit", command: nil, filePath: "src/app.ts",
                                 oldText: "a", newText: "b")
        XCTAssertNil(WatchApprovalEligibility.approvalId(for: session))
    }

    func testAnOversizedCommandStaysDisplayOnly() {
        let long = String(repeating: "x", count: WatchApprovalEligibility.maxDetailLength + 1)
        XCTAssertNil(WatchApprovalEligibility.approvalId(for: permission(command: long)))
        let atLimit = String(repeating: "x", count: WatchApprovalEligibility.maxDetailLength)
        XCTAssertNotNil(WatchApprovalEligibility.approvalId(for: permission(command: atLimit)))
    }

    func testAResolvedSessionIsNotDecidable() {
        XCTAssertNil(WatchApprovalEligibility.approvalId(for: permission(status: .working)))
    }

    func testReadOnlyRevokesProjectedActionAndRefusesOldTap() {
        let original = permission()
        var readOnly = original
        readOnly.pendingApproval = PendingApproval(id: "ap-1", tool: "Bash", commandPreview: "swift test",
                                                   command: "swift test", answerable: false)
        var action = WatchSessionActionState()
        let tap = action.begin(alert: state([original]).topAlert!, choice: .allow, attemptId: "tap")!
        let projected = state([readOnly])
        XCTAssertNil(projected.topAlert?.approvalId)
        XCTAssertEqual(ApprovalEligibility.unavailableReason(for: readOnly), .readOnly)
        XCTAssertEqual(WatchSessionActionGate().admit(tap, sessions: [readOnly]), .refused)
        action.reconcile(with: projected)
        XCTAssertNil(action.action)
    }

    func testActivitySkipsReadOnlyAndKeepsTargetWordingTogether() {
        var readOnly = permission(id: "first", approvalId: "first-approval", project: "Read only")
        readOnly.pendingApproval = PendingApproval(id: "first-approval", tool: "Bash", commandPreview: "readonly", answerable: false)
        let valid = permission(id: "second", approvalId: "second-approval", project: "Actionable")
        let target = ActivityApprovalTarget.select(from: [readOnly, valid])
        XCTAssertEqual(target?.approvalID, "second-approval")
        XCTAssertTrue(target?.title.hasPrefix("Actionable wants to") == true)
        XCTAssertEqual(target?.detail, valid.pendingApproval?.commandPreview)
        XCTAssertNil(ActivityApprovalTarget.select(from: [readOnly]))
        let bot = AgentSession(id: valid.id, agent: .grokBot, project: valid.project,
                               status: .needsResponse, waitKind: .permission, pendingApproval: valid.pendingApproval,
                               statusSince: now, updatedAt: now)
        XCTAssertNil(ActivityApprovalTarget.select(from: [bot]))
        XCTAssertNil(state([bot]).topAlert?.approvalId)
        let diff = permission(tool: "Edit", command: nil, filePath: "file", oldText: "a", newText: "b")
        XCTAssertNotNil(ActivityApprovalTarget.select(from: [diff]))
        XCTAssertNil(state([diff]).topAlert?.approvalId)
        XCTAssertNil(ActivityApprovalTarget.select(from: [permission(status: .working)]))
        XCTAssertNil(ActivityApprovalTarget.select(from: [permission(approvalId: " ")]))
    }

    // MARK: the wire may only say allow or deny

    func testTheWatchCannotEncodeAnAlwaysAllow() {
        for choice in WatchApprovalChoice.allCases {
            XCTAssertNotEqual(choice.decision, .alwaysAllow)
            XCTAssertNotEqual(choice.decision, .allowSession)
        }
        let alwaysAllow = Data(#"{"attemptId":"a","sessionId":"s","approvalId":"ap-1","choice":"alwaysAllow"}"#.utf8)
        XCTAssertNil(try? JSONDecoder().decode(WatchApprovalRequest.self, from: alwaysAllow))
        let unknown = Data(#"{"attemptId":"a","sessionId":"s","approvalId":"ap-1","choice":"jump"}"#.utf8)
        XCTAssertNil(try? JSONDecoder().decode(WatchApprovalRequest.self, from: unknown))
    }

    // MARK: the iPhone's gate

    private func request(session: String = "s-build", approval: String = "ap-1",
                         attempt: String = "t-1",
                         choice: WatchApprovalChoice = .allow) -> WatchSessionActionRequest {
        WatchApprovalRequest(attemptId: attempt, sessionId: session,
                             approvalId: approval, choice: choice).sessionAction
    }

    func testAValidAllowIsForwarded() {
        let gate = WatchSessionActionGate()
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]),
                       .decide(approvalId: "ap-1", decision: .allow))
    }

    func testAValidDenyIsForwarded() {
        let gate = WatchSessionActionGate()
        XCTAssertEqual(gate.admit(request(choice: .deny), sessions: [permission()]),
                       .decide(approvalId: "ap-1", decision: .deny))
    }

    func testAStaleApprovalIdIsRefused() {
        let gate = WatchSessionActionGate()
        XCTAssertEqual(gate.admit(request(approval: "ap-0"), sessions: [permission()]), .refused)
    }

    func testAnApprovalThatAlreadyResolvedIsRefused() {
        let gate = WatchSessionActionGate()
        XCTAssertEqual(gate.admit(request(), sessions: [permission(status: .working)]), .refused)
        XCTAssertEqual(gate.admit(request(), sessions: []), .refused)
    }

    func testAMismatchedSessionIsRefused() {
        let gate = WatchSessionActionGate()
        XCTAssertEqual(gate.admit(request(session: "s-other"), sessions: [permission()]), .refused)
    }

    func testADisplayOnlyApprovalCannotBeActedOn() {
        // Even a hand-made message naming the real id: the detail rule is the
        // authority, and it is re-run here rather than trusted from the wrist.
        let session = permission(tool: "Edit", command: nil, filePath: "src/app.ts",
                                 oldText: "a", newText: "b")
        let gate = WatchSessionActionGate()
        XCTAssertEqual(gate.admit(request(), sessions: [session]), .refused)
    }

    func testARepeatedAttemptIsNotForwardedTwice() {
        var gate = WatchSessionActionGate()
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]),
                       .decide(approvalId: "ap-1", decision: .allow))
        gate.commit("t-1")
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]), .duplicate)
    }

    func testAReplayedAttemptCannotResolveADifferentApproval() {
        var gate = WatchSessionActionGate()
        gate.commit("t-1")
        // The old tap arrives again while a *new* prompt is pending. It is
        // recognised as the old one, not applied to the new one.
        let newer = permission(approvalId: "ap-2")
        XCTAssertEqual(gate.admit(request(), sessions: [newer]), .duplicate)
        // And a fresh tap for the same id it was originally about is refused,
        // because that prompt is gone.
        XCTAssertEqual(gate.admit(request(attempt: "t-2"), sessions: [newer]), .refused)
    }

    func testAnUndeliveredAttemptCanBeMadeAgain() {
        var gate = WatchSessionActionGate()
        // Nothing is committed when delivery fails…
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]),
                       .decide(approvalId: "ap-1", decision: .allow))
        // …so the same tap is still forwardable.
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]),
                       .decide(approvalId: "ap-1", decision: .allow))
        gate.commit("t-1")
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]), .duplicate)
    }

    func testTheAttemptHistoryIsBounded() {
        var gate = WatchSessionActionGate()
        for index in 0...WatchSessionActionGate.historyLimit { gate.commit("t-\(index)") }
        XCTAssertEqual(gate.admit(request(attempt: "t-0"), sessions: [permission()]),
                       .decide(approvalId: "ap-1", decision: .allow),
                       "the oldest attempt aged out")
        XCTAssertEqual(gate.admit(request(attempt: "t-\(WatchSessionActionGate.historyLimit)"),
                                  sessions: [permission()]), .duplicate)
    }

    // MARK: the Watch's action state

    private var alert: WatchAlert { state([permission()]).topAlert! }

    func testASecondTapDoesNotSendASecondDecision() {
        var action = WatchSessionActionState()
        XCTAssertNotNil(action.begin(alert: alert, choice: .allow, attemptId: "t-1"))
        XCTAssertTrue(action.isBusy)
        XCTAssertNil(action.begin(alert: alert, choice: .allow, attemptId: "t-2"))
        XCTAssertNil(action.begin(alert: alert, choice: .deny, attemptId: "t-3"))
        XCTAssertEqual(action.action?.attemptId, "t-1")
    }

    func testADisplayOnlyAlertCannotStartAnAttempt() {
        let readOnly = state([question()]).topAlert!
        var action = WatchSessionActionState()
        XCTAssertNil(action.begin(alert: readOnly, choice: .allow, attemptId: "t-1"))
        XCTAssertFalse(action.isBusy)
    }

    func testAnAcceptedDecisionAwaitsTheMacRatherThanClaimingResolution() {
        var action = WatchSessionActionState()
        _ = action.begin(alert: alert, choice: .allow, attemptId: "t-1")
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .accepted))
        XCTAssertEqual(action.action?.phase, .awaitingResolution)
        XCTAssertTrue(action.isBusy, "still no second tap")

        // The prompt is still pending in the next state: the alert stays.
        action.reconcile(with: state([permission()]))
        XCTAssertEqual(action.action?.phase, .awaitingResolution)

        // The Mac confirms it resolved.
        action.reconcile(with: state([]))
        XCTAssertNil(action.action)
    }

    func testAFailedDeliveryIsSaidOutLoudAndCanBeRetried() {
        var action = WatchSessionActionState()
        _ = action.begin(alert: alert, choice: .allow, attemptId: "t-1")
        action.fail(attemptId: "t-1")
        XCTAssertEqual(action.action?.phase, .failed)
        XCTAssertFalse(action.isBusy)
        XCTAssertNotNil(action.begin(alert: alert, choice: .allow, attemptId: "t-2"))
    }

    func testARefusalIsSaidOutLoud() {
        var action = WatchSessionActionState()
        _ = action.begin(alert: alert, choice: .deny, attemptId: "t-1")
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .refused))
        XCTAssertEqual(action.action?.phase, .refused)
        XCTAssertFalse(action.isBusy)
    }

    func testALateReplyForAnOldAttemptIsIgnored() {
        var action = WatchSessionActionState()
        _ = action.begin(alert: alert, choice: .allow, attemptId: "t-1")
        action.apply(WatchSessionActionResult(attemptId: "t-old", outcome: .failed))
        XCTAssertEqual(action.action?.phase, .sending)
    }

    // MARK: Demo Mode resolves through the same path

    func testDemoResolutionClearsTheAlertAndMovesTheCount() {
        let demo = WatchDemoScenario.permission.state(now: now)
        let approvalId = demo.topAlert?.approvalId
        XCTAssertNotNil(approvalId, "the demo permission must be decidable, or the buttons never show")

        let resolved = demo.resolvingApproval(approvalId!)
        XCTAssertFalse(resolved.alerts.contains { $0.approvalId == approvalId })
        XCTAssertEqual(resolved.counts.needsResponse, demo.counts.needsResponse - 1)
        XCTAssertEqual(resolved.counts.working, demo.counts.working + 1)
        XCTAssertEqual(resolved.presentation.requiresInput, demo.presentation.requiresInput - 1)

        var action = WatchSessionActionState()
        _ = action.begin(alert: demo.topAlert!, choice: .allow, attemptId: "t-1")
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .accepted))
        action.reconcile(with: resolved)
        XCTAssertNil(action.action)
    }

    func testResolvingAnUnknownApprovalChangesNothing() {
        let demo = WatchDemoScenario.permission.state(now: now)
        XCTAssertEqual(demo.resolvingApproval("nope"), demo)
    }

    // MARK: stopping a running turn

    /// A running Codex turn the app-server connection is carrying.
    private func running(id: String = "s-run", agent: AgentKind = .codex,
                         status: SessionStatus = .working,
                         since: TimeInterval = 0) -> AgentSession {
        AgentSession(
            id: id, agent: agent, project: "ios-vibebuddy", status: status,
            summary: "Running the test suite…",
            observations: [ObservationEvidence(source: .appserver, lastObservedAt: now, health: .healthy)],
            attention: .followed,
            statusSince: now.addingTimeInterval(since), updatedAt: now)
    }

    private func task(_ session: AgentSession) -> WatchFollowedTask {
        state([session]).followedTasks.first { $0.sessionID == session.id }!
    }

    private func stopRequest(_ session: AgentSession,
                             attempt: String = "t-1") -> WatchSessionActionRequest {
        WatchSessionActionRequest(attemptId: attempt, sessionId: session.id,
                                  action: .stop(statusSince: session.statusSince))
    }

    func testAStopIsForwardedOnlyForTheTurnItWasAimedAt() {
        let gate = WatchSessionActionGate()
        let session = running()
        XCTAssertEqual(gate.admit(stopRequest(session), sessions: [session]),
                       .stop(statusSince: session.statusSince))

        // The same session, one turn later: the tap named a turn that is over.
        XCTAssertEqual(gate.admit(stopRequest(session), sessions: [running(since: 5)]), .refused)
        // Gone from the Mac entirely.
        XCTAssertEqual(gate.admit(stopRequest(session), sessions: []), .refused)
    }

    func testAStopTheMacWouldRefuseNeverLeavesThePhone() {
        let gate = WatchSessionActionGate()
        for session in [running(agent: .claudeCode), running(agent: .grok),
                        running(status: .done), running(status: .needsResponse)] {
            XCTAssertEqual(gate.admit(stopRequest(session), sessions: [session]), .refused,
                           "\(session.agent) \(session.status) must not reach the Mac")
        }
        var unobserved = running()
        unobserved.observations = nil
        XCTAssertEqual(gate.admit(stopRequest(unobserved), sessions: [unobserved]), .refused)
    }

    func testASecondStopTapDoesNotSendASecondInterrupt() {
        var action = WatchSessionActionState()
        let session = running()
        XCTAssertNotNil(action.begin(stop: task(session), attemptId: "t-1"))
        XCTAssertTrue(action.isBusy)
        XCTAssertNil(action.begin(stop: task(session), attemptId: "t-2"))
        XCTAssertNil(action.begin(alert: alert, choice: .allow, attemptId: "t-3"),
                     "one action per Watch, whatever its kind")
        XCTAssertEqual(action.action?.attemptId, "t-1")
        XCTAssertTrue(action.action?.isStop == true)

        var gate = WatchSessionActionGate()
        gate.commit("t-1")
        XCTAssertEqual(gate.admit(stopRequest(session), sessions: [session]), .duplicate)
    }

    func testAnUnstoppableTaskCannotStartAnAttempt() {
        var action = WatchSessionActionState()
        XCTAssertNil(action.begin(stop: task(running(agent: .claudeCode)), attemptId: "t-1"))
        XCTAssertNil(action.begin(stop: task(running(status: .done)), attemptId: "t-1"))
        XCTAssertFalse(action.isBusy)
    }

    func testAnAcceptedStopWaitsForTheMacAndOnlyASnapshotTakesTheButtonAway() {
        var action = WatchSessionActionState()
        let session = running()
        _ = action.begin(stop: task(session), attemptId: "t-1")
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .accepted))
        XCTAssertEqual(action.action?.phase, .awaitingResolution)
        XCTAssertTrue(action.isBusy, "still no second tap")

        // The turn is still running in the next state: the button stays, and so
        // does the sentence about it. Accepted is not stopped.
        action.reconcile(with: state([session]))
        XCTAssertEqual(action.action?.phase, .awaitingResolution)

        // The Mac reports the turn ended.
        var ended = session
        ended.status = .done
        action.reconcile(with: state([ended]))
        XCTAssertNil(action.action)
    }

    func testAnAcceptedStopClearsWhenTheNextTurnIsADifferentOne() {
        var action = WatchSessionActionState()
        _ = action.begin(stop: task(running()), attemptId: "t-1")
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .accepted))
        // Same session, still working, but a new turn: the attempt was about
        // the old one and must not go on describing this one.
        action.reconcile(with: state([running(since: 5)]))
        XCTAssertNil(action.action)
    }

    func testARefusedStopIsSaidOutLoudAndAFailedOneCanBeRetried() {
        var action = WatchSessionActionState()
        let session = running()
        _ = action.begin(stop: task(session), attemptId: "t-1")
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .refused))
        XCTAssertEqual(action.action?.phase, .refused)
        XCTAssertFalse(action.isBusy)

        action.fail(attemptId: "t-1")
        XCTAssertEqual(action.action?.phase, .refused, "a late reply for a settled attempt changes nothing")

        var second = WatchSessionActionState()
        _ = second.begin(stop: task(session), attemptId: "t-1")
        second.fail(attemptId: "t-1")
        XCTAssertEqual(second.action?.phase, .failed)
        XCTAssertNotNil(second.begin(stop: task(session), attemptId: "t-2"))
    }

    // MARK: answering — the contract 03 builds its input on

    private var answerable: AgentSession {
        AgentSession(id: "s-ask", agent: .codex, project: "docs", status: .needsResponse,
                     waitKind: .question,
                     pendingQuestion: PendingQuestion(id: "q-1", prompt: "Which tone?"),
                     statusSince: now, updatedAt: now)
    }

    func testAnAnswerIsBoundToTheQuestionItWasWrittenFor() {
        let gate = WatchSessionActionGate()
        let request = WatchSessionActionRequest(attemptId: "t-1", sessionId: "s-ask",
                                                action: .answer(pendingId: "q-1", text: " yes, go on "))
        XCTAssertEqual(gate.admit(request, sessions: [answerable]),
                       .answer(pendingId: "q-1", text: "yes, go on"))

        let stale = WatchSessionActionRequest(attemptId: "t-2", sessionId: "s-ask",
                                              action: .answer(pendingId: "q-0", text: "yes"))
        XCTAssertEqual(gate.admit(stale, sessions: [answerable]), .refused)
        let empty = WatchSessionActionRequest(attemptId: "t-3", sessionId: "s-ask",
                                              action: .answer(pendingId: "q-1", text: "   "))
        XCTAssertEqual(gate.admit(empty, sessions: [answerable]), .refused)
        // A permission is not a question, whatever the payload claims.
        XCTAssertEqual(gate.admit(request, sessions: [permission(id: "s-ask")]), .refused)
    }

    func testAnAnswerAttemptClearsWhenTheQuestionIsGone() {
        var action = WatchSessionActionState()
        let asking = state([answerable])
        let alert = asking.topAlert!
        XCTAssertTrue(alert.isAnswerable)
        XCTAssertNotNil(action.begin(alert: alert, answer: "yes", attemptId: "t-1"))
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .accepted))
        action.reconcile(with: asking)
        XCTAssertNotNil(action.action)
        action.reconcile(with: state([]))
        XCTAssertNil(action.action)
    }

    // MARK: a restored cache is a memory, not a control surface

    func testACachedAlertCanNeitherBeDecidedNorAnswered() throws {
        let live = state([permission(), answerable])
        XCTAssertTrue(live.alerts.contains { $0.isDecidable })
        XCTAssertTrue(live.alerts.contains { $0.isAnswerable })

        let cached = WatchStoredState(state: live, queue: WatchCompletionQueue()).state
        // The command and the question text stay on the live relay, so nothing
        // restored from disk may act — an id kept past its words would offer a
        // button for a request nobody can read.
        XCTAssertFalse(cached.alerts.contains { $0.isDecidable })
        XCTAssertFalse(cached.alerts.contains { $0.isAnswerable })
        var action = WatchSessionActionState()
        for alert in cached.alerts {
            XCTAssertNil(action.begin(alert: alert, choice: .allow, attemptId: "t-1"))
            XCTAssertNil(action.begin(alert: alert, answer: "yes", attemptId: "t-2"))
        }
    }

    // MARK: the payload still carries no secrets

    func testTheActionMessageCarriesNoBearerToken() throws {
        for payload in [try JSONEncoder().encode(request()),
                        try JSONEncoder().encode(WatchApprovalRequest(
                            attemptId: "t-1", sessionId: "s-build",
                            approvalId: "ap-1", choice: .allow)),
                        try JSONEncoder().encode(WatchSessionActionRequest(
                            attemptId: "t-1", sessionId: "s-build",
                            action: .stop(statusSince: now)))] {
            let json = String(decoding: payload, as: UTF8.self)
            XCTAssertFalse(json.contains("token"))
            XCTAssertFalse(json.contains("Bearer"))
        }
        // Exactly three fields: the tap, the session, and what the tap is for.
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(request())) as? [String: Any])
        XCTAssertEqual(Set(decoded.keys), ["attemptId", "sessionId", "action"])
        // The older Watch's approval form is untouched, key for key.
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(WatchApprovalRequest(
                attemptId: "t-1", sessionId: "s-build",
                approvalId: "ap-1", choice: .allow))) as? [String: Any])
        XCTAssertEqual(Set(legacy.keys), ["attemptId", "sessionId", "approvalId", "choice"])
        XCTAssertEqual(WatchApprovalRequest.messageKey, "vibebuddy.watchApproval")
        XCTAssertEqual(WatchApprovalResult.messageKey, "vibebuddy.watchApprovalResult")
    }
}
