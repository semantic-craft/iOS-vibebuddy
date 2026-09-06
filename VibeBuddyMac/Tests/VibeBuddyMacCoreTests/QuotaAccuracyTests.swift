import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Quota accuracy regressions")
struct QuotaAccuracyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Other buckets and nonweekly durations cannot become Codex weekly allowance")
    func bucketAndDuration() throws {
        let usage = Data(#"{"result":{"summary":{}}}"#.utf8)
        let other = Data(#"{"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":10080}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":9,"windowDurationMins":10080}}}}}"#.utf8)
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try CodexUsageResponseDecoder.decode(rateLimitsResponse: other, usageResponse: usage, fetchedAt: now)
        }
        let input = Data(#"{"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12.5,"windowDurationMins":2880},"secondary":{"usedPercent":20}}}}}"#.utf8)
        let sample = try CodexUsageResponseDecoder.decode(rateLimitsResponse: input, usageResponse: usage, fetchedAt: now)
        let quota = ProviderQuota(.available(sample, nextRefreshAt: nil), provider: .codex)
        #expect(quota.weeklyRemainingPercent == nil)
        #expect(quota.shortWindowRemainingPercent == nil)
        #expect(quota.otherWindows?.map(\.durationMinutes) == [2880, nil])
    }

    @Test("A missing or malformed Codex window cannot discard the other window",
          arguments: [#"{"usedPercent":null}"#, #"{}"#, #""invalid window""#])
    func independentWindowDecoding(primary: String) throws {
        let input = Data("{\"result\":{\"rateLimits\":{\"primary\":\(primary),\"secondary\":{\"usedPercent\":25,\"windowDurationMins\":10080,\"resetsAt\":\"invalid\"}}}}".utf8)
        let usage = Data(#"{"result":{"summary":{}}}"#.utf8)
        let sample = try CodexUsageResponseDecoder.decode(rateLimitsResponse: input, usageResponse: usage, fetchedAt: now)
        let quota = ProviderQuota(.available(sample, nextRefreshAt: nil), provider: .codex)
        #expect(quota.shortWindowRemainingPercent == nil)
        #expect(quota.weeklyRemainingPercent == 75)
        #expect(quota.weeklyResetsAt == nil)
    }

    @Test("Claude percentage survives missing reset, and dates only roll across a plausible year boundary")
    func resetDates() throws {
        let formatter = ISO8601DateFormatter()
        func read(_ date: String, at timestamp: String) throws -> AccountUsageSnapshot {
            let data = try JSONSerialization.data(withJSONObject: ["is_error": false,
                "result": "Current session: 20% used · resets \(date) (UTC)\nCurrent week (all models): 30% used"])
            return try ClaudeUsageResponseDecoder.decode(data, fetchedAt: try #require(formatter.date(from: timestamp)))
        }
        let across = try read("Jan 1 at 1am", at: "2026-12-31T23:00:00Z")
        #expect(across.primary?.resetsAt == formatter.date(from: "2027-01-01T01:00:00Z"))
        let past = try read("Dec 31 at 11pm", at: "2027-01-01T01:00:00Z")
        #expect(past.primary?.resetsAt == formatter.date(from: "2026-12-31T23:00:00Z"))
        let distant = try read("Sep 1 at 1am", at: "2026-09-20T01:00:00Z")
        #expect(distant.primary?.usedPercent == 20)
        #expect(distant.primary?.resetsAt == nil)
        #expect(distant.secondary?.usedPercent == 30)
        #expect(distant.secondary?.resetsAt == nil)
    }

    @Test("A relayed window ages from source time and becomes unknown at reset, independently")
    func sourceTimeAndReset() throws {
        let quota = ProviderQuota(provider: .codex, weeklyRemainingPercent: 0,
                                  weeklyResetsAt: now.addingTimeInterval(1000), weeklyWindowDurationMinutes: 10080,
                                  shortWindowRemainingPercent: 45, shortWindowResetsAt: now.addingTimeInterval(60),
                                  shortWindowDurationMinutes: 300, observedAt: now)
        let restored = try JSONDecoder().decode(ProviderQuota.self, from: JSONEncoder().encode(quota))
        #expect(restored.window(.weekly).currentRemainingPercent(now: now) == 0)
        #expect(restored.window(.short).status(now: now.addingTimeInterval(60)) == .awaitingReset)
        #expect(restored.window(.short).currentRemainingPercent(now: now.addingTimeInterval(60)) == nil)
        #expect(restored.window(.weekly).status(now: now.addingTimeInterval(900)) == .stale)
        #expect(restored.observedAt == now)
    }

    @Test("Unlabelled notifications need an established Codex main allowance", arguments: [false, true])
    func unlabelledNeedsIdentity(otherMain: Bool) async throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("quota-context-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socket) }
        let limits: [String: Any] = otherMain
            ? ["rateLimits": ["limitId": "other", "primary": ["usedPercent": 99, "windowDurationMins": 10080]]]
            : [:]
        let connection = FakeConnection(results: ["initialize": [:], "thread/list": ["data": []],
            "account/rateLimits/read": limits, "account/usage/read": ["summary": [:]]])
        let feed = AccountUsageLiveFeed()
        let subscription = await feed.subscribe()
        let monitor = CodexAppServerMonitor(enabled: true, socketPath: socket.path, usageFeed: feed,
                                            makeClient: { _ in connection })
        let run = Task { await monitor.run(store: SessionStore()) }
        defer { run.cancel() }
        #expect(await waitFor { await monitor.diagnostics().connected })
        connection.push(["method": "account/rateLimits/updated", "params": ["rateLimits": [
            "primary": ["usedPercent": 99, "windowDurationMins": 300]]]])
        connection.push(["method": "account/rateLimits/updated", "params": ["rateLimits": [
            "limitId": "codex", "primary": ["usedPercent": 15, "windowDurationMins": 300]]]])
        #expect(await waitFor { await feed.latest(for: .codex)?.primary?.usedPercent == 15 })
        var iterator = subscription.stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.primary?.usedPercent == 15)
        await feed.unsubscribe(subscription.id)
    }

}
