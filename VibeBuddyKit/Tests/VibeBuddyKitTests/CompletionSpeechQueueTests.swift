import Foundation
import Testing
@testable import VibeBuddyKit

@MainActor
struct CompletionSpeechQueueTests {
    @Test("Completions serialize, duplicates do not play, and a newly read queued result is skipped")
    func serialSpeech() async throws {
        let queue = CompletionSpeechQueue()
        let gate = SpeechGate()
        var events: [String] = []
        var secondStillUnread = true
        queue.enqueue(id: "first") {
            events.append("first-start")
            await gate.wait()
            events.append("first-end")
        }
        queue.enqueue(id: "first") { events.append("duplicate") }
        queue.enqueue(id: "second") {
            if secondStillUnread { events.append("second-play") }
        }
        queue.enqueue(id: "third") { events.append("third-play") }
        await gate.waitUntilEntered()
        #expect(events == ["first-start"])
        secondStillUnread = false
        gate.release()
        await waitForIdle(queue)
        #expect(events == ["first-start", "first-end", "third-play"])
    }

    @Test("Stopping clears pending speech and a late operation cannot consume the new queue")
    func stopAndRestart() async throws {
        let queue = CompletionSpeechQueue()
        let gate = SpeechGate()
        var events: [String] = []
        queue.enqueue(id: "old-active") {
            await gate.wait()
            if !Task.isCancelled { events.append("old-play") }
        }
        queue.enqueue(id: "old-pending") { events.append("old-pending-play") }
        await gate.waitUntilEntered()
        queue.cancel()
        queue.enqueue(id: "fresh") { events.append("fresh-play") }
        gate.release()
        await waitForIdle(queue)
        #expect(events == ["fresh-play"])
    }

    private func waitForIdle(_ queue: CompletionSpeechQueue) async {
        // Install the observer before yielding, so even synchronous jobs signal it.
        await withCheckedContinuation { continuation in
            queue.onBusyChanged = { busy in
                if !busy { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class SpeechGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered?.resume(); entered = nil
        }
    }
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
