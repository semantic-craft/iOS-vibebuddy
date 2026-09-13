import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
private final class FakeWatchTransport: WatchStateTransport {
    var onWaitReadRequest: ((WatchWaitReadRequest) async -> Bool)?
    var onCompletionRequest: ((WatchCompletionRequest) async -> WatchCompletionResult)?
    var isAvailable = true
    var onReady: (() -> Void)?
    var onSessionAction: ((WatchSessionActionRequest) async -> WatchSessionActionResult)?
    var failNextSends = false
    /// Everything the transport accepted, in order.
    private(set) var sent: [Data] = []
    /// What the mailbox is holding for a Watch that has not read it yet. A send
    /// replaces it, the way writing the application context does.
    private(set) var queued: [Data] = []

    func send(_ payload: Data) throws {
        if failNextSends { throw WatchRelayError.unsupported }
        sent.append(payload)
        queued = [payload]
    }

    var states: [WatchDashboardState] {
        sent.compactMap { try? JSONDecoder().decode(WatchDashboardState.self, from: $0) }
    }

    var queuedStates: [WatchDashboardState] {
        queued.compactMap { try? JSONDecoder().decode(WatchDashboardState.self, from: $0) }
    }

    /// A tap on the wrist, delivered the way WatchConnectivity delivers one.
    func tap(_ request: WatchSessionActionRequest) async -> WatchSessionActionResult {
        guard let onSessionAction else {
            return WatchSessionActionResult(attemptId: request.attemptId, outcome: .failed)
        }
        return await onSessionAction(request)
    }

    /// The same tap in the approval-only words an older watchOS build speaks.
    /// The iPhone must keep honouring them: a Watch app updates on its own
    /// schedule, and its Approve button has to survive that window.
    func tap(_ request: WatchApprovalRequest) async -> WatchApprovalResult {
        WatchApprovalResult(await tap(request.sessionAction))
    }

    /// The Watch came back. Drive the callback the real session fires.
    func becomeAvailable() {
        isAvailable = true
        failNextSends = false
        onReady?()
    }
}

