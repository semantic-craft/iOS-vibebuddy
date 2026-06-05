import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("VoiceSessionMatch — resolve a spoken project name to one session")
struct VoiceSessionMatchTests {

    private func session(_ project: String) -> AgentSession {
        AgentSession(id: project, agent: .claudeCode, project: project, status: .needsResponse,
                     waitKind: .permission,
                     statusSince: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("an exact name matches (case-insensitive, trimmed)")
    func exact() {
        let sessions = [session("payments-api"), session("docs-site")]
        #expect(VoiceSessionMatch.match("Payments-API", in: sessions)?.project == "payments-api")
        #expect(VoiceSessionMatch.match("  docs-site ", in: sessions)?.project == "docs-site")
    }

    @Test("a unique prefix/substring matches when there is no exact hit")
    func uniqueSubstring() {
        let sessions = [session("payments-api"), session("docs-site")]
        #expect(VoiceSessionMatch.match("payments", in: sessions)?.project == "payments-api")
    }

    @Test("an ambiguous substring refuses rather than guessing a target")
    func ambiguousRefused() {
        let sessions = [session("payments-api"), session("users-api")]
        #expect(VoiceSessionMatch.match("api", in: sessions) == nil)
    }

    @Test("an exact hit wins even when it is also a substring of another session")
    func exactBeatsSubstring() {
        let sessions = [session("api"), session("payments-api")]
        #expect(VoiceSessionMatch.match("api", in: sessions)?.project == "api")
    }

    @Test("no match and empty query both return nil")
    func noMatch() {
        let sessions = [session("payments-api")]
        #expect(VoiceSessionMatch.match("billing", in: sessions) == nil)
        #expect(VoiceSessionMatch.match("", in: sessions) == nil)
        #expect(VoiceSessionMatch.match("   ", in: sessions) == nil)
    }

    @Test("a query longer than any project name does not match (no reverse-contains)")
    func noReverseContains() {
        // Old behavior matched when the query *contained* a project name, which let
        // a one-char project name match almost anything. That direction is gone.
        let sessions = [session("a"), session("payments-api")]
        #expect(VoiceSessionMatch.match("approve that for me", in: sessions) == nil)
    }
}
