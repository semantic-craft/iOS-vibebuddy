import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class HistorySummaryToolTests: XCTestCase {
    func testSavedMissingAndStaleSummaryRemainReadOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = fixture.repository()
        let snapshot = try await writer.refresh()
        let session = try XCTUnwrap(snapshot.sessions.first)
        let reader = fixture.repository(readOnly: true)
        let beforeMissing = try fixture.storeBytes()
        let missing = try await HistoryTools.getSummary(arguments: ["key": "codex:native"], repository: reader)
        XCTAssertTrue(missing.contains("No saved summary")); XCTAssertTrue(missing.contains("Mac App History"))
        XCTAssertEqual(try fixture.storeBytes(), beforeMissing)

        let summary = fixture.summary(session)
        try await writer.saveSummary(summary)
        let before = try fixture.storeBytes()
        let direct = try await HistoryTools.getSummary(arguments: ["key": "codex:native"], repository: reader)
        XCTAssertTrue(direct.hasPrefix("stale: false; Coverage: 1 of 2 readable records; partial/excerpted source"))
        XCTAssertTrue(direct.contains("Style: briefing (Action briefing)"))
        XCTAssertTrue(direct.contains("Provider: test-provider\nModel: test-model\nGenerated: 2026-09-13T00:00:00Z"))
        XCTAssertTrue(direct.hasSuffix(summary.text))
        let request = try HistoryCLI.parse(["summary", "vibebuddy://session/codex:native#2"])
        XCTAssertEqual(request.tool, "vibebuddy_get_summary")
        let cli = try await HistoryTools.getSummary(arguments: request.arguments, repository: reader)
        XCTAssertEqual(Data(HistoryCLI.output(cli).utf8), Data((direct + "\n").utf8))
        // A long-lived reader must stat the source again even though its index is unchanged.
        let source = try Data(contentsOf: fixture.source)
        try (source + Data("\n".utf8)).write(to: fixture.source)
        let stale = try await HistoryTools.getSummary(arguments: ["key": "codex:native"], repository: reader)
        XCTAssertTrue(stale.hasPrefix("stale: true; Coverage: " + summary.coverage))
        XCTAssertTrue(stale.contains("Source changed")); XCTAssertTrue(stale.hasSuffix(summary.text))
        // Reading the summary must survive a missing transcript/cache and retain the body.
        try FileManager.default.removeItem(at: fixture.source)
        let unavailable = try await HistoryTools.getSummary(arguments: ["key": "codex:native"], repository: reader)
        XCTAssertTrue(unavailable.hasPrefix("stale: true;"))
        XCTAssertTrue(unavailable.contains("Source unavailable")); XCTAssertTrue(unavailable.hasSuffix(summary.text))
        XCTAssertEqual(try fixture.storeBytes(), before)
        // Codex archive moves retain an unavailable old index entry. Summary shares
        // show's canonical available-source selection and must not become ambiguous.
        let archived = fixture.root.appendingPathComponent("codex/archived_sessions/native.jsonl")
        try FileManager.default.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: archived)
        _ = try await writer.refresh()
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache.appendingPathComponent("index.json"))) as? [String: Any])
        let entries = try XCTUnwrap(index["entries"] as? [String: [String: Any]])
        let candidates = entries.values.compactMap { $0["session"] as? [String: Any] }.filter { $0["nativeSessionID"] as? String == "native" }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.filter { $0["isAvailable"] as? Bool == true }.count, 1)
        let movedBefore = try fixture.storeBytes()
        let writerRead = try await HistoryTools.getSummary(arguments: ["key": "codex:native"], repository: writer)
        XCTAssertTrue(writerRead.hasSuffix(summary.text))
        let moved = try await HistoryTools.getSummary(arguments: ["key": "codex:native"], repository: fixture.repository(readOnly: true))
        XCTAssertTrue(moved.hasPrefix("stale: true;")); XCTAssertTrue(moved.hasSuffix(summary.text))
        XCTAssertEqual(try fixture.storeBytes(), movedBefore)
    }

    func testKeyFailuresAndUnknownRevisionAreExplicit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = fixture.repository()
        let snapshot = try await writer.refresh()
        let session = try XCTUnwrap(snapshot.sessions.first)
        var summary = fixture.summary(session)
        summary.sourceRevision = nil
        try await writer.saveSummary(summary)
        let reader = fixture.repository(readOnly: true)
        let before = try fixture.storeBytes()
        let legacy = try await HistoryTools.getSummary(arguments: ["key": "codex:native"], repository: reader)
        XCTAssertTrue(legacy.hasPrefix("stale: true;")); XCTAssertTrue(legacy.contains("Saved source revision unknown"))
        for (key, message) in [("broken", "Invalid session key or reference."),
                               ("codex:missing", "Unknown session key."),
                               ("other-agent:native", "Unknown session agent.")] {
            do { _ = try await HistoryTools.getSummary(arguments: ["key": key], repository: reader); XCTFail("Accepted \(key)") }
            catch HistoryToolError.executionFailed(let text) { XCTAssertEqual(text, message) }
        }
        let invalidArguments: [[String: Any]] = [[:], ["key": 1], ["key": "codex:native", "generate": true]]
        for args in invalidArguments {
            do { _ = try await HistoryTools.getSummary(arguments: args, repository: reader); XCTFail("Accepted invalid arguments") }
            catch HistoryToolError.invalidArguments { }
        }
        XCTAssertEqual(try fixture.storeBytes(), before)
        let duplicate = fixture.source.deletingLastPathComponent().appendingPathComponent("other/native.jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: fixture.source).write(to: duplicate)
        _ = try await writer.refresh()
        let ambiguous = fixture.repository(readOnly: true)
        let ambiguousBefore = try fixture.storeBytes()
        do { _ = try await HistoryTools.getSummary(arguments: ["key": "codex:native"], repository: ambiguous); XCTFail("Accepted ambiguous identity") }
        catch HistoryToolError.executionFailed(let text) { XCTAssertEqual(text, "Ambiguous session key: multiple source files.") }
        XCTAssertEqual(try fixture.storeBytes(), ambiguousBefore)
    }

    func testSummaryWithoutIndexUsesNativeIdentityAndCreatesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = fixture.repository()
        let snapshot = try await writer.refresh()
        let session = try XCTUnwrap(snapshot.sessions.first)
        try await writer.saveSummary(fixture.summary(session))
        for url in try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil)
            where !url.lastPathComponent.hasPrefix("summary-") { try FileManager.default.removeItem(at: url) }
        let before = try fixture.storeBytes()
        let result = try await HistoryTools.getSummary(arguments: ["key": "codex:native"], repository: fixture.repository(readOnly: true))
        XCTAssertTrue(result.hasPrefix("stale: false;"))
        XCTAssertEqual(try fixture.storeBytes(), before)
        let absent = fixture.root.appendingPathComponent("absent")
        let empty = SessionHistoryRepository(claudeHome: fixture.root.appendingPathComponent("claude"),
            codexHome: fixture.root.appendingPathComponent("codex"), cacheDirectory: absent, readOnly: true)
        let missing = try await HistoryTools.getSummary(arguments: ["key": "codex:native"], repository: empty)
        XCTAssertTrue(missing.contains("No saved summary"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    private struct Fixture {
        let root: URL
        var source: URL { root.appendingPathComponent("codex/sessions/native.jsonl") }
        var cache: URL { root.appendingPathComponent("cache") }
        init() throws {
            // Avoid macOS /var vs /private/var aliases hiding a retained missing source
            // when a new repository reloads the persisted index after an archive move.
            root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".scratch/summary-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header = #"{"type":"session_meta","payload":{"id":"native","cwd":"/repo"}}"#
            let message = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}"#
            try Data((header + "\n" + message).utf8).write(to: source)
        }
        func repository(readOnly: Bool = false) -> SessionHistoryRepository {
            SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), cacheDirectory: cache, readOnly: readOnly)
        }
        func summary(_ session: SessionHistorySession) -> SessionHistorySummary {
            SessionHistorySummary(sessionID: session.id, sourcePath: session.sourcePath, sourceRevision: session.sourceRevision,
                text: "## Saved result\nExisting body", provider: "test-provider", model: "test-model",
                generatedAt: ISO8601DateFormatter().date(from: "2026-09-13T00:00:00Z")!,
                coverage: "1 of 2 readable records; partial/excerpted source", style: .briefing)
        }
        func storeBytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).map {
                ($0.lastPathComponent, try Data(contentsOf: $0))
            })
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
