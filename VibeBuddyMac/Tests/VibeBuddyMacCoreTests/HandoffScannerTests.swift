import Foundation
import XCTest
import VibeBuddyKit
@testable import VibeBuddyMacCore

final class HandoffScannerTests: XCTestCase {
    private func checkout() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-" + UUID().uuidString)
        let handoffs = root.appendingPathComponent(".scratch/effort/handoffs")
        try FileManager.default.createDirectory(at: handoffs, withIntermediateDirectories: true)
        try """
        Source session: claude-code:abc-123
        Ticket: /repo/.scratch/effort/issues/01.md
        Branch: feat/x
        Worktree: /repo

        # Handoff
        """.write(to: handoffs.appendingPathComponent("2026-09-14-claude-code-codex.md"), atomically: true, encoding: .utf8)
        try "Source session: unknown\nTicket: t\n".write(to: handoffs.appendingPathComponent("2026-09-13-unknown.md"), atomically: true, encoding: .utf8)
        try "# not a handoff\nSource session: codex:zzz\n".write(to: handoffs.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "Source session: codex:zzz\n".write(to: handoffs.appendingPathComponent("plain.txt"), atomically: true, encoding: .utf8)
        // A symlink inside handoffs pointing outside .scratch is ignored.
        let outside = root.appendingPathComponent("outside.md")
        try "Source session: codex:outside\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: handoffs.appendingPathComponent("link.md"), withDestinationURL: outside)
        return root
    }

    func testFindsHandoffsAndParsesTheHeader() throws {
        let root = try checkout()
        defer { try? FileManager.default.removeItem(at: root) }
        var scanner = HandoffScanner()
        let records = scanner.scan(directories: [root.path, "/nonexistent/dir", root.path])
        XCTAssertEqual(records.count, 2)
        let known = try XCTUnwrap(records.first { $0.sourceKey != nil })
        XCTAssertEqual(known.sourceKey, "claude-code:abc-123")
        XCTAssertEqual(known.ticket, "/repo/.scratch/effort/issues/01.md")
        XCTAssertEqual(known.branch, "feat/x")
        XCTAssertEqual(known.worktree, "/repo")
        XCTAssertTrue(known.path.hasSuffix("/handoffs/2026-09-14-claude-code-codex.md"))
        XCTAssertEqual(known.takenBy, [])
        let unknown = try XCTUnwrap(records.first { $0.sourceKey == nil })
        XCTAssertEqual(unknown.ticket, "t")
    }

    func testWorktreeSymlinkedScratchIsFollowedOnce() throws {
        let root = try checkout()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("wt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        try FileManager.default.createSymbolicLink(at: worktree.appendingPathComponent(".scratch"), withDestinationURL: root.appendingPathComponent(".scratch"))
        var scanner = HandoffScanner()
        XCTAssertEqual(scanner.scan(directories: [worktree.path, root.path]).count, 2, "the same .scratch through two checkouts is listed once")
    }

    func testCacheFollowsTheDirectoryModificationTime() throws {
        let root = try checkout()
        defer { try? FileManager.default.removeItem(at: root) }
        var scanner = HandoffScanner()
        XCTAssertEqual(scanner.scan(directories: [root.path]).count, 2)
        let handoffs = root.appendingPathComponent(".scratch/effort/handoffs")
        try "Source session: codex:new\n".write(to: handoffs.appendingPathComponent("2026-09-15-codex-claude.md"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: handoffs.path)
        XCTAssertEqual(scanner.scan(directories: [root.path]).count, 3)
        try FileManager.default.removeItem(at: handoffs)
        XCTAssertEqual(scanner.scan(directories: [root.path]).count, 0)
    }

    func testSnapshotCarriesHandoffsAndOlderJSONStillDecodes() throws {
        let record = HandoffRecord(path: "/repo/.scratch/e/handoffs/a.md", sourceKey: "codex:1", writtenAt: Date(timeIntervalSince1970: 1_800_000_000), takenBy: ["s2"])
        let snapshot = Snapshot(sessions: [], serverTime: Date(timeIntervalSince1970: 1_800_000_000), handoffs: [record])
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: data).handoffs, [record])
        let older = Data(#"{"sessions":[],"serverTime":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Snapshot.self, from: older).handoffs)
    }
}
