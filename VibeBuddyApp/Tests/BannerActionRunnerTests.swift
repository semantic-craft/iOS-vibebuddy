import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

private final class ScriptedWaitClient: DecisionClient, @unchecked Sendable {
    var decideStatus: WaitActionResult
    var answerStatus: WaitActionResult
    var lastDecide: (approvalId: String, decision: ApprovalDecision)?
    var lastAnswer: (sessionId: String, text: String)?

    init(decideStatus: WaitActionResult = .accepted, answerStatus: WaitActionResult = .accepted) {
        self.decideStatus = decideStatus
        self.answerStatus = answerStatus
    }

    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome { .accepted }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool {
        decideStatus == .accepted
    }
    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> WaitActionResult {
        lastDecide = (approvalId, decision)
        return decideStatus
    }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func answerResult(_ pairing: PairingPayload, sessionId: String, answer: String) async -> WaitActionResult {
        lastAnswer = (sessionId, answer)
        return answerStatus
    }
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}

private actor HeldRecorder {
    private(set) var entries: [(QueuedSessionAction, ConnectionFailureReason?)] = []
    var stores = true
    func refuse() { stores = false }
    func record(_ action: QueuedSessionAction, _ reason: ConnectionFailureReason?) -> Bool {
        entries.append((action, reason))
        return stores
    }
}

final class BannerActionRunnerTests: XCTestCase {
    private let pairing = PairingPayload(host: "127.0.0.1", port: 9, token: "t")
    private var info: [AnyHashable: Any] {
        [NotificationUserInfoKey.sessionId: "s1", NotificationUserInfoKey.approvalId: "ap-1"]
    }

    func testApproveSendsAllow() async {
        let client = ScriptedWaitClient()
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.approve.rawValue,
            userInfo: info, text: nil, pairing: pairing, client: client)
        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(client.lastDecide?.approvalId, "ap-1")
        XCTAssertEqual(client.lastDecide?.decision, .allow)
    }

    func testDenySendsDeny() async {
        let client = ScriptedWaitClient()
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.deny.rawValue,
            userInfo: info, text: nil, pairing: pairing, client: client)
        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(client.lastDecide?.decision, .deny)
    }

    func testAnswerSendsText() async {
        let client = ScriptedWaitClient()
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.answer.rawValue,
            userInfo: info, text: "  ship it  ", pairing: pairing, client: client)
        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(client.lastAnswer?.sessionId, "s1")
        XCTAssertEqual(client.lastAnswer?.text, "ship it")
    }

    func testAlreadyResolvedOpensTheSession() async {
        let client = ScriptedWaitClient(decideStatus: .alreadyResolved)
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.approve.rawValue,
            userInfo: info, text: nil, pairing: pairing, client: client)
        XCTAssertEqual(outcome, .openSession("s1"))
    }

    func testConflictOpensTheSession() async {
        let client = ScriptedWaitClient(answerStatus: .alreadyResolved)
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.answer.rawValue,
            userInfo: info, text: "yes", pairing: pairing, client: client)
        XCTAssertEqual(outcome, .openSession("s1"))
    }

    func testALostReceiptIsReportedUnconfirmedNotHeld() async {
        // A refusal or a timeout after the body went out: the Mac may have
        // acted, so the tap is neither held nor retried, and the person is
        // told to look. A reply an older push left unnamed has nothing to
        // describe, so it opens the session as before.
        let client = ScriptedWaitClient(decideStatus: .failed, answerStatus: .failed)
        for action in [NotificationActionID.approve, .deny] {
            let outcome = await BannerActionRunner.perform(
                actionIdentifier: action.rawValue, userInfo: info, text: nil,
                pairing: pairing, client: client, hold: { _, _ in XCTFail("a lost receipt was held"); return true })
            guard case .unconfirmed(let record) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(record.approvalId, "ap-1")
        }
        let reply = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.answer.rawValue, userInfo: info, text: "yes",
            pairing: pairing, client: client)
        XCTAssertEqual(reply, .openSession("s1"))
    }

    func testAHoldTheStoreRefusesIsReportedNotHeld() async {
        let client = ScriptedWaitClient(decideStatus: .unreachable)
        let held = HeldRecorder()
        await held.refuse()
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.approve.rawValue, userInfo: info, text: nil,
            pairing: pairing, client: client, epoch: "e1", hold: { await held.record($0, $1) })
        guard case .notHeld(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(record.action, .approval(id: "ap-1", choice: .allow))
    }

    func testAnUnreachableMacHoldsApproveUnderTheRequestKey() async {
        let client = ScriptedWaitClient(decideStatus: .unreachable)
        let held = HeldRecorder()
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.approve.rawValue,
            userInfo: info, text: nil, pairing: PairingPayload(host: "100.100.0.7", port: 9876, token: "t"),
            client: client, epoch: "e1", hold: { await held.record($0, $1) }, phoneHasTailnet: { false })
        guard case .held(let sessionId, let key) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(sessionId, "s1")
        let entries = await held.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.0.id, key, "the hold is filed under the key the Mac was asked with")
        XCTAssertEqual(entries.first?.0.action, .approval(id: "ap-1", choice: .allow))
        XCTAssertEqual(entries.first?.0.origin, .banner)
        XCTAssertEqual(entries.first?.0.pairingEpoch, "e1")
        XCTAssertEqual(entries.first?.1, .tailnetOff(host: "100.100.0.7"))
    }

    func testAReplyThatNamesItsQuestionIsHeldAndAnUnnamedOneIsNot() async {
        let client = ScriptedWaitClient(answerStatus: .unreachable)
        let held = HeldRecorder()
        var named = info
        named[NotificationUserInfoKey.questionId] = "q-7"
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.answer.rawValue, userInfo: named, text: "ship it",
            pairing: pairing, client: client, epoch: "e1", hold: { await held.record($0, $1) },
            phoneHasTailnet: { true })
        guard case .held = outcome else { return XCTFail("\(outcome)") }
        let entries = await held.entries
        XCTAssertEqual(entries.first?.0.action, .answer(pendingId: "q-7", text: "ship it"))
        // An older Mac's push names no question: nothing to hold against.
        let unnamed = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.answer.rawValue, userInfo: info, text: "ship it",
            pairing: pairing, client: client, epoch: "e1", hold: { _, _ in XCTFail("an unnamed reply was held"); return true })
        XCTAssertEqual(unnamed, .openSession("s1"))
    }

    func testAnUnreachableMacWithoutAQueueStillOpensTheSession() async {
        let client = ScriptedWaitClient(decideStatus: .unreachable, answerStatus: .unreachable)
        for action in [NotificationActionID.approve, .deny, .answer] {
            let outcome = await BannerActionRunner.perform(
                actionIdentifier: action.rawValue, userInfo: info, text: "yes",
                pairing: pairing, client: client)
            XCTAssertEqual(outcome, .openSession("s1"))
        }
    }

    func testNoPairingOpensTheSession() async {
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: NotificationActionID.approve.rawValue,
            userInfo: info, text: nil, pairing: nil, client: NullDecisionClient())
        XCTAssertEqual(outcome, .openSession("s1"))
    }

    func testUnknownActionIsIgnored() async {
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: info, text: nil, pairing: pairing, client: NullDecisionClient())
        XCTAssertEqual(outcome, .ignored)
    }
}