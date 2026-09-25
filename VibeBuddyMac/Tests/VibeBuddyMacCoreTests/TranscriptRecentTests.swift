import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("TranscriptReader — recent entries")
struct TranscriptRecentTests {

    private let toolUse =
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}"#

    private func entries(_ lines: [String], limit: Int = 12) -> [TranscriptEntry] {
        TranscriptReader.recentEntries(tail: Data(lines.joined(separator: "\n").utf8), limit: limit)
    }

    @Test("a tool-only assistant turn surfaces as the tool name")
    func toolActivity() {
        let r = entries([toolUse])
        #expect(r.count == 1)
        #expect(r[0].role == "assistant")
        #expect(r[0].text == "⚙ Edit")
    }

    @Test("plain-string content is supported")
    func stringContent() {
        let line = #"{"message":{"role":"assistant","content":"plain reply"}}"#
        #expect(entries([line]).map(\.text) == ["plain reply"])
    }

    @Test("grok's own log produces the same entry shapes")
    func grokEntriesMatchTheClaudeShape() {
        let entries = GrokSessionReader.recentEntries(updatesTail: Data([
            GrokFixture.userChunk("do the thing"),
            GrokFixture.toolCall(id: "call-1", title: "search_replace"),
            GrokFixture.agentChunk("done the thing"),
        ].joined(separator: "\n").utf8))
        #expect(entries.map(\.role) == ["user", "assistant", "assistant"])
        #expect(entries.map(\.text) == ["do the thing", "⚙ search_replace", "done the thing"])
    }
}
