import Foundation
import XCTest
import VibeBuddyKit
@testable import VibeBuddyMacCore

final class ContinueWithTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func session(_ id: String, agent: AgentKind = .claudeCode, status: SessionStatus = .done, cwd: String? = "/repo") -> AgentSession {
        var s = AgentSession(id: id, agent: agent, project: "repo", status: status, waitKind: nil, hasUnreadCompletion: false,
                             completionID: status == .done ? "c" : nil, statusSince: now, updatedAt: now)
        s.checkoutPath = cwd
        return s
    }

    func testKeysHandoffMatchAndPrompt() {
        XCTAssertEqual(ContinueWith.sessionKey(for: session("a")), "claude-code:a")
        XCTAssertEqual(ContinueWith.sessionKey(for: session("b", agent: .grok)), "grok-build:b")
        XCTAssertNil(ContinueWith.sessionKey(for: session("c", agent: .copilot)))
        let older = HandoffRecord(path: "/r/.scratch/e/handoffs/old.md", sourceKey: "claude-code:a", writtenAt: now.addingTimeInterval(-100))
        let newer = HandoffRecord(path: "/r/.scratch/e/handoffs/new.md", sourceKey: "claude-code:a", writtenAt: now)
        let other = HandoffRecord(path: "/r/.scratch/e/handoffs/x.md", sourceKey: "codex:a", writtenAt: now.addingTimeInterval(10))
        XCTAssertEqual(ContinueWith.handoff(for: session("a"), in: [older, other, newer])?.path, newer.path)
        XCTAssertNil(ContinueWith.handoff(for: session("z"), in: [older]))
        XCTAssertEqual(ContinueWith.prompt(sessionKey: "claude-code:a", handoffPath: newer.path),
                       "Read /r/.scratch/e/handoffs/new.md, then continue.\nContinues: vibebuddy://session/claude-code:a")
        let bare = ContinueWith.prompt(sessionKey: "claude-code:a", handoffPath: nil)
        XCTAssertTrue(bare.hasPrefix("Continues: vibebuddy://session/claude-code:a\n"))
        XCTAssertTrue(bare.contains("vibebuddy-mcp facts 'claude-code:a'"))
        XCTAssertEqual(ContinueWith.taskName(for: session("a")), "Continue: repo")
    }

    func testBusySessionsExcludeTheSourceAndFinishedOnes() {
        let busy = ContinueWith.busySessions(in: "/repo/", among: [
            session("src", status: .working), session("w", agent: .codex, status: .working), session("q", status: .needsResponse),
            session("done"), session("elsewhere", status: .working, cwd: "/other")
        ], excluding: "src")
        XCTAssertEqual(busy.map(\.id), ["w", "q"])
    }

    @MainActor
    func testRecordedContinuationReachesTheSnapshotAndTheHandoffRecordAndSurvivesARestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cont-" + UUID().uuidString)
        let handoffs = root.appendingPathComponent(".scratch/e/handoffs")
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: handoffs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = handoffs.appendingPathComponent("2026-09-14-claude-code-codex.md")
        try "Source session: claude-code:src\n".write(to: path, atomically: true, encoding: .utf8)
        let journal = state.appendingPathComponent("lifecycle-journal.json")
        do {
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: now)
            await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "src", agent: .claudeCode, cwd: root.path, timestamp: now, turnID: "t"))
            await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "new", agent: .codex, cwd: root.path, timestamp: now.addingTimeInterval(1), turnID: "t"))
            let before = await store.snapshot(now: now.addingTimeInterval(2))
            XCTAssertEqual(before.handoffs?.map(\.sourceKey), ["claude-code:src"])
            XCTAssertEqual(before.handoffs?.first?.takenBy, [])
            await store.recordContinuation(receiverKey: "codex:new", sourceKey: "claude-code:src", handoffPath: path.standardizedFileURL.path, now: now.addingTimeInterval(2))
            let after = await store.snapshot(now: now.addingTimeInterval(3))
            XCTAssertEqual(after.handoffs?.first?.takenBy, ["codex:new"])
            XCTAssertEqual(after.sessions.first { $0.id == "new" }?.continuesSessionKey, "claude-code:src")
            XCTAssertNil(after.sessions.first { $0.id == "src" }?.continuesSessionKey)
        }
        for name in ["continuations.json", "recent-directories.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent(name).path), name)
        }
        do {
            // A new process an hour later: directories, handoffs, lineage and each
            // session's own checkout are back without any session reporting again.
            let later = now.addingTimeInterval(3600)
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: later)
            let restored = await store.snapshot(now: later)
            XCTAssertEqual(restored.recentDirectories, [root.path])
            XCTAssertEqual(restored.handoffs?.first?.takenBy, ["codex:new"])
            XCTAssertEqual(restored.sessions.first { $0.id == "new" }?.continuesSessionKey, "claude-code:src")
            XCTAssertEqual(restored.sessions.first { $0.id == "new" }?.checkoutPath, root.path)
            XCTAssertEqual(restored.sessions.first { $0.id == "src" }?.checkoutPath, root.path)
        }
        do {
            // Eight days later both files have forgotten it.
            let later = now.addingTimeInterval(8 * 86_400)
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: later)
            let old = await store.snapshot(now: later)
            XCTAssertNil(old.recentDirectories)
            XCTAssertNil(old.handoffs)
        }
    }

    @MainActor
    func testARestoredSessionWithoutAnObservedCheckoutStaysUnknown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cont-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("lifecycle-journal.json")
        do {
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: now)
            // A session that never reported a cwd: the journal keeps its label only.
            await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "nocwd", agent: .claudeCode, cwd: "repo", timestamp: now, turnID: "t"))
            await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "other", agent: .claudeCode, cwd: "/b/repo", timestamp: now, turnID: "t"))
        }
        let store = SessionStore(sourceID: "mac", journalURL: journal, now: now.addingTimeInterval(60))
        let snapshot = await store.snapshot(now: now.addingTimeInterval(60))
        XCTAssertNil(snapshot.sessions.first { $0.id == "nocwd" }?.checkoutPath, "a folder with the same name is not evidence")
        XCTAssertEqual(snapshot.sessions.first { $0.id == "other" }?.checkoutPath, "/b/repo")
    }
}
