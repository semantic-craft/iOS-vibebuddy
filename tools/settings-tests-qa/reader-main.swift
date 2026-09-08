import Foundation
import VibeBuddyKit

actor SynthesisGate {
    var entered = false
    var waiter: CheckedContinuation<Data, Never>?
    func run() async -> Data {
        entered = true
        return await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(returning: Data()); waiter = nil }
}
@main
struct ReaderQA {
    @MainActor static func check(_ value: Bool, _ label: String) {
        guard value else { print("FAIL: \(label)"); exit(1) }
        print("PASS: \(label)")
    }
    @MainActor static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { print("FAIL: wait deadline"); exit(1) }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    @MainActor static func main() async {
        let gate = SynthesisGate()
        let reader = QwenReadAloud(synthesizePreview: { _, _, _ in await gate.run() })
        let tests = SettingsTestCoordinator()
        let config = QwenReadAloud.PreviewConfiguration(model: "synthetic", voice: "synthetic", workspaceID: nil, useIntl: false)
        tests.start(.readAloud, timeout: .seconds(10), operation: {
            _ = await reader.preview("Synthetic", apiKey: "synthetic-not-a-key", configuration: config)
            return .success(.init(message: "obsolete"))
        }, cleanup: { await reader.cancelPreview() })
        await until { await gate.entered }
        var automaticValidated = false
        reader.speak("Never sent", id: "automatic-fixture") {
            automaticValidated = true
            return false // The actual automatic path cannot access Keychain or generate audio.
        }
        tests.invalidate()
        check(reader.busy && tests.isBusy, "Preview cancellation retains reader and Settings occupancy until synthesis exits")
        check(reader.automaticBusy && !automaticValidated, "Automatic reading remains queued without overlapping preview")
        check(!tests.start(.voice, timeout: .seconds(1), operation: { .failure("must not run") }), "Another Settings test cannot overlap cancelling preview")
        await gate.release()
        await until { automaticValidated && !reader.busy && !tests.isBusy }
        check(tests.outcome == nil, "Late preview data never becomes success or playback")
        check(automaticValidated, "Cancelling preview preserves queued automatic reading and revalidates it afterward")

        let gate2 = SynthesisGate()
        let reader2 = QwenReadAloud(synthesizePreview: { _, _, _ in await gate2.run() })
        let preview = Task { await reader2.preview("Synthetic", apiKey: "synthetic-not-a-key", configuration: config) }
        await until { await gate2.entered }
        var oldAutomaticValidated = false
        reader2.speak("Never sent", id: "old-auto") { oldAutomaticValidated = true; return false }
        reader2.stop() // Existing Buddy onStart uses this same entry.
        check(reader2.busy && !reader2.automaticBusy, "Global stop cancels automatic queue but retains exiting preview occupancy")
        await gate2.release()
        let result = await preview.value
        if case .cancelled = result { check(true, "Global stop returns cancelled preview") }
        else { check(false, "Global stop returns cancelled preview") }
        await Task.yield()
        check(!oldAutomaticValidated, "Global stop prevents an old queued operation from resuming validation")
        reader2.canSpeak = { false }
        let blocked = await reader2.preview("Synthetic", apiKey: "synthetic-not-a-key", configuration: config)
        if case .failed = blocked { check(true, "Active voice gate refuses preview before synthesis") }
        else { check(false, "Active voice gate refuses preview before synthesis") }
        let validationGate = SynthesisGate()
        var keyReads = 0
        let reader3 = QwenReadAloud(automaticKey: { keyReads += 1; return nil })
        var validationReturned = false
        reader3.speak("Never sent", id: "suspended-validation") {
            _ = await validationGate.run()
            validationReturned = true
            return true
        }
        await until { await validationGate.entered }
        reader3.stop()
        await validationGate.release()
        await until { validationReturned }
        await Task.yield()
        check(keyReads == 0, "Stopping during suspended validation prevents credential lookup and synthesis afterward")
        print("All Qwen preview ownership checks passed; no credentials, network or audio were used")
    }
}
