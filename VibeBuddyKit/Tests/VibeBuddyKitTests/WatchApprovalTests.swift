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
                         choice: WatchApprovalChoice = .allow) -> WatchApprovalRequest {
        WatchApprovalRequest(attemptId: attempt, sessionId: session,
                             approvalId: approval, choice: choice)
    }

    func testAValidAllowIsForwarded() {
        let gate = WatchApprovalGate()
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]),
                       .send(approvalId: "ap-1", decision: .allow))
    }

    func testAValidDenyIsForwarded() {
        let gate = WatchApprovalGate()
        XCTAssertEqual(gate.admit(request(choice: .deny), sessions: [permission()]),
                       .send(approvalId: "ap-1", decision: .deny))
    }

    func testAStaleApprovalIdIsRefused() {
        let gate = WatchApprovalGate()
        XCTAssertEqual(gate.admit(request(approval: "ap-0"), sessions: [permission()]), .refused)
    }

    func testAnApprovalThatAlreadyResolvedIsRefused() {
        let gate = WatchApprovalGate()
        XCTAssertEqual(gate.admit(request(), sessions: [permission(status: .working)]), .refused)
        XCTAssertEqual(gate.admit(request(), sessions: []), .refused)
    }

    func testAMismatchedSessionIsRefused() {
        let gate = WatchApprovalGate()
        XCTAssertEqual(gate.admit(request(session: "s-other"), sessions: [permission()]), .refused)
    }

    func testADisplayOnlyApprovalCannotBeActedOn() {
        // Even a hand-made message naming the real id: the detail rule is the
        // authority, and it is re-run here rather than trusted from the wrist.
        let session = permission(tool: "Edit", command: nil, filePath: "src/app.ts",
                                 oldText: "a", newText: "b")
        let gate = WatchApprovalGate()
        XCTAssertEqual(gate.admit(request(), sessions: [session]), .refused)
    }

    func testARepeatedAttemptIsNotForwardedTwice() {
        var gate = WatchApprovalGate()
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]),
                       .send(approvalId: "ap-1", decision: .allow))
        gate.commit("t-1")
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]), .duplicate)
    }

    func testAReplayedAttemptCannotResolveADifferentApproval() {
        var gate = WatchApprovalGate()
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
        var gate = WatchApprovalGate()
        // Nothing is committed when delivery fails…
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]),
                       .send(approvalId: "ap-1", decision: .allow))
        // …so the same tap is still forwardable.
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]),
                       .send(approvalId: "ap-1", decision: .allow))
        gate.commit("t-1")
        XCTAssertEqual(gate.admit(request(), sessions: [permission()]), .duplicate)
    }

    func testTheAttemptHistoryIsBounded() {
        var gate = WatchApprovalGate()
        for index in 0...WatchApprovalGate.historyLimit { gate.commit("t-\(index)") }
        XCTAssertEqual(gate.admit(request(attempt: "t-0"), sessions: [permission()]),
                       .send(approvalId: "ap-1", decision: .allow),
                       "the oldest attempt aged out")
        XCTAssertEqual(gate.admit(request(attempt: "t-\(WatchApprovalGate.historyLimit)"),
                                  sessions: [permission()]), .duplicate)
    }

    // MARK: the Watch's action state

    private var alert: WatchAlert { state([permission()]).topAlert! }

    func testASecondTapDoesNotSendASecondDecision() {
        var action = WatchApprovalActionState()
        XCTAssertNotNil(action.begin(alert: alert, choice: .allow, attemptId: "t-1"))
        XCTAssertTrue(action.isBusy)
        XCTAssertNil(action.begin(alert: alert, choice: .allow, attemptId: "t-2"))
        XCTAssertNil(action.begin(alert: alert, choice: .deny, attemptId: "t-3"))
        XCTAssertEqual(action.action?.attemptId, "t-1")
    }

    func testADisplayOnlyAlertCannotStartAnAttempt() {
        let readOnly = state([question()]).topAlert!
        var action = WatchApprovalActionState()
        XCTAssertNil(action.begin(alert: readOnly, choice: .allow, attemptId: "t-1"))
        XCTAssertFalse(action.isBusy)
    }

    func testAnAcceptedDecisionAwaitsTheMacRatherThanClaimingResolution() {
        var action = WatchApprovalActionState()
        _ = action.begin(alert: alert, choice: .allow, attemptId: "t-1")
        action.apply(WatchApprovalResult(attemptId: "t-1", outcome: .accepted))
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
        var action = WatchApprovalActionState()
        _ = action.begin(alert: alert, choice: .allow, attemptId: "t-1")
        action.fail(attemptId: "t-1")
        XCTAssertEqual(action.action?.phase, .failed)
        XCTAssertFalse(action.isBusy)
        XCTAssertNotNil(action.begin(alert: alert, choice: .allow, attemptId: "t-2"))
    }

    func testARefusalIsSaidOutLoud() {
        var action = WatchApprovalActionState()
        _ = action.begin(alert: alert, choice: .deny, attemptId: "t-1")
        action.apply(WatchApprovalResult(attemptId: "t-1", outcome: .refused))
        XCTAssertEqual(action.action?.phase, .refused)
        XCTAssertFalse(action.isBusy)
    }

    func testALateReplyForAnOldAttemptIsIgnored() {
        var action = WatchApprovalActionState()
        _ = action.begin(alert: alert, choice: .allow, attemptId: "t-1")
        action.apply(WatchApprovalResult(attemptId: "t-old", outcome: .failed))
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

        var action = WatchApprovalActionState()
        _ = action.begin(alert: demo.topAlert!, choice: .allow, attemptId: "t-1")
        action.apply(WatchApprovalResult(attemptId: "t-1", outcome: .accepted))
        action.reconcile(with: resolved)
        XCTAssertNil(action.action)
    }

    func testResolvingAnUnknownApprovalChangesNothing() {
        let demo = WatchDemoScenario.permission.state(now: now)
        XCTAssertEqual(demo.resolvingApproval("nope"), demo)
    }

    // MARK: the payload still carries no secrets

    func testTheActionMessageCarriesNoBearerToken() throws {
        let payload = try JSONEncoder().encode(request())
        let json = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(json.contains("Bearer"))
        // Exactly four fields: the attempt, the session, the approval, the choice.
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(Set(decoded.keys), ["attemptId", "sessionId", "approvalId", "choice"])
    }
}
