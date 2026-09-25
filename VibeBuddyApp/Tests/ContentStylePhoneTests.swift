import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

private actor ContentStyleClient: DecisionClient {
    var value = ContentStyleState(sourceID: "mac", configuration: .default, revision: "saved-1")
    var presentationConflict = false
    var presentationGenerated = true
    func useVerifiedExcerpt() { presentationGenerated = false }
    var presentationUnavailable = false
    var holdPresentation = false
    var presentationContinuation: CheckedContinuation<ContentPresentation, any Error>?
    func failPresentation(hold: Bool = false) { presentationUnavailable = true; holdPresentation = hold }
    func isHoldingPresentation() -> Bool { presentationContinuation != nil }
    func releasePresentationFailure() {
        presentationContinuation?.resume(throwing: ContentRequestFailure.unavailable)
        presentationContinuation = nil
    }
    var holdSave = false
    var saveContinuation: CheckedContinuation<ContentStyleState, any Error>?
    func configure(conflict: Bool = false, hold: Bool = false) { presentationConflict = conflict; holdSave = hold }
    func isHolding() -> Bool { saveContinuation != nil }
    func release() { saveContinuation?.resume(returning: value); saveContinuation = nil }
    func contentStyle(_ pairing: PairingPayload) async throws -> ContentStyleState { value }
    func updateContentStyle(_ pairing: PairingPayload, update: ContentStyleUpdate) async throws -> ContentStyleState {
        if holdSave { return try await withCheckedThrowingContinuation { saveContinuation = $0 } }
        guard update.expectedRevision == value.revision else { throw ContentRequestFailure.conflict }
        value = ContentStyleState(sourceID: "mac", configuration: update.configuration, revision: "saved-2")
        return value
    }
    func presentation(_ pairing: PairingPayload, request: ContentPresentationRequest) async throws -> ContentPresentation {
        if holdPresentation {
            return try await withCheckedThrowingContinuation { presentationContinuation = $0 }
        }
        if presentationConflict { throw ContentRequestFailure.conflict }
        if presentationUnavailable { throw ContentRequestFailure.unavailable }
        return ContentPresentation(request: request, revision: "speech-1", text: "Current briefing", generated: presentationGenerated)
    }
    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome { .failed }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { false }
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}

private struct ControlledContentStream: SnapshotStreaming {
    let value: AsyncThrowingStream<Snapshot, Error>
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> { value }
}

@MainActor
final class ContentStylePhoneTests: XCTestCase {
    func testCancelledPreviewCannotBecomeBusyAgain() async {
        let announcer = PhoneAnnouncer()
        announcer.preview()
        XCTAssertTrue(announcer.isPreviewing)
        XCTAssertTrue(announcer.isBusy)

        announcer.cancelPreview()
        XCTAssertFalse(announcer.isPreviewing)
        XCTAssertFalse(announcer.isBusy)
        XCTAssertNil(announcer.previewMessage)
        await Task.yield()
        XCTAssertFalse(announcer.isPreviewing)
        XCTAssertFalse(announcer.isBusy)
        XCTAssertNil(announcer.previewMessage)
    }

    func testMigrationPreservesConfiguredProviderAndThenSeparatesConversation() {
        let name = "phone-speech-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("openai", forKey: VoiceSettings.providerKey)
        XCTAssertEqual(PhoneReadAloudSelection.load(defaults: defaults, hasKey: { _ in true }), .provider(.openai))
        defaults.set("qwen", forKey: VoiceSettings.providerKey)
        XCTAssertEqual(PhoneReadAloudSelection.load(defaults: defaults, hasKey: { _ in false }), .provider(.openai))
        // Gemini was removed 2026-09-25: a stored Gemini selection reads as system speech.
        defaults.set("gemini", forKey: PhoneReadAloudSelection.defaultsKey)
        XCTAssertEqual(PhoneReadAloudSelection.load(defaults: defaults, hasKey: { _ in true }), .system)
        defaults.set("system", forKey: PhoneReadAloudSelection.defaultsKey)
        XCTAssertEqual(PhoneReadAloudSelection.load(defaults: defaults, hasKey: { _ in true }), .system)
        defaults.removeObject(forKey: PhoneReadAloudSelection.defaultsKey)
        XCTAssertEqual(PhoneReadAloudSelection.load(defaults: defaults, hasKey: { _ in false }), .system)
    }

