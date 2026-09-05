import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Privacy-minimized lifecycle journal")
struct LifecycleJournalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("capacity and retention bound the persisted timeline")
    func boundedRotation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-journal-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = LifecycleJournal(url: url, capacity: 2, retention: 60, now: now)

        journal.append(entry("expired", at: now.addingTimeInterval(-61)), now: now)
        journal.append(entry("one", at: now), now: now)
        journal.append(entry("two", at: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
        journal.append(entry("three", at: now.addingTimeInterval(2)), now: now.addingTimeInterval(2))

        let reopened = LifecycleJournal(url: url, capacity: 2, retention: 60,
                                        now: now.addingTimeInterval(2))
        #expect(reopened.recent(limit: 10).map(\.sessionID) == ["three", "two"])
    }

    @Test("raw prompt, reasoning, and tool IO never reach disk")
    func excludesSensitiveRawFields() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-journal-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(journalURL: url, now: now)
        let secret = "PRIVATE-CONTENT-DO-NOT-PERSIST"
        let payload = #"{"hook_event_name":"Notification","session_id":"privacy-session","cwd":"/tmp/project","message":"PRIVATE-CONTENT-DO-NOT-PERSIST","reasoning":"PRIVATE-CONTENT-DO-NOT-PERSIST","tool_input":{"command":"PRIVATE-CONTENT-DO-NOT-PERSIST"},"tool_response":{"output":"PRIVATE-CONTENT-DO-NOT-PERSIST"}}"#

        #expect(await store.ingest(Data(payload.utf8), receivedAt: now))
        let persisted = try String(contentsOf: url, encoding: .utf8)

        #expect(!persisted.contains(secret))
        #expect(!persisted.contains("message"))
        #expect(!persisted.contains("reasoning"))
        #expect(!persisted.contains("tool_input"))
        #expect(!persisted.contains("tool_response"))
        #expect(await store.recentLifecycle().first?.status == .needsResponse)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblings == ["journal.json"])
    }

    @Test("a failed clear remains visible and can be retried")
    func failedClearCanRetry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-journal-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("journal.json")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        var journal = LifecycleJournal(url: url, now: now)
        journal.append(entry("retry-clear", at: now), now: now)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)

        let firstClear = journal.clear()
        #expect(!firstClear)
        #expect(journal.recent(limit: 1).first?.sessionID == "retry-clear")

        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: directory.path)
        let secondClear = journal.clear()
        #expect(secondClear)
        #expect(journal.recent(limit: 1).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a failed publication never replaces the destination or leaves staging data")
    func failedPublicationCleansStaging() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-journal-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var journal = LifecycleJournal(url: url, now: now)

        journal.append(entry("fail-open", at: now), now: now)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(journal.recent(limit: 1).first?.sessionID == "fail-open")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblings == ["journal.json"])
    }

    @Test("restart restores only recent active and waiting sessions")
    func restoresMeaningfulStateOnly() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-journal-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SessionStore(staleAfter: 3_600, journalURL: url, now: now)

        await first.ingest(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"working","cwd":"/x/work"}"#.utf8), receivedAt: now)
        await first.ingest(Data(#"{"hook_event_name":"Notification","session_id":"waiting","cwd":"/x/wait","message":"sensitive question"}"#.utf8), receivedAt: now)
        await first.ingest(Data(#"{"hook_event_name":"Stop","session_id":"done","cwd":"/x/done","last_assistant_message":"sensitive result"}"#.utf8), receivedAt: now)
        await first.ingest(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"ended","cwd":"/x/ended"}"#.utf8), receivedAt: now)
        await first.ingest(Data(#"{"hook_event_name":"SessionEnd","session_id":"ended"}"#.utf8), receivedAt: now.addingTimeInterval(1))
        await first.ingest(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"stale"}"#.utf8), receivedAt: now.addingTimeInterval(-3_601))
        await first.ingest(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"long-window"}"#.utf8), receivedAt: now.addingTimeInterval(-10_800))

        let restarted = SessionStore(staleAfter: 3_600, journalURL: url,
                                     now: now.addingTimeInterval(2))
        let sessions = await restarted.snapshot(now: now.addingTimeInterval(2)).sessions

        #expect(Set(sessions.map(\.id)) == ["working", "waiting"])
        #expect(sessions.first(where: { $0.id == "working" })?.status == .working)
        #expect(sessions.first(where: { $0.id == "waiting" })?.status == .needsResponse)
        #expect(sessions.allSatisfy { $0.summary == nil && $0.pendingApproval == nil && $0.pendingQuestion == nil })
        #expect(sessions.allSatisfy { $0.observations?.map(\.source) == [.recovery] })

        let longerWindow = SessionStore(staleAfter: 4 * 3_600, journalURL: url,
                                        now: now.addingTimeInterval(2))
        #expect(await longerWindow.snapshot(now: now).sessions.contains { $0.id == "long-window" })

        let shorterWindow = SessionStore(staleAfter: 30 * 60, journalURL: url,
                                         now: now.addingTimeInterval(2))
        #expect(!(await shorterWindow.snapshot(now: now).sessions.contains { $0.id == "long-window" }))
    }

    @Test("a follow survives a restart with the session it belongs to")
    func restoresFollowedFlag() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-journal-follow-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("journal.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SessionStore(staleAfter: 3_600, journalURL: url, now: now)
        await first.ingest(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"followed","cwd":"/x/a"}"#.utf8), receivedAt: now)
        await first.ingest(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"plain","cwd":"/x/b"}"#.utf8), receivedAt: now)
        await first.setFollowed(sessionID: "followed", true, now: now.addingTimeInterval(1))

        let restarted = SessionStore(staleAfter: 3_600, journalURL: url, now: now.addingTimeInterval(2))
        let sessions = await restarted.snapshot(now: now.addingTimeInterval(2)).sessions
        #expect(sessions.first { $0.id == "followed" }?.isFollowed == true)
        #expect(sessions.first { $0.id == "plain" }?.isFollowed == false)
    }

    private func entry(_ sessionID: String, at date: Date) -> LifecycleJournalEntry {
        LifecycleJournalEntry(
            sessionID: sessionID,
            agent: .codex,
            event: "userPromptSubmit",
            source: .rollout,
            timestamp: date,
            status: .working,
            waitKind: nil
        )
    }
}
