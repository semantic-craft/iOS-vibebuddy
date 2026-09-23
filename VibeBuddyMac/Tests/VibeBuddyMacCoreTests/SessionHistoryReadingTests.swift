import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite struct SessionHistoryReadingTests {
    @Test func groupedToolsThinkingAndHiddenContextKeepMessageIdentity() throws {
        let lines = [
            ###"{"type":"user","uuid":"meta","message":{"role":"user","content":"# AGENTS.md instructions for /tmp"}}"###,
            ###"{"type":"assistant","uuid":"think","message":{"id":"a","role":"assistant","content":[{"type":"thinking","thinking":"Check the failing command."}]}}"###,
            ###"{"type":"assistant","uuid":"text","message":{"id":"a","role":"assistant","content":[{"type":"text","text":"## Result\nTesting first."},{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"swift test"}}]}}"###,
            ###"{"type":"user","uuid":"out","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","is_error":true,"content":"test failed"}]}}"###,
            ###"{"type":"system","subtype":"compact_boundary"}"###
        ]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let record = try SessionHistoryParser.read(url: file, agent: .claude, updatedAt: Date())
        let rows = SessionHistoryPresentation.rows(record.messages)
        #expect(rows.count == 2)
        #expect(rows[0].text.contains("## Result"))
        #expect(rows[0].thinking == "Check the failing command.")
        #expect(rows[0].tools.count == 1)
        #expect(rows[0].tools[0].isError)
        #expect(rows[0].tools[0].output == "test failed")
        #expect(rows[0].tools[0].preview == "swift test")
        let resultID = try #require(record.messages.first(where: { $0.isToolOutput == true })?.id)
        #expect(rows[0].contains(resultID))
        #expect(rows.last?.kind == .compactSummary)
        let meta = try #require(record.messages.first(where: { $0.kind == .meta }))
        #expect(SessionHistoryPresentation.rows(record.messages, revealing: meta.id).contains { $0.contains(meta.id) })
    }
    @Test func markdownUsesBlockStructureAndCodeContent() {
        let blocks = SessionHistoryMarkdown.parse("# Heading\n\n**bold**\n\n```swift\nlet n = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        #expect(blocks.count == 4)
        guard case .heading(1, let heading) = blocks[0], case .code("swift", let code) = blocks[2], case .table(let table) = blocks[3] else { Issue.record("Expected heading, fenced code and GFM table"); return }
        #expect(heading.contains("Heading")); #expect(code == "let n = 1\n"); #expect(table.count == 2)
    }
}
