import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class HistoryToolsTests: XCTestCase {
    func testRegistryAndCLIParity() throws {
        let definitions = HistoryTools.definitions()
        XCTAssertEqual(definitions.compactMap { $0["name"] as? String }, ["vibebuddy_get_session", "vibebuddy_live_status", "vibebuddy_handoff_facts"])
        XCTAssertEqual(Set(HistoryCLI.commands.values), Set(definitions.compactMap { $0["name"] as? String }))
        for definition in definitions {
            XCTAssertEqual((definition["annotations"] as? [String: Bool])?["readOnlyHint"], true)
            XCTAssertEqual((definition["inputSchema"] as? [String: Any])?["additionalProperties"] as? Bool, false)
        }
        let request = try HistoryCLI.parse(["show", "codex:native", "--max-messages", "5", "--tools"])
        XCTAssertEqual(request.tool, "vibebuddy_get_session")
        XCTAssertEqual(request.arguments["key"] as? String, "codex:native")
        XCTAssertEqual(request.arguments["max_messages"] as? String, "5")
        XCTAssertEqual(request.arguments["tools"] as? Bool, true)
        XCTAssertThrowsError(try HistoryCLI.parse(["show"]))
        XCTAssertThrowsError(try HistoryCLI.parse(["show", "codex:native", "--agent", "codex"]))
    }

    /// The reader locates one transcript by native id under the agent roots,
    /// writes nothing anywhere, and sees a rewrite on the next read.
    func testReaderLocatesByNativeIDAndWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude"), codex = root.appendingPathComponent("codex"), cursor = root.appendingPathComponent("cursor")
        let rollout = codex.appendingPathComponent("sessions/2026/09/23/rollout-2026-09-23T10-00-00-native.jsonl")
        let archived = codex.appendingPathComponent("archived_sessions/rollout-2026-09-01T10-00-00-old.jsonl")
        let claudeFile = claude.appendingPathComponent("projects/-repo/claude-id.jsonl")
        let cursorFile = cursor.appendingPathComponent("projects/Users-me-repo/agent-transcripts/cur-id/cur-id.jsonl")
        for file in [rollout, archived, claudeFile, cursorFile] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        func codexLines(_ id: String, _ text: String) -> Data {
            Data((#"{"type":"session_meta","payload":{"id":"ID","cwd":"/repo","source":"cli"}}"#.replacingOccurrences(of: "ID", with: id) + "\n"
                + #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"TEXT"}]}}"#.replacingOccurrences(of: "TEXT", with: text)).utf8)
        }
        try codexLines("native", "hello").write(to: rollout)
        try codexLines("old", "archived hello").write(to: archived)
        try Data(#"{"type":"user","sessionId":"claude-id","cwd":"/repo","message":{"role":"user","content":"from claude"}}"#.utf8).write(to: claudeFile)
        try Data(#"{"role":"user","message":{"content":[{"type":"text","text":"<user_query>from cursor</user_query>"}]}}"#.utf8).write(to: cursorFile)
        let reader = SessionTranscriptReader(claudeHome: claude, codexHome: codex, cursorHome: cursor)
        let first = try await reader.readTranscript(key: "codex:native")
        XCTAssertEqual(first.session.messages.map(\.text), ["hello"])
        XCTAssertEqual(first.session.sourceArchived, false)
        let old = try await reader.readTranscript(key: "codex:old")
        XCTAssertEqual(old.session.sourceArchived, true)
        let fromClaude = try await reader.readTranscript(key: "claude-code:claude-id")
        XCTAssertTrue(fromClaude.session.messages.contains { $0.text == "from claude" })
        let fromCursor = try await reader.readTranscript(key: "cursor:cur-id")
        XCTAssertTrue(fromCursor.session.messages.contains { $0.text.contains("from cursor") })
        try codexLines("native", "changed").write(to: rollout, options: .atomic)
        let second = try await reader.readTranscript(key: "codex:native")
        XCTAssertEqual(second.session.messages.map(\.text), ["changed"])
        do { _ = try await reader.readTranscript(key: "codex:missing"); XCTFail("found a missing session") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Unknown session key")) }
        do { _ = try await reader.readTranscript(key: "grok-build:abc"); XCTFail("read Grok") } catch {}
        let everything = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.compactMap { ($0 as? URL)?.lastPathComponent }
        XCTAssertEqual(Set(everything.filter { $0.hasSuffix(".jsonl") }), Set([rollout, archived, claudeFile, cursorFile].map(\.lastPathComponent)))
        XCTAssertFalse(everything.contains { $0.hasSuffix(".json") || $0.hasSuffix(".sqlite") }, "the reader writes no cache")
    }

    func testE2ERunReadsOnlyItsOwnAgentRoots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("agents/codex/sessions/e2e.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"type":"session_meta","payload":{"id":"e2e","cwd":"/repo","source":"cli"}}"#.utf8).write(to: file)
        let reader = SessionTranscriptReader.forCurrentRun(environment: ["VIBEBUDDY_E2E_ROOT": root.path])
        let transcript = try await reader.readTranscript(key: "codex:e2e")
        XCTAssertEqual(transcript.session.nativeSessionID, "e2e")
    }
}
