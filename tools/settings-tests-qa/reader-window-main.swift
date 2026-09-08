import AppKit
import SwiftUI
import VibeBuddyKit

actor PreviewWindowGate {
    var entered = false
    var waiter: CheckedContinuation<Data, Never>?
    func wait() async -> Data {
        entered = true
        return await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(returning: Data()); waiter = nil }
}
/// A `SpeechSynthesizer` that parks in `synthesize` instead of reaching a network.
struct WindowGateSynthesizer: SpeechSynthesizer {
    let gate: PreviewWindowGate
    func synthesize(_ text: String, apiKey: String) async throws -> Data { await gate.wait() }
}
struct ReaderFixture: View {
    @ObservedObject var tests: SettingsTestCoordinator
    var body: some View {
        Form {
            Text("S4 isolated read-aloud lifecycle fixture")
            Text("No credentials, services, microphone or audio output")
            SettingsTestFeedback(tests: tests, purpose: .readAloud)
        }.formStyle(.grouped).modifier(SettingsTestLifecycle(tests: tests))
    }
}
@main
struct ReaderWindowQA {
    @MainActor static func check(_ value: Bool, _ label: String) {
        guard value else { print("FAIL: \(label)"); exit(1) }
        print("PASS: \(label)")
    }
    @MainActor static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { print("FAIL: wait deadline"); exit(1) }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        let tests = SettingsTestCoordinator()
        let windows = AppWindows(dashboard: AnyView(Text("Unused fixture dashboard")), settings: AnyView(ReaderFixture(tests: tests)))
        Task { @MainActor in
            windows.showDashboard()
            windows.showSettings()
            try? await Task.sleep(for: .milliseconds(300))
            guard let window = windows.settingsWindow, window.isKeyWindow else { print("STOP: fixture not foreground"); exit(2) }
            let gate = PreviewWindowGate()
            let reader = ReadAloud(automaticKey: { _ in nil }, makeSynthesizer: { _ in WindowGateSynthesizer(gate: gate) })
            let config = SpeechSynthesisConfiguration(provider: .qwen, model: "synthetic", voice: "synthetic")
            tests.start(.readAloud, timeout: .seconds(10), operation: {
                _ = await reader.preview("Synthetic sample", apiKey: "synthetic-not-a-key", configuration: config)
                return .success(.init(message: "Must be discarded"))
            }, cleanup: { await reader.cancelPreview() })
            await until { await gate.entered }
            var automaticValidated = false
            reader.speak("Never sent", id: "queued-fixture") { automaticValidated = true; return false }
            check(tests.phase == .running && reader.busy, "Native retained window has an active Settings preview")
            guard window.isKeyWindow else { print("STOP: foreground changed"); exit(2) }
            window.close()
            await until { tests.phase == .unverified }
            check(!window.isVisible && tests.outcome == nil && tests.isBusy, "Actual window close invalidates preview while waiting for its resource exit")
            check(reader.automaticBusy && !automaticValidated, "Closing Settings preserves waiting automatic work")
            await gate.release()
            await until { !tests.isBusy && !reader.busy && automaticValidated }
            check(tests.outcome == nil, "Late preview after close cannot restore success")
            // Do not reacquire focus if another application took it after close.
            guard NSApp.isActive, windows.dashboardWindow?.isKeyWindow == true else { print("STOP: own dashboard not foreground; reopen not tested"); exit(2) }
            windows.showSettings()
            try? await Task.sleep(for: .milliseconds(150))
            guard window.isKeyWindow else { print("STOP: foreground changed"); exit(2) }
            check(windows.settingsWindow === window && tests.phase == .unverified, "Reopened retained fixture is unverified")
            window.close()
            windows.dashboardWindow?.close()
            print("All native read-aloud lifecycle fixture checks passed")
            app.terminate(nil)
        }
        app.run()
    }
}
