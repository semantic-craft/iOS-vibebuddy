import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class CursorHistoryTests: XCTestCase {
    func testTranscriptPreservesReadableContentProjectTimeAndCoverage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let prompt = "Fix the search field\n" + String(repeating: "完整正文", count: 300)
        let reply = String(repeating: "Readable response. ", count: 70).trimmingCharacters(in: .whitespaces)
        let input = String(repeating: "echo searchable-tool-input; ", count: 50)
        let text = "<timestamp>Wednesday, Sep 9, 2026, 3:14 AM (UTC+8)</timestamp>\n<user_query>\(prompt)</user_query>"
        try fixture.write([
            ["role": "user", "message": ["content": [["type": "text", "text": text]]]],
            ["role": "assistant", "message": ["content": [
                ["type": "text", "text": reply],
                ["type": "tool_use", "name": "Shell", "input": ["command": input]],
                ["type": "tool_use", "name": "Read", "input": ["path": "source.swift"]]
            ]]],
            ["type": "turn_ended", "status": "error", "error": "command failed"],
            ["type": "turn_ended", "status": "aborted"]
        ], to: fixture.source)
        let session = try SessionHistoryParser.read(url: fixture.source, agent: .cursor, updatedAt: .distantPast)
        XCTAssertEqual(session.id, "cursor:" + fixture.id)
        XCTAssertEqual(session.title, "Fix the search field")
        XCTAssertEqual(session.projectPath, fixture.project.path)
        XCTAssertEqual(session.updatedAt, ISO8601DateFormatter().date(from: "2026-09-08T19:14:00Z"))
        XCTAssertEqual(session.messageCount, 4)
        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant, .tool, .tool])
        XCTAssertEqual(session.messages[0].text, prompt)
        XCTAssertEqual(session.messages[1].text, reply)
        XCTAssertTrue(session.messages[2].text.contains(input))
        XCTAssertTrue(session.messages.allSatisfy { $0.isToolOutput != true && $0.kind != .thinking })
        XCTAssertTrue(session.warnings.contains { $0.contains("no tool results or thinking") })
        XCTAssertTrue(session.warnings.contains { $0.contains("error: command failed") })
        XCTAssertTrue(session.warnings.contains { $0.contains("aborted") })
        let raw = String(data: try JSONSerialization.data(withJSONObject: ["role": "assistant", "message": ["content": [["type": "text", "text": reply]]]]), encoding: .utf8)!
        XCTAssertEqual(CursorTranscripts.parse(line: raw), [.assistantText(String(reply.prefix(600)))])

        let flat = fixture.source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("flat.jsonl")
        try fixture.write([["role": "user", "message": ["content": [["type": "text", "text": "<timestamp>unparseable</timestamp>\nUnwrapped question"]]]]], to: flat)
        let fallback = Date(timeIntervalSince1970: 1234)
        let flatSession = try SessionHistoryParser.read(url: flat, agent: .cursor, updatedAt: fallback)
        XCTAssertEqual(flatSession.updatedAt, fallback)
        XCTAssertEqual(flatSession.projectPath, fixture.project.path)
        XCTAssertEqual(flatSession.messages.first?.text, "Unwrapped question")
    }

    func testMinuteBearingUTCOffsetsAndInvalidFallback() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let fallback = Date(timeIntervalSince1970: 1234)
        let cases: [(String, String?)] = [
            ("+5:30", "2026-09-08T21:44:00Z"),
            ("-3:30", "2026-09-09T06:44:00Z"),
            ("-0:30", "2026-09-09T03:44:00Z"),
            ("+5:45", "2026-09-08T21:29:00Z"),
            ("+5:60", nil),
            ("+14:01", nil)
        ]
        for (offset, expected) in cases {
            let text = "<timestamp>Wednesday, Sep 9, 2026, 3:14 AM (UTC\(offset))</timestamp>\n<user_query>Offset check</user_query>"
            try fixture.write([["role": "user", "message": ["content": [["type": "text", "text": text]]]]], to: fixture.source)
            let session = try SessionHistoryParser.read(url: fixture.source, agent: .cursor, updatedAt: fallback)
            let date = expected.flatMap { ISO8601DateFormatter().date(from: $0) }
            XCTAssertEqual(session.messages.first?.timestamp, date, offset)
            XCTAssertEqual(session.updatedAt, date ?? fallback, offset)
        }
    }

    func testReaderSeparatesAgentKeysAndShowReadsCursor() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write([
            ["role": "user", "message": ["content": [["type": "text", "text": "Cursor unique search phrase"]]]],
            ["role": "assistant", "message": ["content": [["type": "text", "text": "The field retains focus."]]]],
            ["type": "turn_ended", "status": "success"]
        ], to: fixture.source)
        let cloud = fixture.source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bc-" + fixture.id + ".jsonl")
        try FileManager.default.copyItem(at: fixture.source, to: cloud)
        let stray = fixture.cursor.appendingPathComponent("projects/stray.jsonl")
        try FileManager.default.copyItem(at: fixture.source, to: stray)
        let claude = fixture.root.appendingPathComponent("claude/projects/p/" + fixture.id + ".jsonl")
        try fixture.write([["type": "user", "sessionId": fixture.id, "cwd": fixture.project.path,
                            "message": ["role": "user", "content": "Claude text"]]], to: claude)
        let codex = fixture.root.appendingPathComponent("codex/sessions/rollout-2026-09-09T03-14-00-" + fixture.id + ".jsonl")
        try fixture.write([
            ["type": "session_meta", "payload": ["id": fixture.id, "cwd": fixture.project.path]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Codex text"]]
        ], to: codex)
        let original = try Data(contentsOf: fixture.source)
        let reader = fixture.reader()
        // One native id under three agents: each key reads its own agent's file only.
        for (key, text) in [("claude-code:", "Claude text"), ("codex:", "Codex text"), ("cursor:", "Cursor unique search phrase")] {
            let transcript = try await reader.readTranscript(key: key + fixture.id)
            XCTAssertTrue(transcript.session.messages.contains { $0.text == text }, key)
        }
        let reference = "vibebuddy://session/cursor:" + fixture.id + "#1"
        let show = try await HistoryTools.getSession(arguments: ["key": reference], reader: reader)
        XCTAssertTrue(show.contains("Cursor unique search phrase"))
        XCTAssertTrue(show.contains("no tool results or thinking"))
        XCTAssertEqual(try HistorySessionReference(reference).key, "cursor:" + fixture.id)
        // Cloud agents (`bc-`) are outside the local transcript's coverage.
        do { _ = try await reader.readTranscript(key: "cursor:bc-" + fixture.id); XCTFail("read a cloud agent") } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.source), original)
    }

    private struct Fixture {
        let root: URL
        let project: URL
        let cursor: URL
        let source: URL
        let id = "747b278b-e90a-462f-bc5a-9608a8ca31ae"
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cursor-history-" + UUID().uuidString)
            project = root.appendingPathComponent("project-with-hyphens")
            cursor = root.appendingPathComponent("cursor")
            let flattened = String(project.path.dropFirst()).replacingOccurrences(of: "/", with: "-")
            source = cursor.appendingPathComponent("projects/" + flattened + "/agent-transcripts/" + id + "/" + id + ".jsonl")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func write(_ records: [[String: Any]], to file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
            try data.write(to: file)
        }
        func reader() -> SessionTranscriptReader {
            SessionTranscriptReader(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), cursorHome: cursor)
        }
    }
}
