import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class HistoryToolsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func session(_ id: String, project: String, age: TimeInterval = 0) -> SessionHistorySession {
        SessionHistorySession(id: id, nativeSessionID: id, agent: .codex, projectPath: project,
                              title: "中文 | title\nnext", sourcePath: "/source/\(id)", updatedAt: now.addingTimeInterval(-age), messages: [])
    }

    func testRegistryAndCLIParity() throws {
        let definitions = HistoryTools.definitions()
        XCTAssertEqual(definitions.compactMap { $0["name"] as? String }, ["vibebuddy_get_session", "vibebuddy_list_sessions", "vibebuddy_list_projects", "vibebuddy_search"])
        XCTAssertEqual(Set(HistoryCLI.commands.values), Set(definitions.compactMap { $0["name"] as? String }))
        for definition in definitions {
            XCTAssertEqual((definition["annotations"] as? [String: Bool])?["readOnlyHint"], true)
            XCTAssertEqual((definition["inputSchema"] as? [String: Any])?["additionalProperties"] as? Bool, false)
        }
        let schemas = definitions.compactMap { $0["inputSchema"] as? [String: Any] }
        XCTAssertEqual(Set((schemas[1]["properties"] as? [String: Any] ?? [:]).keys), Set(["project", "agents", "since", "starred", "limit"]))
        XCTAssertEqual(Set((schemas[2]["properties"] as? [String: Any] ?? [:]).keys), Set(["since", "limit"]))
        let snapshot = SessionHistorySnapshot(sessions: [session("native-id", project: "/a/repo")])
        let request = try HistoryCLI.parse(["sessions", "--project", "/a/repo", "--limit", "5", "--agent", "codex"])
        XCTAssertEqual(request.arguments["limit"] as? String, "5")
        let direct = try HistoryTools.call(request.tool, arguments: ["project": "/a/repo", "limit": 5, "agents": ["codex"]], snapshot: snapshot, now: now)
        let cli = try HistoryTools.call(request.tool, arguments: request.arguments, snapshot: snapshot, now: now)
        XCTAssertEqual(Data(HistoryCLI.output(cli).utf8), Data((direct + "\n").utf8))
        XCTAssertTrue(cli.contains("codex:native-id"))
        XCTAssertTrue(cli.contains("中文 \\| title next"))
    }

    func testFiltersAmbiguityAndFreshness() throws {
        var favorite = session("old", project: "/a/repo", age: 8 * 86400)
        favorite.isFavorite = true; favorite.isPinned = true
        let snapshot = SessionHistorySnapshot(sessions: [favorite, session("new", project: "/b/repo")])
        let tool = "vibebuddy_list_sessions"
        XCTAssertTrue(try HistoryTools.call(tool, arguments: ["project": "repo"], snapshot: snapshot).contains("ambiguous"))
        let exact = try HistoryTools.call(tool, arguments: ["project": "/a/repo"], snapshot: snapshot)
        XCTAssertTrue(exact.contains("codex:old")); XCTAssertFalse(exact.contains("codex:new"))
        let recent = try HistoryTools.call(tool, arguments: ["since": "7d"], snapshot: snapshot, now: now)
        XCTAssertTrue(recent.contains("codex:new")); XCTAssertFalse(recent.contains("codex:old"))
        XCTAssertTrue(try HistoryTools.call(tool, arguments: ["starred": true], snapshot: snapshot).contains("codex:old"))
        XCTAssertTrue(try HistoryTools.call(tool, arguments: ["limit": 1], snapshot: snapshot).contains("codex:new"))
        let invalidArguments: [[String: Any]] = [["limit": 0], ["limit": true], ["limit": 1.5], ["starred": 1], ["since": "yesterday"], ["agents": ["unknown-agent"]], ["dispatch": true]]
        for invalid in invalidArguments {
            XCTAssertThrowsError(try HistoryTools.call(tool, arguments: invalid, snapshot: snapshot))
        }
        for since in ["24h", "2026-09-13", "2026-09-13T10:00:00Z"] {
            XCTAssertNoThrow(try HistoryTools.call(tool, arguments: ["since": since], snapshot: snapshot, now: now))
        }
    }

    func testReadOnlyStoreRemainsByteIdenticalAndRejectsWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude"), codex = root.appendingPathComponent("codex"), cache = root.appendingPathComponent("cache")
        let file = codex.appendingPathComponent("sessions/test.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"type":"session_meta","payload":{"id":"native","cwd":"/repo","source":"cli"}}"# + "\n" + #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}"#).utf8).write(to: file)
        let writer = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache)
        let original = try await writer.refresh()
        let id = try XCTUnwrap(original.sessions.first?.id)
        try await writer.setFavorite(sessionID: id, isFavorite: true)
        try await writer.setPinned(sessionID: id, isPinned: true)
        try await writer.setArchived(sessionID: id, isArchived: true)
        let before = try bytes(cache)
        let reader = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache, readOnly: true)
        let usable = await reader.hasUsableIndex(); XCTAssertTrue(usable)
        let snapshot = await reader.snapshot()
        XCTAssertTrue(snapshot.sessions.first?.isFavorite == true)
        XCTAssertTrue(snapshot.sessions.first?.isPinned == true)
        XCTAssertTrue(snapshot.sessions.first?.archivedLocally == true)
        for tool in ["vibebuddy_list_sessions", "vibebuddy_list_projects"] { _ = try HistoryTools.call(tool, arguments: [:], snapshot: snapshot) }
        _ = try await reader.session(id: id)
        _ = try await reader.summary(sessionID: id)
        do { _ = try await reader.refresh(rebuild: true); XCTFail("refresh wrote") } catch {}
        do { try await reader.setFavorite(sessionID: id, isFavorite: false); XCTFail("favorite wrote") } catch {}
        do { try await reader.setPinned(sessionID: id, isPinned: false); XCTFail("pin wrote") } catch {}
        do { try await reader.setArchived(sessionID: id, isArchived: false); XCTFail("archive wrote") } catch {}
        let hits = try await reader.search("hello")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(try bytes(cache), before)
        let missing = root.appendingPathComponent("missing")
        let empty = SessionHistoryRepository(cacheDirectory: missing, readOnly: true)
        let exists = await empty.hasUsableIndex(); XCTAssertFalse(exists)
        _ = await empty.snapshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }


    func testPersistedPendingSourceWithoutEntryIsReportedByBothLists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        let cache = root.appendingPathComponent("cache")
        let sources = codex.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        for id in ["one", "two"] {
            let data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "cwd": "/repo", "source": "cli"]])
            try data.write(to: sources.appendingPathComponent(id + ".jsonl"))
        }
        let writer = SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: codex, cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache, refreshByteBudget: 1)
        let initial = try await writer.refresh()
        XCTAssertEqual(initial.pendingSourceCount, 1)
        let before = try bytes(cache)
        let reader = SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: codex, cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache, readOnly: true)
        let snapshot = await reader.snapshot()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.pendingSourceCount, 1)
        for tool in ["vibebuddy_list_sessions", "vibebuddy_list_projects"] {
            let text = try HistoryTools.call(tool, arguments: [:], snapshot: snapshot)
            XCTAssertTrue(text.contains("Partial index: 1 source(s) pending"))
            XCTAssertTrue(text.contains("older or newer"))
        }
        XCTAssertEqual(try bytes(cache), before)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: cache.appendingPathComponent("index.json"))) as! [String: Any]
        let pending = try XCTUnwrap((stored["pendingPaths"] as? [String])?.first)
        try FileManager.default.removeItem(atPath: pending)
        let afterRemoval = try await writer.refresh()
        XCTAssertEqual(afterRemoval.pendingSourceCount, 0, "root=\(codex.path) resolved=\(codex.resolvingSymlinksInPath().path) pending=\(pending)")
        let reopened = SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: codex, cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache, readOnly: true)
        let final = await reopened.snapshot()
        XCTAssertEqual(final.pendingSourceCount, 0)
    }

    private func bytes(_ root: URL) throws -> [String: Data] {
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in urls where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }
}
