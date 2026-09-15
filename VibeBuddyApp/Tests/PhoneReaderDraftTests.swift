import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
final class PhoneReaderDraftTests: XCTestCase {
    func testDraftSurvivesNavigationButCannotRetargetOrCrossPairings() {
        let drafts = PhoneReaderDrafts()
        let task = AgentSession(id: "task", agent: .codex, project: "p", status: .working, statusSince: Date(), updatedAt: Date())
        drafts.update(scope: "mac/epoch", session: task) { $0.text = "Keep my answer" }
        XCTAssertEqual(drafts.draft(scope: "mac/epoch", session: task).text, "Keep my answer")
        var next = task; next.statusSince = task.statusSince.addingTimeInterval(1)
        XCTAssertFalse(drafts.draft(scope: "mac/epoch", session: next).matches(next))
        drafts.update(scope: "mac/epoch", session: next) { $0.text = "wrong round" }
        XCTAssertEqual(drafts.draft(scope: "mac/epoch", session: next).text, "Keep my answer")
        XCTAssertTrue(drafts.draft(scope: "mac/new-epoch", session: task).isEmpty)
        XCTAssertTrue(drafts.draft(scope: "other/epoch", session: task).isEmpty)
    }

    func testFrozenReaderAuthorityRejectsSourceChangeAndSameSourceRepairing() async throws {
        let stream = AsyncThrowingStream<Snapshot, Error>.makeStream()
        let store = DashboardStore(streamer: ReaderStream(values: stream.stream), notifier: SilentNotifier(),
                                   decisionClient: NullDecisionClient(), watchRelay: nil, reportDevice: { _ in })
        let task = AgentSession(id: "same-task", agent: .codex, project: "p", status: .working,
                                statusSince: Date(), updatedAt: Date())
        store.start(PairingPayload(host: "reader-test", port: 9, token: "test"))
        let epoch = ConnectionStore.pairingEpoch
        XCTAssertFalse(store.readerAuthorityIsCurrent(scope: "unknown/" + epoch))
        stream.continuation.yield(Snapshot(sessions: [task], serverTime: Date(), sourceID: "mac-a"))
        for _ in 0..<100 where store.completionSourceID != "mac-a" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.readerAuthorityIsCurrent(scope: "mac-a/" + epoch))
        stream.continuation.yield(Snapshot(sessions: [task], serverTime: Date(), sourceID: "mac-b"))
        for _ in 0..<100 where store.completionSourceID != "mac-b" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.readerAuthorityIsCurrent(scope: "mac-a/" + epoch))
        XCTAssertTrue(store.readerAuthorityIsCurrent(scope: "mac-b/" + epoch))
        ConnectionStore.rotateEpoch()
        XCTAssertFalse(store.readerAuthorityIsCurrent(scope: "mac-b/" + epoch))
        XCTAssertFalse(store.readerAuthorityIsCurrent(scope: "mac-b/" + ConnectionStore.pairingEpoch))
        await store.stop().value
        stream.continuation.finish()
    }

    func testLateReceiptDoesNotEraseAnEditedDraft() {
        let drafts = PhoneReaderDrafts()
        let task = AgentSession(id: "task", agent: .codex, project: "p", status: .working, statusSince: Date(), updatedAt: Date())
        drafts.update(scope: "source", session: task) { $0.text = "sent" }
        let sent = drafts.draft(scope: "source", session: task)
        drafts.update(scope: "source", session: task) { $0.text = "next thought" }
        drafts.clearIfUnchanged(sent, scope: "source", session: task)
        XCTAssertEqual(drafts.draft(scope: "source", session: task).text, "next thought")
    }
}

private struct ReaderStream: SnapshotStreaming {
    let values: AsyncThrowingStream<Snapshot, Error>
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> { values }
}
