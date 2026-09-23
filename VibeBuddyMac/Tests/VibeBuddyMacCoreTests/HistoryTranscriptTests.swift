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
        let repository = SessionTranscriptReader(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), cursorHome: root.appendingPathComponent("cursor"))
        let first = try await HistoryTools.getSession(arguments: ["key": "claude-code:native", "max_messages": 1], reader: repository)
        XCTAssertTrue(first.hasPrefix("Source revision:")); XCTAssertTrue(first.contains("(source)"))
        XCTAssertTrue(first.contains("[seq 1] User")); XCTAssertTrue(first.contains("from_seq=2")); XCTAssertFalse(first.contains("secret-meta"))
        let request = try HistoryCLI.parse(["show", "vibebuddy://session/claude-code:native#2", "--max-messages", "1"])
        let page = try await HistoryTools.getSession(arguments: request.arguments, reader: repository)
        XCTAssertTrue(page.contains("[seq 2] Assistant")); XCTAssertTrue(page.contains("Tool: Read"))
        XCTAssertFalse(page.contains("output-detail")); XCTAssertFalse(page.contains("reasoning-detail"))
        let expanded = try await HistoryTools.getSession(arguments: ["key": "claude-code:native", "from_seq": 2, "max_messages": 1, "tools": true, "thinking": true], reader: repository)
        XCTAssertTrue(expanded.contains("[seq 2] Assistant")); XCTAssertTrue(expanded.contains("output-detail")); XCTAssertTrue(expanded.contains("reasoning-detail"))
        let transcript = try await repository.readTranscript(key: "claude-code:native")
        for message in transcript.session.messages where message.role == .tool { XCTAssertEqual(transcript.seq(messageID: message.id), 2) }
        let beyond = try await HistoryTools.getSession(arguments: ["key": "claude-code:native", "from_seq": 999], reader: repository)
        XCTAssertTrue(beyond.contains("End of readable transcript")); XCTAssertFalse(beyond.contains("[seq"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["claude"], "reading writes nothing")
        XCTAssertThrowsError(try HistorySessionReference("vibebuddy://session/codex:native#0"))
        do { _ = try await repository.readTranscript(key: "claude-code:missing"); XCTFail("unknown accepted") } catch HistoryToolError.executionFailed { }
        let duplicate = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("other/native.jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: duplicate)
        let fresh = SessionTranscriptReader(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), cursorHome: root.appendingPathComponent("cursor"))
        do { _ = try await fresh.readTranscript(key: "claude-code:native"); XCTFail("ambiguity accepted") } catch HistoryToolError.executionFailed { }
    }

    func testNativeArchiveMoveIsFollowedAndDuplicatesStayAmbiguous() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        let file = codex.appendingPathComponent("sessions/native.jsonl")
        let archived = codex.appendingPathComponent("archived_sessions/native.jsonl")
        for url in [file, archived] { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let source = #"{"type":"session_meta","payload":{"id":"native","cwd":"/repo"}}"# + "\n" +
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Retain this dialogue after archive"}]}}"#
        try Data(source.utf8).write(to: file)
        let reader = SessionTranscriptReader(claudeHome: root.appendingPathComponent("claude"), codexHome: codex, cursorHome: root.appendingPathComponent("cursor"))
        let live = try await reader.readTranscript(key: "codex:native")
        XCTAssertEqual(live.session.sourceArchived, false)
        try FileManager.default.moveItem(at: file, to: archived)
        let moved = try await reader.readTranscript(key: "codex:native")
        XCTAssertEqual(moved.session.sourceArchived, true)
        XCTAssertEqual(URL(fileURLWithPath: moved.session.sourcePath).lastPathComponent, "native.jsonl")
        let output = try await HistoryTools.getSession(arguments: try HistoryCLI.parse(["show", "vibebuddy://session/codex:native#1"]).arguments, reader: reader)
        XCTAssertTrue(output.contains("[seq 1] User"))
        XCTAssertTrue(output.contains("Retain this dialogue after archive"))
        // Two available files for one id stay ambiguous once the cached path is gone.
        try Data(source.utf8).write(to: file)
        try FileManager.default.removeItem(at: archived)
        try Data(source.utf8).write(to: archived)
        let duplicate = SessionTranscriptReader(claudeHome: root.appendingPathComponent("claude"), codexHome: codex, cursorHome: root.appendingPathComponent("cursor"))
        do { _ = try await duplicate.readTranscript(key: "codex:native"); XCTFail("available duplicates accepted") }
        catch HistoryToolError.executionFailed { }
    }
}
