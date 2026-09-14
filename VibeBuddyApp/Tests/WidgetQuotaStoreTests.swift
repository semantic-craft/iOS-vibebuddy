import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

final class WidgetQuotaStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var reloads = 0

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.\(UUID())")
        reloads = 0
    }

    private func snapshot(remaining: Int = 41, live: Bool = true, savedAt: Date = Date()) -> PhoneQuotaSnapshot {
        PhoneQuotaSnapshot(
            quotas: [ProviderQuota(provider: .claude, weeklyRemainingPercent: remaining,
                                   weeklyWindowDurationMinutes: 10080,
                                   observedAt: Date(timeIntervalSince1970: 1_800_000_000))],
            macName: "Studio Mac", relayLive: live, savedAt: savedAt, isDemo: false)
    }

    func testRoundTripAndClear() {
        let saved = snapshot()
        XCTAssertTrue(WidgetQuotaStore.save(saved, to: defaults) { reloads += 1 })
        XCTAssertEqual(WidgetQuotaStore.load(from: defaults), saved)
        XCTAssertTrue(WidgetQuotaStore.clear(in: defaults) { reloads += 1 })
        XCTAssertNil(WidgetQuotaStore.load(from: defaults))
        XCTAssertFalse(WidgetQuotaStore.clear(in: defaults) { reloads += 1 })
        XCTAssertEqual(reloads, 2)
    }

    func testSameReadingIsNotWrittenAgain() {
        let first = snapshot(savedAt: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(WidgetQuotaStore.save(first, to: defaults) { reloads += 1 })
        // A later snapshot with the same numbers: no write, no widget reload.
        XCTAssertFalse(WidgetQuotaStore.save(snapshot(savedAt: Date(timeIntervalSince1970: 2)), to: defaults) { reloads += 1 })
        XCTAssertEqual(WidgetQuotaStore.load(from: defaults)?.savedAt, first.savedAt)
        XCTAssertTrue(WidgetQuotaStore.save(snapshot(remaining: 40), to: defaults) { reloads += 1 })
        XCTAssertEqual(reloads, 2)
    }

    func testRelayDropKeepsTheNumbers() {
        WidgetQuotaStore.save(snapshot(), to: defaults) { reloads += 1 }
        XCTAssertTrue(WidgetQuotaStore.markRelayOffline(in: defaults) { reloads += 1 })
        XCTAssertFalse(WidgetQuotaStore.markRelayOffline(in: defaults) { reloads += 1 })
        let stored = WidgetQuotaStore.load(from: defaults)
        XCTAssertEqual(stored?.relayLive, false)
        XCTAssertEqual(stored?.quotas.first?.weeklyRemainingPercent, 41)
        XCTAssertEqual(reloads, 2)
    }
}
