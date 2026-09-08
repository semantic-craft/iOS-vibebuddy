import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

private actor DecisionRecorder: DecisionClient {
    private(set) var sentActions = 0
    private(set) var acknowledgedSessionIDs: [String] = []
    private(set) var waitRequests: [WaitReadRequest] = []
    func acknowledgeWait(_ pairing: PairingPayload, request: WaitReadRequest) async -> Bool {
        waitRequests.append(request)
        return true
    }
    private(set) var completionRequests: [CompletionReadRequest] = []
    private(set) var attentions: [(sessionId: String, level: SessionAttention?)] = []
    private(set) var recentOutputIDs: [String] = []
    private var nextOutput: RecentOutput?
    private var heldOutput: CheckedContinuation<RecentOutput?, Never>?
    private var hold = false
    func holdNextOutput() { hold = true }
    func outputIsHeld() -> Bool { heldOutput != nil }
    func releaseOutput() { heldOutput?.resume(returning: nextOutput); heldOutput = nil }

    func setNext(_ output: RecentOutput) { nextOutput = output }

    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome {
        acknowledgedSessionIDs.append(request.sessionID)
        completionRequests.append(request)
        return .accepted
    }

    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {
        attentions.append((sessionId, level))
    }

    func recentOutput(_ pairing: PairingPayload, sessionId: String) async -> RecentOutput? {
        recentOutputIDs.append(sessionId)
        if hold { return await withCheckedContinuation { heldOutput = $0 } }
        return nextOutput ?? RecentOutput(sessionId: sessionId, source: .transcript)
    }

    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { sentActions += 1; return true }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async { sentActions += 1 }
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
}



@MainActor
final class DashboardStoreTests: XCTestCase {
    func testColdStartDeepLinkDoesNotAcknowledgeAnUnseenRound() async throws {
        let decisions = DecisionRecorder()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: decisions)

        store.open(VibeBuddyDeepLink.sessionURL(id: "completed-task"))
        let beforeStart = await decisions.acknowledgedSessionIDs
        XCTAssertEqual(beforeStart, [])

        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        for _ in 0..<50 {
            if !(await decisions.acknowledgedSessionIDs).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let afterStart = await decisions.acknowledgedSessionIDs
        XCTAssertEqual(afterStart, [])
        await store.stop().value
    }

