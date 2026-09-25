import Foundation
import Testing
@testable import VibeBuddyKit

/// M-07: the wrist shows a request or a result whole, and folds only an
/// outlier behind Show more — never a command it offers Approve for.
struct WatchReadingFoldTests {
    @Test func aDecidableCommandIsNeverFoldedEvenInCJK() {
        let longest = String(repeating: "删", count: WatchApprovalEligibility.maxDetailLength)
        #expect(!WatchReadingFold(longest, limit: WatchReadingFold.requestLimit).isFolded)
        // One character on screen, several scalars: a decomposed Hangul file
        // name (common on macOS) and a ZWJ emoji weigh what the gate counts.
        let hangul = String(repeating: "\u{1112}\u{1161}\u{11AB}", count: WatchApprovalEligibility.maxDetailLength)
        let family = String(repeating: "👨‍👩‍👧", count: WatchApprovalEligibility.maxDetailLength)
        for text in [hangul, family] {
            #expect(text.count == WatchApprovalEligibility.maxDetailLength)
            #expect(!WatchReadingFold(text, limit: WatchReadingFold.requestLimit).isFolded)
        }
        #expect(!WatchReadingFold("short", limit: WatchReadingFold.resultLimit).isFolded)
    }

    @Test func aLongTextFoldsAtAWordAndKeepsTheWholeText() {
        let text = String(repeating: "alpha beta gamma ", count: 20)
        let fold = WatchReadingFold(text, limit: 50)
        #expect(fold.isFolded)
        #expect(fold.full == text)
        #expect(fold.preview.hasSuffix("…"))
        #expect(WatchReadingFold.width(fold.preview) <= 51)
        // Stopped at a word, not inside one.
        let words = Set(["alpha", "beta", "gamma"])
        #expect(words.contains(String(fold.preview.dropLast().split(separator: " ").last ?? "")))
    }

    @Test func cjkCountsTwiceSoBothLanguagesFoldAtAboutTheSameHeight() {
        #expect(WatchReadingFold.width("结果") == 4)
        let fold = WatchReadingFold(String(repeating: "界面更新完成。", count: 20), limit: 20)
        #expect(fold.preview == "界面更新完成。界面更…")
        // Just past the limit, or nothing but whitespace: shown as it is.
        #expect(!WatchReadingFold(String(repeating: "x", count: 21), limit: 20).isFolded)
        #expect(!WatchReadingFold(String(repeating: " ", count: 80), limit: 20).isFolded)
        #expect(!WatchReadingFold(String(repeating: "x", count: 5_000), limit: .max).isFolded)
    }

    @Test func aBannerShowsTheWholeTargetItOffersApproveFor() {
        let command = String(repeating: "a", count: 150)
        let short = PendingApproval(id: "a", tool: "Bash", commandPreview: String(command.prefix(120)),
                                    command: command)
        #expect(short.notificationBody == command)
        let long = String(repeating: "b", count: 400)
        let cut = PendingApproval(id: "b", tool: "Bash", commandPreview: String(long.prefix(120)), command: long)
        #expect(cut.notificationBody == String(long.prefix(120)) + "…")
        let url = PendingApproval(id: "c", tool: "WebFetch", commandPreview: "https://example.com")
        #expect(url.notificationBody == "https://example.com")
    }

    @Test func theResultExcerptTravelsToTheDetailButNotToWidgets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var done = AgentSession(id: "done", agent: .codex, project: "Demo", status: .done,
                                hasUnreadCompletion: true, attention: .followed,
                                statusSince: now, updatedAt: now)
        done.completionID = "round-1"
        done.completionText = "  Moved both reads onto one rule.  "
        #expect(WatchFollowedTask(done).resultExcerpt == "Moved both reads onto one rule.")
        #expect(WatchFollowedTask(done).complicationTask.resultExcerpt == nil)
        var working = done
        working.status = .working
        #expect(WatchFollowedTask(working).resultExcerpt == nil)
    }
}
