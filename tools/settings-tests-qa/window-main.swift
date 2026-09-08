import AppKit
import SwiftUI

actor WindowGate {
    var waiter: CheckedContinuation<SettingsTestCoordinator.Outcome, Never>?
    var entered = false
    func wait() async -> SettingsTestCoordinator.Outcome {
        entered = true
        return await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(returning: .success(.init(message: "Late fixture result"))); waiter = nil }
}
struct Fixture: View {
    @ObservedObject var tests: SettingsTestCoordinator
    var body: some View {
        Form {
            Text("S3 isolated lifecycle fixture — no services or credentials")
            SettingsTestFeedback(tests: tests, purpose: .voice)
            SettingsTestFeedback(tests: tests, purpose: .summary)
        }.formStyle(.grouped).modifier(SettingsTestLifecycle(tests: tests))
    }
}
@main
struct WindowQA {
    @MainActor static func check(_ value: Bool, _ label: String) {
        guard value else { print("FAIL: \(label)"); exit(1) }
        print("PASS: \(label)")
    }
    @MainActor static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { print("FAIL: wait deadline"); exit(1) }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        let tests = SettingsTestCoordinator()
        let windows = AppWindows(dashboard: AnyView(Text("Unrelated fixture window")), settings: AnyView(Fixture(tests: tests)))
        Task { @MainActor in
            windows.showSettings()
            try? await Task.sleep(for: .milliseconds(300))
            guard let window = windows.settingsWindow, window.isKeyWindow else { print("STOP: fixture not foreground"); exit(2) }
            let gate = WindowGate()
            tests.start(.voice, timeout: .seconds(10), operation: { await gate.wait() })
            await until { await gate.entered }
            check(window.isVisible && tests.phase == .running, "Real retained Settings fixture displays running test")
            let unrelated = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            unrelated.isReleasedWhenClosed = false
            unrelated.identifier = .init("unrelated.fixture")
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: unrelated)
            check(tests.phase == .running, "Unrelated window close does not cancel Settings test")
            guard window.isKeyWindow else { print("STOP: foreground changed"); exit(2) }
            window.close()
            await until { tests.phase == .unverified }
            check(!window.isVisible && tests.isBusy && tests.outcome == nil, "Actual NSWindow close clears state while cancellation retains slot")
            await gate.release()
            await until { !tests.isBusy }
            check(tests.outcome == nil, "Late fixture response after window close is discarded")
            windows.showSettings()
            try? await Task.sleep(for: .milliseconds(200))
            check(windows.settingsWindow === window && tests.phase == .unverified, "Reopened retained window is unverified")
            tests.start(.summary, timeout: .seconds(1), operation: { .success(.init(message: "Fixture summary")) })
            await until { !tests.isBusy }
            check(tests.purpose == .summary && tests.phase == .succeeded, "Reopened window accepts a separate new purpose")
            guard window.isKeyWindow else { print("STOP: foreground changed"); exit(2) }
            window.close()
            check(tests.outcome == nil, "Closing completed fixture clears temporary result")
            print("All native Settings lifecycle fixture checks passed")
            app.terminate(nil)
        }
        app.run()
    }
}