    func testWatchAcknowledgementCarriesExactRoundAndRejectsAnotherSource() async throws {
        let decisions = DecisionRecorder()
        let now = Date()
        var completed = AgentSession(id: "task", agent: .claudeCode, project: "Task",
                                     status: .done, hasUnreadCompletion: true,
                                     statusSince: now, updatedAt: now)
        completed.completionID = "round-1"
        let store = DashboardStore(
            streamer: ScriptedStreamer(snapshots: [Snapshot(sessions: [completed], serverTime: now, sourceID: "mac-a")]),
            notifier: SilentNotifier(), decisionClient: decisions, watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        for _ in 0..<50 {
            if !store.allSessions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let epoch = ConnectionStore.pairingEpoch
        let wrong = WatchTaskLink(sourceID: "mac-b", pairingEpoch: epoch, sessionID: "task", completionID: "round-1")
        let refused = await store.acknowledgeFromWatch(WatchCompletionRequest(attemptID: "wrong", link: wrong))
        XCTAssertEqual(refused.outcome, .sourceMismatch)
        // Local explicit selection captures this exact visible result.
        store.acknowledge("task")
        await Task.yield()
        let unopened = await decisions.completionRequests
        XCTAssertTrue(unopened.isEmpty)
        store.acknowledge("task", displayedCompletion: store.completionRequest(for: completed))
        for _ in 0..<50 {
            if !(await decisions.completionRequests).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await decisions.completionRequests
        XCTAssertEqual(sent, [CompletionReadRequest(sourceID: "mac-a", sessionID: "task", completionID: "round-1")])
        await store.stop().value
    }

    func testPhoneAndWatchReadTheExactWaitWithoutAnsweringIt() async throws {
        let decisions = DecisionRecorder()
        let now = Date()
        let waiting = AgentSession(id: "task", agent: .claudeCode, project: "Task",
                                   status: .needsResponse, waitKind: .question,
                                   statusSince: now, updatedAt: now)
        let store = DashboardStore(
            streamer: ScriptedStreamer(snapshots: [Snapshot(sessions: [waiting], serverTime: now, sourceID: "mac-a")]),
            notifier: SilentNotifier(), decisionClient: decisions, watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        for _ in 0..<50 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        store.acknowledge("task")
        for _ in 0..<50 {
            if !(await decisions.waitRequests).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let read = WaitReadRequest(sourceID: "mac-a", sessionID: "task", statusSince: now, waitKind: .question)
        let epoch = ConnectionStore.pairingEpoch
        let rejected = await store.acknowledgeWaitFromWatch(WatchWaitReadRequest(pairingEpoch: "other", read: read))
        XCTAssertFalse(rejected)
        let accepted = await store.acknowledgeWaitFromWatch(WatchWaitReadRequest(pairingEpoch: epoch, read: read))
        XCTAssertTrue(accepted)
        let sent = await decisions.waitRequests
        XCTAssertEqual(sent, [read, read])
        let completions = await decisions.completionRequests
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(store.allSessions.first?.status, .needsResponse)
        await store.stop().value
    }

    func testFollowFlipsTheRowAtOnceAndTellsTheMac() async throws {
        let decisions = DecisionRecorder()
        let t = Date(timeIntervalSince1970: 0)
        let working = AgentSession(id: "s", agent: .claudeCode, project: "p",
                                   status: .working, statusSince: t, updatedAt: t)
        let store = DashboardStore(
            streamer: ScriptedStreamer(snapshots: [Snapshot(sessions: [working], serverTime: t)]),
            notifier: SilentNotifier(), decisionClient: decisions, watchRelay: nil)
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        for _ in 0..<50 {
            if !store.allSessions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.allSessions.first?.effectiveAttention, .normal)

        store.setAttention("s", .followed)
        XCTAssertEqual(store.allSessions.first?.effectiveAttention, .followed)
        XCTAssertEqual(store.allSessions.first?.attentionOverride, .followed)
        for _ in 0..<50 {
            if !(await decisions.attentions).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await decisions.attentions
        XCTAssertEqual(sent.map(\.sessionId), ["s"])
        XCTAssertEqual(sent.map(\.level), [.followed])
        await store.stop().value
    }

    /// The Mac's device registry can be emptied by a Mac restart while this app
    /// is only backgrounded. Reporting once per launch left the Mac unable to
    /// push until the phone next cold-launched; every reconnect must repair it.
    /// The Mac's device registry can be emptied by a Mac restart while this app
    /// is only backgrounded. Reporting once per launch left the Mac unable to
    /// push until the phone next cold-launched; every reconnect must repair it.
    func testEveryReconnectReReportsTheDeviceToTheMac() async throws {
        var reports: [PairingPayload] = []
        let store = DashboardStore(
            streamer: EmptyStreamer(),      // finishes at once → the reconnect loop
            notifier: SilentNotifier(), decisionClient: NullDecisionClient(),
            watchRelay: nil, reportDevice: { reports.append($0) })

        let pairing = PairingPayload(host: "127.0.0.1", port: 9, token: "test")
        store.start(pairing)
        for _ in 0..<500 {
            if reports.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.stop().value

        XCTAssertGreaterThanOrEqual(reports.count, 2)
        XCTAssertEqual(reports.first?.host, "127.0.0.1")
    }

    func testDelayedOutputCannotCrossPairing() async throws {
        let decisions = DecisionRecorder()
        await decisions.setNext(RecentOutput(sessionId: "s", entries: [.init(role: "assistant", text: "old Mac")]))
        await decisions.holdNextOutput()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(), decisionClient: decisions, watchRelay: nil)
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "old"))
        let read = Task { await store.loadRecentOutput("s") }
        while !(await decisions.outputIsHeld()) { await Task.yield() }
        store.start(PairingPayload(host: "127.0.0.2", port: 9, token: "new"))
        await decisions.releaseOutput()
        await read.value
        XCTAssertNil(store.recentOutputs["s"])
        await store.stop().value
    }

    func testLoadingRecentOutputDoesNotAcknowledgeCompletion() async throws {
        let decisions = DecisionRecorder()
        await decisions.setNext(RecentOutput(
            sessionId: "s", source: .transcript,
            entries: [RecentOutputEntry(role: "assistant", text: "done")]))
        let t = Date(timeIntervalSince1970: 0)
        let done = AgentSession(id: "s", agent: .claudeCode, project: "p",
                                status: .done, hasUnreadCompletion: true,
                                statusSince: t, updatedAt: t)
        let store = DashboardStore(
            streamer: ScriptedStreamer(snapshots: [Snapshot(sessions: [done], serverTime: t)]),
            notifier: SilentNotifier(), decisionClient: decisions, watchRelay: nil)
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        for _ in 0..<50 {
            if !store.allSessions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        await store.loadRecentOutput("s")
        XCTAssertEqual(store.recentOutputs["s"]?.entries.map(\.text), ["done"])
        XCTAssertEqual(store.allSessions.first?.hasUnreadCompletion, true)
        let acknowledged = await decisions.acknowledgedSessionIDs
        XCTAssertEqual(acknowledged, [])
        await store.stop().value
    }
}

private final class PausedReadNotifier: AttentionNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    var isPaused: Bool { lock.withLock { continuation != nil } }
    func requestAuthorization() {}
    func withdraw(_ identifiers: [String]) {}
    func confirmPairing() {}
    func notify(_ alert: SoundAlert) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }
    func release() {
        let saved = lock.withLock {
            let saved = continuation
            continuation = nil
            return saved
        }
        saved?.resume(returning: true)
    }
}

private struct SwitchingReadStreamer: SnapshotStreaming {
    func stream(_ pairing: PairingPayload) -> AsyncStream<Snapshot> {
        let now = Date()
        return AsyncStream { continuation in
            if pairing.host == "old" {
                continuation.yield(Snapshot(sessions: [], serverTime: now, sourceID: "old"))
                let waiting = AgentSession(id: "wait", agent: .claudeCode, project: "Wait",
                    status: .needsResponse, waitKind: .question, statusSince: now, updatedAt: now)
                continuation.yield(Snapshot(sessions: [waiting], serverTime: now, sourceID: "old"))
            } else {
                var done = AgentSession(id: "task", agent: .claudeCode, project: "Task", status: .done,
                    hasUnreadCompletion: true, statusSince: now, updatedAt: now)
                done.completionID = "new-round"
                continuation.yield(Snapshot(sessions: [done], serverTime: now, sourceID: "new"))
            }
        }
    }
}

extension DashboardStoreTests {
    func testOldSnapshotCannotRetireNewSourceReadAfterNotificationSuspension() async throws {
        let notifier = PausedReadNotifier()
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let reads = PhoneCompletionReads(url: url)
        let store = DashboardStore(streamer: SwitchingReadStreamer(), notifier: notifier,
                                   decisionClient: NullDecisionClient(), watchRelay: nil,
                                   completionReads: reads, reportDevice: { _ in })
        addTeardownBlock { @MainActor in
            notifier.release()
            await store.stop().value
        }
        store.start(PairingPayload(host: "old", port: 9, token: "test"))
        for _ in 0..<100 where !notifier.isPaused { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(notifier.isPaused)
        store.start(PairingPayload(host: "new", port: 9, token: "test"))
        for _ in 0..<100 where store.allSessions.first?.id != "task" { try await Task.sleep(for: .milliseconds(10)) }
        reads.pause()
        let request = CompletionReadRequest(sourceID: "new", sessionID: "task", completionID: "new-round")
        try reads.viewed(request, epoch: ConnectionStore.pairingEpoch)
        notifier.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reads.entries.map(\.request), [request])
        XCTAssertEqual(store.allSessions.first?.id, "task")
    }
}

private actor PhoneActionRecorder: DecisionClient {
    var snapshot: Snapshot
    var outcome: PhoneActionResult
    private(set) var sent = 0
    init(snapshot: Snapshot, outcome: PhoneActionResult) { self.snapshot = snapshot; self.outcome = outcome }
    var holdSnapshot = false
    var heldSnapshot: CheckedContinuation<Snapshot?, Never>?
    func pauseSnapshot() { holdSnapshot = true }
    func snapshotIsHeld() -> Bool { heldSnapshot != nil }
    func releaseSnapshot() { heldSnapshot?.resume(returning: snapshot); heldSnapshot = nil }
    func replaceSnapshot(_ next: Snapshot) { snapshot = next }
    func actionSnapshot(_ pairing: PairingPayload) async -> Snapshot? {
        if holdSnapshot { return await withCheckedContinuation { heldSnapshot = $0 } }
        return snapshot
    }
    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> PhoneActionResult {
        sent += 1
        try? await Task.sleep(for: .milliseconds(30))
        return outcome
    }
    func phoneAnswer(_ pairing: PairingPayload, session: AgentSession, text: String?,
                     answers: QuestionAnswers?, requestID: String) async -> PhoneActionResult {
        sent += 1
        return outcome
    }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { sent += 1; return outcome == .received }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome { .failed }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}

extension DashboardStoreTests {
    func testVoiceWaitsForReceiptAndAmbiguousActionIsNotReplayed() async throws {
        let now = Date()
        let session = AgentSession(id: "fixture", agent: .claudeCode, project: "Fixture",
                                   status: .needsResponse, waitKind: .permission,
                                   pendingApproval: PendingApproval(id: "fixture-wait", tool: "Bash", commandPreview: "fixture only"),
                                   statusSince: now, updatedAt: now)
        let snapshot = Snapshot(sessions: [session], serverTime: now, sourceID: "fixture-mac")
        let client = PhoneActionRecorder(snapshot: snapshot, outcome: .unconfirmed)
        let store = DashboardStore(streamer: ScriptedStreamer(snapshots: [snapshot]), notifier: SilentNotifier(),
                                   decisionClient: client, watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "fixture"))
        for _ in 0..<100 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let result = Task { await store.performVoiceAction(.approve(project: "Fixture")) }
        for _ in 0..<100 where store.phoneActionState(for: session) == nil { await Task.yield() }
        XCTAssertEqual(store.phoneActionState(for: session), .sending)
        let duplicate = await store.decideConfirmed("fixture-wait", .allow)
        XCTAssertEqual(duplicate, .sending)
        let spoken = await result.value
        XCTAssertEqual(spoken, PhoneActionResult.unconfirmed.message)
        let retry = await store.decideConfirmed("fixture-wait", .allow)
        XCTAssertEqual(retry, .unconfirmed)
        let sent = await client.sent
        XCTAssertEqual(sent, 1)
        await store.stop().value
    }

    func testSeparateCodexInstructionsRemainSendableAndStaleDraftIsRefused() async throws {
        let now = Date()
        let session = AgentSession(id: "fixture", agent: .codex, project: "Fixture", status: .working,
                                   statusSince: now, updatedAt: now)
        let snapshot = Snapshot(sessions: [session], serverTime: now, sourceID: "fixture-mac")
        let client = PhoneActionRecorder(snapshot: snapshot, outcome: .received)
        let store = DashboardStore(streamer: ScriptedStreamer(snapshots: [snapshot]), notifier: SilentNotifier(),
                                   decisionClient: client, watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "fixture"))
        for _ in 0..<100 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let first = await store.answer(session.id, answer: "fixture instruction one", expected: session)
        let second = await store.answer(session.id, answer: "fixture instruction two", expected: session)
        XCTAssertEqual(first, .received)
        XCTAssertEqual(second, .received)
        var stale = session
        stale.statusSince = now.addingTimeInterval(-10)
        let refused = await store.answer(session.id, answer: "old draft", expected: stale)
        XCTAssertEqual(refused, .expired)
        let sent = await client.sent
        XCTAssertEqual(sent, 2)
        await store.stop().value
    }

    func testHTTPReceiptDoesNotTreatUnavailableOrUnknownAsSuccess() {
        XCTAssertEqual(PhoneActionResult(statusCode: 200), .received)
        XCTAssertEqual(PhoneActionResult(statusCode: 202), .expired)
        XCTAssertEqual(PhoneActionResult(statusCode: 409), .expired)
        XCTAssertEqual(PhoneActionResult(statusCode: 401), .failed)
        XCTAssertEqual(PhoneActionResult(statusCode: nil), .unconfirmed)
        XCTAssertEqual(PhoneActionResult(statusCode: 500), .unconfirmed)
    }
}


extension DashboardStoreTests {
    func testWatchRechecksCapabilityAndNeverSendsExpiredTap() async throws {
        let now = Date()
        var session = AgentSession(id: "approval-01", agent: .claudeCode, project: "Fixture",
            status: .needsResponse, waitKind: .permission,
            pendingApproval: PendingApproval(id: "wait-01", tool: "Bash", commandPreview: "pwd", command: "pwd"),
            statusSince: now, updatedAt: now)
        let snapshot = Snapshot(sessions: [session], serverTime: now, sourceID: "fixture-mac")
        let client = PhoneActionRecorder(snapshot: snapshot, outcome: .received)
        let store = DashboardStore(streamer: ScriptedStreamer(snapshots: [snapshot]), notifier: SilentNotifier(),
                                   decisionClient: client, watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "fixture"))
        addTeardownBlock { @MainActor in await store.stop().value }
        for _ in 0..<100 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let request = WatchApprovalRequest(attemptId: "first", sessionId: session.id, approvalId: "wait-01", choice: .allow)
        let accepted = await store.actFromWatch(request.sessionAction)
        XCTAssertEqual(accepted.outcome, .accepted)
        XCTAssertEqual(store.allSessions.first?.status, .needsResponse, "Acceptance does not finish the task")
        let duplicate = await store.actFromWatch(request.sessionAction)
        XCTAssertEqual(duplicate.outcome, .accepted)
        session.pendingApproval = PendingApproval(id: "wait-01", tool: "Bash", commandPreview: "pwd", command: "pwd", answerable: false)
        await client.replaceSnapshot(Snapshot(sessions: [session], serverTime: now, sourceID: "fixture-mac"))
        let refused = await store.actFromWatch(WatchApprovalRequest(attemptId: "late", sessionId: session.id, approvalId: "wait-01", choice: .deny).sessionAction)
        XCTAssertEqual(refused.outcome, .refused)
        let count = await client.sent
        XCTAssertEqual(count, 1)
        await store.stop().value
        let offline = await store.actFromWatch(request.sessionAction)
        XCTAssertEqual(offline.outcome, .failed)
        let finalCount = await client.sent
        XCTAssertEqual(finalCount, 1)
    }
}


