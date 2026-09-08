import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Doubao protocol boundaries")
struct DoubaoRealtimeSessionTests {
    @Test("PCM capture blocks become complete 20ms frames without changing bytes")
    func frames() {
        var frames = DoubaoPCMFrames()
        let input = Data((0..<1921).map { UInt8($0 % 251) })
        frames.append(input.prefix(301))
        #expect(frames.next() == nil)
        frames.append(input.dropFirst(301))
        var output = Data()
        for _ in 0..<3 { output.append(frames.next()!) }
        #expect(output == input.prefix(1920))
        #expect(frames.byteCount == 1)
        #expect(frames.next() == nil)
    }

    @Test("Audio pacing absorbs scheduler overhead without catch-up bursts")
    func pacing() {
        let start = ContinuousClock.now
        var pacer = DoubaoAudioPacer(now: start)
        var wake = start
        for index in 1...1000 {
            let next = pacer.next(after: wake.advanced(by: .milliseconds(1)))
            #expect(next == start.advanced(by: .milliseconds(index * 20)))
            wake = next
        }
        let stalled = wake.advanced(by: .milliseconds(300))
        #expect(pacer.next(after: stalled) == stalled.advanced(by: .milliseconds(20)))
    }

    @Test("Confirmed API uses session audio formats and flat function schemas")
    func configuration() {
        let config = DoubaoRealtimeSession.sessionConfig(model: "1.2.6.1", instructions: "synthetic", voice: "zh_female_vv_jupiter_bigtts", tools: VoiceTools.all)
        #expect(config["model"] as? String == "1.2.6.1")
        #expect(config["id"] == nil)
        let audio = config["audio"] as! [String: Any]
        let input = audio["input"] as! [String: Any]
        let output = audio["output"] as! [String: Any]
        #expect((input["format"] as? [String: Any])?["rate"] as? Int == 16000)
        #expect((input["format"] as? [String: Any])?["type"] as? String == "pcm")
        #expect((output["format"] as? [String: Any])?["rate"] as? Int == 24000)
        // `pcm` means Float32 output in the official demo and produces noise in our PCM16 player.
        #expect((output["format"] as? [String: Any])?["type"] as? String == "pcm_s16le")
        #expect(output["voice"] as? String == "zh_female_vv_jupiter_bigtts")
        #expect((config["tools"] as? [[String: Any]])?.first?["name"] != nil)
    }

    @Test("Interrupted response is rejected; missing identity explicitly requires reopening")
    func interruption() {
        var state = DoubaoResponseState()
        #expect(!state.hasActiveResponse)
        #expect(state.accept(["response_id": "", "question_id": "q1"]) == .accepted)
        #expect(state.accept(["response_id": "r1", "question_id": "q1"]) == .accepted)
        state.interrupt()
        #expect(state.accept(["response_id": "r1"]) == .cancelled)
        #expect(state.accept(["question_id": "q1"]) == .cancelled)
        #expect(state.accept(["type": "response.function_call_arguments.done"]) == .ambiguous)
        #expect(state.accept(["response_id": "", "question_id": "q2"]) == .accepted)
    }

    @Test("Audio completion followed by response completion does not reactivate a finished response")
    func completionOrder() {
        var state = DoubaoResponseState()
        #expect(state.accept(["type": "response.output_audio.delta", "response_id": "r1"]) == .accepted)
        #expect(state.hasActiveResponse)
        #expect(state.accept(["type": "response.output_audio.done", "response_id": "r1"]) == .accepted)
        #expect(!state.hasActiveResponse)
        #expect(state.accept(["type": "response.done", "response_id": "r1"]) == .accepted)
        #expect(!state.hasActiveResponse)
        // Matches the ASR handler: ordinary speech after a completed response is
        // not an interruption, so the documented identity-free FC remains usable.
        if state.hasActiveResponse { state.interrupt() }
        #expect(state.accept(["type": "response.function_call_arguments.done"]) == .accepted)
    }

    @Test("Tools aggregate once by call ID and cancellation rejects late results")
    func toolBatch() {
        var batch = DoubaoToolBatch()
        let items: [[String: Any]] = [
            ["call_id": "a", "name": "one", "arguments": "{}"],
            ["call_id": "b", "name": "two", "arguments": "{}"]]
        #expect(batch.begin(items).count == 2)
        #expect(batch.begin(items).isEmpty)
        #expect(batch.complete(callID: "b", result: "second") == nil)
        let receipt = batch.complete(callID: "a", result: "first")!
        #expect(receipt.count == 2)
        #expect(receipt[0]["call_id"] as? String == "a")
        #expect(receipt[0]["role"] as? String == "tool")
        #expect((receipt[1]["content"] as? [[String: String]])?.first?["text"] == "second")
        #expect(batch.complete(callID: "a", result: "late") == nil)
        #expect(batch.begin([["call_id": "c", "name": "three", "arguments": "{}"]]).count == 1)
        #expect(batch.cancel() == ["c"])
        #expect(batch.complete(callID: "c", result: "late") == nil)
    }
}
