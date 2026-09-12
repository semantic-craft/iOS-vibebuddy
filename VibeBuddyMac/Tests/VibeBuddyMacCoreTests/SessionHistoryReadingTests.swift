import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite struct SessionHistoryReadingTests {
    @Test func groupedToolsThinkingAndHiddenContextKeepSearchIdentity() throws {
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
        let material = SessionHistorySummaryService.material(record)
        #expect(!material.text.contains("AGENTS.md"))
        #expect(!material.text.contains("Check the failing command."))
        #expect(material.text.contains("test failed"))
        var compacted = record
        compacted.messages = [.init(id: "source-summary", role: .system, text: "Earlier decision: retain local archives.", kind: .compactSummary)]
        #expect(SessionHistorySummaryService.material(compacted).text.contains("Earlier decision: retain local archives."))
    }
    @Test func markdownUsesBlockStructureAndCodeContent() {
        let blocks = SessionHistoryMarkdown.parse("# Heading\n\n**bold**\n\n```swift\nlet n = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        #expect(blocks.count == 4)
        guard case .heading(1, let heading) = blocks[0], case .code("swift", let code) = blocks[2], case .table(let table) = blocks[3] else { Issue.record("Expected heading, fenced code and GFM table"); return }
        #expect(heading.contains("Heading")); #expect(code == "let n = 1\n"); #expect(table.count == 2)
    }
    @Test func summaryCoverageAndConversationOutputAreDistinctFromNotifications() throws {
        let messages = (0..<30).map { SessionHistoryMessage(id: "\($0)", role: .user, text: String(repeating: "evidence \($0) ", count: 1000)) }
        let history = SessionHistorySession(id: "test", nativeSessionID: "test", agent: .claude, projectPath: "/tmp", title: "Goal", sourcePath: "/tmp/source", updatedAt: Date(), messages: messages)
        let material = SessionHistorySummaryService.material(history)
        #expect(material.text.count < 50_000)
        #expect(material.coverage.contains("partial"))
        #expect(material.text.contains("evidence 0")); #expect(material.text.contains("evidence 29"))
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason":"stop", "message":["role":"assistant", "content":"## Goal\nSummarize the conversation.\n\n## Open work\nDevice testing is pending."]]]])
        #expect(CompletionSummaryHTTP.decode(response, provider: .qwen, conversation: true).failure == nil)
        #expect(CompletionSummaryHTTP.decode(response, provider: .qwen).failure != nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_HISTORY_SUMMARY_E2E"] == "1"))
    func configuredProviderSummarizesARealHistoryCopy() async throws {
        let environment = ProcessInfo.processInfo.environment
        let source = try #require(environment["VIBEBUDDY_HISTORY_SUMMARY_SOURCE"])
        let output = try #require(environment["VIBEBUDDY_HISTORY_SUMMARY_OUTPUT"])
        let file = URL(fileURLWithPath: source)
        var history = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        let attributes = try FileManager.default.attributesOfItem(atPath: source)
        history.sourceRevision = "\((attributes[.modificationDate] as? Date ?? .distantPast).timeIntervalSince1970)|\((attributes[.size] as? Int) ?? 0)"
        let defaults = try #require(UserDefaults(suiteName: "com.vibebuddy.mac"))
        let config = CompletionSummaryConfiguration.load(defaults: defaults)
        let result = try await SessionHistorySummaryService().generate(history, configuration: config)
        #expect(!result.text.isEmpty)
        #expect(result.isCurrent(for: history))
        let repository = SessionHistoryRepository(cacheDirectory: URL(fileURLWithPath: output))
        try await repository.saveSummary(result)
        let restored = try await repository.summary(sessionID: history.id)
        #expect(restored == result)
        print("History summary generated with configured provider; bytes=\(result.text.utf8.count)")
    }
}
