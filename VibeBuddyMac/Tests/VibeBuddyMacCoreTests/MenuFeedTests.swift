import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Mac menu feed — the Companion's three groups, newest first inside each")
struct MenuFeedTests {
    private let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    private func session(_ id: String, project: String = "app", ago: TimeInterval = 0,
                         _ status: SessionStatus = .working, summary: String? = nil) -> AgentSession {
        var s = AgentSession(id: id, agent: .codex, project: project, status: status,
                             statusSince: epoch - ago, updatedAt: epoch - ago)
        s.summary = summary
        return s
    }

    private func failed(_ id: String, ago: TimeInterval = 0) -> AgentSession {
        var s = session(id, ago: ago, .done)
        s.failed = true
        return s
    }

    /// `.done` alone reads as idle; the unread bit is what makes it a completion.
    private func unread(_ id: String, ago: TimeInterval = 0) -> AgentSession {
        var s = session(id, ago: ago, .done)
        s.hasUnreadCompletion = true
        return s
    }

    // MARK: grouping and ordering

    @Test func attentionLeadsTheGroupsAndEachIsNewestFirst() {
        let feed = MenuFeed([session("old", ago: 600), failed("broke", ago: 300),
                             session("fresh", ago: 10), session("ask", ago: 400, .needsResponse),
                             session("mid", ago: 120)])
        #expect(feed.sections.map(\.kind) == [.needsYou, .working])
        #expect(feed.sessions(.needsYou).map(\.id) == ["broke", "ask"])
        #expect(feed.sessions(.working).map(\.id) == ["fresh", "mid", "old"])
        #expect(feed.emptyState == nil)
    }

    @Test func everySessionLandsInExactlyOneGroup() {
        let input = [session("a", ago: 5), failed("b", ago: 6), session("c", ago: 7, .needsResponse),
                     unread("d", ago: 8), session("e", ago: 9, .done)]
        let feed = MenuFeed(input)
        #expect(feed.sections.map(\.kind) == [.needsYou, .working, .done])
        #expect(feed.rows.count == input.count)
        #expect(Set(feed.rows.map(\.id)).count == input.count)
    }

    @Test func everyRowIsOrderedNewestFirstWithinItsGroup() {
        let feed = MenuFeed([session("a", ago: 100), session("b", ago: 50), session("c", ago: 200),
                             failed("x", ago: 30), failed("y", ago: 90)])
        #expect(feed.sessions(.working).map(\.id) == ["b", "a", "c"])
        #expect(feed.sessions(.needsYou).map(\.id) == ["x", "y"])
    }

    @Test func sessionsSharingATimestampKeepTheSnapshotOrder() {
        let same = [session("first"), session("second"), session("third")]
        #expect(MenuFeed(same).rows.map(\.id) == ["first", "second", "third"])
        // Reversing the input reverses the output: nothing else is deciding.
        #expect(MenuFeed(same.reversed()).rows.map(\.id) == ["third", "second", "first"])
    }

    // MARK: the summary is always the whole snapshot

    @Test func narrowingTheListLeavesTheSummaryAlone() {
        let input = [session("a", project: "api", .needsResponse), session("b", project: "docs"),
                     unread("c"), session("d", project: "web", .done)]
        let whole = MenuFeed(input)
        let narrowed = MenuFeed(input, query: "api")
        #expect(narrowed.summary == whole.summary)
        #expect(narrowed.summary == TaskPresentationSummary(sessions: input))
        #expect(narrowed.rows.count == 1)
    }

    @Test func countsReportMatchesAgainstTheWholeSnapshot() {
        let input = [session("a", project: "api"), session("b", project: "api"), session("c", project: "web")]
        let narrowed = MenuFeed(input, query: "api")
        #expect(narrowed.matchCount == 2)
        #expect(narrowed.totalCount == 3)
        let whole = MenuFeed(input)
        #expect(whole.matchCount == 3)
        #expect(whole.totalCount == 3)
    }

    // MARK: querying

