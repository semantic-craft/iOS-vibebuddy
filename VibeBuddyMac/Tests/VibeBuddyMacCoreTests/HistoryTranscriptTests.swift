import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class HistoryTranscriptTests: XCTestCase {
    func testProjectionPagingExpansionAndReferenceParity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("claude/projects/repo/native.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            ##"{"sessionId":"native","type":"user","message":{"role":"user","content":"# AGENTS.md instructions secret-meta"}}"##,
            #"{"sessionId":"native","type":"user","message":{"role":"user","content":"Hello"}}"#,
            #"{"sessionId":"native","type":"assistant","message":{"id":"a","role":"assistant","content":[{"type":"thinking","thinking":"reasoning-detail"},{"type":"text","text":"Answer"},{"type":"tool_use","id":"t","name":"Read","input":{"path":"/file","extra":"input-detail"}}]}}"#,
            #"{"sessionId":"native","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"output-detail"}]}}"#,
            #"{"sessionId":"native","type":"user","message":{"role":"user","content":"Next"}}"#
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: source)
        let repository = SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), cacheDirectory: root.appendingPathComponent("absent"), readOnly: true)
        let first = try await HistoryTools.getSession(arguments: ["key": "claude-code:native", "max_messages": 1], repository: repository)
        XCTAssertTrue(first.hasPrefix("Source revision:")); XCTAssertTrue(first.contains("source, index stale"))
        XCTAssertTrue(first.contains("[seq 1] User")); XCTAssertTrue(first.contains("from_seq=2")); XCTAssertFalse(first.contains("secret-meta"))
        let request = try HistoryCLI.parse(["show", "vibebuddy://session/claude-code:native#2", "--max-messages", "1"])
        let page = try await HistoryTools.getSession(arguments: request.arguments, repository: repository)
        XCTAssertTrue(page.contains("[seq 2] Assistant")); XCTAssertTrue(page.contains("Tool: Read"))
        XCTAssertFalse(page.contains("output-detail")); XCTAssertFalse(page.contains("reasoning-detail"))
        let expanded = try await HistoryTools.getSession(arguments: ["key": "claude-code:native", "from_seq": 2, "max_messages": 1, "tools": true, "thinking": true], repository: repository)
        XCTAssertTrue(expanded.contains("[seq 2] Assistant")); XCTAssertTrue(expanded.contains("output-detail")); XCTAssertTrue(expanded.contains("reasoning-detail"))
        let transcript = try await repository.readTranscript(key: "claude-code:native")
        for message in transcript.session.messages where message.role == .tool { XCTAssertEqual(transcript.seq(messageID: message.id), 2) }
        let beyond = try await HistoryTools.getSession(arguments: ["key": "claude-code:native", "from_seq": 999], repository: repository)
        XCTAssertTrue(beyond.contains("End of readable transcript")); XCTAssertFalse(beyond.contains("[seq"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
        XCTAssertThrowsError(try HistorySessionReference("vibebuddy://session/codex:native#0"))
        do { _ = try await repository.readTranscript(key: "claude-code:missing"); XCTFail("unknown accepted") } catch HistoryToolError.executionFailed { }
        let duplicate = source.deletingLastPathComponent().appendingPathComponent("other/native.jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: duplicate)
        do { _ = try await repository.readTranscript(key: "claude-code:native"); XCTFail("ambiguity accepted") } catch HistoryToolError.executionFailed { }
    }

    func testLegacyCacheStaleSourceAndRevisionMismatchNeverWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude"), codex = root.appendingPathComponent("codex"), cache = root.appendingPathComponent("cache")
        let file = codex.appendingPathComponent("sessions/native.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = #"{"type":"session_meta","payload":{"id":"native","cwd":"/repo"}}"#
        let message = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"old"}]}}"#
        try Data((header + "\n" + message).utf8).write(to: file)
        let writer = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cacheDirectory: cache)
        _ = try await writer.refresh()
        let before = try bytes(cache)
        let reader = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cacheDirectory: cache, readOnly: true)
        let warm = try await reader.readTranscript(key: "codex:native")
        XCTAssertEqual(warm.provenance, "cache")
        try Data((header + "\n" + message + "\n" + message.replacingOccurrences(of: "old", with: "fresh")).utf8).write(to: file)
        let stale = try await reader.readTranscript(key: "codex:native")
        XCTAssertEqual(stale.provenance, "source, index stale")
        XCTAssertNotEqual(stale.session.sourceRevision, warm.session.sourceRevision)
        XCTAssertTrue(stale.session.messages.contains { $0.text == "fresh" })
        // A warm page reuses its single slot, even if an unrelated disk cache becomes unreadable.
        XCTAssertEqual(try bytes(cache), before)
        let again = try await reader.readTranscript(key: "codex:native")
        XCTAssertEqual(again.session, stale.session)
        let content = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first { $0.lastPathComponent != "index.json" })
        var full = try JSONDecoder().decode(SessionHistorySession.self, from: Data(contentsOf: content))
        full.sourceRevision = "mismatched-revision"
        try JSONEncoder().encode(full).write(to: content)
        let mismatchedBefore = try bytes(cache)
        let freshReader = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cacheDirectory: cache, readOnly: true)
        let mismatched = try await freshReader.readTranscript(key: "codex:native")
        XCTAssertEqual(mismatched.provenance, "source, index stale")
        XCTAssertEqual(try bytes(cache), mismatchedBefore)
    }
    private func bytes(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
