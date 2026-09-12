import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Mac menu feed — the Companion's three groups, newest first inside each")
struct MenuFeedTests {
    private let epoch = Date(timeIntervalSince1970: 1_780_000_000)
    /// A day and a bit: past `SessionCurrency.window`.
    private let stale: TimeInterval = 26 * 3600

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

    /// Every row in the order the panel draws them.
    private func rows(_ feed: MenuFeed) -> [AgentSession] { feed.sections.flatMap(\.sessions) }
    private func sessions(_ feed: MenuFeed, _ kind: MenuFeed.Section.Kind) -> [AgentSession] {
        feed.sections.first { $0.kind == kind }?.sessions ?? []
    }
    private func make(_ input: [AgentSession], query: String = "") -> MenuFeed {
        MenuFeed(input, query: query, now: epoch)
    }

    // MARK: grouping and ordering

    @Test func attentionLeadsTheGroupsAndEachIsNewestFirst() {
        let feed = make([session("old", ago: 600), failed("broke", ago: 300),
                             session("fresh", ago: 10), session("ask", ago: 400, .needsResponse),
                             session("mid", ago: 120)])
        #expect(feed.sections.map(\.kind) == [.needsYou, .working])
        #expect(sessions(feed, .needsYou).map(\.id) == ["broke", "ask"])
        #expect(sessions(feed, .working).map(\.id) == ["fresh", "mid", "old"])
        #expect(feed.emptyState == nil)
    }

    @Test func everySessionLandsInExactlyOneGroup() {
        let input = [session("a", ago: 5), failed("b", ago: 6), session("c", ago: 7, .needsResponse),
                     unread("d", ago: 8), session("e", ago: 9, .done)]
        let feed = make(input)
        #expect(feed.sections.map(\.kind) == [.needsYou, .working, .done])
        #expect(rows(feed).count == input.count)
        #expect(Set(rows(feed).map(\.id)).count == input.count)
    }

    @Test func everyRowIsOrderedNewestFirstWithinItsGroup() {
        let feed = make([session("a", ago: 100), session("b", ago: 50), session("c", ago: 200),
                             failed("x", ago: 30), failed("y", ago: 90)])
        #expect(sessions(feed, .working).map(\.id) == ["b", "a", "c"])
        #expect(sessions(feed, .needsYou).map(\.id) == ["x", "y"])
    }

    @Test func sessionsSharingATimestampKeepTheSnapshotOrder() {
        let same = [session("first"), session("second"), session("third")]
        #expect(rows(make(same)).map(\.id) == ["first", "second", "third"])
        // Reversing the input reverses the output: nothing else is deciding.
        #expect(rows(make(same.reversed())).map(\.id) == ["third", "second", "first"])
    }

    // MARK: the summary is always the whole snapshot

    @Test func narrowingTheListLeavesTheSummaryAlone() {
        let input = [session("a", project: "api", .needsResponse), session("b", project: "docs"),
                     unread("c"), session("d", project: "web", .done)]
        let whole = make(input)
        let narrowed = make(input, query: "api")
        #expect(narrowed.summary == whole.summary)
        #expect(narrowed.summary == TaskPresentationSummary(currentIn: input, now: epoch))
        #expect(rows(narrowed).count == 1)
    }

    @Test func countsReportMatchesAgainstTheWholeSnapshot() {
        let input = [session("a", project: "api"), session("b", project: "api"), session("c", project: "web")]
        let narrowed = make(input, query: "api")
        #expect(narrowed.matchCount == 2)
        #expect(narrowed.totalCount == 3)
        let whole = make(input)
        #expect(whole.matchCount == 3)
        #expect(whole.totalCount == 3)
    }

    // MARK: what is current

    @Test func finishedWorkOlderThanADayFoldsIntoOlderAndLeavesTheSummary() {
        let input = [session("today", ago: 600, .done), session("lastWeek", ago: stale, .done),
                     unread("readLater", ago: stale - 60), session("run")]
        let f = make(input)
        #expect(f.sections.map(\.kind) == [.working, .done, .older])
        #expect(sessions(f, .done).map(\.id) == ["today"])
        #expect(sessions(f, .older).map(\.id) == ["readLater", "lastWeek"])
        // The panel's line counts what is current, like the phone and the Watch.
        #expect(f.summary.idle == 1)
        #expect(f.summary.completeUnread == 0)
        #expect(f.summary.thinking == 1)
        #expect(f.totalCount == 4)
    }

    @Test func aWaitAFailureARunAndAFollowedUnreadNeverFold() {
        var followed = unread("followed", ago: stale)
        followed.attention = .followed
        let input = [session("wait", ago: stale, .needsResponse), failed("broke", ago: stale),
                     session("stalled", ago: stale), followed]
        let f = make(input)
        #expect(sessions(f, .older).isEmpty)
        #expect(sessions(f, .needsYou).map(\.id) == ["wait", "broke"])
        #expect(sessions(f, .working).map(\.id) == ["stalled"])
        #expect(sessions(f, .done).map(\.id) == ["followed"])
    }

