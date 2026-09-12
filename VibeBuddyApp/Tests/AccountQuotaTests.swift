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
        let windows = AccountQuotaView.windows(quota)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(AccountQuotaView.title(windows[0]), "Plan allowance · 30-day window")
        XCTAssertEqual(windows[0].currentRemainingPercent(now: now), 72)
        XCTAssertEqual(windows[0].status(now: now), .stale)
        XCTAssertNil(windows[1].currentRemainingPercent(now: now))
        XCTAssertEqual(windows[1].status(now: now), .awaitingReset)
        XCTAssertTrue(AccountQuotaView.windows(.unavailable(.cursor, reason: "Collection disabled")).isEmpty)
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
