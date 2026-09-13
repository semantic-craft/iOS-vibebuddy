import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class HistoryRefreshCoordinationTests: XCTestCase {
    func testLockContentionSkipsAppAndRejectsExplicitIndexThenReleases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("history")
        let repository = SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"),
                                                  codexHome: root.appendingPathComponent("codex"), cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache)
        var lock: HistoryRefreshLock? = try HistoryRefreshLock(directory: cache)
        let skipped = try await repository.refresh()
        XCTAssertTrue(skipped.issues.contains { $0.contains("another refresh is running") })
        do { _ = try await repository.index(); XCTFail("Index must reject a busy writer") }
        catch HistoryToolError.refreshBusy { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("index.json").path))
        withExtendedLifetime(lock) {}
        lock = nil
        let created = try await repository.index()
        XCTAssertNotNil(created)
        let existing = try await repository.index()
        XCTAssertNil(existing)
    }

    func testRefreshPublishesFTSEagerlyAndReloadsOtherWritersWithoutQueryWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude")
        let codex = root.appendingPathComponent("codex")
        let cache = root.appendingPathComponent("history")
        let sources = claude.appendingPathComponent("projects/repo")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        func write(_ id: String, _ message: String) throws {
            let row: [String: Any] = ["uuid": id, "sessionId": id, "message": ["role": "user", "content": message]]
            try JSONSerialization.data(withJSONObject: row).write(to: sources.appendingPathComponent(id + ".jsonl"), options: .atomic)
        }
        try write("one", "eager 中文 needle")
        let app = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache)
        _ = try await app.refresh()
        let oldReader = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache, readOnly: true)
        _ = await oldReader.snapshot()
        try write("two", "another needle")
        let cli = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache)
        _ = try await cli.index(rebuild: true)
        let refreshed = try await app.refresh()
        XCTAssertEqual(refreshed.sessions.count, 2)
        let files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        let before = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let reader = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache, readOnly: true)
        let hits = try await reader.search("needle")
        XCTAssertEqual(hits.count, 2)
        let chinese = try await reader.search("中文")
        XCTAssertEqual(chinese.count, 1)
        let after = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        XCTAssertEqual(before, after)
        try write("one", "changed revision needle")
        _ = try await cli.index(rebuild: true)
        let staleHits = try await oldReader.search("needle")
        XCTAssertTrue(staleHits.isEmpty, "New FTS rows must not be paired with old metadata")
        // Interrupted publication: a newer content cache outlives the source,
        // while index.json still names the older revision. Never bless its rows
        // with the older stamp when rebuilding derived search data.
        let latest = await cli.snapshot()
        let first = try XCTUnwrap(latest.sessions.first { $0.nativeSessionID == "one" })
        let contentFiles = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        let content = try XCTUnwrap(contentFiles.first { file in
            guard file.lastPathComponent.count == 69,
                  let data = try? Data(contentsOf: file),
                  let value = try? JSONDecoder().decode(SessionHistorySession.self, from: data) else { return false }
            return value.id == first.id
        })
        var interrupted = try JSONDecoder().decode(SessionHistorySession.self, from: Data(contentsOf: content))
        interrupted.sourceRevision = "newer-unpublished-revision"
        try JSONEncoder().encode(interrupted).write(to: content, options: .atomic)
        try FileManager.default.removeItem(atPath: first.sourcePath)
        let repaired = try await cli.index(rebuild: true)
        XCTAssertTrue(repaired?.issues.contains { $0.contains("cache revision differs") } == true)
        let safeHits = try await cli.search("changed revision")
        XCTAssertTrue(safeHits.isEmpty)

    }
}
