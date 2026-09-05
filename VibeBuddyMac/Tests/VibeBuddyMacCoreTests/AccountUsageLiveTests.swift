import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

private final class CountingProvider: AccountUsageProviding, @unchecked Sendable {
    let lock = NSLock()
    var fetches = 0
    func fetch() async throws -> AccountUsageSnapshot {
        lock.withLock { fetches += 1 }
        return AccountUsageSnapshot(provider: .codex, planType: "pro",
                                    primary: AccountUsageWindow(kind: .primary, usedPercent: 50, windowDurationMinutes: 300, resetsAt: nil),
                                    secondary: AccountUsageWindow(kind: .secondary, usedPercent: 10, windowDurationMinutes: 10080, resetsAt: nil),
                                    lifetimeTokens: nil, latestDailyTokens: nil, fetchedAt: Date())
    }
}

private actor MemoryCache: AccountUsageCaching {
    var saved: AccountUsageSnapshot?
    func load() -> AccountUsageSnapshot? { saved }
    func save(_ snapshot: AccountUsageSnapshot, permit: AccountUsageCacheCommitPermit) throws {
        _ = permit.commit { saved = snapshot }
    }
}

@Suite("Live account usage")
struct AccountUsageLiveTests {
    let now = Date(timeIntervalSince1970: 1_788_600_000)

    private func live(usedPercent: Int) -> AccountUsageSnapshot {
        AccountUsageSnapshot(provider: .codex, planType: "pro",
                             primary: AccountUsageWindow(kind: .primary, usedPercent: usedPercent, windowDurationMinutes: 300, resetsAt: nil),
                             secondary: AccountUsageWindow(kind: .secondary, usedPercent: 11, windowDurationMinutes: 10080, resetsAt: nil),
                             lifetimeTokens: nil, latestDailyTokens: nil, fetchedAt: now)
    }

    @Test("a live sample becomes the state, is cached, and holds the spawning fetch off until it ages")
    func acceptLiveHoldsFetch() async {
        let provider = CountingProvider()
        let cache = MemoryCache()
        let collector = AccountUsageCollector(provider: provider, cache: cache, enabled: true)
        let state = await collector.acceptLive(live(usedPercent: 33), holdFor: 20 * 60, now: now)
        #expect(state.snapshot?.primary?.usedPercent == 33)
        #expect(state.isStale == false)
        #expect(state.nextRefreshAt == now.addingTimeInterval(20 * 60))
        #expect(await cache.saved?.primary?.usedPercent == 33)

        _ = await collector.refresh(now: now.addingTimeInterval(60))
        #expect(provider.fetches == 0)
        let later = await collector.refresh(now: now.addingTimeInterval(21 * 60))
        #expect(provider.fetches == 1)
        #expect(later.snapshot?.primary?.usedPercent == 50)
    }

    @Test("a disabled collector ignores live samples")
    func disabledIgnoresLive() async {
        let collector = AccountUsageCollector(provider: CountingProvider(), cache: MemoryCache(), enabled: false)
        let state = await collector.acceptLive(live(usedPercent: 33), holdFor: 60, now: now)
        #expect(state == .disabled)
    }

    @Test("the feed remembers the latest sample per provider and streams to subscribers")
    func feed() async {
        let feed = AccountUsageLiveFeed()
        let subscription = await feed.subscribe()
        await feed.publish(live(usedPercent: 5))
        await feed.publish(live(usedPercent: 6))
        #expect(await feed.latest(for: .codex)?.primary?.usedPercent == 6)
        #expect(await feed.latest(for: .claude) == nil)
        var seen: [Int] = []
        for await snapshot in subscription.stream {
            seen.append(snapshot.primary?.usedPercent ?? -1)
            if seen.count == 2 { break }
        }
        #expect(seen == [5, 6])
        await feed.unsubscribe(subscription.id)
    }
}

/// A scripted daemon connection: canned results per method, notifications
/// pushed by the test.
private final class FakeConnection: CodexAppServerConnecting, @unchecked Sendable {
    let messages: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var results: [String: [String: Any]]
    private(set) var calls: [String] = []
    init(results: [String: [String: Any]]) {
        self.results = results
        var sink: AsyncStream<Data>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { sink = $0 }
        self.sink = sink
    }
    func connect() throws {}
    func request(_ method: String, params: [String: Any], timeout: Duration) async throws -> [String: Any] {
        lock.withLock { calls.append(method) }
        if let result = lock.withLock({ results[method] }) { return result }
        throw CodexAppServerClient.ClientError.rpc(code: -32601, message: "no such method \(method)")
    }
    func notify(_ method: String, params: [String: Any]?) {}
    func push(_ notification: [String: Any]) {
        sink.yield(try! JSONSerialization.data(withJSONObject: notification))
    }
    func close() { sink.finish() }
    func set(_ method: String, _ result: [String: Any]) { lock.withLock { results[method] = result } }
}

@Suite("Codex app-server live usage")
struct CodexAppServerLiveUsageTests {
    private let rateLimits: [String: Any] = [
        "rateLimits": ["limitId": "codex", "planType": "pro",
                       "primary": ["usedPercent": 11, "windowDurationMins": 10080, "resetsAt": 1_789_207_457],
                       "secondary": NSNull()],
        "rateLimitsByLimitId": ["codex": ["limitId": "codex", "planType": "pro",
                                          "primary": ["usedPercent": 11, "windowDurationMins": 10080, "resetsAt": 1_789_207_457]]],
    ]

    private func waitFor(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test("connecting publishes the daemon's rate limits, and a sparse update re-publishes them merged")
    func liveRateLimits() async throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("vb-sock-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socket) }
        let connection = FakeConnection(results: [
            "initialize": ["userAgent": "Codex Desktop/0.145.0 (test)"],
            "thread/list": ["data": [], "nextCursor": NSNull()],
            "account/rateLimits/read": rateLimits,
            "account/usage/read": ["summary": ["lifetimeTokens": 4242]],
        ])
        let feed = AccountUsageLiveFeed()
        let monitor = CodexAppServerMonitor(enabled: true, socketPath: socket.path, usageFeed: feed,
                                            makeClient: { _ in connection })
        let store = SessionStore()
        let run = Task { await monitor.run(store: store) }
        defer { run.cancel() }

        #expect(await waitFor { await feed.latest(for: .codex) != nil })
        let first = try #require(await feed.latest(for: .codex))
        #expect(first.planType == "pro")
        #expect(first.primary?.usedPercent == 11)
        #expect(first.primary?.windowDurationMinutes == 10080)
        #expect(first.lifetimeTokens == 4242)
        #expect(ProviderQuota(.available(first, nextRefreshAt: nil), provider: .codex).weeklyRemainingPercent == 89)
        #expect(connection.calls.contains("account/rateLimits/read"))

        connection.push(["method": "account/rateLimits/updated",
                         "params": ["rateLimits": ["limitId": "codex",
                                                   "primary": ["usedPercent": 37, "windowDurationMins": 10080, "resetsAt": 1_789_207_457]]]])
        #expect(await waitFor { await feed.latest(for: .codex)?.primary?.usedPercent == 37 })
        let merged = try #require(await feed.latest(for: .codex))
        #expect(merged.planType == "pro")          // kept from the full read
        #expect(merged.lifetimeTokens == 4242)     // kept from the usage read
        #expect(await monitor.diagnostics().connected)
    }
}
