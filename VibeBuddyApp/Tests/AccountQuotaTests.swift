import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
final class AccountQuotaTests: XCTestCase {
    func testPhonePreservesPoolsAndCachedResetSemantics() {
        let now = Date()
        let monthly = QuotaWindow(remainingPercent: 72, durationMinutes: 43200,
                                  resetsAt: now.addingTimeInterval(600), observedAt: now,
                                  label: "Plan allowance")
        let expired = QuotaWindow(remainingPercent: 91, durationMinutes: 43200,
                                  resetsAt: now.addingTimeInterval(-1), observedAt: now,
                                  label: "On-demand")
        let quota = ProviderQuota(provider: .cursor, otherWindows: [monthly, expired], isCached: true)
        let windows = UsageRows.windows(quota)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(UsageRows.title(windows[0]), "Plan allowance · 30-day window")
        XCTAssertEqual(UsageRows.shortTitle(windows[0]), "Plan allowance · 30-day")
        XCTAssertEqual(windows[0].currentRemainingPercent(now: now), 72)
        XCTAssertEqual(windows[0].status(now: now), .stale)
        XCTAssertNil(windows[1].currentRemainingPercent(now: now))
        XCTAssertEqual(windows[1].status(now: now), .awaitingReset)
        XCTAssertEqual(UsageRows.paceCaption(windows[1], now: now).0, "Reset reached · awaiting update")
        XCTAssertTrue(UsageRows.windows(.unavailable(.cursor, reason: "Collection disabled")).isEmpty)
    }

    /// The Demo reading the acceptance list names: Grok Build's week is the
    /// tightest, and a nearly-empty scoped week never takes the headline.
    func testTightestSkipsScopedWindows() {
        let now = Date()
        var quotas = DashboardStore.demoQuotas(now: now)
        guard let (quota, window) = UsageRows.tightest(quotas, now: now) else { return XCTFail("no tightest") }
        XCTAssertEqual(quota.provider, .grok)
        XCTAssertEqual(UsageRows.shortTitle(window), "7-day")
        XCTAssertEqual(window.currentRemainingPercent(now: now), 23)

        quotas = quotas.map { quota in
            var quota = quota
            if quota.provider == .claude {
                quota.scopedWindows = [QuotaWindow(remainingPercent: 2, durationMinutes: 10080,
                                                   resetsAt: now.addingTimeInterval(86_400), observedAt: now, label: "Opus only")]
            }
            return quota
        }
        XCTAssertEqual(UsageRows.tightest(quotas, now: now)?.0.provider, .grok)
        XCTAssertNil(UsageRows.tightest([.unavailable(.codex, reason: "signed out")], now: now))
    }

    func testSwitchingMacClearsPublishedQuotaBeforeNewSnapshot() async throws {
        let quota = ProviderQuota(provider: .codex, weeklyRemainingPercent: 63, observedAt: Date())
        let store = DashboardStore(streamer: QuotaStreamer(quota: quota), notifier: SilentNotifier(),
                                   decisionClient: NullDecisionClient(), watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "mac-a", port: 9, token: "test"))
        for _ in 0..<100 where store.lastProviderQuota.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.lastProviderQuota, [quota])
        XCTAssertNotNil(store.lastTokenConsumption)
        store.start(PairingPayload(host: "mac-b", port: 9, token: "test"))
        XCTAssertTrue(store.lastProviderQuota.isEmpty)
        XCTAssertNil(store.lastTokenConsumption)
        store.forgetPairing()
        XCTAssertTrue(store.lastProviderQuota.isEmpty)
        XCTAssertNil(store.lastTokenConsumption)
    }
}

private struct QuotaStreamer: SnapshotStreaming {
    let quota: ProviderQuota
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> {
        AsyncThrowingStream { continuation in
            if pairing.host == "mac-a" {
                continuation.yield(Snapshot(sessions: [], serverTime: Date(), sourceID: "mac-a", providerQuota: [quota], tokenConsumption: TokenConsumptionSnapshot.demo()))
            }
            continuation.finish()
        }
    }
}
