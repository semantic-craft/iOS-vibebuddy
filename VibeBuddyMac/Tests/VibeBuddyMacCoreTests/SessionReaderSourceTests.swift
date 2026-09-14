import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Reader source resolution")
struct SessionReaderSourceTests {
    private func live(_ id: String, _ agent: AgentKind) -> AgentSession {
        AgentSession(id: id, agent: agent, project: "project", status: .working, statusSince: Date(), updatedAt: Date())
    }

    @Test func transcriptKeysUseTheAgentKeyNameAndRecordIDsTheRawValue() throws {
        let claude = live("019c6e27-e55b-73d1-87d8-4e01f1f75043", .claudeCode)
        #expect(SessionReaderSource.resolve(for: claude) == .transcript(key: "claude-code:019c6e27-e55b-73d1-87d8-4e01f1f75043"))
        #expect(SessionReaderSource.recordID(for: claude) == "claude:019c6e27-e55b-73d1-87d8-4e01f1f75043")
        #expect(SessionReaderSource.resolve(for: live("thread_1", .codex)) == .transcript(key: "codex:thread_1"))
        #expect(SessionReaderSource.resolve(for: live("composer-9", .cursor)) == .transcript(key: "cursor:composer-9"))
        // Every key this produces must parse as a history reference.
        let reference = try HistorySessionReference(try #require(SessionReaderSource.transcriptKey(for: claude)))
        #expect(reference.agent == .claude && reference.nativeID == claude.id)
    }

    @Test func agentsWithoutATranscriptReaderFallBackToRecentOutput() {
        for agent in [AgentKind.grok, .grokBot, .copilot, .opencode, .qwen, .kimi, .antigravity] {
            #expect(SessionReaderSource.resolve(for: live("abc-123", agent)) == .recentOutput, "\(agent)")
        }
        // Grok Build still has a list-only record id, so the star and Show source can find it.
        #expect(SessionReaderSource.recordID(for: live("abc-123", .grok)) == "grokBuild:abc-123")
        #expect(SessionReaderSource.recordID(for: live("abc-123", .grokBot)) == nil)
    }

    @Test func idsThatAreNotNativeSessionIDsNeverBecomeKeys() {
        #expect(SessionReaderSource.resolve(for: live("bc_1234", .cursor)) == .transcript(key: "cursor:bc_1234"))
        #expect(SessionReaderSource.resolve(for: live("cloud/agent 7", .cursor)) == .recentOutput)
        #expect(SessionReaderSource.resolve(for: live("", .claudeCode)) == .recentOutput)
        #expect(SessionReaderSource.recordID(for: live("a:b", .claudeCode)) == nil)
    }
}

@Suite("Reader window")
struct ReaderWindowTests {
    @Test func opensOnTheLastPageAndWalksBackwards() {
        let window = ReaderWindow.tail(of: 75)
        #expect(window.range == 45..<75 && window.hasEarlier)
        let earlier = window.expandedEarlier()
        #expect(earlier.range == 15..<75)
        let all = earlier.expandedEarlier()
        #expect(all.range == 0..<75 && !all.hasEarlier)
        #expect(all.expandedEarlier() == all)
        #expect(ReaderWindow.tail(of: 4).range == 0..<4)
        #expect(ReaderWindow.tail(of: 0).range == 0..<0)
    }

    @Test func refreshedTranscriptCanShrinkBeforeTheWindowUpdates() {
        let oldWindow = ReaderWindow.tail(of: 75)
        let refreshedRows = ["a", "b", "c"]
        let visible = oldWindow.grown(to: refreshedRows.count)
        #expect(Array(refreshedRows[visible.range]).isEmpty)
        #expect(oldWindow.grown(to: 0).range == 0..<0)
    }

    @Test func revealingASearchHitStartsAtTheHit() {
        let window = ReaderWindow.revealing(52, of: 75)
        #expect(window.range == 52..<75 && window.hasEarlier)
        #expect(ReaderWindow.revealing(90, of: 75).range == 75..<75)
    }

    @Test func appendedRowsKeepTheStartAndOtherChangesReset() {
        let old = ["a", "b", "c"]
        #expect(ReaderWindow.appendedCount(old: old, new: ["a", "b", "c", "d", "e"]) == 2)
        #expect(ReaderWindow.appendedCount(old: old, new: old) == 0)
        #expect(ReaderWindow.appendedCount(old: old, new: ["a", "x", "c", "d"]) == nil)
        #expect(ReaderWindow.appendedCount(old: old, new: ["a", "b"]) == nil)
        #expect(ReaderWindow.tail(of: 3).grown(to: 5).range == 0..<5)
        #expect(ReaderWindow(start: 40, count: 70).grown(to: 72).range == 40..<72)
    }
}
