import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("SessionStore — termination & self-healing")
struct SessionStoreTests {

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a SessionEnd hook removes the session end-to-end")
    func sessionEndRemoves() async throws {
        let store = SessionStore()
        await store.ingest(
            Data(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/proj"}"#.utf8),
            receivedAt: t0)
        #expect(await store.snapshot(now: t0).sessions.count == 1)

        await store.ingest(
            Data(#"{"hook_event_name":"SessionEnd","session_id":"s","cwd":"/x/proj"}"#.utf8),
            receivedAt: t0.addingTimeInterval(1))
        #expect(await store.snapshot(now: t0.addingTimeInterval(1)).sessions.isEmpty)
    }

    @Test("sweep drops a needsResponse idle past staleAfter")
    func sweepDropsStale() async throws {
        let store = SessionStore(staleAfter: 60)
        await store.ingest(
            Data(#"{"hook_event_name":"Notification","session_id":"s","cwd":"/x/proj","message":"waiting for your input"}"#.utf8),
            receivedAt: t0)
        #expect(await store.snapshot(now: t0).sessions.first?.status == .needsResponse)

        await store.sweep(now: t0.addingTimeInterval(120))   // 120s > 60s staleAfter
        #expect(await store.snapshot(now: t0.addingTimeInterval(120)).sessions.isEmpty)
    }

    @Test("sweep drops a needsResponse whose transcript advanced after it began waiting")
    func sweepReconcilesFromTranscript() async throws {
        let tmp = NSTemporaryDirectory() + "vb-sweep-\(UUID().uuidString).jsonl"
        try "{}".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = SessionStore(staleAfter: 86_400)   // long, so only the transcript rule can fire
        let payload = #"{"hook_event_name":"Notification","session_id":"s","cwd":"/x/proj","message":"waiting for your input","transcript_path":"\#(tmp)"}"#
        await store.ingest(Data(payload.utf8), receivedAt: t0)   // statusSince = t0
        #expect(await store.snapshot(now: t0).sessions.first?.status == .needsResponse)

        // The transcript was modified AFTER the wait began → the prompt was answered.
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(100)], ofItemAtPath: tmp)
        await store.sweep(now: t0.addingTimeInterval(200))
        #expect(await store.snapshot(now: t0.addingTimeInterval(200)).sessions.isEmpty)
    }

    @Test("beginApproval fires the needsResponse handler so a closed app can be pushed")
    func beginApprovalNotifies() async {
        actor Box { var ids: [String] = []; func add(_ id: String) { ids.append(id) }; func all() -> [String] { ids } }
        let box = Box()
        let store = SessionStore()
        await store.ingest(
            Data(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/proj"}"#.utf8),
            receivedAt: t0)
        await store.setNeedsResponseHandler { session in
            await box.add(session.pendingApproval?.id ?? "none")
        }
        await store.beginApproval(sessionID: "s",
                                  PendingApproval(id: "ap1", tool: "Bash", commandPreview: "rm x"),
                                  at: t0.addingTimeInterval(1))
        try? await Task.sleep(for: .milliseconds(100))   // handler runs in a detached Task
        #expect(await box.all() == ["ap1"])
    }

    @Test("beginApproval makes the session needsResponse with a pendingApproval; endApproval clears it")
    func approvalLifecycle() async {
        let store = SessionStore()
        await store.ingest(
            Data(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/proj"}"#.utf8),
            receivedAt: t0)

        await store.beginApproval(sessionID: "s",
                                  PendingApproval(id: "ap1", tool: "Bash", commandPreview: "rm x"),
                                  at: t0.addingTimeInterval(1))
        let waiting = await store.snapshot(now: t0).sessions.first
        #expect(waiting?.status == .needsResponse)
        #expect(waiting?.pendingApproval?.id == "ap1")

        await store.endApproval(sessionID: "s", at: t0.addingTimeInterval(2))
        let done = await store.snapshot(now: t0).sessions.first
        #expect(done?.pendingApproval == nil)
        #expect(done?.status == .working)
    }

    @Test("a terminalRef arriving before SessionStart still lands once the session exists")
    func terminalRefBeforeSession() async {
        let store = SessionStore()
        // /terminal races ahead — the session doesn't exist yet
        await store.setTerminalRef(sessionID: "s", TerminalRef(termProgram: "ghostty", tmux: "/tmp/x,1,0", tmuxPane: "%4"))
        #expect(await store.snapshot(now: t0).sessions.isEmpty)
        // SessionStart then creates it → the remembered ref is applied
        await store.ingest(Data(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/p"}"#.utf8), receivedAt: t0)
        #expect(await store.snapshot(now: t0).sessions.first?.terminalRef?.tmuxPane == "%4")
    }

    @Test("snapshot delivery is passive; only explicit acknowledgement clears unread")
    func unreadAcknowledgementIsAuthoritative() async {
        let store = SessionStore()
        await store.ingest(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/x/p"}"#.utf8),
                           receivedAt: t0)
        await store.ingest(Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/x/p"}"#.utf8),
                           receivedAt: t0.addingTimeInterval(1))

        #expect(await store.snapshot(now: t0).sessions.first?.hasUnreadCompletion == true)
        #expect(await store.snapshot(now: t0.addingTimeInterval(2)).sessions.first?.hasUnreadCompletion == true)
        #expect(await store.acknowledgeCompletion(sessionID: "s"))
        #expect(await store.snapshot(now: t0.addingTimeInterval(3)).sessions.first?.presentationState == .idle)
    }

    @Test("a probe retirement does not refresh rollout observation evidence")
    func retirementDoesNotRecordRolloutEvidence() async {
        // Wall-clock T0 so source diagnostics stay inside the 10-minute healthy window.
        let observedAt = Date()
        let store = SessionStore()
        await store.ingest(HookEvent(
            kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            cwd: "/x/p", observationSource: .rollout, timestamp: observedAt,
            desktopThreadID: "s"))
        let before = await store.snapshot(now: observedAt)
        #expect(before.sessions.first?.status == .working)
        #expect(before.sessions.first?.observations?.first { $0.source == .rollout }?.lastObservedAt == observedAt)
        #expect(before.observationDiagnostics?.health(agent: .codex, source: .rollout) == .healthy)
        #expect(before.observationDiagnostics?.lastObserved(agent: .codex, source: .rollout) == observedAt)

        let retiredAt = observedAt.addingTimeInterval(30)
        await store.ingest(HookEvent(
            kind: .stop, sessionID: "s", agent: .codex,
            cwd: "/x/p", message: "Abandoned",
            observationSource: .rollout, timestamp: retiredAt,
            desktopThreadID: "s"),
            recordsEvidence: false)

        let after = await store.snapshot(now: retiredAt)
        #expect(after.sessions.first?.status == .done)
        #expect(after.sessions.first?.summary == "Abandoned")
        #expect(after.sessions.first?.desktopThreadID == "s")
        #expect(after.sessions.first?.failed != true)
        #expect(after.sessions.first?.observations?.first { $0.source == .rollout }?.lastObservedAt == observedAt)
        #expect(after.observationDiagnostics?.health(agent: .codex, source: .rollout) == .healthy)
        #expect(after.observationDiagnostics?.lastObserved(agent: .codex, source: .rollout) == observedAt)
    }
}

private extension Array where Element == AgentObservationDiagnostic {
    func health(agent: AgentKind, source: ObservationSource) -> ObservationHealth? {
        first(where: { $0.agent == agent })?.sources
            .first(where: { $0.source == source })?.health
    }

    func lastObserved(agent: AgentKind, source: ObservationSource) -> Date? {
        first(where: { $0.agent == agent })?.sources
            .first(where: { $0.source == source })?.lastObservedAt
    }
}