    private func connected(_ client: ContentStyleClient, notice: CompletionNotice? = nil) async throws -> (DashboardStore, AgentSession) {
        let now = Date()
        var session = AgentSession(id: "task", agent: .codex, project: "test", status: .done,
                                   summary: "Saved short result", hasUnreadCompletion: true,
                                   statusSince: now, updatedAt: now)
        session.completionID = "round"
        session.name = "Paint the harbor"
        session.completionNotice = notice
        var snapshot = Snapshot(sessions: [session], serverTime: now, sourceID: "mac")
        snapshot.contentPresentationRevision = "speech-1"
        let store = DashboardStore(streamer: ScriptedStreamer(snapshots: [snapshot]), notifier: SilentNotifier(), decisionClient: client, watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "content-style-test", port: 9, token: "test"))
        for _ in 0..<100 where store.contentStyleState == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.contentStyleState?.revision, "saved-1")
        return (store, session)
    }

    func testCompletionFallbackRequiresCurrentVerifiedNoticeAndNamesTask() async throws {
        let cases: [(String, CompletionNotice.State, Bool)] = [
            ("mac/task/round", .pending, false), ("mac/task/round", .cancelled, false),
            ("mac/task/old-round", .summary, false), ("other/task/round", .summary, false),
            ("mac/task/round", .summary, true)
        ]
        for (id, state, allowed) in cases {
            let client = ContentStyleClient()
            await client.failPresentation()
            let notice = CompletionNotice(id: id, deadline: Date().addingTimeInterval(30), state: state,
                                          text: "Saved harbor result")
            let (store, session) = try await connected(client, notice: notice)
            do {
                let announcement = try await store.announcement(for: XCTUnwrap(AnnouncementPlan.Item(session)))
                XCTAssertTrue(allowed, "Unverified notice must not read old summary: \(id) / \(state)")
                XCTAssertTrue(announcement.text.contains("Paint the harbor"))
                XCTAssertTrue(announcement.text.contains("Saved harbor result"))
                XCTAssertTrue(announcement.savedFallback)
            } catch ContentRequestFailure.unavailable {
                XCTAssertFalse(allowed)
            }
            await store.stop().value
        }
    }

    func testPreparedOfflineCompletionStopsWhenSameNoticeIsCancelled() async throws {
        let channel = AsyncThrowingStream<Snapshot, Error>.makeStream()
        let client = ContentStyleClient()
        await client.failPresentation()
        let store = DashboardStore(streamer: ControlledContentStream(value: channel.stream), notifier: SilentNotifier(),
                                   decisionClient: client, watchRelay: nil, reportDevice: { _ in })
        let now = Date()
        var session = AgentSession(id: "task", agent: .codex, project: "test", status: .done,
                                   hasUnreadCompletion: true, statusSince: now, updatedAt: now)
        session.completionID = "round"
        session.completionNotice = CompletionNotice(id: "mac/task/round", deadline: now.addingTimeInterval(30),
                                                    state: .summary, text: "Verified saved summary")
        var snapshot = Snapshot(sessions: [session], serverTime: now, sourceID: "mac")
        snapshot.contentPresentationRevision = "speech-1"
        store.start(PairingPayload(host: "content-style-test", port: 9, token: "test"))
        channel.continuation.yield(snapshot)
        for _ in 0..<100 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let prepared = try await store.announcement(for: XCTUnwrap(AnnouncementPlan.Item(session)))
        XCTAssertTrue(store.announcementIsCurrent(prepared))
        XCTAssertNotNil(prepared.savedCompletionNotice)
        session.completionNotice?.state = .cancelled
        snapshot.sessions = [session]
        snapshot.serverTime = now.addingTimeInterval(1)
        channel.continuation.yield(snapshot)
        for _ in 0..<100 where store.allSessions.first?.completionNotice?.state != .cancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.allSessions.first?.completionNotice?.state, .cancelled)
        XCTAssertFalse(store.announcementIsCurrent(prepared))
        await store.stop().value
        channel.continuation.finish()
    }

    func testVerifiedServerExcerptDoesNotRequireSavedNoticePermission() async throws {
        let client = ContentStyleClient()
        await client.useVerifiedExcerpt()
        let notice = CompletionNotice(id: "mac/task/round", deadline: Date().addingTimeInterval(30), state: .cancelled)
        let (store, session) = try await connected(client, notice: notice)
        let prepared = try await store.announcement(for: XCTUnwrap(AnnouncementPlan.Item(session)))
        XCTAssertTrue(prepared.savedFallback)
        XCTAssertNil(prepared.savedCompletionNotice)
        XCTAssertEqual(prepared.text, "Current briefing")
        XCTAssertTrue(store.announcementIsCurrent(prepared))
        await store.stop().value
    }

    func testCompletionFallbackRejectsNoticeCancelledDuringNetworkRequest() async throws {
        let channel = AsyncThrowingStream<Snapshot, Error>.makeStream()
        let client = ContentStyleClient()
        await client.failPresentation(hold: true)
        let store = DashboardStore(streamer: ControlledContentStream(value: channel.stream), notifier: SilentNotifier(),
                                   decisionClient: client, watchRelay: nil, reportDevice: { _ in })
        let now = Date()
        var session = AgentSession(id: "task", agent: .codex, project: "test", status: .done,
                                   summary: "Old summary", hasUnreadCompletion: true, statusSince: now, updatedAt: now)
        session.completionID = "round"
        session.completionNotice = CompletionNotice(id: "mac/task/round", deadline: now.addingTimeInterval(30),
                                                    state: .summary, text: "Previously ready summary")
        var snapshot = Snapshot(sessions: [session], serverTime: now, sourceID: "mac")
        snapshot.contentPresentationRevision = "speech-1"
        store.start(PairingPayload(host: "content-style-test", port: 9, token: "test"))
        channel.continuation.yield(snapshot)
        for _ in 0..<100 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let item = try XCTUnwrap(AnnouncementPlan.Item(session))
        let pending = Task { try await store.announcement(for: item) }
        for _ in 0..<100 {
            if await client.isHoldingPresentation() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requestIsHeld = await client.isHoldingPresentation()
        XCTAssertTrue(requestIsHeld)
        session.completionNotice?.state = .cancelled
        snapshot.sessions = [session]
        snapshot.serverTime = now.addingTimeInterval(1)
        channel.continuation.yield(snapshot)
        for _ in 0..<100 where store.allSessions.first?.completionNotice?.state != .cancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.allSessions.first?.completionNotice?.state, .cancelled)
        await client.releasePresentationFailure()
        do { _ = try await pending.value; XCTFail("Cancelled same-round notice cannot fall back to captured summary") }
        catch ContentRequestFailure.unavailable { }
        await store.stop().value
        channel.continuation.finish()
    }

    func testCASConflictKeepsConfirmedValueAndReportsConflict() async throws {
        let client = ContentStyleClient()
        let (store, _) = try await connected(client)
        let saved = await store.saveContentStyle(.init(style: .decision), expectedRevision: "older")
        XCTAssertFalse(saved)
        XCTAssertEqual(store.contentStyleState?.configuration.style, .concise)
        XCTAssertNotNil(store.contentStyleMessage)
        let accepted = await store.saveContentStyle(.init(style: .decision), expectedRevision: "saved-1")
        XCTAssertTrue(accepted)
        XCTAssertEqual(store.contentStyleState?.configuration.style, .decision)
        await store.stop().value
    }

    func testLateSaveCannotRestoreForgottenMac() async throws {
        let client = ContentStyleClient()
        let (store, _) = try await connected(client)
        await client.configure(hold: true)
        let save = Task { await store.saveContentStyle(.init(style: .decision), expectedRevision: "saved-1") }
        for _ in 0..<100 {
            if await client.isHolding() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.forgetPairing()
        await client.release()
        let saved = await save.value
        XCTAssertFalse(saved)
        XCTAssertNil(store.contentStyleState)
        XCTAssertFalse(store.contentStyleSaving)
        await store.stop().value
    }

    func testPreparedSpeechIsRejectedWhenItsRoundChangesBeforePlayback() async throws {
        let channel = AsyncThrowingStream<Snapshot, Error>.makeStream()
        let client = ContentStyleClient()
        let store = DashboardStore(streamer: ControlledContentStream(value: channel.stream), notifier: SilentNotifier(),
                                   decisionClient: client, watchRelay: nil, reportDevice: { _ in })
        let now = Date()
        var session = AgentSession(id: "task", agent: .codex, project: "test", status: .done,
                                   hasUnreadCompletion: true, statusSince: now, updatedAt: now)
        session.completionID = "round-1"
        var snapshot = Snapshot(sessions: [session], serverTime: now, sourceID: "mac")
        snapshot.contentPresentationRevision = "speech-1"
        store.start(PairingPayload(host: "content-style-test", port: 9, token: "test"))
        channel.continuation.yield(snapshot)
        for _ in 0..<100 where store.allSessions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let prepared = try await store.announcement(for: XCTUnwrap(AnnouncementPlan.Item(session)))
        XCTAssertTrue(store.announcementIsCurrent(prepared))
        session.completionID = "round-2"
        snapshot.sessions = [session]
        snapshot.serverTime = now.addingTimeInterval(1)
        channel.continuation.yield(snapshot)
        for _ in 0..<100 where store.allSessions.first?.completionID != "round-2" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.announcementIsCurrent(prepared))
        await store.stop().value
        channel.continuation.finish()
    }

    func testStalePresentationNeverFallsBackAndSourceChangeInvalidatesPreparedSpeech() async throws {
        let client = ContentStyleClient()
        let (store, session) = try await connected(client)
        let item = try XCTUnwrap(AnnouncementPlan.Item(session))
        let speech = try await store.announcement(for: item)
        XCTAssertTrue(store.announcementIsCurrent(speech))
        await client.configure(conflict: true)
        do { _ = try await store.announcement(for: item); XCTFail("409 must skip, not read cached text") }
        catch ContentRequestFailure.conflict { }
        store.forgetPairing()
        XCTAssertFalse(store.announcementIsCurrent(speech))
        await store.stop().value
    }
}