private struct ApprovalStream: SnapshotStreaming {
    let snapshots: AsyncStream<Snapshot>
    func stream(_ pairing: PairingPayload) -> AsyncStream<Snapshot> { snapshots }
}

extension DashboardStoreTests {
    func testDisconnectWhileFetchingAuthorityDoesNotSendPhoneDecision() async throws {
        let now = Date()
        let session = AgentSession(id: "disconnect-01", agent: .claudeCode, project: "Fixture",
            status: .needsResponse, waitKind: .permission,
            pendingApproval: PendingApproval(id: "disconnect-wait", tool: "Bash", commandPreview: "pwd", command: "pwd"),
            statusSince: now, updatedAt: now)
        let snapshot = Snapshot(sessions: [session], serverTime: now, sourceID: "fixture-mac")
        let stream = AsyncStream<Snapshot>.makeStream()
        let client = PhoneActionRecorder(snapshot: snapshot, outcome: .received)
        await client.pauseSnapshot()
        let store = DashboardStore(streamer: ApprovalStream(snapshots: stream.stream), notifier: SilentNotifier(),
                                   decisionClient: client, watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "fixture"))
        addTeardownBlock { @MainActor in await store.stop().value }
        stream.continuation.yield(snapshot)
        for _ in 0..<100 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let attempt = Task { await store.decideConfirmed("disconnect-wait", .allow) }
        for _ in 0..<100 {
            if await client.snapshotIsHeld() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        stream.continuation.finish()
        for _ in 0..<100 where store.state == .connected { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotEqual(store.state, .connected)
        await client.releaseSnapshot()
        let result = await attempt.value
        XCTAssertEqual(result, .expired)
        let count = await client.sent
        XCTAssertEqual(count, 0)
    }
}

extension DashboardStoreTests {
    func testHomeFiltersIntersectWithoutChangingSnapshotBuddyOrDeepLink() async throws {
        let now = Date()
        let stream = AsyncStream<Snapshot>.makeStream()
        let decisions = DecisionRecorder()
        let store = DashboardStore(streamer: ApprovalStream(snapshots: stream.stream), notifier: SilentNotifier(),
            decisionClient: decisions, watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "fixture"))
        addTeardownBlock { @MainActor in await store.stop().value }
        var selected = AgentSession(id: "selected", agent: .codex, project: "Project A", status: .working,
            statusSince: now, updatedAt: now)
        selected.attention = .followed
        // Effective attention is the snapshot value, not the manual override.
        selected.attentionOverride = .muted
        func fixture(_ id: String, project: String = "Project A", agent: AgentKind = .codex,
                     status: SessionStatus = .working, attention: SessionAttention = .followed) -> AgentSession {
            var session = AgentSession(id: id, agent: agent, project: project, status: status,
                hasUnreadCompletion: status == .done, statusSince: now, updatedAt: now)
            session.attention = attention
            return session
        }
        let otherProject = fixture("project", project: "Project B")
        let otherAgent = fixture("agent", agent: .grokBot)
        let otherStatus = fixture("status", status: .done)
        let otherAttention = fixture("attention", attention: .normal)
        let sessions = [selected, otherProject, otherAgent, otherStatus, otherAttention]
        stream.continuation.yield(Snapshot(sessions: sessions, serverTime: now))
        for _ in 0..<100 where store.allSessions.count != 5 { try await Task.sleep(for: .milliseconds(5)) }
        store.toggleBuddy("project")
        var filters = DashboardFilters(project: "Project A", status: .thinking, agent: .codex, attention: .followed)
        XCTAssertEqual(filters.sessions(from: store.allSessions).map(\.id), ["selected"])
        XCTAssertEqual(store.allSessions.count, 5)
        XCTAssertEqual(store.buddySessionIDs, ["project"])
        store.open(VibeBuddyDeepLink.sessionURL(id: "status"))
        XCTAssertEqual(store.focusedSessionId, "status")
        XCTAssertTrue(store.allSessions.contains { $0.id == store.focusedSessionId })
        XCTAssertFalse(filters.sessions(from: store.allSessions).contains { $0.id == store.focusedSessionId })
        XCTAssertEqual(store.allSessions.first { $0.id == "status" }?.hasUnreadCompletion, true)

