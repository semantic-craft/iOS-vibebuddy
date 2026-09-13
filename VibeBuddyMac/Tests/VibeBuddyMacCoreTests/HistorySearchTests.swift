import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class HistorySearchTests: XCTestCase {
    func testReadableHitsScopeLimitAndRawToolReferenceRoundTripNeverWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = fixture.repository()
        _ = try await writer.refresh()
        let before = try fixture.bytes()
        let reader = fixture.repository(readOnly: true)
        let request = try HistoryCLI.parse(["search", "中文", "--project", "repo", "--agent", "claude-code", "--limit", "1"])
        XCTAssertEqual(request.tool, "vibebuddy_search")
        let text = try await HistoryTools.search(arguments: request.arguments, repository: reader)
        let direct = try await HistoryTools.search(arguments: ["query": "中文", "project": "/work/repo", "agents": ["claude-code"], "limit": 1], repository: reader)
        XCTAssertEqual(HistoryCLI.output(text), direct + "\n")
        XCTAssertTrue(text.contains("ref: vibebuddy://session/claude-code:native#1"))
        XCTAssertEqual(text.components(separatedBy: "ref: ").count - 1, 1)
        XCTAssertFalse(text.contains("injected-only"))
        let page = try await HistoryTools.getSession(arguments: ["key": reference(text), "max_messages": 1], repository: reader)
        XCTAssertTrue(page.contains("## [seq 1] User"))
        XCTAssertTrue(page.contains("中文结果"))

        let code = try await HistoryTools.search(arguments: ["query": "worker.run(", "project": "/work/repo"], repository: reader)
        let transcript = try await reader.readTranscript(key: "claude-code:native")
        let raw = try XCTUnwrap(transcript.session.messages.first { $0.isToolOutput == true })
        let seq = try XCTUnwrap(transcript.seq(messageID: raw.id))
        XCTAssertEqual(reference(code), "vibebuddy://session/claude-code:native#\(seq)")
        let expanded = try await HistoryTools.getSession(arguments: ["key": reference(code), "max_messages": 1, "tools": true], repository: reader)
        XCTAssertTrue(expanded.contains("## [seq \(seq)] Assistant"))
        XCTAssertTrue(expanded.contains("worker.run("))

        let scoped = try await HistoryTools.search(arguments: ["query": "中文结果", "agents": ["codex"], "limit": 1], repository: reader)
        XCTAssertTrue(scoped.contains("ref: vibebuddy://session/codex:older#1"))
        let recent = try await HistoryTools.search(arguments: ["query": "中文结果", "agents": ["codex"], "since": "2026-09-01"], repository: reader)
        XCTAssertTrue(recent.contains("No matches found."))
        let missingProject = try await HistoryTools.search(arguments: ["query": "中文结果", "project": "unknown"], repository: reader)
        XCTAssertTrue(missingProject.contains("Known projects:"))
        XCTAssertEqual(text.components(separatedBy: "\n").last, direct.components(separatedBy: "\n").last)
        let empty = try await HistoryTools.search(arguments: ["query": "no-match-sentinel"], repository: reader)
        XCTAssertTrue(empty.contains("No matches found."))
        XCTAssertEqual(try fixture.bytes(), before)
    }

    func testReadOnlyOpenMissingRowsAndMissingDatabaseAreExplicitAndDoNotCreateFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = fixture.repository()
        let snapshot = try await writer.refresh()
        let native = try XCTUnwrap(snapshot.sessions.first { $0.agent == .claude })
        let fullValue = try await writer.session(id: native.id)
        let full = try XCTUnwrap(fullValue)
        do {
            let writable = try SessionHistorySearchIndex(directory: fixture.cache)
            try writable.replace(full, stamp: "old-revision")
        }
        let before = try fixture.bytes()
        do {
            let readonly = try SessionHistorySearchIndex(directory: fixture.cache, readOnly: true)
            XCTAssertThrowsError(try readonly.replace(full, stamp: "must-not-write"))
        }
        let reader = fixture.repository(readOnly: true)
        let text = try await HistoryTools.search(arguments: ["query": "中文结果", "project": "/work/repo"], repository: reader)
        XCTAssertTrue(text.contains("claude-code:native: not indexed yet"))
        XCTAssertFalse(text.contains("ref: "))
        XCTAssertEqual(try fixture.bytes(), before)

        try FileManager.default.removeItem(at: fixture.cache.appendingPathComponent("search.sqlite"))
        let withoutDB = try fixture.bytes()
        let missing = try await HistoryTools.search(arguments: ["query": "中文结果"], repository: reader)
        XCTAssertTrue(missing.contains("claude-code:native: not indexed yet"))
        XCTAssertTrue(missing.contains("codex:older: not indexed yet"))
        XCTAssertEqual(try fixture.bytes(), withoutDB)
        let absent = fixture.root.appendingPathComponent("absent")
        XCTAssertThrowsError(try SessionHistorySearchIndex(directory: absent, readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testChangedSourceCannotProduceReferenceToWrongRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.repository().refresh()
        let original = try Data(contentsOf: fixture.claudeSource)
        try (original + Data("\n".utf8)).write(to: fixture.claudeSource)
        let before = try fixture.bytes()
        let reader = fixture.repository(readOnly: true)
        let text = try await HistoryTools.search(arguments: ["query": "中文结果", "project": "/work/repo"], repository: reader)
        XCTAssertTrue(text.contains("not indexed yet"))
        XCTAssertFalse(text.contains("ref: "))
        for invalid: [String: Any] in [[:], ["query": "  "], ["query": 3], ["query": "中文", "limit": true], ["query": "中文", "starred": true]] {
            do { _ = try await HistoryTools.search(arguments: invalid, repository: reader); XCTFail("invalid arguments accepted") }
            catch HistoryToolError.invalidArguments { }
        }
        XCTAssertEqual(try fixture.bytes(), before)
    }

    func testUnstampedCachePublishedAfterMetadataCannotInventReference() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.repository().refresh()
        let cacheFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil).first { file in
            guard file.pathExtension == "json", file.lastPathComponent != "index.json",
                  let session = try? JSONDecoder().decode(SessionHistorySession.self, from: Data(contentsOf: file)) else { return false }
            return session.agent == .claude
        })
        var session = try JSONDecoder().decode(SessionHistorySession.self, from: Data(contentsOf: cacheFile))
        session.sourceRevision = nil
        session.messages.reverse()
        try JSONEncoder().encode(session).write(to: cacheFile)
        let indexFile = fixture.cache.appendingPathComponent("index.json")
        let indexTime = try XCTUnwrap(indexFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try FileManager.default.setAttributes([.modificationDate: indexTime.addingTimeInterval(10)], ofItemAtPath: cacheFile.path)
        let before = try fixture.bytes()
        let reader = fixture.repository(readOnly: true)
        let text = try await HistoryTools.search(arguments: ["query": "中文结果", "project": "/work/repo"], repository: reader)
        XCTAssertTrue(text.contains("References unavailable:"))
        XCTAssertFalse(text.contains("ref: "))
        let shown = try await HistoryTools.getSession(arguments: ["key": "claude-code:native"], repository: reader)
        XCTAssertTrue(shown.contains("source, index stale"))
        XCTAssertTrue(shown.contains("## [seq 1] User"))
        XCTAssertEqual(try fixture.bytes(), before)
    }

    private func reference(_ text: String) -> String {
        text.components(separatedBy: "\n").first { $0.hasPrefix("ref: ") }.map { String($0.dropFirst(5)) } ?? "missing"
    }

    private struct Fixture {
        let root: URL
        var cache: URL { root.appendingPathComponent("history") }
        var claudeSource: URL { root.appendingPathComponent("claude/projects/repo/native.jsonl") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let codexSource = root.appendingPathComponent("codex/sessions/older.jsonl")
            for file in [claudeSource, codexSource] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let claude = [
                ##"{"sessionId":"native","cwd":"/work/repo","timestamp":"2026-09-10T10:00:00Z","type":"user","message":{"role":"user","content":"# AGENTS.md instructions 中文结果 injected-only"}}"##,
                #"{"sessionId":"native","type":"user","message":{"role":"user","content":"中文结果"}}"#,
                #"{"sessionId":"native","type":"assistant","message":{"id":"a","role":"assistant","content":[{"type":"text","text":"Checking code"},{"type":"tool_use","id":"tool","name":"Bash","input":{"command":"cat result"}}]}}"#,
                #"{"sessionId":"native","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool","content":"worker.run(argument) 完成"}]}}"#
            ]
            let codex = [
                #"{"timestamp":"2026-08-01T10:00:00Z","type":"session_meta","payload":{"id":"older","cwd":"/work/other"}}"#,
                #"{"timestamp":"2026-08-01T10:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"中文结果"}]}}"#
            ]
            try Data(claude.joined(separator: "\n").utf8).write(to: claudeSource)
            try Data(codex.joined(separator: "\n").utf8).write(to: codexSource)
        }
        func repository(readOnly: Bool = false) -> SessionHistoryRepository {
            SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache, readOnly: readOnly)
        }
        func bytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
