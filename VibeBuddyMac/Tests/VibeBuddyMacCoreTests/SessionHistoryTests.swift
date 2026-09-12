import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class SessionHistoryTests: XCTestCase {
    func testIncrementalSearchIdentityFavoritesAndMissingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude")
        let codex = root.appendingPathComponent("codex")
        let cache = root.appendingPathComponent("cache")
        let c = claude.appendingPathComponent("projects/project/same.jsonl")
        let x = codex.appendingPathComponent("sessions/rollout.jsonl")
        for file in [c, x] { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let original = #"{"uuid":"u1","sessionId":"same","cwd":"/project-a","type":"user","message":{"role":"user","content":[{"type":"text","text":"中文恢复 await worker()"}]}}"# + "\n"
        try Data(original.utf8).write(to: c)
        try Data((#"{"type":"session_meta","payload":{"id":"same","cwd":"/project-b"}}"# + "\n" + #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"HELLO"}]}}"# + "\n").utf8).write(to: x)
        let child = claude.appendingPathComponent("projects/project/subagents/agent-child.jsonl")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(original.replacingOccurrences(of: "中文恢复 await worker()", with: "child must not replace parent").utf8).write(to: child)
        let repository = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cacheDirectory: cache)
        let initial = try await repository.refresh()
        XCTAssertEqual(initial.sessions.count, 2)
        XCTAssertTrue(initial.sessions.allSatisfy { $0.messages.isEmpty })
        let loaded = try await repository.session(id: "claude:same")
        XCTAssertEqual(loaded?.messages.count, 1)
        XCTAssertTrue(initial.issues.contains { $0.contains("child-session") })
        XCTAssertEqual(Set(initial.sessions.map(\.id)), ["claude:same", "codex:same"])
        let chinese = try await repository.search("恢复")
        XCTAssertEqual(chinese.first?.sessionID, "claude:same")
        let code = try await repository.search("await worker()")
        XCTAssertEqual(code.first?.messageID, chinese.first?.messageID)
        let english = try await repository.search("hello")
        XCTAssertEqual(english.count, 1)
        try await repository.setFavorite(sessionID: "claude:same", isFavorite: true)
        let appended = original + #"{"uuid":"a1","sessionId":"same","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"new result"}]}}"# + "\n{broken"
        try Data(appended.utf8).write(to: c)
        let incremental = try await repository.refresh()
        XCTAssertEqual(incremental.sessions.first(where: { $0.agent == .claude })?.messageCount, 2)
        XCTAssertFalse(incremental.sessions.first(where: { $0.agent == .claude })!.warnings.isEmpty)
        let stable = try await repository.search("恢复")
        XCTAssertEqual(stable.first?.messageID, chinese.first?.messageID)
        let restarted = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cacheDirectory: cache)
        let restored = await restarted.snapshot()
        XCTAssertTrue(restored.sessions.first(where: { $0.agent == .claude })!.isFavorite)
        let rebuilt = try await restarted.refresh(rebuild: true)
        XCTAssertTrue(rebuilt.sessions.first(where: { $0.agent == .claude })!.isFavorite)
        XCTAssertEqual(try Data(contentsOf: c), Data(appended.utf8))
        try FileManager.default.removeItem(at: c)
        let missing = try await restarted.refresh()
        XCTAssertFalse(missing.sessions.first(where: { $0.agent == .claude })!.isAvailable)
        XCTAssertTrue(missing.sessions.first(where: { $0.agent == .claude })!.isFavorite)
    }

    func testRefreshBatchesAdvanceAndWarmRefreshDoesNotRewriteIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude")
        let codex = root.appendingPathComponent("codex")
        let cache = root.appendingPathComponent("cache")
        let project = claude.appendingPathComponent("projects/p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for id in ["one", "two"] {
            let row = "{\"uuid\":\"u\",\"sessionId\":\"\(id)\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
            try Data(row.utf8).write(to: project.appendingPathComponent(id + ".jsonl"))
        }
        let repo = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cacheDirectory: cache, refreshByteBudget: 1)
        let first = try await repo.refresh()
        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertTrue(first.issues.contains { $0.contains("Indexing:") })
        let second = try await repo.refresh()
        XCTAssertEqual(second.sessions.count, 2)
        XCTAssertTrue(second.sessions.allSatisfy(\.isAvailable))
        let index = cache.appendingPathComponent("index.json")
        let sentinel = Date(timeIntervalSince1970: 1234)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: index.path)
        _ = try await repo.refresh()
        let modified = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, sentinel)
        _ = try await repo.refresh(rebuild: true)
        let rebuilt = try await repo.refresh()
        XCTAssertEqual(rebuilt.sessions.count, 2)
        XCTAssertFalse(rebuilt.issues.contains { $0.contains("Indexing:") })
    }

    func testFailedCacheWriteRetriesWithoutSourceChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude")
        let codex = root.appendingPathComponent("codex")
        let file = claude.appendingPathComponent("projects/p/s.jsonl")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"uuid":"u","sessionId":"s","message":{"role":"user","content":"hello"}}"#.utf8).write(to: file)
        try Data("blocked".utf8).write(to: cache)
        let repo = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cacheDirectory: cache)
        do { _ = try await repo.refresh(); XCTFail("Expected cache write failure") } catch { }
        try FileManager.default.removeItem(at: cache)
        _ = try await repo.refresh()
        let reopened = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cacheDirectory: cache)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.sessions.count, 1)
    }

    func testCodexMirrorDoesNotConsumeEarlierEventOnlyTurn() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"continue"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"first answer"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"continue"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"continue"}]}}"#
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        let session = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        XCTAssertEqual(session.messages.map(\.text), ["continue", "first answer", "continue"])
    }

    func testCodexMessageIdentitySurvivesSourcePrepend() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let existing = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"original target"}]}}"#
        let prepended = existing.replacingOccurrences(of: "original target", with: "unrelated new message")
        try Data(existing.utf8).write(to: file)
        let before = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        try Data((prepended + "\n" + existing).utf8).write(to: file)
        let after = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        XCTAssertEqual(after.messages.first(where: { $0.id == before.messages[0].id })?.text, "original target")
        XCTAssertNotEqual(after.messages[0].id, before.messages[0].id)
    }

    func testCanonicalCodexMessagesDoNotDuplicateEventMirrorsAndToolsExport() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"request"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"request"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"echo hello"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"```sample```"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"event-only answer"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"request"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","channel":"analysis","content":[{"type":"output_text","text":"private reasoning"}]}}"#
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        let session = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        XCTAssertEqual(session.messages.count, 5)
        XCTAssertEqual(session.messages.last?.text, "request")
        XCTAssertTrue(session.messages.contains { $0.text == "event-only answer" })
        XCTAssertEqual(session.messages[1].toolName, "shell")
        XCTAssertFalse(session.messages.contains { $0.text.contains("private reasoning") })
        XCTAssertTrue(SessionHistoryExport.markdown(session: session).contains("````text"))
    }
}
