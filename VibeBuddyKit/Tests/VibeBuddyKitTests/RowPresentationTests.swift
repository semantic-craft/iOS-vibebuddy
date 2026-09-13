import Foundation
import Testing
@testable import VibeBuddyKit

struct RowPresentationTests {
    @Test func resultUsesOnlyCurrentEvidenceAndNeverTreatsProgressAsCompletion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var session = AgentSession(id: "row", agent: .codex, project: "project", status: .done,
                                   statusSince: now, updatedAt: now)
        session.summary = "Running checks"
        session.completionID = "current"
        session.completionNotice = .init(id: "source/row/old", deadline: now, state: .summary, text: "All passed.")
        #expect(RowPresentation(session: session).activityOrResult == String(localized: "This turn ended", bundle: .module))
        #expect(RowPresentation(session: session).progress == "Running checks")
        session.completionText = "## Result\nImplemented the fix. Device validation remains pending."
        #expect(RowPresentation(session: session).activityOrResult == "Implemented the fix.")
        session.status = .working
        #expect(RowPresentation(session: session).activityOrResult == ToolActivity.label(for: session))
    }
}
