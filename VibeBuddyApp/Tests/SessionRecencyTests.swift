import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

/// The phone's dashboard shows today's work, not the Mac's whole history
/// (ADR-0014). A task waiting on a person is the exception and never ages out.
final class SessionRecencyTests: XCTestCase {
    private let now = Date()

    private func session(_ id: String, _ status: SessionStatus, hoursAgo: Double,
                         unread: Bool = false) -> AgentSession {
        let at = now.addingTimeInterval(-hoursAgo * 3600)
        return AgentSession(id: id, agent: .claudeCode, project: "p", status: status,
                            hasUnreadCompletion: unread, statusSince: at, updatedAt: at)
    }

    func testFinishedWorkLeavesTheListAfterADayAndAWaitNeverDoes() {
        let fresh = session("fresh", .done, hoursAgo: 2)
        let stale = session("stale", .done, hoursAgo: 5 * 24)
        let unreadButStale = session("unread", .done, hoursAgo: 30, unread: true)
        let oldWait = session("wait", .needsResponse, hoursAgo: 5 * 24)

        let kept = SessionRecency.current([fresh, stale, unreadButStale, oldWait], now: now).map(\.id)
        XCTAssertEqual(kept, ["fresh", "wait"])
        XCTAssertEqual(SessionRecency.inactiveCount([fresh, stale, unreadButStale, oldWait], now: now), 2)
    }

    func testTheWindowEdgeKeepsTheRowUntilItIsPast() {
        XCTAssertTrue(SessionRecency.isCurrent(session("edge", .done, hoursAgo: 23.9), now: now))
        XCTAssertFalse(SessionRecency.isCurrent(session("past", .done, hoursAgo: 24.1), now: now))
    }

    func testFiltersHideStaleRowsButStillCountAndCanShowThem() {
        let sessions = [session("fresh", .working, hoursAgo: 1), session("stale", .done, hoursAgo: 48)]
        var filters = DashboardFilters()
        XCTAssertEqual(filters.sessions(from: sessions, now: now).map(\.id), ["fresh"])
        XCTAssertEqual(filters.hiddenCount(from: sessions, now: now), 1)

        filters.includeInactive = true
        XCTAssertEqual(filters.sessions(from: sessions, now: now).map(\.id), ["fresh", "stale"])
        XCTAssertEqual(filters.hiddenCount(from: sessions, now: now), 0)
    }

    func testStatusGroupingNamesTheBucketsItActuallyHas() {
        let sessions = [session("a", .needsResponse, hoursAgo: 1), session("b", .working, hoursAgo: 1)]
        let sections = DashboardFilters().sections(from: sessions, now: now)
        XCTAssertEqual(sections.map(\.title), [String(localized: "Needs you"), String(localized: "Working")])
        XCTAssertEqual(sections.first?.sessions.map(\.id), ["a"])
    }
}
