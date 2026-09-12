import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Doubao protocol boundaries")
struct DoubaoRealtimeSessionTests {
    @Test("Final ASR fields follow the duplex demo; failed and empty input are not final text")
    func finalTranscriptionFields() {
        let type = "conversation.item.input_audio_transcription.completed"
        for (fields, expected) in [
            (["transcript": "first", "text": "second"], "first"),
            (["transcript": " \n", "text": "second"], "second"),
            (["text": "second"], "second"),
        ] {
            let event = DoubaoRealtimeSession.userTranscriptionEvent(fields.merging(["type": type]) { _, new in new })
            guard case .userTranscript(let text, let final) = event else {
                Issue.record("Expected a completed user transcript"); continue
            }
            #expect(text == expected && final)
        }
        #expect(DoubaoRealtimeSession.userTranscriptionEvent(["type": type, "transcript": "", "text": " "]) == nil)
        #expect(DoubaoRealtimeSession.userTranscriptionEvent([
            "type": "conversation.item.input_audio_transcription.failed", "text": "failed hypothesis",
        ]) == nil)
    }

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

    @Test("Interrupted media resumes only inside a fresh identified audio segment")
    func identifiedAudioSegmentAfterInterruption() {
        var state = DoubaoResponseState()
        _ = state.accept(["type": "response.output_audio.started", "response_id": "old"])
        state.interrupt()
        #expect(state.accept(["type": "response.output_audio.delta"]) == .cancelled)
        #expect(state.accept(["type": "response.output_audio.started", "response_id": "old"]) == .cancelled)
        #expect(state.accept(["type": "response.output_audio.started", "response_id": "new", "question_id": "q2"]) == .accepted)
        #expect(state.accept(["type": "response.output_audio.delta"]) == .accepted)
        #expect(state.accept(["type": "response.output_audio.delta", "response_id": "old"]) == .cancelled)
        #expect(state.accept(["type": "response.output_audio.done", "response_id": "new"]) == .accepted)
        #expect(state.accept(["type": "response.output_audio.delta"]) == .cancelled)
        #expect(state.accept(["type": "response.done"]) == .accepted)
        #expect(!state.hasActiveResponse)
        let status: [String: Any] = ["name": "get_session_status", "call_id": "read", "arguments": "{}"]
        #expect(state.accept(["type": "response.function_call_arguments.done", "items": [status]]) == .accepted)
        let action: [String: Any] = ["name": "approve_session", "call_id": "act", "arguments": "{}"]
        #expect(state.accept(["type": "response.function_call_arguments.done", "items": [status, action]]) == .ambiguous)
        state.interrupt()
        #expect(state.accept(["type": "response.output_audio.delta"]) == .cancelled)
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
    @Test("Hangup resolves the full batch before close even with unfinished tools")
    func hangupBatch() throws {
        var batch = DoubaoToolBatch()
        _ = batch.begin([
            ["call_id": "finished", "name": "get_session_status", "arguments": "{}"],
            ["call_id": "pending", "name": "answer_session", "arguments": "{}"],
            ["call_id": "hangup", "name": "end_voice_call", "arguments": "{}"],
        ])
        #expect(batch.complete(callID: "finished", result: "known result") == nil)
        let completed = batch.complete(callID: "hangup", result: "ending", endingSession: true)
        let receipt = try #require(completed)
        #expect(receipt.compactMap { $0["call_id"] as? String } == ["finished", "pending", "hangup"])
        let texts = receipt.map { ($0["content"] as? [[String: String]])?.first?["text"] ?? "" }
        #expect(texts[0] == "known result")
        #expect(texts[1].contains("cancelled") && texts[1].contains("unconfirmed"))
        #expect(texts[2] == "ending")
        #expect(!batch.hasPending)
        #expect(batch.complete(callID: "pending", result: "late") == nil)
        #expect(batch.complete(callID: "hangup", result: "duplicate", endingSession: true) == nil)
    }

}

@Suite("Doubao completed transcript delivery")
@MainActor
struct DoubaoFinalTranscriptTests {
    @Test("Official text-only final reaches the coordinator and closes exactly once")
    func textOnlyFinalEndsCall() throws {
        let audio = TranscriptAudio()
        var closes = 0
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" }, closeSession: { _ in closes += 1 })
        coordinator.handle(.connected)
        let event = try #require(DoubaoRealtimeSession.userTranscriptionEvent([
            "type": "conversation.item.input_audio_transcription.completed", "text": "请立即挂断这次语音通话"]))
        coordinator.handle(event)
        #expect(coordinator.lastUserText == "请立即挂断这次语音通话")
        #expect(audio.stops == 1 && closes == 1 && coordinator.phase == .idle)
        coordinator.handle(event)
        #expect(audio.stops == 1 && closes == 1)
    }

    @Test("Completed parser prefers nonblank transcript then text and ignores failed events")
    func fieldPrecedence() throws {
        let audio = TranscriptAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" })
        coordinator.handle(.connected)
        for fields in [["transcript": "ordinary", "text": "请立即挂断这次语音通话"],
                       ["transcript": "  ", "text": "ordinary"], ["text": "ordinary"]] {
            let object = fields.merging(["type": "conversation.item.input_audio_transcription.completed"]) { first, _ in first }
            coordinator.handle(try #require(DoubaoRealtimeSession.userTranscriptionEvent(object)))
            #expect(coordinator.lastUserText == "ordinary")
            #expect(coordinator.phase == .listening && audio.stops == 0)
        }
        for hypothesis in ["ord", "ordinary updated"] {
            coordinator.handle(try #require(DoubaoRealtimeSession.userTranscriptionEvent([
                "type": "conversation.item.input_audio_transcription.delta", "delta": hypothesis])))
            #expect(coordinator.lastUserText == hypothesis)
            #expect(coordinator.phase == .listening && audio.stops == 0)
        }
        #expect(DoubaoRealtimeSession.userTranscriptionEvent(["type": "conversation.item.input_audio_transcription.completed", "transcript": " ", "text": ""]) == nil)
        #expect(DoubaoRealtimeSession.userTranscriptionEvent(["type": "conversation.item.input_audio_transcription.failed", "text": "请立即挂断这次语音通话"]) == nil)
        coordinator.stop()
    }
}

@MainActor
private final class TranscriptAudio: VoiceCallAudio {
    var isPlaybackPending = false
    var stops = 0
    func flushPlayback() -> [VoicePlaybackCheckpoint] { [] }
    func enqueue(_ data: Data, item: VoiceAudioItem?) {}
    func stop() { stops += 1 }
}
