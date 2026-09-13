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

    func testSharedExecutableResolverPreservesConfiguredPriorityAndLocalFallback() {
        let home = URL(fileURLWithPath: "/fixture/grok")
        let configured = home.appendingPathComponent("bin/grok")
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/grok")
        let path = URL(fileURLWithPath: "/fixture/path/grok")
        XCTAssertEqual(GrokUsageProvider.resolveGrokExecutable(environment: ["PATH": "/usr/bin:/bin"], grokHome: home,
            fileManager: GrokExecutableFiles([local.path])), local)
        XCTAssertEqual(GrokUsageProvider.resolveGrokExecutable(environment: ["PATH": "/fixture/path"], grokHome: home,
            fileManager: GrokExecutableFiles([configured.path, path.path, local.path])), configured)
        XCTAssertEqual(GrokUsageProvider.resolveGrokExecutable(environment: ["PATH": "/fixture/path"], grokHome: home,
            fileManager: GrokExecutableFiles([path.path, local.path])), path)
    }

    func testCustomHomeExecutableListsSlugWorkspaceUsingOnlySummaryMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-list-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent(String(repeating: "long project ", count: 14))
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        XCTAssertGreaterThan(GrokSessionLocator.encode(cwd: cwd.path)!.utf8.count, 255)
        let home = root.appendingPathComponent("custom-grok")
        let directory = home.appendingPathComponent("sessions/project-0123456789abcdef/" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = try JSONSerialization.data(withJSONObject: ["info": ["id": id, "cwd": cwd.path]])
        try metadata.write(to: directory.appendingPathComponent("summary.json"))
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("grok")
        // A fixture executable, never the installed CLI. Shell builtins work
        // inside the same write/fork-denying sandbox as the production source.
        let script = """
        #!/bin/sh
        [ "$1" = "--cwd" ] && [ -d "$2" ] && [ "$3" = "sessions" ] && [ "$4" = "list" ] || exit 64
        printf '%s\\n' '\(sample)'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let inventory = GrokHistorySource.scan(home: home)
        XCTAssertEqual(inventory.issues, [])
        XCTAssertEqual(inventory.sessions.count, 1)
        XCTAssertEqual(inventory.sessions.first?.projectPath, cwd.path)
        XCTAssertEqual(inventory.sessions.first?.nativeSessionID, id)
        XCTAssertEqual(inventory.sessions.first?.messages, [])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("summary.json")), metadata)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["summary.json"])
    }

    func testSlugWorkspaceRejectsConflictingIdentityAndSymlinkMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("grok-cwd-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("project-0123456789abcdef")
        let first = workspace.appendingPathComponent(id)
        let secondID = "00000000-0000-4000-8000-000000000009"
        let second = workspace.appendingPathComponent(secondID)
        for directory in [first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func metadata(_ id: String, _ cwd: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["info": ["id": id, "cwd": cwd]])
        }
        let summary = first.appendingPathComponent("summary.json")
        try metadata(id, "/first").write(to: summary)
        try metadata(secondID, "/second").write(to: second.appendingPathComponent("summary.json"))
        XCTAssertNil(GrokHistorySource.workspaceCwd(directory: workspace))
        try FileManager.default.removeItem(at: second)
        try metadata(secondID, "/first").write(to: summary)
        XCTAssertNil(GrokHistorySource.workspaceCwd(directory: workspace), "A different native ID cannot supply cwd.")
        try FileManager.default.removeItem(at: summary)
        let outside = root.appendingPathComponent("outside.json")
        try metadata(id, "/first").write(to: outside)
        try FileManager.default.createSymbolicLink(at: summary, withDestinationURL: outside)
        XCTAssertNil(GrokHistorySource.workspaceCwd(directory: workspace))
    }

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
        let repository = SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), cursorHome: root.appendingPathComponent("cursor"), grokHome: grok, cacheDirectory: cache, readOnly: true)
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
        let summary = try await HistoryToolExecutor(repository: repository).execute("vibebuddy_get_summary", arguments: ["key": "grok-build:" + id])
        XCTAssertTrue(summary.contains("No saved summary")); XCTAssertTrue(summary.contains(GrokHistorySource.coverage))
        XCTAssertFalse(summary.contains("Generate"))
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
        let repository = SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), cursorHome: root.appendingPathComponent("cursor"), grokHome: grok, cacheDirectory: cache)
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

private final class GrokExecutableFiles: FileManager, @unchecked Sendable {
    let executablePaths: Set<String>
    init(_ paths: Set<String>) { executablePaths = paths; super.init() }
    override func isExecutableFile(atPath path: String) -> Bool { executablePaths.contains(path) }
}
