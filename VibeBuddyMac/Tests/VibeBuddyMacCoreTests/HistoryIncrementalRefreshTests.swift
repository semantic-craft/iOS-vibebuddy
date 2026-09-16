import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class HistoryIncrementalRefreshTests: XCTestCase {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var codex: URL { root.appendingPathComponent("codex") }
        var cache: URL { root.appendingPathComponent("cache") }
        func repository(budget: Int = 256 * 1024 * 1024, readOnly: Bool = false) -> SessionHistoryRepository {
            SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: codex,
                cursorHome: root.appendingPathComponent("cursor"), cacheDirectory: cache,
                refreshByteBudget: budget, readOnly: readOnly)
        }
        func write(_ name: String, text: String, id: String = UUID().uuidString) throws -> URL {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rows: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp", "source": "cli"]],
                ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]
            ]
            var data = Data()
            for row in rows { data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10) }
            try data.write(to: file, options: .atomic)
            return file
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testDirtyReplacementSearchDeletionAndArchiveMovePreservePreferences() async throws {
        let f = Fixture(); defer { f.remove() }
        let id = UUID().uuidString
        let file = try f.write("codex/sessions/a.jsonl", text: "oldword", id: id)
        let repository = f.repository()
        let first = try await repository.refresh()
        let session = try XCTUnwrap(first.sessions.first)
        try await repository.setFavorite(sessionID: session.id, isFavorite: true)
        try await repository.setPinned(sessionID: session.id, isPinned: true)
        let reader = f.repository(readOnly: true)
        let before = try await reader.readTranscript(key: "codex:" + id)
        XCTAssertTrue(before.session.messages.contains { $0.text.contains("oldword") })
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        _ = try f.write("codex/sessions/a.jsonl", text: "newword", id: id)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let beforeIndex = try await reader.readTranscript(key: "codex:" + id)
        XCTAssertTrue(beforeIndex.session.messages.contains { $0.text.contains("newword") })
        XCTAssertNotEqual(beforeIndex.session.sourceRevision, before.session.sourceRevision)
        let replacement = try await repository.refresh(changedPaths: [file.path])
        XCTAssertNotEqual(replacement.sessions.first?.sourceRevision, session.sourceRevision)
        XCTAssertEqual(replacement.sessions.count, 1)
        let resolved = try await repository.resolveIndexedSession(key: "codex:" + id)
        XCTAssertEqual(resolved?.sourcePath, session.sourcePath)
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: f.cache.appendingPathComponent("index.json"))) as? [String: Any]
        XCTAssertEqual((index?["entries"] as? [String: Any])?.count, 1)
        try await reader.reloadReadOnlyMetadata()
        let after = try await reader.readTranscript(key: "codex:" + id)
        XCTAssertTrue(after.session.messages.contains { $0.text.contains("newword") })
        let hits = try await repository.search("newword")
        let oldHits = try await repository.search("oldword")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(oldHits.isEmpty)
        _ = try f.write("codex/sessions/a.jsonl", text: "endword", id: id)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let reconciled = try await repository.refresh(failIfBusy: true)
        XCTAssertNotEqual(reconciled.sessions.first?.sourceRevision, replacement.sessions.first?.sourceRevision)
        let reconciledHits = try await repository.search("endword")
        XCTAssertEqual(reconciledHits.count, 1)
        let archived = f.codex.appendingPathComponent("archived_sessions/a.jsonl")
        try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: archived)
        let moved = try await repository.refresh(changedPaths: [file.path, archived.path])
        let current = try XCTUnwrap(moved.sessions.first)
        XCTAssertEqual(moved.sessions.count, 1)
        XCTAssertEqual(current.sourceArchived, true)
        XCTAssertTrue(current.isFavorite)
        XCTAssertEqual(current.isPinned, true)
        try FileManager.default.removeItem(at: archived)
        let deleted = try await repository.refresh(changedPaths: [archived.path])
        XCTAssertFalse(try XCTUnwrap(deleted.sessions.first).isAvailable)
        XCTAssertTrue(try XCTUnwrap(deleted.sessions.first).isFavorite)
    }

    func testPendingBatchesDrainAndWriterAdoptsExternalPublication() async throws {
        let f = Fixture(); defer { f.remove() }
        _ = try f.write("codex/sessions/initial.jsonl", text: "initial")
        let repository = f.repository(budget: 1)
        _ = try await repository.refresh()
        let a = try f.write("codex/sessions/a.jsonl", text: "alpha")
        let b = try f.write("codex/sessions/b.jsonl", text: "bravo")
        let partial = try await repository.refresh(changedPaths: [a.path, b.path])
        XCTAssertEqual(partial.pendingSourceCount, 1)
        let other = f.repository()
        let external = try await other.refresh(changedPaths: [])
        XCTAssertEqual(external.pendingSourceCount, 0)
        let newest = try XCTUnwrap(external.sessions.first)
        try await other.setFavorite(sessionID: newest.id, isFavorite: true)
        let adopted = try await repository.refresh(changedPaths: [])
        XCTAssertEqual(adopted.sessions.count, 3)
        XCTAssertEqual(adopted.pendingSourceCount, 0)
        XCTAssertTrue(adopted.sessions.contains { $0.id == newest.id && $0.isFavorite })
    }

    func testLegacyIndexRemainsSearchableBeforeWriterMigration() async throws {
        let f = Fixture(); defer { f.remove() }
        let file = try f.write("codex/sessions/legacy.jsonl", text: "legacyneedle")
        let repository = f.repository()
        let snapshot = try await repository.refresh()
        let metadata = try XCTUnwrap(snapshot.sessions.first)
        let loaded = try await repository.session(id: metadata.id)
        var full = try XCTUnwrap(loaded)
        let attributes = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let legacy = "\(try XCTUnwrap(attributes.contentModificationDate).timeIntervalSince1970)|\(try XCTUnwrap(attributes.fileSize))"
        full.sourceRevision = legacy
        let index = try SessionHistorySearchIndex(directory: f.cache)
        try index.replace(full, stamp: "v7|" + legacy)
        for json in try FileManager.default.contentsOfDirectory(at: f.cache, includingPropertiesForKeys: nil) where json.pathExtension == "json" {
            guard var value = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any] else { continue }
            if json.lastPathComponent == "index.json", var entries = value["entries"] as? [String: [String: Any]] {
                for path in entries.keys {
                    var entry = entries[path]!
                    var session = entry["session"] as! [String: Any]
                    session["sourceRevision"] = legacy
                    entry["session"] = session
                    entries[path] = entry
                }
                value["entries"] = entries
            } else if value["sourcePath"] != nil { value["sourceRevision"] = legacy }
            try JSONSerialization.data(withJSONObject: value).write(to: json, options: .atomic)
        }
        let saved = SessionHistorySummary(sessionID: metadata.id, sourcePath: metadata.sourcePath,
            sourceRevision: legacy, text: "Summary", provider: "test", model: "test", generatedAt: Date(), coverage: "all")
        try await repository.saveSummary(saved)
        let reader = f.repository(readOnly: true)
        let page = try await reader.search("legacyneedle", sessionIDs: [metadata.id])
        XCTAssertEqual(page.hits.count, 1)
        XCTAssertTrue(page.notIndexed.isEmpty)
        let summary = try await reader.readSummary(key: "codex:" + metadata.nativeSessionID)
        XCTAssertFalse(try XCTUnwrap(summary).isStale)
        let migrated = try await repository.refresh()
        let current = try XCTUnwrap(migrated.sessions.first)
        XCTAssertTrue(try XCTUnwrap(current.sourceRevision).hasPrefix("fs1|"))
        XCTAssertTrue(saved.isCurrent(for: current))
        let advancedTime = try XCTUnwrap(attributes.contentModificationDate).addingTimeInterval(0.001)
        try FileManager.default.setAttributes([.modificationDate: advancedTime], ofItemAtPath: file.path)
        let advanced = try await repository.refresh(changedPaths: [file.path])
        XCTAssertFalse(saved.isCurrent(for: try XCTUnwrap(advanced.sessions.first)))
        var modern = saved
        modern.sourceRevision = current.sourceRevision
        _ = try f.write("codex/sessions/legacy.jsonl", text: "changedwords", id: current.nativeSessionID)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(attributes.contentModificationDate)], ofItemAtPath: file.path)
        let changedSnapshot = try await repository.refresh(changedPaths: [file.path])
        XCTAssertFalse(modern.isCurrent(for: try XCTUnwrap(changedSnapshot.sessions.first)))
    }

    func testLegacySummaryRevisionAcceptsOnlyFloatingPointRounding() {
        var summary = SessionHistorySummary(sessionID: "s", sourcePath: "/source",
            sourceRevision: "1789507060.6177843|123", text: "summary", provider: "test", model: "test",
            generatedAt: Date(), coverage: "all")
        let current = "fs1|1|2|123|1789507060:617784000|1789507060:617784000"
        XCTAssertTrue(summary.matchesSourceRevision(current))
        XCTAssertFalse(summary.matchesSourceRevision("fs1|1|2|123|1789507060:618784000|1789507060:617784000"))
        XCTAssertFalse(summary.matchesSourceRevision("fs1|1|2|124|1789507060:617784000|1789507060:617784000"))
        summary.sourceRevision = current
        XCTAssertFalse(summary.matchesSourceRevision("fs1|1|2|123|1789507060:617784001|1789507060:617784000"))
    }

    func testRetryAfterIndexRepairFailurePublishesPreviouslyParsedChanges() async throws {
        let f = Fixture(); defer { f.remove() }
        let changing = try f.write("codex/sessions/changing.jsonl", text: "beforeupdate")
        let retained = try f.write("codex/sessions/retained.jsonl", text: "retained")
        let repository = f.repository()
        let initial = try await repository.refresh()
        let old = try XCTUnwrap(initial.sessions.first { $0.sourcePath == changing.path })
        let other = try XCTUnwrap(initial.sessions.first { $0.sourcePath == retained.path })
        let loaded = try await repository.session(id: other.id)
        let otherContent = try XCTUnwrap(loaded)
        try SessionHistorySearchIndex(directory: f.cache).replace(otherContent, stamp: "requires-repair")
        let caches = try FileManager.default.contentsOfDirectory(at: f.cache, includingPropertiesForKeys: nil)
        let contentFile = try XCTUnwrap(caches.first { file in
            guard file.pathExtension == "json", let data = try? Data(contentsOf: file),
                  let session = try? JSONDecoder().decode(SessionHistorySession.self, from: data) else { return false }
            return session.sourcePath == other.sourcePath
        })
        let content = try Data(contentsOf: contentFile)
        let oldIndex = try Data(contentsOf: f.cache.appendingPathComponent("index.json"))
        try FileManager.default.removeItem(at: contentFile)
        _ = try f.write("codex/sessions/changing.jsonl", text: "afterupdate", id: old.nativeSessionID)
        do {
            _ = try await repository.refresh()
            XCTFail("Missing cache for index repair must fail publication")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: f.cache.appendingPathComponent("index.json")), oldIndex)
        try content.write(to: contentFile, options: .atomic)
        let retried = try await repository.refresh()
        let fresh = await f.repository(readOnly: true).snapshot()
        let current = try XCTUnwrap(retried.sessions.first { $0.id == old.id })
        XCTAssertNotEqual(current.sourceRevision, old.sourceRevision)
        XCTAssertEqual(fresh.sessions.first { $0.id == old.id }?.sourceRevision, current.sourceRevision)
        let hits = try await f.repository(readOnly: true).search("afterupdate")
        XCTAssertEqual(hits.count, 1)
    }

    func testParentResolutionIsRefreshedBetweenBatches() async throws {
        let f = Fixture(); defer { f.remove() }
        let first = try f.write("codex/sessions/first/file.jsonl", text: "firstsource")
        let repository = f.repository()
        _ = try await repository.refresh()
        let alias = f.codex.appendingPathComponent("sessions/alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first.deletingLastPathComponent())
        let eventPath = alias.appendingPathComponent("file.jsonl").path
        _ = try await repository.refresh(changedPaths: [eventPath])
        let second = try f.write("codex/sessions/second/file.jsonl", text: "secondsource")
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second.deletingLastPathComponent())
        let updated = try await repository.refresh(changedPaths: [eventPath])
        XCTAssertEqual(updated.sessions.count, 2)
        let hits = try await repository.search("secondsource")
        XCTAssertEqual(hits.count, 1)
    }

    func testUnrecheckedSourceCoveragePersistsUntilReconciliation() async throws {
        let f = Fixture(); defer { f.remove() }
        let source = try f.write("codex/sessions/initial.jsonl", text: "initial")
        let repository = f.repository()
        let initial = try await repository.refresh()
        let warning = try XCTUnwrap(initial.issues.first { $0.contains("claude/projects") })
        let updated = try await repository.refresh(changedPaths: [source.path])
        XCTAssertTrue(updated.issues.contains(warning))
        let claudeRoot = f.root.appendingPathComponent("claude/projects")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let reconciled = try await repository.refresh()
        XCTAssertFalse(reconciled.issues.contains(warning))
        let nextUpdate = try await repository.refresh(changedPaths: [source.path])
        XCTAssertFalse(nextUpdate.issues.contains(warning))
    }

    func testLockContentionDoesNotConsumeChangeAndExcludedPathsStayExcluded() async throws {
        let f = Fixture(); defer { f.remove() }
        _ = try f.write("codex/sessions/initial.jsonl", text: "initial")
        let repository = f.repository()
        _ = try await repository.refresh()
        let file = try f.write("codex/sessions/new.jsonl", text: "newsource")
        var lock: HistoryRefreshLock? = try HistoryRefreshLock(directory: f.cache)
        do {
            _ = try await repository.refresh(changedPaths: [file.path])
            XCTFail("Expected writer contention")
        } catch HistoryToolError.refreshBusy { }
        withExtendedLifetime(lock) {}
        lock = nil
        let excluded = try f.write("claude/projects/p/subagents/agent-child.jsonl", text: "excluded")
        let unrelated = try f.write("cursor/projects/p/unrelated.jsonl", text: "excluded")
        let updated = try await repository.refresh(changedPaths: [file.path, excluded.path, unrelated.path])
        XCTAssertEqual(updated.sessions.count, 2)
        XCTAssertEqual(updated.pendingSourceCount, 0)
        let hits = try await repository.search("excluded")
        XCTAssertTrue(hits.isEmpty)
    }
}
