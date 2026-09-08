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

    @Test("a transcript-inferred question still reconciles from later transcript activity")
    func sweepReconcilesInferredQuestion() async throws {
        let tmp = NSTemporaryDirectory() + "vb-inferred-wait-\(UUID().uuidString).jsonl"
        try "{}".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = SessionStore(staleAfter: 86_400)
        let question = PendingQuestion(id: "inferred", prompt: "Which color?", options: [])
        await store.ingest(HookEvent(kind: .notification, sessionID: "s", agent: .codex,
                                    cwd: "/x/proj", message: "Waiting for your input", transcriptPath: tmp,
                                    timestamp: t0, enrichment: TranscriptInfo(pendingQuestion: question)))
        #expect(await store.snapshot(now: t0).sessions.first?.pendingQuestion?.id == "inferred")
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(2)], ofItemAtPath: tmp)
        await store.sweep(now: t0.addingTimeInterval(10))
        #expect(await store.snapshot(now: t0.addingTimeInterval(10)).sessions.isEmpty)
    }

    @Test("transcript writes do not resolve an explicit unanswered question or approval", arguments: [false, true])
    func sweepPreservesExplicitWait(approval: Bool) async throws {
        let tmp = NSTemporaryDirectory() + "vb-live-wait-\(UUID().uuidString).jsonl"
        try "{}".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = SessionStore(staleAfter: 86_400)
        let payload = #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/proj","transcript_path":"\#(tmp)"}"#
        await store.ingest(Data(payload.utf8), receivedAt: t0)
        if approval {
            await store.beginApproval(sessionID: "s", PendingApproval(id: "ap", tool: "Bash", commandPreview: "echo test"), at: t0.addingTimeInterval(1))
        } else {
            await store.beginQuestion(sessionID: "s", PendingQuestion(id: "q", prompt: "Which color?", options: []), at: t0.addingTimeInterval(1))
        }
        await store.ingest(HookEvent(kind: .sessionMetadataChanged, sessionID: "s", timestamp: t0.addingTimeInterval(1.25),
                                    enrichment: TranscriptInfo(pendingQuestion: PendingQuestion(id: "inferred", prompt: "Old log question", options: []))))
        // A late completion from the other request type cannot settle this wait.
        if approval { await store.endQuestion(sessionID: "s", questionID: "q", at: t0.addingTimeInterval(1.5)) }
        else { await store.endApproval(sessionID: "s", approvalID: "ap", at: t0.addingTimeInterval(1.5)) }
        // Nor can a superseded request of the same type settle it.
        if approval { await store.endApproval(sessionID: "s", approvalID: "old-ap", at: t0.addingTimeInterval(1.75)) }
        else { await store.endQuestion(sessionID: "s", questionID: "old-q", at: t0.addingTimeInterval(1.75)) }
        // A held, answerable card outlives a stray tool-progress notification.
        await store.ingest(HookEvent(kind: .postToolUse, sessionID: "s", timestamp: t0.addingTimeInterval(1.8)))
        await store.ingest(HookEvent(kind: .notification, sessionID: "s", message: "Waiting for your input", timestamp: t0.addingTimeInterval(1.9)))
        // App-server flushes the question itself after publishing the wait.
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(2)], ofItemAtPath: tmp)
        await store.sweep(now: t0.addingTimeInterval(10))
        let waiting = await store.snapshot(now: t0.addingTimeInterval(10)).sessions.first
        #expect(waiting?.status == .needsResponse)
        #expect(approval ? waiting?.pendingApproval?.id == "ap" : waiting?.pendingQuestion?.id == "q")
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(302)).count == 1)
        if approval { await store.endApproval(sessionID: "s", approvalID: "ap", at: t0.addingTimeInterval(303)) }
        else { await store.endQuestion(sessionID: "s", questionID: "q", at: t0.addingTimeInterval(303)) }
        #expect(await store.snapshot(now: t0.addingTimeInterval(303)).sessions.first?.status == .working)
        // Once the explicit wait ends, a later inferred wait regains mtime recovery.
        await store.ingest(HookEvent(kind: .notification, sessionID: "s", message: "Waiting for your input", timestamp: t0.addingTimeInterval(303.1),
                                    enrichment: TranscriptInfo(pendingQuestion: PendingQuestion(id: "later-log", prompt: "Later question", options: []))))
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(303.2)], ofItemAtPath: tmp)
        await store.sweep(now: t0.addingTimeInterval(304))
        #expect(await store.snapshot(now: t0.addingTimeInterval(304)).sessions.isEmpty)
        // Explicit provenance does not disable the bounded abandonment cleanup.
        await store.ingest(Data(payload.utf8), receivedAt: t0.addingTimeInterval(304))
        await store.beginQuestion(sessionID: "s", PendingQuestion(id: "stale", prompt: "Still waiting?", options: []), at: t0.addingTimeInterval(305))
        await store.sweep(now: t0.addingTimeInterval(86_800))
        #expect(await store.snapshot(now: t0.addingTimeInterval(86_800)).sessions.isEmpty)
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

        await store.endApproval(sessionID: "s", approvalID: "ap1", at: t0.addingTimeInterval(2))
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
    func unreadAcknowledgementIsAuthoritative() async throws {
        let store = SessionStore()
        await store.ingest(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/x/p"}"#.utf8),
                           receivedAt: t0)
        await store.ingest(Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/x/p"}"#.utf8),
                           receivedAt: t0.addingTimeInterval(1))

        #expect(await store.snapshot(now: t0).sessions.first?.hasUnreadCompletion == true)
        #expect(await store.snapshot(now: t0.addingTimeInterval(2)).sessions.first?.hasUnreadCompletion == true)
        let request = try await completionReadRequest(store, sessionID: "s")
        #expect(await store.acknowledgeCompletion(request).outcome == .accepted)
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
            desktopThreadID: "s", probeRetirement: true),
            recordsEvidence: false)

        let after = await store.snapshot(now: retiredAt)
        #expect(after.sessions.first?.status == .done)
        #expect(after.sessions.first?.summary == "Abandoned")
        #expect(after.sessions.first?.desktopThreadID == "s")
        #expect(after.sessions.first?.failed != true)
        #expect(after.sessions.first?.hasUnreadCompletion == false)
        #expect(after.sessions.first?.observations?.first { $0.source == .rollout }?.lastObservedAt == observedAt)
        #expect(after.observationDiagnostics?.health(agent: .codex, source: .rollout) == .healthy)
        #expect(after.observationDiagnostics?.lastObserved(agent: .codex, source: .rollout) == observedAt)
    }

    @Test("Every supported provider reaches the runtime snapshot")
    func includesCursorInWireSnapshot() async {
        let store = SessionStore(sourceID: "test")
        await store.setProviderQuota([
            ProviderQuota(provider: .codex, weeklyRemainingPercent: 70),
            ProviderQuota(provider: .claude, weeklyRemainingPercent: 40),
            ProviderQuota(provider: .grok, weeklyRemainingPercent: 55),
            ProviderQuota(provider: .cursor, weeklyRemainingPercent: 60),
            ProviderQuota(provider: .grokBot, weeklyRemainingPercent: 65),
        ])
        let snap = await store.snapshot(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snap.providerQuota?.map(\.provider) == AccountUsageProvider.allCases)
        #expect(snap.providerQuota?.contains { $0.provider == .cursor } == true)
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
