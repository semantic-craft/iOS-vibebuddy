import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Exercises the production reducer/result/notice/policy/claim pipeline. Only the
/// model subprocess and OS notification sink are replaced with deterministic doubles.
@Suite(.timeLimit(.minutes(1)))
struct GeminiCompletionDeliveryTests {
    enum Ending: String, CaseIterable, Sendable { case success, newTurn, expired }
    actor ModelGate {
        var calls = 0
        var continuation: CheckedContinuation<Void, Never>?
        func response() async -> AntigravityTextRunner.Output {
            calls += 1
            await withCheckedContinuation { continuation = $0 }
            return .init(data: Data(#"{"status":"SUCCESS","num_turns":1,"response":"Build passed; device verification remains pending.","usage":{"total_tokens":31}}"#.utf8), status: 0)
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value: Date
        init(_ date: Date) { value = date }
        var now: Date { lock.withLock { value } }
        func advance() { lock.withLock { value += 13 } }
    }
    final class Sink: AttentionNotifier, @unchecked Sendable {
        let lock = NSLock()
        var values: [SoundAlert] = []
        var alerts: [SoundAlert] { lock.withLock { values } }
        func notify(_ alert: SoundAlert) async -> LocalNotificationAttempt {
            lock.withLock { values.append(alert) }
            return .scheduled()
        }
        func withdraw(_ identifiers: [String]) async {}
    }
    func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await condition())
    }

    @Test(arguments: Ending.allCases)
    func geminiCompletionReachesOneClaimAndRejectsStaleWording(_ ending: Ending) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "gemini-delivery-\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let t = Date(), clock = Clock(Date())
        let source = UUID().uuidString
        let journal = dir.appendingPathComponent("lifecycle.json")
        let attention = dir.appendingPathComponent("attention.json")
        let notices = dir.appendingPathComponent("notices.json")
        let store = SessionStore(sourceID: source, journalURL: journal, attentionURL: attention, resultClock: { clock.now })
        let config = CompletionSummaryConfiguration(enabled: true, provider: .gemini, modelID: "gemini-3.8-flash")
        #expect(config.usesGeminiCLI)
        await store.configureContentPresentation(service: ContentPresentationService(), configuration: { config })
        let gate = ModelGate()
        let service = CompletionSummaryService(key: { _ in Issue.record("Local route must never load API key"); return nil })
        await service.setCLIRunnerForTesting { _, args, _, env, _ in
            #expect(args.contains("gemini-3.8-flash-low"))
            #expect(Set(env.keys) == ["HOME", "PATH"])
            return await gate.response()
        }
        // Same result extraction and service invocation used by the app's
        // generateCompletionNotice, after its OS eligibility gates.
        await store.configureCompletionNotices(url: notices, enabled: { true }) { session in
            guard let id = session.completionID,
                  case .ready(let result) = await store.completionResult(sessionID: session.id, completionID: id) else {
                Issue.record("Native completion result must be frozen before generation"); return nil
            }
            let input = CompletionSummaryInput(sourceID: result.sourceID, sessionID: result.sessionID,
                completionID: result.completionID, turnID: result.turnID, title: session.displayTitle,
                finalText: result.finalText, completedAt: result.completedAt, observedAt: result.observedAt)
            return await service.generate(input, configuration: config).text
        }
        let sink = Sink()
        let attempts = CompletionNoticeAttempts(defaults: UserDefaults(suiteName: suite)!)
        let coordinator = NotificationCoordinator(notifier: sink, completionAttempts: attempts)
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            timestamp: t.addingTimeInterval(-60), turnID: "a"))
        _ = await store.setAttention(sessionID: "s", .followed)
        let working = await store.snapshot(now: t)
        await coordinator.observe(working.sessions, now: t, appActive: false, quietMode: false)
        let stop = HookEvent(kind: .stop, sessionID: "s", agent: .codex, timestamp: t,
            turnID: "a", completionText: "Native final record. Build passed; device verification remains pending.", completionSucceeded: true)
        await store.ingest(stop)
        let pending = await store.snapshot(now: t)
        let notice = try #require(pending.sessions.first?.completionNotice)
        #expect(notice.state == .pending)
        await coordinator.observe(pending.sessions, now: t, appActive: false, quietMode: false)
        #expect(sink.alerts.isEmpty)
        try await eventually { await gate.calls == 1 }
        await store.ingest(stop) // corroborating duplicate must not create another model job
        _ = await store.snapshot(now: t)
        #expect(await gate.calls == 1)
        if ending == .newTurn {
            await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
                timestamp: t.addingTimeInterval(1), turnID: "b"))
            _ = await store.snapshot(now: t.addingTimeInterval(1))
        } else if ending == .expired { clock.advance() }
        await gate.release()
        await service.waitUntilIdle()
        try await eventually {
            if ending == .newTurn { return CompletionNoticeLedger(url: notices).notices[notice.id]?.state == .cancelled }
            return await store.snapshot(now: clock.now).sessions.first?.completionNotice?.state != .pending
        }
        let resolved = await store.snapshot(now: clock.now)
        let earned = await coordinator.observe(resolved.sessions, now: clock.now, appActive: false, quietMode: false)
        await coordinator.observe(resolved.sessions, now: clock.now, appActive: false, quietMode: false)
        if ending == .newTurn {
            #expect(sink.alerts.isEmpty)
            #expect(resolved.sessions.first?.status == .working)
        } else {
            #expect(resolved.sessions.first?.completionNotice?.state == (ending == .success ? .summary : .plain))
            #expect(earned.count == 1)
            #expect(sink.alerts.count == 1)
            let actual = try #require(sink.alerts.first?.session.completionNotice)
            #expect(actual.state == (ending == .success ? .summary : .plain))
            #expect(actual.text == (ending == .success ? "Build passed; device verification remains pending." : nil))
            // A second coordinator earning the same cue still cannot claim it again.
            let replay = NotificationCoordinator(notifier: sink, completionAttempts: CompletionNoticeAttempts(defaults: UserDefaults(suiteName: suite)!))
            await replay.observe(working.sessions, now: t, appActive: false, quietMode: false)
            await replay.observe(resolved.sessions, now: clock.now, appActive: false, quietMode: false)
            #expect(sink.alerts.count == 1)
        }
        let restored = SessionStore(sourceID: source, journalURL: journal, attentionURL: attention, resultClock: { clock.now })
        await restored.configureContentPresentation(service: ContentPresentationService(), configuration: { config })
        await restored.configureCompletionNotices(url: notices, enabled: { true }) { _ in
            Issue.record("Restart must not regenerate historical completion"); return nil
        }
        let recovered = await restored.snapshot(now: clock.now)
        let restartSink = Sink()
        let restart = NotificationCoordinator(notifier: restartSink, completionAttempts: CompletionNoticeAttempts(defaults: UserDefaults(suiteName: suite)!))
        await restart.observe(recovered.sessions, now: clock.now, appActive: false, quietMode: false)
        await restart.observe(recovered.sessions, now: clock.now, appActive: false, quietMode: false)
        #expect(restartSink.alerts.isEmpty)
        #expect(await gate.calls == 1)
    }
}
