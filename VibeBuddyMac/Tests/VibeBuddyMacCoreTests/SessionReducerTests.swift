import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("SessionReducer — hook events to status")
struct SessionReducerTests {

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func ev(
        _ kind: HookEvent.Kind,
        _ sid: String = "s1",
        cwd: String? = "/Users/me/projects/vibebuddy",
        tool: String? = nil,
        message: String? = nil,
        toolError: Bool = false,
        at: TimeInterval = 0
    ) -> HookEvent {
        HookEvent(kind: kind, sessionID: sid, agent: .claudeCode,
                  cwd: cwd, toolName: tool, message: message,
                  toolError: toolError, timestamp: t0.addingTimeInterval(at))
    }

    @Test("a tool error before Stop marks the done session failed")
    func toolErrorThenStopIsFailed() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.apply(ev(.postToolUse, tool: "Bash", toolError: true, at: 1))
        r.apply(ev(.stop, at: 2))
        #expect(r.sessions["s1"]?.status == .done)
        #expect(r.sessions["s1"]?.isStuck == true)
    }

    @Test("a clean turn ends not-failed")
    func cleanTurnNotFailed() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.apply(ev(.postToolUse, tool: "Bash", toolError: true, at: 1))   // errored mid-turn
        r.apply(ev(.postToolUse, tool: "Bash", toolError: false, at: 2))  // …then recovered
        r.apply(ev(.stop, at: 3))
        #expect(r.sessions["s1"]?.isStuck == false)
    }

    @Test("a failure-looking Stop message marks failed even without a tool error")
    func failureStopMessage() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.apply(ev(.stop, message: "Build failed: 3 errors", at: 1))
        #expect(r.sessions["s1"]?.isStuck == true)
    }

    @Test("spentTokens accumulates distinct per-turn readings, ignoring re-reads")
    func spentAccumulates() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.enrich(sessionID: "s1", with: TranscriptInfo(tokens: 1000))   // turn 1
        r.enrich(sessionID: "s1", with: TranscriptInfo(tokens: 1000))   // same turn re-read → not double-counted
        r.enrich(sessionID: "s1", with: TranscriptInfo(tokens: 1500))   // turn 2
        #expect(r.sessions["s1"]?.spentTokens == 2500)
        #expect(r.sessions["s1"]?.tokens == 1500)   // latest turn
    }

    @Test("a new prompt clears a prior failure")
    func newPromptClearsFailure() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.apply(ev(.postToolUse, tool: "Bash", toolError: true, at: 1))
        r.apply(ev(.userPromptSubmit, at: 2))
        #expect(r.sessions["s1"]?.isStuck == false)
    }

    @Test("SessionStart creates a working session with project from cwd")
    func startCreates() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        let s = r.sessions["s1"]
        #expect(s?.status == .working)
        #expect(s?.project == "vibebuddy")
        #expect(s?.agent == .claudeCode)
    }

    @Test("Notification about permission → needsResponse/permission with summary")
    func notificationPermission() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.apply(ev(.notification, message: "Claude needs your permission to use Bash", at: 1))
        let s = r.sessions["s1"]
        #expect(s?.status == .needsResponse)
        #expect(s?.waitKind == .permission)
        #expect(s?.summary == "Claude needs your permission to use Bash")
    }

    @Test("Notification about input → needsResponse/question")
    func notificationQuestion() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.apply(ev(.notification, message: "Claude is waiting for your input", at: 1))
        #expect(r.sessions["s1"]?.status == .needsResponse)
        #expect(r.sessions["s1"]?.waitKind == .question)
    }

    @Test("PostToolUse moves a waiting session back to working and clears waitKind")
    func recoverAfterApproval() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.apply(ev(.notification, message: "needs your permission", at: 1))
        r.apply(ev(.postToolUse, tool: "Bash", at: 2))
        #expect(r.sessions["s1"]?.status == .working)
        #expect(r.sessions["s1"]?.waitKind == nil)
    }

    @Test("Stop marks the session done")
    func stopDone() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.apply(ev(.stop, at: 5))
        #expect(r.sessions["s1"]?.status == .done)
    }

    @Test("statusSince does not move when the status is unchanged")
    func statusSinceStable() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart, at: 0))
        r.apply(ev(.preToolUse, tool: "Read", at: 3))   // still working
        #expect(r.sessions["s1"]?.statusSince == t0)
    }

    @Test("statusSince moves on a real transition")
    func statusSinceChanges() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart, at: 0))
        r.apply(ev(.notification, message: "permission", at: 4))
        #expect(r.sessions["s1"]?.statusSince == t0.addingTimeInterval(4))
    }

    @Test("two sessions are tracked independently")
    func twoSessions() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart, "a", at: 0))
        r.apply(ev(.sessionStart, "b", at: 0))
        r.apply(ev(.notification, "a", message: "permission", at: 1))
        r.apply(ev(.stop, "b", at: 1))
        #expect(r.sessions["a"]?.status == .needsResponse)
        #expect(r.sessions["b"]?.status == .done)
    }

    @Test("Stop on an unknown session creates it as done (late start / Codex notify)")
    func stopCreatesDone() {
        var r = SessionReducer()
        r.apply(ev(.stop, "ghost", cwd: "/x/proj", at: 0))
        #expect(r.sessions["ghost"]?.status == .done)
        #expect(r.sessions["ghost"]?.project == "proj")
    }

    @Test("Stop carries a summary and agent when provided (Codex turn-complete)")
    func stopSummary() {
        var r = SessionReducer()
        r.apply(HookEvent(kind: .stop, sessionID: "c", agent: .codex,
                          cwd: "/x/p", message: "done refactoring", timestamp: t0))
        #expect(r.sessions["c"]?.status == .done)
        #expect(r.sessions["c"]?.summary == "done refactoring")
        #expect(r.sessions["c"]?.agent == .codex)
    }

    @Test("snapshot() returns sessions sorted by attention then recency")
    func snapshotSorted() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart, "done1", at: 0))
        r.apply(ev(.stop, "done1", at: 1))
        r.apply(ev(.sessionStart, "work1", at: 2))
        r.apply(ev(.sessionStart, "need1", at: 3))
        r.apply(ev(.notification, "need1", message: "permission", at: 4))
        let snap = r.snapshot(now: t0.addingTimeInterval(10))
        #expect(snap.sessions.map(\.id) == ["need1", "work1", "done1"])
        #expect(snap.serverTime == t0.addingTimeInterval(10))
    }

    // MARK: - Session termination

    @Test("SessionEnd removes the session from the dashboard")
    func sessionEndRemoves() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.apply(ev(.notification, message: "Claude is waiting for your input", at: 1))
        r.apply(ev(.sessionEnd, at: 2))
        #expect(r.sessions["s1"] == nil)
    }

    @Test("SessionEnd on an unknown session is a harmless no-op")
    func sessionEndUnknown() {
        var r = SessionReducer()
        r.apply(ev(.sessionEnd, "ghost", at: 0))
        #expect(r.sessions.isEmpty)
    }

    // MARK: - RC3: stale wait-prompt summary on a terminal transition

    @Test("Stop with no message clears a stale needsResponse summary")
    func stopClearsStaleSummary() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.apply(ev(.notification, message: "Claude needs your permission to use Bash", at: 1))
        r.apply(ev(.stop, at: 2))            // Stop carries no message
        #expect(r.sessions["s1"]?.status == .done)
        #expect(r.sessions["s1"]?.summary == nil)   // the permission prompt must not linger
    }

    // MARK: - Self-healing reconciliation

    @Test("reconcile drops a needsResponse whose transcript advanced after it began waiting")
    func reconcileDropsAnswered() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart, at: 0))
        r.apply(ev(.notification, message: "waiting for your input", at: 5))  // statusSince = t0+5
        r.reconcile(now: t0.addingTimeInterval(20),
                    lastActivity: ["s1": t0.addingTimeInterval(12)],          // transcript grew after t0+5
                    staleAfter: 3600)
        #expect(r.sessions["s1"] == nil)
    }

    @Test("reconcile keeps a fresh, unanswered needsResponse")
    func reconcileKeepsFresh() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart, at: 0))
        r.apply(ev(.notification, message: "waiting for your input", at: 5))  // statusSince = updatedAt = t0+5
        r.reconcile(now: t0.addingTimeInterval(10),
                    lastActivity: ["s1": t0.addingTimeInterval(2)],           // transcript older than the wait
                    staleAfter: 3600)                                          // age 5s << 3600
        #expect(r.sessions["s1"]?.status == .needsResponse)
    }

    @Test("reconcile drops a needsResponse idle past staleAfter with no new activity")
    func reconcileDropsStale() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart, at: 0))
        r.apply(ev(.notification, message: "waiting for your input", at: 5))  // updatedAt = t0+5
        r.reconcile(now: t0.addingTimeInterval(5000),                          // ~83 min later
                    lastActivity: [:],                                         // no transcript activity known
                    staleAfter: 1800)                                          // 30 min
        #expect(r.sessions["s1"] == nil)
    }

    @Test("reconcile never touches working or done sessions")
    func reconcileScopedToWaiting() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart, "w", at: 0))
        r.apply(ev(.sessionStart, "d", at: 0))
        r.apply(ev(.stop, "d", at: 1))
        r.reconcile(now: t0.addingTimeInterval(100_000), lastActivity: [:], staleAfter: 60)
        #expect(r.sessions["w"]?.status == .working)
        #expect(r.sessions["d"]?.status == .done)
    }

    // MARK: - Remote approval set/clear

    @Test("setPendingApproval marks the session needsResponse/permission with the approval")
    func setsPendingApproval() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.setPendingApproval(sessionID: "s1",
                             PendingApproval(id: "ap1", tool: "Bash", commandPreview: "rm -rf x"),
                             at: t0.addingTimeInterval(1))
        let s = r.sessions["s1"]
        #expect(s?.status == .needsResponse)
        #expect(s?.waitKind == .permission)
        #expect(s?.pendingApproval?.id == "ap1")
    }

    @Test("setPendingApproval clears any pending question")
    func setPendingApprovalClearsQuestion() {
        var r = SessionReducer()
        let question = PendingQuestion(
            id: "branch",
            prompt: "Which branch?",
            options: [QuestionOption(id: "main", label: "main")]
        )
        r.apply(ev(.sessionStart))
        r.apply(ev(.notification, message: "waiting for your input", at: 1))
        r.enrich(sessionID: "s1", with: TranscriptInfo(pendingQuestion: question))
        r.setPendingApproval(sessionID: "s1",
                             PendingApproval(id: "ap1", tool: "Bash", commandPreview: "x"),
                             at: t0.addingTimeInterval(2))
        let s = r.sessions["s1"]
        #expect(s?.waitKind == .permission)
        #expect(s?.pendingQuestion == nil)
        #expect(s?.pendingApproval?.id == "ap1")
    }

    @Test("enrich pending question replaces an existing approval")
    func enrichPendingQuestionReplacesApproval() {
        var r = SessionReducer()
        let question = PendingQuestion(
            id: "branch",
            prompt: "Which branch?",
            options: [QuestionOption(id: "main", label: "main")]
        )
        r.apply(ev(.sessionStart))
        r.setPendingApproval(sessionID: "s1",
                             PendingApproval(id: "ap1", tool: "Bash", commandPreview: "x"),
                             at: t0.addingTimeInterval(1))
        r.enrich(sessionID: "s1", with: TranscriptInfo(pendingQuestion: question))
        let s = r.sessions["s1"]
        #expect(s?.waitKind == .question)
        #expect(s?.pendingApproval == nil)
        #expect(s?.pendingQuestion?.id == "branch")
        #expect(s?.summary == "Which branch?")
    }

    @Test("clearPendingApproval drops the approval and returns the session to working")
    func clearsPendingApproval() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.setPendingApproval(sessionID: "s1",
                             PendingApproval(id: "ap1", tool: "Bash", commandPreview: "x"),
                             at: t0.addingTimeInterval(1))
        r.clearPendingApproval(sessionID: "s1", at: t0.addingTimeInterval(2))
        let s = r.sessions["s1"]
        #expect(s?.pendingApproval == nil)
        #expect(s?.status == .working)
        #expect(s?.waitKind == nil)
    }

    // MARK: - Terminal ref

    @Test("setTerminalRef attaches the ref without changing status")
    func setsTerminalRef() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.setTerminalRef(sessionID: "s1", TerminalRef(termProgram: "ghostty", tmux: "/tmp/x,1,0", tmuxPane: "%2"))
        #expect(r.sessions["s1"]?.terminalRef?.tmuxPane == "%2")
        #expect(r.sessions["s1"]?.status == .working)
    }

    // MARK: - Context usage enrichment

    @Test("enrich carries contextTokens and a model-derived contextWindow")
    func enrichContextUsage() {
        var r = SessionReducer()
        r.apply(ev(.sessionStart))
        r.enrich(sessionID: "s1", with: TranscriptInfo(model: "claude-opus-4-8", tokens: 1200, contextTokens: 21000))
        #expect(r.sessions["s1"]?.contextTokens == 21000)
        #expect(r.sessions["s1"]?.contextWindow == 200_000)
        #expect(r.sessions["s1"]?.tokens == 1200)
    }
}
