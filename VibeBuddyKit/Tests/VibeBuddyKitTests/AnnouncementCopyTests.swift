import Foundation
import Testing
@testable import VibeBuddyKit

struct AnnouncementCopyTests {
    @Test func doesNotPromoteToolRecoveryToFailureOrTurnToProjectSuccess() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var session = AgentSession(id: "announce", agent: .codex, project: "Project", status: .working,
                                   summary: "Retrying", failed: true, statusSince: now, updatedAt: now)
        #expect(AnnouncementCopy.text(for: session, sound: .agentStuck) == nil)
        session.status = .done; session.failed = false; session.completionID = "one"
        session.completionNotice = .init(id: "source/announce/one", deadline: now, state: .summary,
                                        text: "Checks passed; device acceptance pending.")
        let text = AnnouncementCopy.text(for: session, sound: .agentDone)
        #expect(text?.contains("The agent reports:") == true)
        #expect(text?.contains("device acceptance pending") == true)
        #expect(text?.contains("This turn ended") == true)
    }
}