    @Test func queryMatchesProjectSummaryOrNothing() {
        let input = [session("byProject", project: "payments-api"),
                     session("bySummary", project: "web", summary: "Retry the failing upload"),
                     session("neither", project: "docs", summary: "Rewrote the intro")]
        #expect(MenuFeed(input, query: "payments").rows.map(\.id) == ["byProject"])
        #expect(MenuFeed(input, query: "upload").rows.map(\.id) == ["bySummary"])
        #expect(MenuFeed(input, query: "nothing here").rows.isEmpty)
    }

    @Test func queryIgnoresCase() {
        let input = [session("a", project: "Payments-API", summary: "Fix the Upload")]
        #expect(MenuFeed(input, query: "payments").matchCount == 1)
        #expect(MenuFeed(input, query: "UPLOAD").matchCount == 1)
    }

    @Test func aQueryOfOnlyWhitespaceIsNoQueryAtAll() {
        let input = [session("a"), session("b", .done)]
        let blank = MenuFeed(input, query: "   \n ")
        #expect(blank.query.isEmpty)
        #expect(blank.matchCount == 2)
        #expect(blank.emptyState == nil)
    }

    @Test func aNamedSessionIsStillFoundByItsProject() {
        var named = session("named", project: "payments-api")
        named.name = "nightly deploy"
        #expect(MenuFeed([named], query: "payments").matchCount == 1)
        #expect(MenuFeed([named], query: "nightly").matchCount == 1)
    }

    // MARK: empty states

    @Test func nothingReportingAndNothingMatchingReadDifferently() {
        #expect(MenuFeed([]).emptyState == .noSessions)
        #expect(MenuFeed([], query: "api").emptyState == .noSessions)
        #expect(MenuFeed([session("a", project: "web")], query: "api").emptyState == .noMatches("api"))
        #expect(MenuFeed([session("a", project: "web")], query: "  api  ").emptyState == .noMatches("api"))
    }

    // MARK: edges

    @Test func anEmptyProjectNameIsJustAnEmptyName() {
        let feed = MenuFeed([session("blank", project: "   "), session("named", project: "app")])
        #expect(feed.rows.count == 2)
        #expect(MenuFeed([session("blank", project: "   ")], query: "app").emptyState == .noMatches("app"))
    }

    /// An absent group draws no heading, so the panel shortens instead of
    /// showing three titles over one row.
    @Test func aSnapshotOfOneStateFillsExactlyOneGroup() {
        let waiting = (0..<3).map { session("w\($0)", ago: TimeInterval($0), .needsResponse) }
        #expect(MenuFeed(waiting).sections.map(\.kind) == [.needsYou])
        #expect(MenuFeed(waiting).sessions(.needsYou).count == 3)
        let calm = (0..<3).map { session("c\($0)", ago: TimeInterval($0), .done) }
        #expect(MenuFeed(calm).sections.map(\.kind) == [.done])
        #expect(MenuFeed(calm).sessions(.done).count == 3)
    }

    @Test func returnGoesToTheFirstRowOfTheFirstGroup() {
        #expect(MenuFeed([session("new", ago: 1), session("old", ago: 90)]).topResult?.id == "new")
        #expect(MenuFeed([session("new", ago: 1), failed("broke", ago: 90)]).topResult?.id == "broke")
        // A finished task is never the target while something is still running,
        // however recently it finished.
        #expect(MenuFeed([unread("just done", ago: 1), session("running", ago: 90)]).topResult?.id == "running")
        #expect(MenuFeed([]).topResult == nil)
    }

    // MARK: the row's timestamp

    @Test func ageStaysShortEnoughToRideAtTheEndOfARow() {
        let now = epoch
        #expect(MenuFeed.age(of: now, now: now) == "now")
        #expect(MenuFeed.age(of: now - 4, now: now) == "now")
        #expect(MenuFeed.age(of: now - 44, now: now) == "44s")
        #expect(MenuFeed.age(of: now - 60, now: now) == "1m")
        #expect(MenuFeed.age(of: now - 52 * 60, now: now) == "52m")
        #expect(MenuFeed.age(of: now - 3 * 3600, now: now) == "3h")
        #expect(MenuFeed.age(of: now - 2 * 86_400, now: now) == "2d")
        // A clock that jumped backwards reads as the present, never as a negative age.
        #expect(MenuFeed.age(of: now + 30, now: now) == "now")
    }
}
