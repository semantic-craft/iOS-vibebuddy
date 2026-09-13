import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

/// The inbox home (ticket 01, `.scratch/iphone-board`): "First up" is the head
/// of the shared pending queue, the tiles count the same summary the mood
/// line reads, and a project's number is its share of that queue.
final class InboxProjectionTests: XCTestCase {
    private let now = Date()

    private func session(_ id: String, _ status: SessionStatus, project: String, minutesAgo: Double,
                         unread: Bool = false, failed: Bool = false, question: Bool = false) -> AgentSession {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        var s = AgentSession(id: id, agent: .claudeCode, project: project, status: status,
                             hasUnreadCompletion: unread, statusSince: at, updatedAt: at)
        if failed { s.failed = true }
        if question {
            s.waitKind = .question
            s.pendingQuestion = PendingQuestion(id: id + "-q", prompt: "Which?")
        }
        return s
    }

    private func snapshot() -> [AgentSession] {
        [session("result-a", .done, project: "payments-api", minutesAgo: 3, unread: true),
         session("stuck", .done, project: "release-check", minutesAgo: 2, failed: true),
         session("result-b", .done, project: "web-dashboard", minutesAgo: 9, unread: true),
         session("run-1", .working, project: "glaux-book", minutesAgo: 1),
         session("run-2", .working, project: "payments-api", minutesAgo: 1),
         session("read", .done, project: "payments-api", minutesAgo: 20),
         session("old", .done, project: "archive", minutesAgo: 30 * 60)]
    }

    func testFirstUpIsTheHeadOfThePendingQueueAndCountsAreTheSummary() {
        let inbox = InboxProjection(sessions: snapshot(), now: now)
        // Stuck before unread results: the same order the Watch and the Mac read.
        XCTAssertEqual(inbox.firstUp?.id, "stuck")
        XCTAssertEqual(inbox.pending.map(\.id), ["stuck", "result-a", "result-b"])
        XCTAssertEqual(inbox.pendingCount, 3)
        XCTAssertEqual(InboxBucket.all.count(in: inbox.summary), 6, "the 30-hour-old read session is not current")
        XCTAssertEqual(InboxBucket.unreadResults.count(in: inbox.summary), 2)
        XCTAssertEqual(InboxBucket.needsYou.count(in: inbox.summary), 1)
        XCTAssertEqual(InboxBucket.working.count(in: inbox.summary), 2)
        XCTAssertTrue(inbox.hasCurrent)
    }

    func testTheThirdTileSaysStuckUntilSomethingAsksAQuestion() {
        var sessions = snapshot()
        XCTAssertEqual(InboxBucket.needsYou.title(for: InboxProjection(sessions: sessions, now: now).summary),
                       String(localized: "Stuck"))
        sessions.append(session("ask", .needsResponse, project: "docs-review", minutesAgo: 1, question: true))
        let inbox = InboxProjection(sessions: sessions, now: now)
        XCTAssertEqual(InboxBucket.needsYou.title(for: inbox.summary), String(localized: "Needs you"))
        XCTAssertEqual(InboxBucket.needsYou.count(in: inbox.summary), 2)
        XCTAssertEqual(inbox.firstUp?.id, "ask", "a question outranks a confirmed failure")
    }

    func testProjectsLeadWithPendingWorkAndCarryOnlyTheirPendingCount() {
        let inbox = InboxProjection(sessions: snapshot(), now: now)
        XCTAssertEqual(inbox.projects.map(\.project),
                       ["release-check", "payments-api", "web-dashboard", "glaux-book"],
                       "projects follow the pending queue (stuck, then unread results), then the rest by latest activity; the old project is not current")
        XCTAssertEqual(inbox.projects.map(\.pendingCount), [1, 1, 1, 0])
    }

    func testBucketFiltersNarrowTheListAndTitleIt() {
        let sessions = snapshot()
        var filters = DashboardFilters()
        filters.bucket = .needsYou
        XCTAssertEqual(filters.sessions(from: sessions, now: now).map(\.id), ["stuck"])
        XCTAssertEqual(filters.pendingSessions(from: sessions, now: now).map(\.id), ["stuck"])
        XCTAssertTrue(filters.isActive)
        let summary = InboxProjection(sessions: sessions, now: now).summary
        XCTAssertEqual(filters.scopeTitle(summary: summary), String(localized: "Stuck"))

        filters = DashboardFilters()
        filters.project = "payments-api"
        XCTAssertEqual(Set(filters.sessions(from: sessions, now: now).map(\.id)), ["result-a", "run-2", "read"])
        XCTAssertEqual(filters.scopeTitle(summary: summary), "payments-api")
        XCTAssertEqual(DashboardFilters().scopeTitle(summary: summary), String(localized: "All sessions"))
    }

    func testAnEmptyOrStaleSnapshotHasNoCurrentWork() {
        XCTAssertFalse(InboxProjection(sessions: [], now: now).hasCurrent)
        let stale = [session("old", .done, project: "archive", minutesAgo: 30 * 60)]
        let inbox = InboxProjection(sessions: stale, now: now)
        XCTAssertFalse(inbox.hasCurrent)
        XCTAssertNil(inbox.firstUp)
        XCTAssertTrue(inbox.projects.isEmpty)
    }
}