@MainActor
final class WatchRelayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(working: Int, at offset: TimeInterval = 0,
                       relay: WatchRelayState = .live) -> WatchDashboardState {
        let sessions = (0..<working).map {
            AgentSession(id: "s\($0)", agent: .claudeCode, project: "vibebuddy",
                         status: .working, statusSince: now, updatedAt: now)
        }
        var result = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions, serverTime: now),
            quotas: [], relay: relay, now: now.addingTimeInterval(offset))
        result.relayRevision = UInt64(100 + offset)
        return result
    }

    func testEquivalentStateIsNotResent() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        XCTAssertTrue(relay.publish(state(working: 1)))
        XCTAssertFalse(relay.publish(state(working: 1, at: 30)))
        XCTAssertTrue(relay.publish(state(working: 1, at: 900)))

        XCTAssertEqual(transport.sent.count, 2)
    }

    func testWaitDestinationChangesTravelThroughTheExistingRelay() throws {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)
        func projected(_ agent: AgentKind, answerable: Bool, connection: WatchRelayState = .live) -> WatchDashboardState {
            let session = AgentSession(id: "same-task", agent: agent, project: "Project",
                status: .needsResponse, waitKind: .question,
                pendingQuestion: PendingQuestion(id: "same-request", prompt: "Choose", answerable: answerable),
                statusSince: now, updatedAt: now)
            return WatchDashboardProjection.make(snapshot: Snapshot(sessions: [session], serverTime: now),
                                                  quotas: [], relay: connection, now: now)
        }
        XCTAssertTrue(relay.publish(projected(.codex, answerable: true)))
        XCTAssertTrue(relay.publish(projected(.codex, answerable: false)))
        XCTAssertTrue(relay.publish(projected(.grokBot, answerable: false)))
        XCTAssertTrue(relay.publish(projected(.grokBot, answerable: false, connection: .disconnected)))
        XCTAssertTrue(relay.publish(projected(.codex, answerable: true)))
        XCTAssertEqual(transport.states.map { $0.topAlert?.handling },
                       [.remoteAvailable, .macNativePrompt, .macGrokBot, .macGrokBot, .remoteAvailable])
        XCTAssertTrue(transport.states.allSatisfy { $0.topAlert?.isDecidable == false })
        XCTAssertEqual(transport.states[3].connection(now: now, phoneReachable: true), .macDisconnected)
        XCTAssertEqual(transport.states.last?.connection(now: now, phoneReachable: true), .live)
    }

    func testMeaningfulChangeProducesANewContext() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        relay.publish(state(working: 1))
        relay.publish(state(working: 2))
        relay.publish(state(working: 2, relay: .disconnected))

        XCTAssertEqual(transport.states.map(\.counts.working), [1, 2, 2])
        XCTAssertEqual(transport.states.map(\.relay), [.live, .live, .disconnected])
    }

    func testAnUnavailableWatchGetsOnlyTheNewestStateWhenItReturns() {
        let transport = FakeWatchTransport()
        transport.isAvailable = false
        let relay = WatchRelay(transport: transport)

        relay.publish(state(working: 1))
        relay.publish(state(working: 2))
        relay.publish(state(working: 3))
        XCTAssertEqual(transport.sent.count, 0)

        transport.becomeAvailable()

        XCTAssertEqual(transport.states.map(\.counts.working), [3])
    }

    func testARefusedSendIsRetriedRatherThanLost() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        transport.failNextSends = true
        XCTAssertFalse(relay.publish(state(working: 1)))
        XCTAssertEqual(transport.sent.count, 0)
        XCTAssertNotNil(relay.pending)

        transport.becomeAvailable()

        XCTAssertEqual(transport.states.map(\.counts.working), [1])
        XCTAssertNil(relay.pending)
    }

    func testAStateQueuedWhileUnavailableIsSentEvenIfItMatchesTheLastDelivered() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        relay.publish(state(working: 1))
        transport.isAvailable = false
        relay.publish(state(working: 2))
        transport.becomeAvailable()
        // The Watch went away holding "2"; it must not be left on "1".
        XCTAssertEqual(transport.states.map(\.counts.working), [1, 2])
    }

    func testOnlyTheNewestStateIsLeftWaitingForABackgroundedWatch() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        relay.publish(state(working: 1))
        relay.publish(state(working: 2))
        relay.publish(state(working: 3))

        // Three states were handed over, but a Watch that reads the mailbox now
        // draws the third one once instead of replaying two obsolete screens.
        XCTAssertEqual(transport.states.map(\.counts.working), [1, 2, 3])
        XCTAssertEqual(transport.queuedStates.map(\.counts.working), [3])
    }

    func testDeliveriesArrivingOutOfOrderLeaveTheNewestOnScreen() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        relay.publish(state(working: 1))
        relay.publish(state(working: 2, at: 30))

        var inbox = WatchStateInbox()
        for payload in transport.sent.reversed() { inbox.accept(payload) }

        XCTAssertEqual(inbox.state?.counts.working, 2)
    }

    func testDemoModeRelaysSampleStateWithQuota() async {
        let transport = FakeWatchTransport()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: NullDecisionClient(),
                                   watchRelay: WatchRelay(transport: transport))
        store.startDemo()

        let relayed = transport.states.last
        XCTAssertEqual(relayed?.isDemo, true)
        XCTAssertEqual(relayed?.relay, .live)
        // Attention buckets (`StateGroups`): the failed demo session counts
        // under Needs you, as on every other surface.
        XCTAssertEqual(relayed?.counts.needsResponse, 4)
        XCTAssertEqual(relayed?.counts.working, 3)
        XCTAssertEqual(relayed?.counts.done, 2)
        XCTAssertEqual(relayed?.stuck, 1)
        // The same failed session leads the wrist's results; the unread
        // completions follow it.
        XCTAssertEqual(relayed?.stuckTasks.count, 1)
        XCTAssertEqual(relayed?.unreadResults.isEmpty, false)
        XCTAssertEqual(Set(relayed?.quotas.map(\.provider) ?? []), Set([.codex, .claude, .grok, .cursor, .grokBot]))
        await store.stop().value
    }

    func testResolvingADemoApprovalRelaysTheNewState() async throws {
        let transport = FakeWatchTransport()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: NullDecisionClient(),
                                   watchRelay: WatchRelay(transport: transport))
        store.startDemo()
        let approvalId = try XCTUnwrap(store.allSessions.compactMap(\.pendingApproval).first).id
        let targetID = try XCTUnwrap(store.allSessions.first { $0.pendingApproval?.id == approvalId }).id
        let publishedBeforeDecision = transport.states.count

        store.decide(approvalId, .allow)

        XCTAssertEqual(transport.states.count, publishedBeforeDecision + 1)
        XCTAssertFalse(transport.states.last?.alerts.contains { $0.sessionId == targetID } ?? true)
        XCTAssertEqual(transport.states.last?.counts.needsResponse, 3)
        await store.stop().value
    }

    func testRelayedPayloadCarriesNoPairingSecretsOrSessionCollection() async {
        let transport = FakeWatchTransport()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: NullDecisionClient(),
                                   watchRelay: WatchRelay(transport: transport))
        store.start(PairingPayload(host: "10.0.0.7", port: 9876, token: "s3cr3t-bearer"))
        store.startDemo()

        let json = String(decoding: transport.sent.last ?? Data(), as: UTF8.self)
        for secret in ["10.0.0.7", "9876", "s3cr3t-bearer", "iTerm", "todos.sort", "\"sessions\""] {
            XCTAssertFalse(json.contains(secret), "relay payload leaked \(secret)")
        }
        await store.stop().value
    }

    // MARK: - Decisions coming back from the wrist

    /// The wrist's view of the world, taken from what was actually relayed —
    /// never from the store's internals, because that is all the Watch has.
    private func relayedAlert(_ transport: FakeWatchTransport,
                              decidable: Bool) throws -> WatchAlert {
        let state = try XCTUnwrap(transport.states.last)
        return try XCTUnwrap(state.alerts.first { $0.isDecidable == decidable })
    }

    private func demoStore(_ transport: FakeWatchTransport,
                           decisions: DecisionClient = NullDecisionClient()) -> DashboardStore {
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: decisions,
                                   watchRelay: WatchRelay(transport: transport))
        addTeardownBlock { @MainActor in await store.stop().value }
        store.startDemo()
        return store
    }

    func testAWatchApprovalResolvesTheApprovalAndReportsAccepted() async throws {
        let transport = FakeWatchTransport()
        let store = demoStore(transport)
        let alert = try relayedAlert(transport, decidable: true)
        let approvalId = try XCTUnwrap(alert.approvalId)

        let result = await transport.tap(WatchApprovalRequest(
            attemptId: "t-1", sessionId: alert.sessionId,
            approvalId: approvalId, choice: .allow))

        XCTAssertEqual(result, WatchApprovalResult(attemptId: "t-1", outcome: .accepted))
        XCTAssertFalse(store.allSessions.contains { $0.pendingApproval?.id == approvalId })
        await store.stop().value
    }

    func testARepeatedTapIsNotResubmitted() async throws {
        let transport = FakeWatchTransport()
        let store = demoStore(transport)
        let alert = try relayedAlert(transport, decidable: true)
        let request = WatchApprovalRequest(attemptId: "t-1", sessionId: alert.sessionId,
                                           approvalId: try XCTUnwrap(alert.approvalId),
                                           choice: .allow)

        _ = await transport.tap(request)
        let relayCount = transport.sent.count
        let repeated = await transport.tap(request)

        // Still accepted — the tap did land — but nothing moved a second time.
        XCTAssertEqual(repeated.outcome, .accepted)
        XCTAssertEqual(transport.sent.count, relayCount, "a duplicate tap re-projected nothing")
        await store.stop().value
    }

    func testATapForAnApprovalThatMovedOnIsRefused() async throws {
        let transport = FakeWatchTransport()
        let store = demoStore(transport)
        let alert = try relayedAlert(transport, decidable: true)

        let stale = await transport.tap(WatchApprovalRequest(
            attemptId: "t-1", sessionId: alert.sessionId,
            approvalId: "an-approval-that-already-resolved", choice: .allow))
        XCTAssertEqual(stale.outcome, .refused)

        let wrongSession = await transport.tap(WatchApprovalRequest(
            attemptId: "t-2", sessionId: "demo-work",
            approvalId: try XCTUnwrap(alert.approvalId), choice: .allow))
        XCTAssertEqual(wrongSession.outcome, .refused)
        await store.stop().value
    }

    func testTheRichEditApprovalCannotBeResolvedFromTheWrist() async throws {
        let transport = FakeWatchTransport()
        let store = demoStore(transport)
        let displayOnly = try relayedAlert(transport, decidable: false)
        // Its real approval id, taken from the phone — the Watch was never told it.
        let hidden = try XCTUnwrap(store.allSessions
            .first { $0.id == displayOnly.sessionId }?.pendingApproval?.id)

        let result = await transport.tap(WatchApprovalRequest(
            attemptId: "t-1", sessionId: displayOnly.sessionId,
            approvalId: hidden, choice: .allow))

        XCTAssertEqual(result.outcome, .refused)
        XCTAssertTrue(store.allSessions.contains { $0.pendingApproval?.id == hidden })
        await store.stop().value
    }

    func testAnUnreachableMacReportsFailedWithoutSendingDecision() async throws {
        let transport = FakeWatchTransport()
        let decisions = UnreachableDecisionClient()
        let sampleStore = demoStore(FakeWatchTransport())
        let samples = sampleStore.allSessions
        await sampleStore.stop().value
        let store = DashboardStore(
            streamer: ScriptedStreamer(snapshots: [Snapshot(sessions: samples, serverTime: Date())]),
            notifier: SilentNotifier(), decisionClient: decisions,
            watchRelay: WatchRelay(transport: transport), reportDevice: { _ in })
        // An authenticated snapshot supplies the waiting task. Switching from
        // sample data to a pairing intentionally clears the previous source.
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        for _ in 0..<50 {
            if !store.allSessions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let alert = try relayedAlert(transport, decidable: true)
        let request = WatchApprovalRequest(attemptId: "t-1", sessionId: alert.sessionId,
                                           approvalId: try XCTUnwrap(alert.approvalId),
                                           choice: .allow)

        let first = await transport.tap(request)
        XCTAssertEqual(first.outcome, .failed)
        // Not remembered as handled, so the user can try the same tap again.
        let second = await transport.tap(request)
        XCTAssertEqual(second.outcome, .failed)
        let attempts = await decisions.attempts
        XCTAssertEqual(attempts, 0, "No decision is sent without a fresh authenticated snapshot")
        await store.stop().value
    }

    // MARK: - Stopping a running turn from the wrist

    /// A running Codex turn the Mac's app-server connection is carrying: the
    /// one shape a stop exists for.
    private func runningCodex(id: String = "task-run",
                              agent: AgentKind = .codex,
                              startedAt: Date) -> AgentSession {
        AgentSession(id: id, agent: agent, project: "vibebuddy", branch: "main",
                     model: "gpt-5-codex", status: .working, summary: "Running the test suite…",
                     observations: [ObservationEvidence(source: .appserver,
                                                        lastObservedAt: startedAt, health: .healthy)],
                     attention: .followed,
                     statusSince: startedAt, updatedAt: startedAt)
    }

    /// A store fed one authenticated snapshot, with a Mac that answers stops
    /// however the test says it does.
    private func connectedStore(_ transport: FakeWatchTransport,
                                sessions: [AgentSession],
                                client: StoppingDecisionClient) async throws -> DashboardStore {
        let snapshot = Snapshot(sessions: sessions, serverTime: now, sourceID: "fixture-mac")
        await client.replaceSnapshot(snapshot)
        let store = DashboardStore(streamer: ScriptedStreamer(snapshots: [snapshot]),
                                   notifier: SilentNotifier(), decisionClient: client,
                                   watchRelay: WatchRelay(transport: transport), reportDevice: { _ in })
        addTeardownBlock { @MainActor in await store.stop().value }
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "fixture"))
        for _ in 0..<100 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        return store
    }

    /// The stop the wrist would actually send, taken from what was relayed to
    /// it — never from the store's internals, because that is all the Watch has.
    private func relayedStop(_ transport: FakeWatchTransport,
                             sessionID: String,
                             attempt: String = "t-1") throws -> WatchSessionActionRequest {
        let state = try XCTUnwrap(transport.states.last)
        let task = try XCTUnwrap(state.followedTasks.first { $0.sessionID == sessionID })
        XCTAssertEqual(task.stop, .offered, "the wrist was not offered a Stop to send")
        var action = WatchSessionActionState()
        return try XCTUnwrap(action.begin(stop: task, attemptId: attempt))
    }

    func testAStopIsForwardedOnceAndAcceptedIsNotStopped() async throws {
        let transport = FakeWatchTransport()
        let client = StoppingDecisionClient(stop: .accepted)
        let started = now.addingTimeInterval(-30)
        let store = try await connectedStore(transport, sessions: [runningCodex(startedAt: started)],
                                             client: client)
        let request = try relayedStop(transport, sessionID: "task-run")

        let result = await transport.tap(request)
        XCTAssertEqual(result.outcome, .accepted)
        var stops = await client.stops
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.sessionID, "task-run")
        XCTAssertEqual(stops.first?.statusSince, started, "the stop named the turn the wrist was shown")
        // Accepted is not stopped: the phone's own copy still says working, and
        // the relayed offer is unchanged until the Mac says otherwise.
        XCTAssertEqual(store.allSessions.first?.status, .working)
        XCTAssertEqual(transport.states.last?.followedTasks.first?.stop, .offered)

        // The same tap again interrupts nothing a second time.
        let repeated = await transport.tap(request)
        XCTAssertEqual(repeated.outcome, .accepted)
        stops = await client.stops
        XCTAssertEqual(stops.count, 1)
    }

    func testAStopAimedAtATurnThatMovedOnIsRefusedWithoutReachingTheMac() async throws {
        let transport = FakeWatchTransport()
        let client = StoppingDecisionClient(stop: .accepted)
        let store = try await connectedStore(transport,
                                             sessions: [runningCodex(startedAt: now.addingTimeInterval(-30))],
                                             client: client)
        let stale = try relayedStop(transport, sessionID: "task-run")
        // The Mac's own copy has moved on to the next turn.
        await client.replaceSnapshot(Snapshot(sessions: [runningCodex(startedAt: now)],
                                              serverTime: now, sourceID: "fixture-mac"))

        let result = await transport.tap(stale)

        XCTAssertEqual(result.outcome, .refused)
        let stops = await client.stops
        XCTAssertTrue(stops.isEmpty, "a stale stop must not reach the Mac at all")
        _ = store
    }

    func testTheMacsRefusalAndAFailedInterruptAreDifferentAnswers() async throws {
        // Both are a 409 on the wire and they mean opposite things on a wrist:
        // "look at the task" against "that can be tapped again".
        for (delivery, expected) in [(StopDelivery.refused, WatchSessionActionOutcome.refused),
                                     (StopDelivery.failed, WatchSessionActionOutcome.failed),
                                     (StopDelivery.unconfirmed, WatchSessionActionOutcome.unknown)] {
            let transport = FakeWatchTransport()
            let client = StoppingDecisionClient(stop: delivery)
            _ = try await connectedStore(transport,
                                         sessions: [runningCodex(startedAt: now.addingTimeInterval(-30))],
                                         client: client)
            let request = try relayedStop(transport, sessionID: "task-run")

            let result = await transport.tap(request)
            XCTAssertEqual(result.outcome, expected, "\(delivery) must read as \(expected)")
            let stops = await client.stops
            XCTAssertEqual(stops.count, 1)

            // Nothing was committed either way, so the tap stays retryable —
            // and it is safe, because the daemon re-checks the same turn.
            let again = await transport.tap(request)
            XCTAssertEqual(again.outcome, expected)
            let retried = await client.stops
            XCTAssertEqual(retried.count, 2)
        }
    }

    func testAnAgentThatCannotBeStoppedRemotelyOffersNoStopAndSendsNone() async throws {
        let transport = FakeWatchTransport()
        let client = StoppingDecisionClient(stop: .accepted)
        let started = now.addingTimeInterval(-30)
        _ = try await connectedStore(transport,
                                     sessions: [runningCodex(id: "task-claude", agent: .claudeCode,
                                                             startedAt: started)],
                                     client: client)
        let state = try XCTUnwrap(transport.states.last)
        let task = try XCTUnwrap(state.followedTasks.first)
        XCTAssertEqual(task.stop, .blocked(.macOnly))
        XCTAssertEqual(task.stop?.block?.message(agent: .claudeCode), "Stop this on your Mac.")

        // Even a hand-made message naming the right turn: the rule is re-run
        // here, not trusted from the wrist.
        let forged = WatchSessionActionRequest(attemptId: "t-1", sessionId: "task-claude",
                                               action: .stop(statusSince: started))
        let result = await transport.tap(forged)
        XCTAssertEqual(result.outcome, .refused)
        let stops = await client.stops
        XCTAssertTrue(stops.isEmpty)
    }

    func testTheMacsOwnWordForTheOutcomeIsWhatIsRead() {
        // Both `refused` and `failed` arrive as a 409, so the body's `status`
        // is the only thing that tells them apart. `unknown` is the daemon
        // saying the interrupt went out and the connection died before it could
        // confirm — only the next snapshot can settle whether it stopped.
        XCTAssertEqual(StopDelivery(status: "accepted"), .accepted)
        XCTAssertEqual(StopDelivery(status: "unknown"), .unconfirmed)
        XCTAssertEqual(StopDelivery(status: "refused"), .refused)
        XCTAssertEqual(StopDelivery(status: "failed"), .failed)
        // An unreadable receipt cannot prove success or that nothing happened.
        XCTAssertEqual(StopDelivery(status: nil), .unconfirmed)
        XCTAssertEqual(StopDelivery(status: ""), .unconfirmed)
        XCTAssertEqual(StopDelivery(status: "Accepted"), .unconfirmed)
    }

    func testADemoStopEndsTheSampleTurnThroughTheSameRelay() async throws {
        let transport = FakeWatchTransport()
        let store = demoStore(transport)
        let request = try relayedStop(transport, sessionID: "demo-work")

        let result = await transport.tap(request)

        XCTAssertEqual(result.outcome, .accepted)
        let stopped = try XCTUnwrap(store.allSessions.first { $0.id == "demo-work" })
        XCTAssertEqual(stopped.status, .done)
        // The Mac marks an acknowledged user stop without error or unread completion.
        XCTAssertEqual(stopped.failed, false)
        XCTAssertEqual(stopped.userStopped, true)
        XCTAssertFalse(stopped.hasUnreadCompletion)
        let relayed = try XCTUnwrap(transport.states.last?.followedTasks.first { $0.sessionID == "demo-work" })
        XCTAssertNil(relayed.stop, "the offer goes away because the world changed")
        await store.stop().value
    }

    // MARK: - Answering a question from the wrist

    /// A Codex question the Mac says can be answered remotely: the one shape a
    /// quick answer exists for.
    private func askingCodex(id: String = "task-ask",
                             questionID: String = "q-1",
                             answerable: Bool = true,
                             at moment: Date) -> AgentSession {
        AgentSession(id: id, agent: .codex, project: "docs-review", model: "gpt-5-codex",
                     status: .needsResponse, waitKind: .question,
                     pendingQuestion: PendingQuestion(id: questionID,
                                                      prompt: "Which tone?",
                                                      options: [QuestionOption(id: "t", label: "Tighten")],
                                                      answerable: answerable),
                     attention: .followed,
                     statusSince: moment, updatedAt: moment)
    }

    private func answeringStore(_ transport: FakeWatchTransport,
                                sessions: [AgentSession],
                                client: AnsweringDecisionClient) async throws -> DashboardStore {
        let snapshot = Snapshot(sessions: sessions, serverTime: now, sourceID: "fixture-mac")
        await client.replaceSnapshot(snapshot)
        let store = DashboardStore(streamer: ScriptedStreamer(snapshots: [snapshot]),
                                   notifier: SilentNotifier(), decisionClient: client,
                                   watchRelay: WatchRelay(transport: transport), reportDevice: { _ in })
        addTeardownBlock { @MainActor in await store.stop().value }
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "fixture", macName: "My Mac"))
        for _ in 0..<100 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        return store
    }

    /// The answer the wrist would actually send: the quick reply it was offered,
    /// begun through the same state machine, from the alert it was relayed.
    private func relayedAnswer(_ transport: FakeWatchTransport,
                               sessionID: String,
                               attempt: String = "t-1") throws -> WatchSessionActionRequest {
        let state = try XCTUnwrap(transport.states.last)
        let alert = try XCTUnwrap(state.alerts.first { $0.sessionId == sessionID })
        let choices = try XCTUnwrap(WatchQuickAnswers.resolve(for: alert),
                                    "the wrist was offered no answer to send")
        let reply = try XCTUnwrap(choices.replies.first)
        var action = WatchSessionActionState()
        return try XCTUnwrap(action.begin(alert: alert, answer: reply.text, attemptId: attempt))
    }

    func testAnAnswerIsForwardedOnceAsTheTextTheWristWasShown() async throws {
        let transport = FakeWatchTransport()
        let client = AnsweringDecisionClient(answer: .received)
        let store = try await answeringStore(transport, sessions: [askingCodex(at: now)],
                                             client: client)
        // The Mac's own name reached the wrist, so the confirmation page can
        // name where the answer is going.
        XCTAssertEqual(transport.states.last?.macName, "My Mac")
        let request = try relayedAnswer(transport, sessionID: "task-ask")

        let result = await transport.tap(request)

        XCTAssertEqual(result.outcome, .accepted)
        var answers = await client.answers
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.sessionID, "task-ask")
        XCTAssertEqual(answers.first?.questionID, "q-1")
        XCTAssertEqual(answers.first?.text, "Tighten", "what was shown is what was sent")
        XCTAssertNil(answers.first?.answers, "the wrist sends free text, never a structured pick")
        // Accepted is not answered: the phone's own copy still says waiting.
        XCTAssertEqual(store.allSessions.first?.status, .needsResponse)

        // The same tap again answers nothing a second time.
        let repeated = await transport.tap(request)
        XCTAssertEqual(repeated.outcome, .accepted)
        answers = await client.answers
        XCTAssertEqual(answers.count, 1)
    }

    func testAnAnswerToAQuestionTheMacAlreadyAnsweredIsRefusedWithoutReachingIt() async throws {
        let transport = FakeWatchTransport()
        let client = AnsweringDecisionClient(answer: .received)
        _ = try await answeringStore(transport, sessions: [askingCodex(at: now)], client: client)
        let stale = try relayedAnswer(transport, sessionID: "task-ask")

        // Answered on the Mac while the wrist was still looking at the card.
        var moved = askingCodex(at: now)
        moved.status = .working
        moved.waitKind = nil
        moved.pendingQuestion = nil
        await client.replaceSnapshot(Snapshot(sessions: [moved], serverTime: now,
                                              sourceID: "fixture-mac"))

        let result = await transport.tap(stale)

        XCTAssertEqual(result.outcome, .refused)
        let answers = await client.answers
        XCTAssertTrue(answers.isEmpty, "a question that is gone must not be answered at all")
    }

    func testAnAnswerAimedAtTheNextQuestionOfTheSameSessionIsRefused() async throws {
        let transport = FakeWatchTransport()
        let client = AnsweringDecisionClient(answer: .received)
        _ = try await answeringStore(transport, sessions: [askingCodex(at: now)], client: client)
        let stale = try relayedAnswer(transport, sessionID: "task-ask")

        // Still waiting, but on a different question. An expired answer must
        // not be re-pointed at whatever is being asked now.
        await client.replaceSnapshot(Snapshot(sessions: [askingCodex(questionID: "q-2", at: now)],
                                              serverTime: now, sourceID: "fixture-mac"))

        let result = await transport.tap(stale)

        XCTAssertEqual(result.outcome, .refused)
        let answers = await client.answers
        XCTAssertTrue(answers.isEmpty)
    }

    func testAReadOnlyQuestionOffersNoAnswerAndSendsNone() async throws {
        let transport = FakeWatchTransport()
        let client = AnsweringDecisionClient(answer: .received)
        _ = try await answeringStore(transport,
                                     sessions: [askingCodex(answerable: false, at: now)],
                                     client: client)
        let alert = try XCTUnwrap(transport.states.last?.alerts.first)
        XCTAssertFalse(alert.isAnswerable)
        XCTAssertNil(WatchQuickAnswers.resolve(for: alert))
        XCTAssertEqual(alert.handling, .macNativePrompt, "the card keeps saying where to answer")

        // Even a hand-made message naming the right question: the rule is
        // re-run here, not trusted from the wrist.
        let forged = WatchSessionActionRequest(attemptId: "t-1", sessionId: "task-ask",
                                               action: .answer(pendingId: "q-1", text: "Tighten"))
        let result = await transport.tap(forged)
        XCTAssertEqual(result.outcome, .refused)
        let answers = await client.answers
        XCTAssertTrue(answers.isEmpty)
    }

    func testTheMacsThreeAnswersAreThreeDifferentThingsOnAWrist() async throws {
        // `expired` says stop tapping; `failed` says nothing was said to the
        // agent, so try again; `unconfirmed` is the Mac's reply going missing
        // after a request it may well have carried out — the one case where
        // "that didn't send" would be a lie.
        for (delivery, expected) in [(PhoneActionResult.expired, WatchSessionActionOutcome.refused),
                                     (PhoneActionResult.failed, WatchSessionActionOutcome.failed),
                                     (PhoneActionResult.unconfirmed, WatchSessionActionOutcome.unknown)] {
            let transport = FakeWatchTransport()
            let client = AnsweringDecisionClient(answer: delivery)
            _ = try await answeringStore(transport, sessions: [askingCodex(at: now)], client: client)
            let request = try relayedAnswer(transport, sessionID: "task-ask")

            let result = await transport.tap(request)
            XCTAssertEqual(result.outcome, expected, "\(delivery) must read as \(expected)")

            // Nothing was committed for any of the three, so the same tap is
            // still admitted — the daemon's own `requestId` de-duplication is
            // what stops a second delivery, which is why the tap carries it.
            let again = await transport.tap(request)
            XCTAssertEqual(again.outcome, expected)
            let answers = await client.answers
            XCTAssertEqual(answers.count, 2)
            XCTAssertEqual(Set(answers.map(\.requestID)), ["t-1"],
                           "one gesture keeps one request id, so the Mac can tell a replay")
        }
    }

    func testAMultiPartQuestionOffersNoQuickAnswerAndSendsNone() async throws {
        // One string cannot finish three questions: a free-text answer lands on
        // the first item and the agent reads the rest as unanswered.
        let transport = FakeWatchTransport()
        let client = AnsweringDecisionClient(answer: .received)
        var many = askingCodex(at: now)
        many.pendingQuestion = PendingQuestion(
            id: "q-1", prompt: "Which tone?",
            questions: [QuestionItem(id: "a", text: "Which tone?",
                                     options: [QuestionOption(id: "t", label: "Tighten")]),
                        QuestionItem(id: "b", text: "Ship it today?")])
        _ = try await answeringStore(transport, sessions: [many], client: client)

        let alert = try XCTUnwrap(transport.states.last?.alerts.first)
        XCTAssertNil(alert.pendingId, "the wrist is given no identity it could act on")
        XCTAssertFalse(alert.isAnswerable)
        XCTAssertNil(WatchQuickAnswers.resolve(for: alert))
        // The wait is still remotely answerable — just not from here.
        XCTAssertEqual(alert.handling, .remoteAvailable)

        let forged = WatchSessionActionRequest(attemptId: "t-1", sessionId: "task-ask",
                                               action: .answer(pendingId: "q-1", text: "Tighten"))
        let result = await transport.tap(forged)
        XCTAssertEqual(result.outcome, .refused)
        let answers = await client.answers
        XCTAssertTrue(answers.isEmpty)
    }

    func testAWalkedPromptIsForwardedOnceAsStructuredAnswers() async throws {
        // Cursor's usual AskQuestion: every question offers choices, so the
        // wrist walks them and the phone forwards the set the way its own
        // card would — structured, keyed by question, never as one string.
        let transport = FakeWatchTransport()
        let client = AnsweringDecisionClient(answer: .received)
        var walked = askingCodex(at: now)
        walked.pendingQuestion = PendingQuestion(
            id: "q-1", prompt: "Which tone?",
            questions: [QuestionItem(id: "tone", text: "Which tone?",
                                     options: [QuestionOption(id: "t", label: "Tighten"),
                                               QuestionOption(id: "p", label: "Plain language", value: "plain")]),
                        QuestionItem(id: "files", text: "Which files?",
                                     options: [QuestionOption(id: "x", label: "README"),
                                               QuestionOption(id: "y", label: "CHANGELOG")],
                                     multiSelect: true)])
        let store = try await answeringStore(transport, sessions: [walked], client: client)

        let alert = try XCTUnwrap(transport.states.last?.alerts.first)
        XCTAssertEqual(alert.pendingId, "q-1")
        XCTAssertTrue(alert.isAnswerable)
        XCTAssertEqual(alert.questions?.map(\.id), ["tone", "files"])
        XCTAssertNil(WatchQuickAnswers.resolve(for: alert), "not one string")

        var action = WatchSessionActionState()
        let request = try XCTUnwrap(action.begin(
            alert: alert, answers: ["tone": ["plain"], "files": ["CHANGELOG", "README"]], attemptId: "t-1"))
        let result = await transport.tap(request)

        XCTAssertEqual(result.outcome, .accepted)
        let answers = await client.answers
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.questionID, "q-1")
        XCTAssertNil(answers.first?.text)
        XCTAssertEqual(answers.first?.answers, ["tone": ["plain"], "files": ["README", "CHANGELOG"]])
        XCTAssertEqual(store.allSessions.first?.status, .needsResponse, "accepted is not answered")

        // A set missing a question never gets past the gate, even hand-made.
        let partial = WatchSessionActionRequest(attemptId: "t-2", sessionId: "task-ask",
                                                action: .answerAll(pendingId: "q-1", answers: ["tone": ["plain"]]))
        let refused = await transport.tap(partial)
        XCTAssertEqual(refused.outcome, .refused)
        let still = await client.answers
        XCTAssertEqual(still.count, 1)
    }

    func testADemoAnswerClearsTheSampleQuestionThroughTheSameRelay() async throws {
        let transport = FakeWatchTransport()
        let store = demoStore(transport)
        let asking = try XCTUnwrap(transport.states.last?.alerts.first { $0.isAnswerable })
        let request = try relayedAnswer(transport, sessionID: asking.sessionId)

        let result = await transport.tap(request)

        XCTAssertEqual(result.outcome, .accepted)
        let answered = try XCTUnwrap(store.allSessions.first { $0.id == asking.sessionId })
        XCTAssertEqual(answered.status, .working)
        XCTAssertNil(answered.pendingQuestion)
        let relayed = try XCTUnwrap(transport.states.last)
        XCTAssertFalse(relayed.alerts.contains { $0.sessionId == asking.sessionId },
                       "the card goes away because the world changed")
        await store.stop().value
    }
}

