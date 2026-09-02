import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Session observation tracking")
struct ObservationTrackingTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("mixed sources keep stable identities and their own last-observed times")
    func mixedSources() {
        var reducer = SessionReducer()
        reducer.apply(HookEvent(kind: .sessionStart, sessionID: "s", agent: .codex,
                                cwd: "/x/p", observationSource: .hook, timestamp: t0))
        reducer.apply(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
                                cwd: "/x/p", observationSource: .rollout,
                                timestamp: t0.addingTimeInterval(2)))

        let observations = reducer.snapshot(now: t0.addingTimeInterval(3)).sessions[0].observations ?? []
        #expect(observations.map(\.source) == [.hook, .rollout])
        #expect(observations.map(\.lastObservedAt) == [t0, t0.addingTimeInterval(2)])
    }

    @Test("a stale source degrades and a new event restores it without changing status")
    func staleThenHealthy() {
        var reducer = SessionReducer()
        reducer.apply(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .claudeCode,
                                cwd: "/x/p", observationSource: .hook, timestamp: t0))

        let stale = reducer.snapshot(now: t0.addingTimeInterval(601), observationStaleAfter: 600)
        #expect(stale.sessions[0].status == .working)
        #expect(stale.sessions[0].observations?.first?.health == .temporarilySilent)

        reducer.apply(HookEvent(kind: .preToolUse, sessionID: "s", agent: .claudeCode,
                                cwd: "/x/p", toolName: "Read", observationSource: .hook,
                                timestamp: t0.addingTimeInterval(602)))
        let restored = reducer.snapshot(now: t0.addingTimeInterval(603), observationStaleAfter: 600)
        #expect(restored.sessions[0].status == .working)
        #expect(restored.sessions[0].observations?.first?.health == .healthy)
    }

    @Test("an undecodable diagnostic signal never changes existing progress")
    func diagnosticFailurePreservesProgress() async {
        let store = SessionStore()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s",
                                     cwd: "/x/p", timestamp: t0))
        let accepted = await store.ingest(Data(#"{"hook_event_name":"FutureEvent"}"#.utf8),
                                          agent: .claudeCode,
                                          receivedAt: t0.addingTimeInterval(1))
        let snapshot = await store.snapshot(now: t0.addingTimeInterval(1))

        #expect(!accepted)
        #expect(snapshot.sessions.first?.status == .working)
        #expect(snapshot.observationDiagnostics?.first(where: { $0.agent == .claudeCode })?
            .sources.first(where: { $0.source == .hook })?.health == .unknownVersion)
    }

    @Test("a fresh signal immediately replaces a cached temporarily-silent row")
    func freshSignalRepairsCachedHealth() async throws {
        let freshAt = Date()
        let staleAt = freshAt.addingTimeInterval(-601)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true)
        try "model = \"gpt\"\n".write(
            to: home.appendingPathComponent(".codex/config.toml"),
            atomically: true, encoding: .utf8)

        let store = SessionStore(diagnosticsHome: home)
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
                                     cwd: "/x/p", timestamp: staleAt))
        let stale = await store.snapshot(now: freshAt)
        #expect(stale.observationDiagnostics?.health(agent: .codex, source: .rollout)
                == .temporarilySilent)

        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
                                     cwd: "/x/p", timestamp: freshAt))
        let recovered = await store.snapshot(now: freshAt.addingTimeInterval(1))
        #expect(recovered.observationDiagnostics?.health(agent: .codex, source: .rollout)
                == .healthy)
    }
}

private extension Array where Element == AgentObservationDiagnostic {
    func health(agent: AgentKind, source: ObservationSource) -> ObservationHealth? {
        first(where: { $0.agent == agent })?.sources
            .first(where: { $0.source == source })?.health
    }
}
