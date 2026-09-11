import Foundation
import Testing
@testable import VibeBuddyKit

struct RealtimeToolDeliveryTests {
    @Test func deliveryWaitsForSocketCompletionBeforeClose() async {
        let start = ContinuousClock.now
        let delivered = await RealtimeToolDelivery.wait(timeout: 1, start: { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done(true) }
        })
        #expect(delivered)
        #expect(start.duration(to: .now) >= .milliseconds(40))
    }

    @Test func timeoutDoesNotWaitForMissingCallbackAndIgnoresLateCompletion() async {
        let start = ContinuousClock.now
        let delivered = await RealtimeToolDelivery.wait(timeout: 0.02, start: { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { done(true) }
        })
        #expect(!delivered)
        #expect(start.duration(to: .now) < .seconds(1))
        try? await Task.sleep(for: .milliseconds(120))
    }

    @Test func socketFailureDoesNotReportDeliverySuccess() async {
        let delivered = await RealtimeToolDelivery.wait(start: { done in done(false) })
        #expect(!delivered)
    }
}
