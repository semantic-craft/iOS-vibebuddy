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
        // The project label is the folder name only; the full path stays off disk.
        #expect(!persisted.contains("/tmp/project"))
        #expect(persisted.contains(#""project":"project""#))
        #expect(await store.recentLifecycle().first?.status == .needsResponse)

        // The same protection is claimed for every file the store writes beside
        // the journal, named or not, so a new ledger is covered by this test
        // instead of breaking it: owner-only, no raw hook content, and no full
        // path except in the one place a full path is the point.
        let directoryMode = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblings.contains("journal.json"))
        // A successful publication leaves no staging file behind.
        #expect(!siblings.contains { $0.hasPrefix(".") || $0.hasSuffix(".tmp") })
        for sibling in siblings {
            let file = directory.appendingPathComponent(sibling)
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(!contents.contains(secret), "\(sibling) persisted raw content")
            for rawField in ["message", "reasoning", "tool_input", "tool_response"] {
                #expect(!contents.contains(rawField), "\(sibling) persisted \(rawField)")
            }
            let mode = try FileManager.default
                .attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600, "\(sibling) is not owner-only")
            // `recent-directories.json` is the one documented home of a full
            // checkout path (ADR-0023, amended 2026-09-14); it is checked below.
            if sibling != "recent-directories.json" {
                #expect(!contents.contains("/tmp/project"), "\(sibling) persisted a full path")
            }
        }

        // That ledger keeps where a task may start and which checkout a session
        // was seen in — the paths and nothing else about what was said there.
        let ledger = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("recent-directories.json"))
        ) as? [String: Any]
        #expect(ledger.map { Set($0.keys) } == ["directories", "sessions"])
        #expect((ledger?["directories"] as? [String: Any])?.keys.sorted() == ["/tmp/project"])
        let checkout = (ledger?["sessions"] as? [String: Any])?["privacy-session"] as? [String: Any]
        #expect(checkout?["path"] as? String == "/tmp/project")
        #expect(checkout.map { Set($0.keys) } == ["path", "seenAt"])
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

    @Test("restart restores recent activity and current completed rounds")
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

        #expect(Set(sessions.map(\.id)) == ["working", "waiting", "done"])
        #expect(sessions.first(where: { $0.id == "working" })?.status == .working)
        #expect(sessions.first(where: { $0.id == "waiting" })?.status == .needsResponse)
        #expect(sessions.first(where: { $0.id == "working" })?.project == "work")
        #expect(sessions.allSatisfy { $0.summary == nil && $0.pendingApproval == nil && $0.pendingQuestion == nil })
        #expect(sessions.allSatisfy { $0.observations?.map(\.source) == [.recovery] })

        let longerWindow = SessionStore(staleAfter: 4 * 3_600, journalURL: url,
                                        now: now.addingTimeInterval(2))
        #expect(await longerWindow.snapshot(now: now).sessions.contains { $0.id == "long-window" })

        let shorterWindow = SessionStore(staleAfter: 30 * 60, journalURL: url,
                                         now: now.addingTimeInterval(2))
        #expect(!(await shorterWindow.snapshot(now: now).sessions.contains { $0.id == "long-window" }))
    }

    @Test("an oversized project label is cut to the journal's byte bound before it is persisted")
    func boundsProjectLabel() {
        let huge = String(repeating: "x", count: 10_000)
        let e = LifecycleJournalEntry(sessionID: "s", agent: .claudeCode, event: "prompt", source: .hook,
                                      timestamp: now, status: .working, waitKind: nil, project: huge)
        #expect(e.project?.utf8.count == LifecycleJournalEntry.maxProjectBytes)
        let cjk = String(repeating: "项", count: 100)   // 3 bytes each: cut on a character boundary
        let c = LifecycleJournalEntry(sessionID: "s", agent: .claudeCode, event: "prompt", source: .hook,
                                      timestamp: now, status: .working, waitKind: nil, project: cjk)
        #expect(c.project!.utf8.count <= LifecycleJournalEntry.maxProjectBytes)
        #expect(c.project!.allSatisfy { $0 == "项" })
        let short = LifecycleJournalEntry(sessionID: "s", agent: .claudeCode, event: "prompt", source: .hook,
                                          timestamp: now, status: .working, waitKind: nil, project: "vibebuddy")
        #expect(short.project == "vibebuddy")
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
