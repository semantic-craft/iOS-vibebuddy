// swiftc -swift-version 6 -parse-as-library VibeBuddyMacApp/Sources/SettingsTestCoordinator.swift tools/settings-tests-qa/main.swift -o /tmp/settings-tests-qa
// No App, window, network, audio, preference or credential access.
import Foundation

actor Gate {
    private var result: SettingsTestCoordinator.Outcome?
    private var waiters: [CheckedContinuation<SettingsTestCoordinator.Outcome, Never>] = []
    private(set) var entries = 0
    func wait() async -> SettingsTestCoordinator.Outcome {
        entries += 1
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func release(_ result: SettingsTestCoordinator.Outcome) {
        self.result = result
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: result) }
    }
}

@main
struct SettingsTestsQA {
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
        let tests = SettingsTestCoordinator()
        let slow = Gate()
        check(tests.start(.voice, timeout: .seconds(2), operation: { await slow.wait() }), "First test starts")
        await until { await slow.entries == 1 }
        check(!tests.start(.summary, timeout: .seconds(2), operation: { .failure("must not run") }), "Duplicate/different-purpose test is refused")
        tests.invalidate() // config edit, purpose switch or retained Settings close
        check(tests.phase == .unverified && tests.outcome == nil, "Invalidation immediately clears result")
        check(tests.isBusy, "Cancelled non-cooperative operation still occupies its slot")
        check(!tests.start(.voice, timeout: .seconds(2), operation: { .failure("must not run") }), "New request cannot overlap cancellation")
        await slow.release(.success(.init(message: "obsolete configuration")))
        await until { !tests.isBusy }
        check(tests.outcome == nil && tests.phase == .unverified, "Late success cannot verify a changed/closed configuration")
        check(tests.start(.summary, timeout: .seconds(2), operation: { .success(.init(message: "fresh summary", text: "Device verification is pending.")) }), "New test starts only after old request exits")
        await until { !tests.isBusy }
        check(tests.purpose == .summary && tests.phase == .succeeded, "Fresh result belongs only to its purpose")
        tests.invalidate()
        check(tests.purpose == nil && tests.outcome == nil, "Navigation clears completed temporary results")

        let timed = Gate()
        check(tests.start(.voice, timeout: .milliseconds(20), operation: { await timed.wait() }), "Timeout scenario starts")
        await until { tests.phase == .failed }
        check(tests.isBusy, "Timeout does not claim the underlying request has exited")
        tests.invalidate()
        await timed.release(.success(.init(message: "too late after deadline")))
        await until { !tests.isBusy }
        check(tests.phase == .unverified && tests.outcome == nil, "Timeout followed by config change rejects late success")

        let request = Gate(), close = Gate()
        check(tests.start(.voice, timeout: .seconds(2), operation: { await request.wait() }, cleanup: { _ = await close.wait() }), "Explicit cancel scenario starts")
        await until { await request.entries == 1 }
        tests.cancel()
        await until { await close.entries > 0 }
        await request.release(.success(.init(message: "cancelled response")))
        check(tests.phase == .cancelled && tests.isBusy, "Explicit cancellation is shown while cleanup is pending")
        await close.release(.success(.init(message: "closed")))
        await until { !tests.isBusy }
        check(tests.phase == .cancelled && tests.outcome == nil, "Resource cleanup finishes without restoring a cancelled result")
        print("All Settings test lifecycle checks passed")
    }
}
