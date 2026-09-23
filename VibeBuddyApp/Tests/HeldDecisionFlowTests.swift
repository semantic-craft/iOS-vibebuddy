import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

/// A Mac that can be unreachable now and back later, remembering every
/// decision it was given and the key it came under.
private final class IntermittentMac: DecisionClient, @unchecked Sendable {
    struct Decision: Equatable { let approvalId: String; let decision: ApprovalDecision; let requestID: String }
    struct Answer: Equatable { let sessionId: String; let text: String?; let requestID: String }

    private let lock = NSLock()
    private var _snapshot: Snapshot?
    private var _reachable = false
    private var _decisions: [Decision] = []
    private var _answers: [Answer] = []
    /// What the Mac answers a decision with while reachable.
    var decisionResult: PhoneActionResult = .received

    var decisions: [Decision] { lock.withLock { _decisions } }
    var answers: [Answer] { lock.withLock { _answers } }

    func set(snapshot: Snapshot?, reachable: Bool) {
        lock.withLock { _snapshot = snapshot; _reachable = reachable }
    }

    func actionSnapshot(_ pairing: PairingPayload) async -> Snapshot? {
        lock.withLock { _reachable ? _snapshot : nil }
    }

    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision,
                       requestID: String) async -> PhoneActionResult {
        lock.withLock {
            guard _reachable else { return .failed }
            _decisions.append(Decision(approvalId: approvalId, decision: decision, requestID: requestID))
            // A repeat under a known key is the Mac's request log answering.
            return decisionResult
        }
    }

    func phoneAnswer(_ pairing: PairingPayload, session: AgentSession, text: String?,
                     answers: QuestionAnswers?, requestID: String) async -> PhoneActionResult {
        lock.withLock {
            guard _reachable else { return .failed }
            _answers.append(Answer(sessionId: session.id, text: text, requestID: requestID))
            return .received
        }
    }

    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome { .accepted }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { false }
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}

@MainActor
private final class HeldTransport: WatchStateTransport {
    var isAvailable = true
    var onReady: (() -> Void)?
    var onSessionAction: ((WatchSessionActionRequest) async -> WatchSessionActionResult)?
    var onCompletionRequest: ((WatchCompletionRequest) async -> WatchCompletionResult)?
    var onRefresh: ((WatchRefreshRequest) async -> WatchRefreshReply)?
    var onActivityOpen: ((WatchActivityOpenRequest) async -> WatchActivityOpenReply)?
    var onWaitReadRequest: ((WatchWaitReadRequest) async -> Bool)?
    private(set) var sent: [Data] = []
    func send(_ payload: Data) throws { sent.append(payload) }
    var states: [WatchDashboardState] { sent.compactMap { try? JSONDecoder().decode(WatchDashboardState.self, from: $0) } }
    func tap(_ request: WatchSessionActionRequest) async -> WatchSessionActionResult {
        await onSessionAction?(request) ?? WatchSessionActionResult(attemptId: request.attemptId, outcome: .failed)
    }
}

/// One snapshot, then the link drops; every reconnect after that hangs, so
/// the store stays disconnected for the rest of the test instead of flapping
/// every two seconds (the shared scripted streamer never ends at all).
private final class OneShotStreamer: SnapshotStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var reconnects = false
    let snapshot: Snapshot
    init(_ snapshot: Snapshot) { self.snapshot = snapshot }

    /// From now on a reconnect attempt yields the snapshot and stays open,
    /// the way a real stream does once the link is back.
    func allowReconnect() { lock.withLock { reconnects = true } }

    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> {
        let (first, open) = lock.withLock { calls += 1; return (calls == 1, reconnects) }
        return AsyncThrowingStream { continuation in
            if first {
                continuation.yield(snapshot)
                continuation.finish()
            } else if open {
                continuation.yield(snapshot)
            }
        }
    }
}

