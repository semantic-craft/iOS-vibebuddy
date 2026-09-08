import Foundation
import VibeBuddyKit
import VibeBuddyMacCore

/// Deliberately hold the actual service's internal worker before any HTTP call.
final class BlockingLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private let gate = DispatchSemaphore(value: 0)
    var started: Bool { lock.withLock { entered } }
    func lookup() -> String? {
        lock.withLock { entered = true }
        gate.wait()
        return nil // Missing synthetic key guarantees no network call.
    }
    func release() { gate.signal() }
}
actor Marker {
    var returned = false
    func mark() { returned = true }
}
@main
struct ServiceQA {
    @MainActor static func check(_ value: Bool, _ message: String) {
        guard value else { print("FAIL: \(message)"); exit(1) }
        print("PASS: \(message)")
    }
    @MainActor static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { print("FAIL: wait deadline"); exit(1) }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    @MainActor static func main() async {
        let lookup = BlockingLookup(), marker = Marker()
        let service = CompletionSummaryService(key: { _ in lookup.lookup() })
        await service.waitUntilIdle()
        check(true, "Already idle service returns immediately")
        let tests = SettingsTestCoordinator()
        let now = Date()
        let input = CompletionSummaryInput(sourceID: "qa", sessionID: "qa", completionID: UUID().uuidString,
            title: "Synthetic test", finalText: "Device verification is pending.", completedAt: now, observedAt: now)
        let config = CompletionSummaryConfiguration(enabled: true, provider: .qwen, modelID: "qwen-test")
        tests.start(.summary, timeout: .seconds(10), operation: {
            _ = await service.generate(input, configuration: config)
            await marker.mark()
            await service.waitUntilIdle()
            return .success(.init(message: "late result"))
        })
        await until { lookup.started }
        tests.cancel()
        await until { await marker.returned }
        check(tests.isBusy, "Generate cancellation returns while internal worker still retains Settings slot")
        check(!tests.start(.summary, timeout: .seconds(1), operation: { .failure("must not run") }), "Next test cannot overlap cancelling internal worker")
        let secondWaiter = Task { await service.waitUntilIdle() }
        lookup.release()
        await until { !tests.isBusy }
        await secondWaiter.value
        check(tests.phase == .cancelled && tests.outcome == nil, "Worker exit permits idle waits to return and discards late result")
        await service.waitUntilIdle()
        let invalid = CompletionSummaryConfiguration(enabled: false)
        _ = await service.generate(.init(sourceID: "qa", sessionID: "qa", completionID: UUID().uuidString,
            title: "Synthetic", finalText: "Pending", completedAt: Date(), observedAt: Date()), configuration: invalid)
        await service.waitUntilIdle()
        check(true, "Rejected request leaves no suspended idle waiter")
        print("All nested service worker checks passed")
    }
}
