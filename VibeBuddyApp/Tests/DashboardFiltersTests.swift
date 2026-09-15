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

    func testPendingNavigationHonorsFiltersButNotGrouping() {
        var outside = session("outside", .needsResponse, hoursAgo: 0)
        outside.project = "other"
        let input = [session("done-a", .done, hoursAgo: 1, unread: true),
                     session("done-b", .done, hoursAgo: 1, unread: true),
                     session("wait", .needsResponse, hoursAgo: 2), outside]
        var filters = DashboardFilters()
        filters.project = "p"
        XCTAssertEqual(filters.pendingSessions(from: input, now: now).map(\.id), ["wait", "done-a", "done-b"])
        filters.grouping = .agent
        XCTAssertEqual(filters.pendingSessions(from: input, now: now).map(\.id), ["wait", "done-a", "done-b"])
        filters.status = .completeUnread
        XCTAssertEqual(filters.pendingSessions(from: input, now: now).map(\.id), ["done-a", "done-b"])
    }

    func testStatusGroupingNamesTheBucketsItActuallyHas() {
        let sessions = [session("a", .needsResponse, hoursAgo: 1), session("b", .working, hoursAgo: 1)]
        var filters = DashboardFilters()
        filters.grouping = .status
        let sections = filters.sections(from: sessions, now: now)
        XCTAssertEqual(sections.map(\.title), [String(localized: "Needs you"), String(localized: "Working")])
        XCTAssertEqual(sections.first?.sessions.map(\.id), ["a"])
    }

    func testRecentsLeadsThenEveryProjectRepeatsItsRows() {
        var a = session("a", .working, hoursAgo: 1); a.project = "alpha"
        var b = session("b", .done, hoursAgo: 2, unread: true); b.project = "beta"
        var c = session("c", .working, hoursAgo: 3); c.project = "alpha"
        let sections = DashboardFilters().sections(from: [c, a, b], now: now)
        XCTAssertEqual(sections.map(\.id), ["recent", "alpha", "beta"])
        XCTAssertEqual(sections[0].sessions.map(\.id), ["a", "b", "c"], "Recents is newest first")
        XCTAssertEqual(sections[1].sessions.map(\.id), ["a", "c"])

        var scoped = DashboardFilters()
        scoped.project = "alpha"
        XCTAssertEqual(scoped.sections(from: [c, a, b], now: now).map(\.id), ["alpha"],
                       "from a project row there is no Recents group")
    }

    func testSearchMatchesTitleProjectOrBranch() {
        var a = session("a", .working, hoursAgo: 1); a.project = "payments-api"; a.branch = "feat/refund"
        var b = session("b", .working, hoursAgo: 1); b.project = "docs-site"
        var filters = DashboardFilters()
        filters.query = "refund"
        XCTAssertEqual(filters.sessions(from: [a, b], now: now).map(\.id), ["a"])
        filters.query = "DOCS"
        XCTAssertEqual(filters.sessions(from: [a, b], now: now).map(\.id), ["b"])
        filters.query = "  "
        XCTAssertEqual(filters.sessions(from: [a, b], now: now).count, 2)
    }
    func testSameNamedProjectsKeepTheirIdentityCountsAndPathSearch() {
        var a = session("a", .needsResponse, hoursAgo: 1)
        a.project = "repo"
        a.checkoutPath = "/work/one/shared/repo"
        var b = session("b", .needsResponse, hoursAgo: 2)
        b.project = "repo"
        b.checkoutPath = "/work/two/shared/repo"
        let firstPath = a.checkoutPath!
        let secondPath = b.checkoutPath!
        let input = [a, b]
        var filters = DashboardFilters()
        filters.grouping = .project
        let sections = filters.sections(from: input, now: now)
        XCTAssertEqual(sections.map(\.id), [firstPath, secondPath])
        XCTAssertEqual(sections.map(\.title), ["repo · one/shared", "repo · two/shared"])
        XCTAssertEqual(sections.map { $0.sessions.map(\.id) }, [["a"], ["b"]])
        let inbox = InboxProjection(sessions: input, now: now)
        XCTAssertEqual(inbox.projects.map(\.id), [firstPath, secondPath])
        XCTAssertEqual(inbox.projects.map(\.pendingCount), [1, 1])
        XCTAssertEqual(inbox.projects.map { $0.label.parentPath }, ["one/shared", "two/shared"])
        for row in inbox.projects {
            filters.project = row.project
            XCTAssertEqual(filters.sessions(from: input, now: now).map(\.dashboardProjectIdentity), [row.project])
        }
        filters.project = nil
        filters.query = "/work/two"
        XCTAssertEqual(filters.sessions(from: input, now: now).map(\.id), ["b"])
        XCTAssertEqual(filters.sections(from: input, now: now).first?.title, "repo · two/shared")
        filters.query = ""
        filters.grouping = .recent
        XCTAssertEqual(filters.sections(from: input, now: now).map(\.id), ["recent", firstPath, secondPath])
    }

    func testLiteralAndEmptyProjectsDoNotBecomeGroupingKeys() {
        var empty = session("empty", .working, hoursAgo: 1)
        empty.project = ""
        var literal = session("literal", .working, hoursAgo: 2)
        literal.project = String(localized: "No project")
        literal.checkoutPath = "  "
        var filters = DashboardFilters()
        filters.grouping = .project
        let sections = filters.sections(from: [empty, literal], now: now)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(Set(sections.map(\.id)), ["", literal.project])
        XCTAssertEqual(DashboardFilters.projectTitle("repo"), "repo")
        XCTAssertEqual(DashboardFilters.projectTitle("  "), String(localized: "No project"))
    }

}
