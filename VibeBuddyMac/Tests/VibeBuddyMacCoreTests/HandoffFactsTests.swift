import Foundation
import XCTest
import VibeBuddyKit
@testable import VibeBuddyMacCore

final class HandoffFactsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A journal and a ledger the daemon could have written, in a temp directory.
    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("facts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var journal = LifecycleJournal(url: dir.appendingPathComponent("lifecycle-journal.json"), now: now)
        journal.append(LifecycleJournalEntry(sessionID: "abc", agent: .claudeCode, event: "userPromptSubmit", source: .hook,
                                             timestamp: now.addingTimeInterval(-600), status: .working, waitKind: nil, project: "repo"), now: now)
        journal.append(LifecycleJournalEntry(sessionID: "abc", agent: .claudeCode, event: "stop", source: .hook,
                                             timestamp: now.addingTimeInterval(-300), status: .done, waitKind: nil, project: "repo",
                                             completionID: "c1", hasUnreadCompletion: true, statusSince: now.addingTimeInterval(-300)), now: now)
        journal.append(LifecycleJournalEntry(sessionID: "abc", agent: .claudeCode, event: "completionAcknowledged", source: .recovery,
                                             timestamp: now.addingTimeInterval(-200), status: .done, waitKind: nil, project: "repo",
                                             completionID: "c1", hasUnreadCompletion: false, statusSince: now.addingTimeInterval(-300),
                                             acknowledgedCompletionID: "c1"), now: now)
        // The same native id under another agent: a different session.
        journal.append(LifecycleJournalEntry(sessionID: "abc", agent: .codex, event: "userPromptSubmit", source: .appserver,
                                             timestamp: now.addingTimeInterval(-100), status: .working, waitKind: nil, project: "other"), now: now)
        // A journal-only session under a unique native id.
        journal.append(LifecycleJournalEntry(sessionID: "solo", agent: .codex, event: "userPromptSubmit", source: .appserver,
                                             timestamp: now.addingTimeInterval(-80), status: .working, waitKind: nil, project: "solo"), now: now)
        var ledger = ToolLedger(url: dir.appendingPathComponent("tool-ledger.json"), now: now)
        ledger.observe(ToolCallRecord(id: "t1", tool: "Edit", files: ["/repo/Sources/A.swift"], linesAdded: 3, linesRemoved: 1,
                                      result: .succeeded, observedAt: now.addingTimeInterval(-500), source: "hook"), sessionID: "abc", now: now, agent: .claudeCode)
        ledger.observe(ToolCallRecord(id: "t2", tool: "Write", files: ["/repo/.scratch/handoff-continue/issues/01-facts-tool.md"],
                                      result: .succeeded, observedAt: now.addingTimeInterval(-450), source: "hook"), sessionID: "abc", now: now, agent: .claudeCode)
        for (i, command) in ["swift test --filter A", "xcodebuild -scheme X"].enumerated() {
            ledger.observe(ToolCallRecord(id: "b\(i)", tool: "Bash", command: command, result: i == 0 ? .succeeded : .failed,
                                          exitCode: i == 0 ? 0 : 65, observedAt: now.addingTimeInterval(Double(-400 + i * 10)), source: "hook"), sessionID: "abc", now: now, agent: .claudeCode)
        }
        ledger.observe(ToolCallRecord(id: "b9", tool: "Bash", command: "git status", result: .unconfirmed,
                                      observedAt: now.addingTimeInterval(-350), source: "hook"), sessionID: "abc", now: now, agent: .claudeCode)
        ledger.observe(ToolCallRecord(id: "acp1", tool: "shell", result: .succeeded, observedAt: now.addingTimeInterval(-50), source: "acp"), sessionID: "cur", now: now, agent: .cursor)
        // The ledger writes at most once per window; the facts tool reads the
        // file, so the fixture must be on disk before it is read.
        ledger.flush(now: now)
        return dir
    }

    private func bytes(_ dir: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    private let fakeGit = HandoffFacts.GitProbe { cwd in
        guard cwd.hasPrefix("/repo") else { return nil }
        return HandoffFacts.GitState(root: "/repo", head: "78f7a997abcd", branch: "feat/x", status: [" M Sources/A.swift", "?? notes.md"], truncated: false)
    }

    func testHeaderFactsAndCoverageForAnObservedSession() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try bytes(dir)
        let text = try HandoffFacts.call(arguments: ["key": "claude-code:abc"], directory: dir, git: fakeGit, now: now)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(4)), ["Source session: claude-code:abc", "Ticket: unknown", "Branch: feat/x", "Worktree: /repo"])
        XCTAssertTrue(text.contains("## Facts (recorded by VibeBuddy, as of 2027-01-15T08:00:00Z)"))
        XCTAssertTrue(text.contains("- Agent: Claude Code · first seen"))
        XCTAssertTrue(text.contains("- Rounds ended: 1 stop event(s), 1 completion id(s) · last status: done · completion read · no failed round recorded"))
        XCTAssertTrue(text.contains("- Checkout: /repo (derived from edited files)"))
        XCTAssertTrue(text.contains("- Git: HEAD 78f7a997abcd on feat/x · 2 changed or untracked path(s) (as of 2027-01-15T08:00:00Z)"))
        XCTAssertTrue(text.contains("- Tickets touched: /repo/.scratch/handoff-continue"))
        XCTAssertTrue(text.contains("- Files edited (2):"))
        XCTAssertTrue(text.contains("- Commands (last 3 of 3, oldest first):"))
        XCTAssertTrue(text.contains("`swift test --filter A` → exit 0"))
        XCTAssertTrue(text.contains("`xcodebuild -scheme X` → exit 65"))
        XCTAssertTrue(text.contains("`git status` → result unconfirmed"))
        XCTAssertTrue(text.contains("- Coverage: hook payloads report commands and exit codes; the ledger keeps"))
        XCTAssertTrue(lines.last!.hasPrefix("- Data: lifecycle journal written "), lines.last!)
        XCTAssertFalse(text.contains("Codex"), "the codex session with the same native id is another session")
        XCTAssertEqual(try bytes(dir), before, "reading facts writes nothing")
    }

    func testCommandLimitAndExplicitCheckout() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = try HandoffFacts.call(arguments: ["key": "vibebuddy://session/claude-code:abc#3", "commands": 1, "cwd": "/repo/sub"], directory: dir, git: fakeGit, now: now)
        XCTAssertTrue(text.contains("- Checkout: /repo/sub (from cwd)"))
        XCTAssertTrue(text.contains("- Commands (last 1 of 3, oldest first):"))
        XCTAssertTrue(text.contains("  - … 2 earlier command(s) not shown"))
        XCTAssertTrue(text.contains("`git status`"))
        XCTAssertFalse(text.contains("swift test"))
    }

    func testToolNamesOnlySourceIsSaidSo() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = try HandoffFacts.call(arguments: ["key": "cursor:cur"], directory: dir, git: fakeGit, now: now)
        XCTAssertTrue(text.contains("- Agent: Cursor · lifecycle not recorded (tool calls only)"))
        XCTAssertTrue(text.contains("- Commands: 1 tool call(s) recorded, none with command text"))
        XCTAssertTrue(text.contains("acp report tool names only"))
        XCTAssertTrue(text.contains("- Git: not probed (no checkout)"))
    }

    func testUnobservedKeyIsAnAnswerNotAnError() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = try HandoffFacts.call(arguments: ["key": "codex:nobody"], directory: dir, git: fakeGit, now: now)
        XCTAssertEqual(text.components(separatedBy: "\n").prefix(4).map { $0 }, ["Source session: codex:nobody", "Ticket: unknown", "Branch: unknown", "Worktree: unknown"])
        XCTAssertTrue(text.contains("- Not recorded: no observation of codex:nobody in the lifecycle journal or tool ledger"))
        XCTAssertTrue(text.contains("- Data: "))
        let absent = try HandoffFacts.call(arguments: ["key": "codex:nobody"], directory: dir.appendingPathComponent("missing"), git: fakeGit, now: now)
        XCTAssertTrue(absent.contains("lifecycle journal absent; tool ledger absent"))
    }

    func testBareNativeIDResolvesWhenUnambiguous() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let single = try HandoffFacts.call(arguments: ["key": "solo"], directory: dir, git: fakeGit, now: now)
        XCTAssertTrue(single.hasPrefix("Source session: codex:solo\n"), single)
        let ledgerOnly = try HandoffFacts.call(arguments: ["key": "cur"], directory: dir, git: fakeGit, now: now)
        XCTAssertTrue(ledgerOnly.hasPrefix("Native id cur has tool calls but no lifecycle record"), ledgerOnly)
        let ambiguous = try HandoffFacts.call(arguments: ["key": "abc"], directory: dir, git: fakeGit, now: now)
        XCTAssertTrue(ambiguous.hasPrefix("Ambiguous native id abc; pass a full key:\n- claude-code:abc\n- codex:abc"), ambiguous)
        XCTAssertThrowsError(try HandoffFacts.call(arguments: ["key": "nope:abc"], directory: dir, git: fakeGit, now: now))
        XCTAssertThrowsError(try HandoffFacts.call(arguments: ["key": "claude-code:abc", "cwd": "relative"], directory: dir, git: fakeGit, now: now))
    }

    func testALineageRecordIsPrintedBeforeAnyObservation() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        var ledger = ContinuationLedger(url: dir.appendingPathComponent(ContinuationLedger.fileName), now: now)
        ledger.record(receiverKey: "codex:brand-new", sourceKey: "claude-code:abc", handoffPath: "/repo/.scratch/e/handoffs/h.md", now: now.addingTimeInterval(-30))
        let unobserved = try HandoffFacts.call(arguments: ["key": "codex:brand-new"], directory: dir, git: fakeGit, now: now)
        XCTAssertTrue(unobserved.contains("- Continues: claude-code:abc (started by the Mac from the handoff at /repo/.scratch/e/handoffs/h.md, 2027-01-15T07:59:30Z)"), unobserved)
        XCTAssertTrue(unobserved.contains("- Not recorded:"))
        let source = try HandoffFacts.call(arguments: ["key": "claude-code:abc"], directory: dir, git: fakeGit, now: now)
        XCTAssertFalse(source.contains("- Continues:"), "the source did not continue anything")
        ledger.record(receiverKey: "cursor:cur", sourceKey: "codex:solo", handoffPath: nil, now: now)
        let observed = try HandoffFacts.call(arguments: ["key": "cursor:cur"], directory: dir, git: fakeGit, now: now)
        XCTAssertTrue(observed.contains("- Continues: codex:solo (started by the Mac from the history tools (no handoff document), 2027-01-15T08:00:00Z)"), observed)
    }

    func testOtherAgentAndUnqualifiedToolsCannotBeAttributedByTheRequestedPrefix() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        var ledger = ToolLedger(url: dir.appendingPathComponent("tool-ledger.json"), now: now)
        ledger.observe(ToolCallRecord(id: "legacy", tool: "Bash", command: "legacy-command", result: .succeeded,
                                      observedAt: now, source: "hook"), sessionID: "abc", now: now)
        ledger.observe(ToolCallRecord(id: "t1", tool: "Bash", command: "codex-check", result: .succeeded,
                                      observedAt: now, source: "hook"), sessionID: "abc", now: now, agent: .codex)
        ledger.flush(now: now)
        let text = try HandoffFacts.call(arguments: ["key": "codex:abc"], directory: dir, git: fakeGit, now: now)
        XCTAssertTrue(text.contains("codex-check"))
        let claude = try HandoffFacts.call(arguments: ["key": "claude-code:abc"], directory: dir, git: fakeGit, now: now)
        XCTAssertTrue(claude.contains("/repo/Sources/A.swift"), "same call id from another agent must not overwrite the original")
        XCTAssertFalse(claude.contains("codex-check"))
        XCTAssertFalse(text.contains("legacy-command"))
        XCTAssertTrue(text.contains("agent was not recorded"))
        XCTAssertFalse(text.contains("swift test --filter A"))
        XCTAssertFalse(text.contains("/repo/Sources/A.swift"))
        XCTAssertTrue(text.contains("- Files edited: none recorded"))
    }

    func testFailedAndUnconfirmedEditsDoNotEstablishFilesOrCheckout() {
        let records = [
            ToolCallRecord(id: "failed", tool: "Edit", files: ["/wrong/.scratch/e/f.md"], result: .failed, observedAt: now, source: "hook"),
            ToolCallRecord(id: "intent", tool: "Write", files: ["/wrong/A.swift"], result: .unconfirmed, observedAt: now, source: "hook"),
            ToolCallRecord(id: "ok", tool: "Edit", files: ["/repo/A.swift"], result: .succeeded, observedAt: now, source: "hook")
        ]
        XCTAssertEqual(HandoffFacts.editedFiles(records), ["/repo/A.swift"])
    }

    func testCLIShapeAndRegistry() throws {
        let parsed = try HistoryCLI.parse(["facts", "claude-code:abc", "--commands", "5", "--cwd", "/repo"])
        XCTAssertEqual(parsed.tool, HandoffFacts.toolName)
        XCTAssertEqual(parsed.arguments["key"] as? String, "claude-code:abc")
        XCTAssertEqual(parsed.arguments["commands"] as? String, "5")
        let normalized = try HistoryTools.normalizeCLIArguments(parsed.tool, arguments: parsed.arguments)
        XCTAssertEqual(normalized["commands"] as? Int, 5)
        XCTAssertNoThrow(try HistoryTools.validateArguments(parsed.tool, arguments: normalized))
        XCTAssertThrowsError(try HistoryTools.validateArguments(parsed.tool, arguments: ["key": "k", "commands": 51]))
        XCTAssertThrowsError(try HistoryCLI.parse(["facts"]))
        XCTAssertEqual(HandoffFacts.definition["title"] as? String, "Handoff facts")
    }
}