/// A Mac that answers a question however the test says, and remembers exactly
/// what it was asked to answer.
private final class AnsweringDecisionClient: DecisionClient, @unchecked Sendable {
    struct Answer: Equatable, Sendable {
        let sessionID: String
        let questionID: String?
        let text: String?
        let answers: QuestionAnswers?
        let requestID: String
    }

    private let lock = NSLock()
    private var _snapshot: Snapshot?
    private var _answers: [Answer] = []
    private let outcome: PhoneActionResult

    init(answer: PhoneActionResult) { outcome = answer }

    var answers: [Answer] { lock.withLock { _answers } }

    func replaceSnapshot(_ snapshot: Snapshot) { lock.withLock { _snapshot = snapshot } }

    func actionSnapshot(_ pairing: PairingPayload) async -> Snapshot? { lock.withLock { _snapshot } }

    func phoneAnswer(_ pairing: PairingPayload, session: AgentSession, text: String?,
                     answers: QuestionAnswers?, requestID: String) async -> PhoneActionResult {
        lock.withLock {
            _answers.append(Answer(sessionID: session.id, questionID: session.pendingQuestion?.id,
                                   text: text, answers: answers, requestID: requestID))
        }
        return outcome
    }

    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome { .accepted }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { true }
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}

/// A Mac that answers a stop however the test says, and remembers exactly what
/// it was asked to stop.
private final class StoppingDecisionClient: DecisionClient, @unchecked Sendable {
    struct Stop: Equatable, Sendable {
        let sessionID: String
        let statusSince: Date
        let requestID: String
    }

    private let lock = NSLock()
    private var _snapshot: Snapshot?
    private var _stops: [Stop] = []
    private let outcome: StopDelivery

    init(stop: StopDelivery) { outcome = stop }

    var stops: [Stop] { lock.withLock { _stops } }

    func replaceSnapshot(_ snapshot: Snapshot) { lock.withLock { _snapshot = snapshot } }

    func actionSnapshot(_ pairing: PairingPayload) async -> Snapshot? { lock.withLock { _snapshot } }

    func phoneStop(_ pairing: PairingPayload, session: AgentSession, requestID: String) async -> StopDelivery {
        lock.withLock {
            _stops.append(Stop(sessionID: session.id, statusSince: session.statusSince,
                               requestID: requestID))
        }
        return outcome
    }

    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome { .accepted }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { true }
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}