        selected.attention = .normal
        stream.continuation.yield(Snapshot(sessions: [selected, otherProject], serverTime: now.addingTimeInterval(1)))
        for _ in 0..<100 where store.allSessions.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(filters.sessions(from: store.allSessions).isEmpty)
        XCTAssertEqual(filters.project, "Project A")
        XCTAssertEqual(store.buddySessionIDs, ["project"])
        stream.continuation.yield(Snapshot(sessions: [otherProject], serverTime: now.addingTimeInterval(2)))
        for _ in 0..<100 where store.allSessions.count != 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(filters.projects(from: store.allSessions).contains("Project A"))
        filters = DashboardFilters()
        XCTAssertEqual(filters.sessions(from: store.allSessions).map(\.id), ["project"])
        let sentActions = await decisions.sentActions
        XCTAssertEqual(sentActions, 0)
        let reads = await decisions.acknowledgedSessionIDs
        let attentionWrites = await decisions.attentions
        let waitReads = await decisions.waitRequests
        XCTAssertTrue(reads.isEmpty)
        XCTAssertTrue(attentionWrites.isEmpty)
        XCTAssertTrue(waitReads.isEmpty)
        XCTAssertTrue(store.phoneActions.isEmpty)
        stream.continuation.finish()
        for _ in 0..<100 where store.state == .connected { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotEqual(store.state, .connected)
        XCTAssertEqual(filters.sessions(from: store.allSessions).map(\.id), ["project"], "Retain the last snapshot offline")
    }

    func testHomeFiltersUsePresentationStateAndMissingProject() {
        let now = Date()
        var session = AgentSession(id: "fixture", agent: .cursor, project: "", status: .done,
            hasUnreadCompletion: true, statusSince: now, updatedAt: now)
        XCTAssertTrue(DashboardFilters(project: "", status: .completeUnread, agent: .cursor).matches(session))
        session.failed = true
        XCTAssertFalse(DashboardFilters(status: .completeUnread).matches(session))
        XCTAssertTrue(DashboardFilters(status: .error).matches(session))
        XCTAssertFalse(DashboardFilters.projectTitle("").isEmpty)
    }
}
