import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("TranscriptReader — recent entries")
struct TranscriptRecentTests {

    private func assistant(_ text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    private func user(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    private let toolUse =
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}"#
    private let toolResult =
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#

    private func entries(_ lines: [String], limit: Int = 12) -> [TranscriptEntry] {
        TranscriptReader.recentEntries(tail: Data(lines.joined(separator: "\n").utf8), limit: limit)
    }

    @Test("returns user and assistant prose in chronological order")
    func chronological() {
        let r = entries([user("do the thing"), assistant("done the thing")])
        #expect(r.map(\.role) == ["user", "assistant"])
        #expect(r.map(\.text) == ["do the thing", "done the thing"])
    }

    @Test("a tool-only assistant turn surfaces as the tool name")
    func toolActivity() {
        let r = entries([toolUse])
        #expect(r.count == 1)
        #expect(r[0].role == "assistant")
        #expect(r[0].text == "⚙ Edit")
    }

    @Test("noisy tool_result user turns are skipped")
    func skipsToolResults() {
        let r = entries([assistant("editing"), toolResult, assistant("saved")])
        #expect(r.map(\.text) == ["editing", "saved"])
    }

    @Test("limit keeps only the last N entries")
    func limit() {
        let r = entries([assistant("a"), assistant("b"), assistant("c")], limit: 2)
        #expect(r.map(\.text) == ["b", "c"])
    }

    @Test("plain-string content is supported")
    func stringContent() {
        let line = #"{"message":{"role":"assistant","content":"plain reply"}}"#
        #expect(entries([line]).map(\.text) == ["plain reply"])
    }

    @Test("empty input yields no entries")
    func empty() {
        #expect(entries([]).isEmpty)
    }

    @Test("recentEntries(path:) reads a file; missing file is nil")
    func readFile() throws {
        let tmp = NSTemporaryDirectory() + "vb-recent-\(UUID().uuidString).jsonl"
        try [user("hi"), assistant("hello")].joined(separator: "\n")
            .write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        #expect(TranscriptReader.recentEntries(path: tmp)?.map(\.text) == ["hi", "hello"])
        #expect(TranscriptReader.recentEntries(path: "/no/such/file.jsonl") == nil)
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

    @Test("a grok log with no messages at all yields no entries")
    func grokEmpty() {
        #expect(GrokSessionReader.recentEntries(updatesTail: Data()).isEmpty)
    }
}
