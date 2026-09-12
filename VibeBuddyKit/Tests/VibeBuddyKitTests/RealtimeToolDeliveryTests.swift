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
        // `delivered == false` is itself the proof that the timeout ended the
        // wait: the only source of `true` is the completion below, which does not
        // run for another 0.1s. No elapsed-time budget for machine load to blow.
        let late = DispatchSemaphore(value: 0)
        let delivered = await RealtimeToolDelivery.wait(timeout: 0.02, start: { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                done(true)
                late.signal()
            }
        })
        #expect(!delivered)
        // The late completion has to land while the test is still alive, or
        // "ignores late completion" is never exercised at all — resuming the
        // finished continuation a second time would trap.
        #expect(await Self.waitForSignal(late), "the late completion should have run")
    }

    @Test func socketFailureDoesNotReportDeliverySuccess() async {
        let delivered = await RealtimeToolDelivery.wait(start: { done in done(false) })
        #expect(!delivered)
    }

    /// Bounded so a completion that never runs fails the test instead of hanging
    /// it; on a healthy run it returns the moment the signal lands.
    private static func waitForSignal(_ semaphore: DispatchSemaphore,
                                      timeout: DispatchTimeInterval = .seconds(30)) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }
}
