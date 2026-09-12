import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

/// The phone's list shows current work (`SessionCurrency`, ADR-0014 / ADR-0017)
/// and offers the rest back; the rule itself is tested in the Kit.
final class DashboardFiltersTests: XCTestCase {
    private let now = Date()

    private func session(_ id: String, _ status: SessionStatus, hoursAgo: Double,
                         unread: Bool = false) -> AgentSession {
        let at = now.addingTimeInterval(-hoursAgo * 3600)
        return AgentSession(id: id, agent: .claudeCode, project: "p", status: status,
                            hasUnreadCompletion: unread, statusSince: at, updatedAt: at)
    }

    func testFiltersHideOlderRowsButStillCountAndCanShowThem() {
        let sessions = [session("fresh", .working, hoursAgo: 1), session("stale", .done, hoursAgo: 48)]
        var filters = DashboardFilters()
        XCTAssertEqual(filters.sessions(from: sessions, now: now).map(\.id), ["fresh"])
        XCTAssertEqual(filters.hiddenCount(from: sessions, now: now), 1)

        filters.includeInactive = true
        XCTAssertEqual(filters.sessions(from: sessions, now: now).map(\.id), ["fresh", "stale"])
        XCTAssertEqual(filters.hiddenCount(from: sessions, now: now), 0)
    }

    func testAnOldWaitIsNeverHiddenAndAnOldUnreadCompletionIs() {
        let sessions = [session("wait", .needsResponse, hoursAgo: 5 * 24),
                        session("unread", .done, hoursAgo: 30, unread: true)]
        let filters = DashboardFilters()
        XCTAssertEqual(filters.sessions(from: sessions, now: now).map(\.id), ["wait"])
        XCTAssertEqual(filters.hiddenCount(from: sessions, now: now), 1)
    }

    func testStatusGroupingNamesTheBucketsItActuallyHas() {
        let sessions = [session("a", .needsResponse, hoursAgo: 1), session("b", .working, hoursAgo: 1)]
        let sections = DashboardFilters().sections(from: sessions, now: now)
        XCTAssertEqual(sections.map(\.title), [String(localized: "Needs you"), String(localized: "Working")])
        XCTAssertEqual(sections.first?.sessions.map(\.id), ["a"])
    }
}
