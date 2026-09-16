import Foundation
import Testing
@testable import VibeBuddyKit

struct HistoryPageTests {
    @Test func dateAndNativeIdentityRemainUnambiguous() throws {
        let message = try JSONDecoder().decode(HistoryMessage.self, from: Data(#"{"id":"one","role":"tool","text":"code","timestamp":0,"toolCallID":"call"}"#.utf8))
        #expect(message.timestamp == Date(timeIntervalSinceReferenceDate: 0))
        let session = AgentSession(id: "native-id", agent: .claudeCode, project: "p", status: .working, statusSince: Date(), updatedAt: Date())
        #expect(HistoryIdentity.transcriptKey(for: session) == "claude-code:native-id")
        let invalid = AgentSession(id: "../native-id", agent: .codex, project: "p", status: .working, statusSince: Date(), updatedAt: Date())
        #expect(HistoryIdentity.transcriptKey(for: invalid) == nil)
    }
}
