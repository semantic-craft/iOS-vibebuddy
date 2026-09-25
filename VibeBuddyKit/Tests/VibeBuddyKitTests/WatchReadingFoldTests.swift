import Foundation
import Testing
@testable import VibeBuddyKit

/// M-07: the wrist shows a request or a result whole, and folds only an
/// outlier behind Show more — never a command it offers Approve for.
struct WatchReadingFoldTests {
    @Test func aDecidableCommandIsNeverFoldedEvenInCJK() {
        let longest = String(repeating: "删", count: WatchApprovalEligibility.maxDetailLength)
        #expect(!WatchReadingFold(longest, limit: WatchReadingFold.requestLimit).isFolded)
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
