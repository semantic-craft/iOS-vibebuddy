import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Historical session action boundaries")
struct HistoryResumePolicyTests {
    private func history() -> SessionHistorySession {
        SessionHistorySession(id: "claude:test", nativeSessionID: "019c6e27-e55b-73d1-87d8-4e01f1f75043", agent: .claude,
                              projectPath: "/tmp/project", title: "Example", sourcePath: "/tmp/source.jsonl",
                              updatedAt: Date(), messages: [])
    }

    @Test func commandQuotesShellMetacharactersWithoutExecuting() {
        var item = history()
        item.projectPath = "/tmp/a'b $(touch unwanted) `echo nope`"
        #expect(HistoryResumePolicy.command(for: item, directoryExists: true) ==
                "cd -- '/tmp/a'\"'\"'b $(touch unwanted) `echo nope`' && claude --resume '019c6e27-e55b-73d1-87d8-4e01f1f75043'")
        item.projectPath = "/tmp/a\ncommand"
        #expect(HistoryResumePolicy.command(for: item, directoryExists: true) == nil)
    }

    @Test func refusesMissingSourcesDirectoriesAndUnknownCodexProvenance() {
        var item = history()
        #expect(HistoryResumePolicy.command(for: item, directoryExists: false) == nil)
        item.isAvailable = false
        #expect(HistoryResumePolicy.command(for: item, directoryExists: true) == nil)
        item.isAvailable = true
        item.agent = .codex
        #expect(HistoryResumePolicy.command(for: item, directoryExists: true) == nil)
        item.agent = .claude
        item.nativeSessionID = "bad; command"
        #expect(HistoryResumePolicy.command(for: item, directoryExists: true) == nil)
    }

    @Test func resolvesOnlyUniqueExactLiveIdentity() {
        var item = history()
        var live = AgentSession(id: item.nativeSessionID, agent: .claudeCode, project: "project", status: .done,
                                terminalRef: TerminalRef(cwd: item.projectPath), statusSince: Date(), updatedAt: Date())
        #expect(HistoryResumePolicy.liveSession(for: item, in: [live]) == live)
        #expect(HistoryResumePolicy.liveSession(for: item, in: [live, live]) == nil)
        live.terminalRef = TerminalRef(cwd: "/different/project")
        #expect(HistoryResumePolicy.liveSession(for: item, in: [live]) == nil)
        live.terminalRef = nil
        #expect(HistoryResumePolicy.liveSession(for: item, in: [live]) == nil)
        live.terminalRef = TerminalRef(cwd: item.projectPath)
        item.agent = .codex
        #expect(HistoryResumePolicy.liveSession(for: item, in: [live]) == nil)
    }

    @Test func resolvesDaemonCodexIdentityWithoutInventingATerminal() {
        var item = history()
        item.agent = .codex
        item.source = "vscode"
        var live = AgentSession(id: item.nativeSessionID, agent: .codex, project: "project", status: .done,
                                statusSince: Date(), updatedAt: Date())
        live.desktopThreadID = item.nativeSessionID
        #expect(HistoryResumePolicy.liveSession(for: item, in: [live]) == live)
        #expect(HistoryResumePolicy.command(for: item, directoryExists: true) == nil)
        #expect(HistoryResumePolicy.liveSession(for: item, in: [live, live]) == nil)
        live.terminalRef = TerminalRef(cwd: "/different/project")
        #expect(HistoryResumePolicy.liveSession(for: item, in: [live]) == nil)
        live.terminalRef = nil
        live.desktopThreadID = UUID().uuidString
        #expect(HistoryResumePolicy.liveSession(for: item, in: [live]) == nil)
    }
}