/// A recording notifier that also keeps every delivery report.
private final class DeliveryNotifier: AttentionNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _reports: [HeldDeliveryEvent] = []
    private var _warnings: [ConnectionFailureReason] = []
    var reports: [HeldDeliveryEvent] { lock.withLock { _reports } }
    var warnings: [ConnectionFailureReason] { lock.withLock { _warnings } }
    func requestAuthorization() {}
    func notify(_ alert: SoundAlert) async -> Bool { true }
    func withdraw(_ identifiers: [String]) {}
    func confirmPairing() {}
    func reportDelivery(_ event: HeldDeliveryEvent, macName: String?) { lock.withLock { _reports.append(event) } }
    func warnUnreachable(_ reason: ConnectionFailureReason, macName: String?) { lock.withLock { _warnings.append(reason) } }
}

/// The 2026-09-22 night, end to end on the phone: a wrist tap while the Mac
/// is out of reach is held, said so, and delivered once when the link
/// returns — under the key the Mac deduplicates on.
@MainActor
final class HeldDecisionFlowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let pairing = PairingPayload(host: "100.100.0.7", port: 9876, token: "fixture", macName: "Studio")

    private func waitingSession() -> AgentSession {
        AgentSession(id: "cursor-1", agent: .cursor, project: "ios-vibebuddy", status: .needsResponse,
                     waitKind: .permission,
                     pendingApproval: PendingApproval(id: "ap-1", tool: "Bash", commandPreview: "swift test",
                                                      command: "swift test"),
                     statusSince: now, updatedAt: now)
    }

    private func snapshot(_ sessions: [AgentSession]) -> Snapshot {
        Snapshot(sessions: sessions, serverTime: now, sourceID: "studio")
    }

    private func store(transport: HeldTransport, mac: IntermittentMac, notifier: DeliveryNotifier,
                       queue: PendingActionStore, streamer: SnapshotStreaming,
                       tailnet: Bool = false) async throws -> DashboardStore {
        let store = DashboardStore(streamer: streamer, notifier: notifier, decisionClient: mac,
                                   watchRelay: WatchRelay(transport: transport),
                                   pendingActions: queue, phoneHasTailnet: { tailnet },
                                   reportDevice: { _ in })
        addTeardownBlock { @MainActor in await store.stop().value }
        store.start(pairing)
        for _ in 0..<200 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        return store
    }

    private func relayedApproval(_ transport: HeldTransport, attempt: String) throws -> WatchSessionActionRequest {
        let state = try XCTUnwrap(transport.states.last)
        let alert = try XCTUnwrap(state.alerts.first { $0.isDecidable })
        var action = WatchSessionActionState()
        return try XCTUnwrap(action.begin(alert: alert, choice: .allow, attemptId: attempt))
    }

    func testAWristTapWhileTheMacIsUnreachableIsHeldAndDeliveredOnceOnReconnect() async throws {
        let transport = HeldTransport()
        let mac = IntermittentMac()
        let notifier = DeliveryNotifier()
        let queue = PendingActionStore(url: nil)
        // One snapshot arrives, then the stream ends — the store reports the
        // Mac gone and the tailnet, not the Mac, is what is missing.
        let stream = snapshot([waitingSession()])
        mac.set(snapshot: stream, reachable: true)
        let store = try await store(transport: transport, mac: mac, notifier: notifier, queue: queue,
                                    streamer: OneShotStreamer(stream))
        for _ in 0..<200 where store.state == .connected { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.failure, .tailnetOff(host: "100.100.0.7"))
        mac.set(snapshot: stream, reachable: false)

        let request = try relayedApproval(transport, attempt: "tap-1")
        let result = await transport.tap(request)
        XCTAssertEqual(result.outcome, .queued)
        XCTAssertEqual(result.reason, .tailnetOff(host: "100.100.0.7"))
        XCTAssertEqual(mac.decisions, [], "nothing reached the Mac")
        XCTAssertEqual(store.heldActions.map(\.id), ["tap-1"])
        // The wrist is told what the phone holds, on the next relay.
        XCTAssertEqual(transport.states.last?.heldActions?.map(\.id), ["tap-1"])
        // …and the notification path was told too, since the tap was on the wrist.
        guard case .held(let held, let reason)? = notifier.reports.last else {
            return XCTFail("no hold reported: \(notifier.reports)")
        }
        XCTAssertEqual(held.id, "tap-1")
        XCTAssertEqual(reason, .tailnetOff(host: "100.100.0.7"))

        // A change of mind replaces the earlier hold; still one decision.
        var deny = request
        deny.attemptId = "tap-2"
        deny.action = .approval(id: "ap-1", choice: .deny)
        let revised = await transport.tap(deny)
        XCTAssertEqual(revised.outcome, .queued)
        XCTAssertEqual(store.heldActions.map(\.id), ["tap-2"])

        // The link returns: one delivery, under the held key, and the hold
        // is reported delivered.
        mac.set(snapshot: stream, reachable: true)
        await store.retryHeldDecisions()
        XCTAssertEqual(mac.decisions, [.init(approvalId: "ap-1", decision: .deny, requestID: "tap-2")])
        XCTAssertTrue(store.heldActions.isEmpty)
        guard case .delivered(let delivered)? = notifier.reports.last else {
            return XCTFail("delivery not reported: \(notifier.reports)")
        }
        XCTAssertEqual(delivered.id, "tap-2")
        // A second pass has nothing left to send.
        await store.retryHeldDecisions()
        XCTAssertEqual(mac.decisions.count, 1)
    }

    func testAHeldDecisionWhoseRequestResolvedElsewhereIsReportedGoneNotApplied() async throws {
        let transport = HeldTransport()
        let mac = IntermittentMac()
        let notifier = DeliveryNotifier()
        let queue = PendingActionStore(url: nil)
        let stream = snapshot([waitingSession()])
        mac.set(snapshot: stream, reachable: true)
        let store = try await store(transport: transport, mac: mac, notifier: notifier, queue: queue,
                                    streamer: OneShotStreamer(stream), tailnet: true)
        for _ in 0..<200 where store.state == .connected { try await Task.sleep(for: .milliseconds(5)) }
        // The stream simply ended with the tunnel up: a drop, not a diagnosis
        // of the Mac — and still a reason to hold.
        XCTAssertEqual(store.failure, .dropped)
        mac.set(snapshot: stream, reachable: false)
        let request = try relayedApproval(transport, attempt: "tap-1")
        let held = await transport.tap(request)
        XCTAssertEqual(held.outcome, .queued)
        XCTAssertEqual(held.reason, .dropped)

        // The Mac comes back with the prompt already resolved from its own screen.
        var resolved = waitingSession()
        resolved.pendingApproval = nil
        resolved.waitKind = nil
        resolved.status = .working
        mac.set(snapshot: snapshot([resolved]), reachable: true)
        await store.retryHeldDecisions()
        XCTAssertEqual(mac.decisions, [], "a decision for a prompt that is gone is not sent")
        XCTAssertTrue(store.heldActions.isEmpty)
        guard case .gone? = notifier.reports.last else { return XCTFail("\(notifier.reports)") }
    }

    func testAStopIsNeverHeldAndNamesTheMissingLink() async throws {
        let transport = HeldTransport()
        let mac = IntermittentMac()
        let notifier = DeliveryNotifier()
        let queue = PendingActionStore(url: nil)
        let running = AgentSession(id: "task-run", agent: .codex, project: "vibebuddy", status: .working,
                                   observations: [ObservationEvidence(source: .appserver,
                                                                      lastObservedAt: now, health: .healthy)],
                                   attention: .followed, statusSince: now, updatedAt: now)
        let stream = snapshot([running])
        mac.set(snapshot: stream, reachable: true)
        let store = try await store(transport: transport, mac: mac, notifier: notifier, queue: queue,
                                    streamer: OneShotStreamer(stream))
        for _ in 0..<200 where store.state == .connected { try await Task.sleep(for: .milliseconds(5)) }
        let state = try XCTUnwrap(transport.states.last)
        let task = try XCTUnwrap(state.followedTasks.first { $0.sessionID == "task-run" })
        var action = WatchSessionActionState()
        let stop = try XCTUnwrap(action.begin(stop: task, attemptId: "stop-1"))

        let result = await transport.tap(stop)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.reason, .tailnetOff(host: "100.100.0.7"))
        XCTAssertTrue(store.heldActions.isEmpty)
    }

    func testThePhoneCardNeverSendsASecondDecisionBesideAHeldOne() async throws {
        let transport = HeldTransport()
        let mac = IntermittentMac()
        let notifier = DeliveryNotifier()
        let queue = PendingActionStore(url: nil)
        let stream = snapshot([waitingSession()])
        let streamer = OneShotStreamer(stream)
        mac.set(snapshot: stream, reachable: true)
        let store = try await store(transport: transport, mac: mac, notifier: notifier, queue: queue,
                                    streamer: streamer)
        for _ in 0..<200 where store.state == .connected { try await Task.sleep(for: .milliseconds(5)) }
        mac.set(snapshot: stream, reachable: false)
        // The wrist holds an Allow; the phone's card shows it as its receipt.
        let request = try relayedApproval(transport, attempt: "wrist-allow")
        let wrist = await transport.tap(request)
        XCTAssertEqual(wrist.outcome, .queued)
        XCTAssertEqual(store.phoneActionState(for: waitingSession()), .held)
        XCTAssertTrue(store.phoneActionDisabled(for: waitingSession()))
        // A Deny from the card replaces the held Allow: one decision, the newest.
        let receipt = await store.decideConfirmed("ap-1", .deny)
        XCTAssertEqual(receipt, .held)
        XCTAssertEqual(store.heldActions.map(\.choice), [.deny])
        XCTAssertNotEqual(store.heldActions.first?.id, "wrist-allow")
        // The link returns: exactly one decision reaches the Mac, the Deny.
        mac.set(snapshot: stream, reachable: true)
        await store.retryHeldDecisions()
        XCTAssertEqual(mac.decisions.map(\.decision), [.deny])
        XCTAssertEqual(store.phoneActionState(for: waitingSession()), .received)
    }

    func testAConnectedCardDecisionReplacesAHeldOneAndGoesOut() async throws {
        let transport = HeldTransport()
        let mac = IntermittentMac()
        let notifier = DeliveryNotifier()
        let queue = PendingActionStore(url: nil)
        let stream = snapshot([waitingSession()])
        let streamer = OneShotStreamer(stream)
        mac.set(snapshot: stream, reachable: true)
        let store = try await store(transport: transport, mac: mac, notifier: notifier, queue: queue,
                                    streamer: streamer)
        for _ in 0..<200 where store.state == .connected { try await Task.sleep(for: .milliseconds(5)) }
        mac.set(snapshot: stream, reachable: false)
        let request = try relayedApproval(transport, attempt: "wrist-allow")
        let wrist = await transport.tap(request)
        XCTAssertEqual(wrist.outcome, .queued)
        // The stream comes back while the Mac's HTTP side still does not
        // answer: the reconnect-edge pass leaves the Allow held, and the card
        // still shows it. (The store retries the stream every two seconds.)
        streamer.allowReconnect()
        for _ in 0..<1200 where store.state != .connected { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.state, .connected)
        XCTAssertEqual(store.heldActions.map(\.id), ["wrist-allow"])
        XCTAssertEqual(store.phoneActionState(for: waitingSession()), .held)
        // Now the Mac answers. A Deny from the connected card withdraws the
        // held Allow and goes out itself — once, and it is the only decision.
        mac.set(snapshot: stream, reachable: true)
        let receipt = await store.decideConfirmed("ap-1", .deny)
        XCTAssertEqual(receipt, .received)
        XCTAssertEqual(mac.decisions.map(\.decision), [.deny])
        XCTAssertTrue(store.heldActions.isEmpty)
        XCTAssertEqual(transport.states.last?.heldActions, [])
        // Nothing left for a later pass to send.
        await store.retryHeldDecisions()
        XCTAssertEqual(mac.decisions.count, 1)
    }

    /// The 2026-09-22 gate, round 1: the phone locked in a pocket, its
    /// stream dropped by the suspension, the Mac reachable all along. The
    /// wrist's tap woke the phone, which held the decision for a link that
    /// was never actually missing — and delivered it three and a half minutes
    /// later, when the phone was unlocked. A tap that finds no stream gets
    /// one delivery pass now, and the wrist hears what happened.
    func testAWristTapBeforeTheStreamIsBackIsDeliveredAtOnceAndReportedThroughTheTap() async throws {
        let transport = HeldTransport()
        let mac = IntermittentMac()
        let notifier = DeliveryNotifier()
        let queue = PendingActionStore(url: nil)
        let stream = snapshot([waitingSession()])
        mac.set(snapshot: stream, reachable: true)
        let store = try await store(transport: transport, mac: mac, notifier: notifier, queue: queue,
                                    streamer: OneShotStreamer(stream), tailnet: true)
        // The stream ended (a suspension drops the socket) and has not come
        // back; the Mac's HTTP side answers throughout.
        for _ in 0..<200 where store.state == .connected { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotEqual(store.state, .connected)

        let request = try relayedApproval(transport, attempt: "tap-1")
        let result = await transport.tap(request)
        XCTAssertEqual(result.outcome, .accepted, "\(result)")
        XCTAssertEqual(mac.decisions, [.init(approvalId: "ap-1", decision: .allow, requestID: "tap-1")])
        XCTAssertTrue(store.heldActions.isEmpty)
        XCTAssertEqual(transport.states.last?.heldActions ?? [], [])
        // The reply to the tap is the report; no "on hold" and no
        // "delivered" banner is posted beside it.
        XCTAssertTrue(notifier.reports.isEmpty, "\(notifier.reports)")
        // A later pass has nothing left to send.
        await store.retryHeldDecisions()
        XCTAssertEqual(mac.decisions.count, 1)
    }

    /// Same tap, but the Mac's request has already been resolved from its
    /// own screen: the pass finds it gone, nothing is applied, and the wrist
    /// is told so through the tap rather than a notification.
    func testAWristTapBeforeTheStreamIsBackForAResolvedRequestIsRefusedThroughTheTap() async throws {
        let transport = HeldTransport()
        let mac = IntermittentMac()
        let notifier = DeliveryNotifier()
        let queue = PendingActionStore(url: nil)
        let stream = snapshot([waitingSession()])
        mac.set(snapshot: stream, reachable: true)
        let store = try await store(transport: transport, mac: mac, notifier: notifier, queue: queue,
                                    streamer: OneShotStreamer(stream), tailnet: true)
        for _ in 0..<200 where store.state == .connected { try await Task.sleep(for: .milliseconds(5)) }
        var resolved = waitingSession()
        resolved.pendingApproval = nil
        resolved.waitKind = nil
        resolved.status = .working
        mac.set(snapshot: snapshot([resolved]), reachable: true)

        let request = try relayedApproval(transport, attempt: "tap-1")
        let result = await transport.tap(request)
        XCTAssertEqual(result.outcome, .refused, "\(result)")
        XCTAssertEqual(mac.decisions, [])
        XCTAssertTrue(store.heldActions.isEmpty)
        XCTAssertTrue(notifier.reports.isEmpty, "\(notifier.reports)")
    }

    func testThePhonesOwnApproveIsHeldWhenTheMacIsUnreachable() async throws {
        let transport = HeldTransport()
        let mac = IntermittentMac()
        let notifier = DeliveryNotifier()
        let queue = PendingActionStore(url: nil)
        let stream = snapshot([waitingSession()])
        mac.set(snapshot: stream, reachable: true)
        let store = try await store(transport: transport, mac: mac, notifier: notifier, queue: queue,
                                    streamer: OneShotStreamer(stream))
        for _ in 0..<200 where store.state == .connected { try await Task.sleep(for: .milliseconds(5)) }
        mac.set(snapshot: stream, reachable: false)

        let receipt = await store.decideConfirmed("ap-1", .allow)
        XCTAssertEqual(receipt, .held)
        XCTAssertEqual(store.heldActions.count, 1)
        XCTAssertEqual(store.phoneActionState(for: waitingSession()), .held)
        // The app's own card toasted; nothing was posted as a notification.
        XCTAssertTrue(notifier.reports.isEmpty)
        // A persisting decision is never held: it must be made where the
        // command is readable, now, or not at all.
        let persisting = await store.decideConfirmed("ap-1", .alwaysAllow)
        XCTAssertNotEqual(persisting, .held)
        XCTAssertEqual(store.heldActions.count, 1)
    }
}