    @Test func returnNeverLandsInOlderWhileSomethingCurrentMatches() {
        let input = [session("old", ago: stale, .done), session("new", ago: 5, .done)]
        #expect(make(input).topResult?.id == "new")
        // With only old work matching, Older is the whole list and Return goes there.
        var namedOld = session("old", ago: stale, .done); namedOld.name = "nightly"
        #expect(make([namedOld, session("new", ago: 5, .done)], query: "nightly").topResult?.id == "old")
    }

    // MARK: querying

    @Test func queryMatchesProjectSummaryOrNothing() {
        let input = [session("byProject", project: "payments-api"),
                     session("bySummary", project: "web", summary: "Retry the failing upload"),
                     session("neither", project: "docs", summary: "Rewrote the intro")]
        #expect(rows(make(input, query: "payments")).map(\.id) == ["byProject"])
        #expect(rows(make(input, query: "upload")).map(\.id) == ["bySummary"])
        #expect(rows(make(input, query: "nothing here")).isEmpty)
    }

    @Test func queryIgnoresCase() {
        let input = [session("a", project: "Payments-API", summary: "Fix the Upload")]
        #expect(make(input, query: "payments").matchCount == 1)
        #expect(make(input, query: "UPLOAD").matchCount == 1)
    }

    @Test func aQueryOfOnlyWhitespaceIsNoQueryAtAll() {
        let input = [session("a"), session("b", .done)]
        let blank = make(input, query: "   \n ")
        #expect(blank.query.isEmpty)
        #expect(blank.matchCount == 2)
        #expect(blank.emptyState == nil)
    }

    @Test func aNamedSessionIsStillFoundByItsProject() {
        var named = session("named", project: "payments-api")
        named.name = "nightly deploy"
        #expect(make([named], query: "payments").matchCount == 1)
        #expect(make([named], query: "nightly").matchCount == 1)
    }

    // MARK: empty states

    @Test func nothingReportingAndNothingMatchingReadDifferently() {
        #expect(make([]).emptyState == .noSessions)
        #expect(make([], query: "api").emptyState == .noSessions)
        #expect(make([session("a", project: "web")], query: "api").emptyState == .noMatches("api"))
        #expect(make([session("a", project: "web")], query: "  api  ").emptyState == .noMatches("api"))
    }

    // MARK: edges

    @Test func anEmptyProjectNameIsJustAnEmptyName() {
        let feed = make([session("blank", project: "   "), session("named", project: "app")])
        #expect(rows(feed).count == 2)
        #expect(make([session("blank", project: "   ")], query: "app").emptyState == .noMatches("app"))
    }

    /// An absent group draws no heading, so the panel shortens instead of
    /// showing three titles over one row.
    @Test func aSnapshotOfOneStateFillsExactlyOneGroup() {
        let waiting = (0..<3).map { session("w\($0)", ago: TimeInterval($0), .needsResponse) }
        #expect(make(waiting).sections.map(\.kind) == [.needsYou])
        #expect(sessions(make(waiting), .needsYou).count == 3)
        let calm = (0..<3).map { session("c\($0)", ago: TimeInterval($0), .done) }
        #expect(make(calm).sections.map(\.kind) == [.done])
        #expect(sessions(make(calm), .done).count == 3)
    }

    @Test func returnGoesToTheFirstRowOfTheFirstGroup() {
        #expect(make([session("new", ago: 1), session("old", ago: 90)]).topResult?.id == "new")
        #expect(make([session("new", ago: 1), failed("broke", ago: 90)]).topResult?.id == "broke")
        // A finished task is never the target while something is still running,
        // however recently it finished.
        #expect(make([unread("just done", ago: 1), session("running", ago: 90)]).topResult?.id == "running")
        #expect(make([]).topResult == nil)
    }

    /// `Needs you` cannot be folded away (ADR-0015), and it leads the list, so
    /// Return lands there however much newer the other groups are.
    @Test func returnLandsInNeedsYouEvenWhenEveryOtherGroupIsNewer() {
        let input = [unread("finished", ago: 1), session("running", ago: 5),
                     session("ask", ago: 3 * 3600, .needsResponse), failed("broke", ago: 2 * 3600)]
        let feed = make(input)
        #expect(feed.sections.first?.kind == .needsYou)
        #expect(feed.topResult?.id == "broke")
        // Narrowing keeps the rule: the newest matching row that needs a person.
        #expect(make(input, query: "app").topResult?.id == "broke")
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
