import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class GrokHistorySourceTests: XCTestCase {
    private let id = "00000000-0000-4000-8000-000000000007"
    private let sample = """

    (no label)
    SESSION ID                            CREATED     UPDATED     SOURCE      SUMMARY
    00000000-0000-4000-8000-000000000007  2026-09-08  2026-09-09  local  Plan 中文 reading workflow
    00000000-0000-4000-8000-000000000008  2026-09-08  2026-09-09  remote  Remote conversation
    """

    func testOfficialListIsMetadataOnlyAndRejectsMalformedRows() {
        let parsed = GrokHistorySource.parse(sample + "\nmalformed row", cwd: "/project", directory: URL(fileURLWithPath: "/grok/sessions/%2Fproject"))
        XCTAssertEqual(parsed.sessions.count, 1)
        XCTAssertEqual(parsed.issues.count, 1)
        let session = parsed.sessions[0]
        XCTAssertEqual(session.nativeSessionID, id)
        XCTAssertEqual(session.projectPath, "/project")
        XCTAssertEqual(session.title, "Plan 中文 reading workflow")
        XCTAssertEqual(session.messages, [])
        XCTAssertEqual(session.messageCount, 0)
        XCTAssertTrue(session.warnings.contains(GrokHistorySource.coverage))
        XCTAssertTrue(session.sourceRevision?.hasPrefix("list-row:") == true)
        let changed = GrokHistorySource.parse(sample.replacingOccurrences(of: "Plan 中文", with: "Changed 中文"), cwd: "/project", directory: URL(fileURLWithPath: "/grok/sessions/%2Fproject"))
        XCTAssertNotEqual(changed.sessions[0].sourceRevision, session.sourceRevision, "List row revisions include title changes on the same day.")
    }

    func testDuplicateIdentityAndInvalidDatesAreOmitted() {
        let duplicate = sample + "\n" + sample
        XCTAssertTrue(GrokHistorySource.parse(duplicate, cwd: "/project", directory: URL(fileURLWithPath: "/grok")).sessions.isEmpty)
        let invalid = sample.replacingOccurrences(of: "2026-09-09", with: "2026-02-30")
        XCTAssertTrue(GrokHistorySource.parse(invalid, cwd: "/project", directory: URL(fileURLWithPath: "/grok")).sessions.isEmpty)
    }

    func testReadOnlyMetadataWorksWithoutTranscriptCacheOrFTS() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let grok = root.appendingPathComponent("grok")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let record = GrokHistorySource.parse(sample, cwd: "/project", directory: grok.appendingPathComponent("sessions/%2Fproject")).sessions[0]
        let session = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
        let data = try JSONSerialization.data(withJSONObject: ["version": 7, "entries": [record.sourcePath: ["modified": record.updatedAt.timeIntervalSinceReferenceDate, "size": 0, "session": session]]])
        let index = cache.appendingPathComponent("index.json")
        try data.write(to: index)
        let repository = SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), grokHome: grok, cacheDirectory: cache, readOnly: true)
        let snapshot = await repository.snapshot()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions[0].sourceRevision, record.sourceRevision)
        let list = try HistoryTools.call("vibebuddy_list_sessions", arguments: ["agents": ["grok-build"]], snapshot: snapshot)
        XCTAssertTrue(list.contains("grok-build:" + id)); XCTAssertTrue(list.contains(GrokHistorySource.coverage))
        let shown = try await HistoryTools.getSession(arguments: ["key": "vibebuddy://session/grok-build:" + id + "#1"], repository: repository)
        XCTAssertTrue(shown.contains("该来源无全文")); XCTAssertFalse(shown.contains("[seq"))
        let search = try await HistoryTools.search(arguments: ["query": "reading", "agents": ["grok-build"]], repository: repository)
        XCTAssertTrue(search.contains(GrokHistorySource.coverage)); XCTAssertTrue(search.contains("No matches found"))
        XCTAssertFalse(search.contains("not indexed yet")); XCTAssertFalse(search.contains("ref:"))
        let selected = try await repository.session(id: record.id)
        XCTAssertEqual(selected?.messages, [])
        XCTAssertEqual(try Data(contentsOf: index), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), ["index.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: grok.path), "Queries must not create a Grok home or run the source command.")
    }

    func testResumeCopiesGrokCommandAndParserCannotReadItsStream() throws {
        let session = GrokHistorySource.parse(sample, cwd: "/project's folder", directory: URL(fileURLWithPath: "/grok")).sessions[0]
        XCTAssertEqual(HistoryResumePolicy.command(for: session, directoryExists: true), "cd -- '/project'\"'\"'s folder' && grok --resume '" + id + "'")
        XCTAssertNil(HistoryResumePolicy.command(for: session, directoryExists: false))
        XCTAssertEqual(try HistorySessionReference("grok-build:" + id).key, "grok-build:" + id)
        XCTAssertThrowsError(try SessionHistoryParser.read(url: URL(fileURLWithPath: "/not-read/updates.jsonl"), agent: .grokBuild, updatedAt: Date())) { error in
            XCTAssertEqual(error.localizedDescription, GrokHistorySource.noTranscript)
        }
    }

    func testMetadataOnlyRebuildNeverBecomesPendingFullText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-rebuild-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let grok = root.appendingPathComponent("absent-grok")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let record = GrokHistorySource.parse(sample, cwd: "/project", directory: grok.appendingPathComponent("sessions/%2Fproject")).sessions[0]
        let session = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
        // Version 6 also exercises migration into the eager message index. The
        // Grok source root is absent, so neither refresh can run a real CLI.
        let data = try JSONSerialization.data(withJSONObject: ["version": 6, "entries": [record.sourcePath: ["modified": record.updatedAt.timeIntervalSinceReferenceDate, "size": 0, "session": session]]])
        try data.write(to: cache.appendingPathComponent("index.json"))
        let repository = SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), grokHome: grok, cacheDirectory: cache)
        let initial = await repository.snapshot()
        XCTAssertEqual(initial.sessions.count, 1)
        XCTAssertEqual(initial.pendingSourceCount, 0)
        let first = try await repository.index(rebuild: true)
        XCTAssertEqual(first?.pendingSourceCount, 0)
        let second = try await repository.refresh(rebuild: true)
        XCTAssertEqual(second.sessions.count, 1)
        XCTAssertEqual(second.pendingSourceCount, 0)
        let reloaded = SessionHistoryRepository(grokHome: grok, cacheDirectory: cache, readOnly: true)
        let persisted = await reloaded.snapshot()
        XCTAssertEqual(persisted.pendingSourceCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: grok.path))
    }
}
