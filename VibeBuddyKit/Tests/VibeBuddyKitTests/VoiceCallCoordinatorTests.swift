import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("VoiceCallCoordinator — shared realtime call behavior")
@MainActor
struct VoiceCallCoordinatorTests {

    @Test("final Qwen and Doubao transcripts end locally without a model tool")
    func finalTranscriptHangup() {
        let audio = FakeVoiceCallAudio()
        var closeCount = 0
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in
            Issue.record("Local hangup must not mutate coding tasks")
            return ""
        }, closeSession: { _ in closeCount += 1 })
        coordinator.handle(.connected)
        coordinator.handle(.audioDelta(Data([1, 2])))
        coordinator.handle(.userTranscript(text: "请立即挂断这次语音通话", final: false))
        #expect(!audio.stopped)
        coordinator.handle(.userTranscript(text: "请立即挂断这次语音通话", final: true))
        coordinator.handle(.userTranscript(text: "请立即挂断这次语音通话", final: true))
        #expect(audio.stopped)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.endedByExplicitVoiceCommand)
        #expect(closeCount == 1)
    }

    @Test("completed negated and quoted hangup requests keep the call open")
    func nonCommandsStayOpen() {
        let audio = FakeVoiceCallAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" })
        coordinator.handle(.connected)
        for text in ["不要挂断通话", "“挂断通话”", "挂断通话？", "结束这个会话之前先跑测试"] {
            coordinator.handle(.userTranscript(text: text, final: true))
            #expect(!audio.stopped)
        }
        coordinator.stop()
    }

    @Test("connecting remains distinct from listening until provider confirmation")
    func awaitsConfirmation() {
        let audio = FakeVoiceCallAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" })
        coordinator.beginConnecting()
        #expect(coordinator.phase == .connecting)
        coordinator.handle(.connected)
        #expect(coordinator.phase == .listening)
        coordinator.handle(.closed)
        #expect(coordinator.phase == .idle)
    }

    @Test("model audio enters speaking without controlling microphone capture")
    func modelAudioEntersSpeaking() {
        let audio = FakeVoiceCallAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" })
        let pcm = Data([0x01, 0x02, 0x03])

        coordinator.handle(.audioDelta(pcm))

        #expect(coordinator.phase == .speaking)
        #expect(audio.enqueuedAudio == [pcm])
    }

    @Test("speaking ends only after both model completion and playback drain")
    func responseDoneWaitsForPlaybackDrain() {
        let audio = FakeVoiceCallAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" })

        coordinator.handle(.audioDelta(Data([0x01])))
        coordinator.handle(.responseDone)

        #expect(coordinator.phase == .speaking)

        audio.isPlaybackPending = false
        coordinator.playbackDrained()

        #expect(coordinator.phase == .listening)
    }

    @Test("barge-in flushes queued audio; stale drain cannot finish new playback")
    func bargeIn() {
        let audio = FakeVoiceCallAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" })
        coordinator.handle(.audioDelta(Data([1, 2])))
        coordinator.handle(.speechStarted)
        #expect(audio.flushCount == 1)
        #expect(coordinator.phase == .listening)
        coordinator.handle(.audioDelta(Data([3, 4])))
        coordinator.handle(.responseDone)
        coordinator.playbackDrained() // previous generation callback
        #expect(coordinator.phase == .speaking)
        audio.isPlaybackPending = false
        coordinator.playbackDrained()
        #expect(coordinator.phase == .listening)
        coordinator.stop()
        coordinator.handle(.audioDelta(Data([5, 6])))
        coordinator.handle(.speechStarted)
        #expect(coordinator.phase == .idle)
        #expect(audio.enqueuedAudio.count == 2)
    }

    @Test("a network gap does not end speaking before response completion")
    func playbackBeforeResponseDone() {
        let audio = FakeVoiceCallAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" })
        coordinator.handle(.audioDelta(Data([1, 2])))
        audio.isPlaybackPending = false
        coordinator.playbackDrained()
        #expect(coordinator.phase == .speaking)
        coordinator.handle(.responseDone)
        #expect(coordinator.phase == .listening)
    }

    @Test("interrupted response audio and tools are discarded even after the next response starts")
    func interruptedResponseIdentity() {
        var filter = RealtimeResponseFilter()
        func accepts(_ event: [String: Any]) -> Bool { filter.accept(event) }
        #expect(accepts(["type": "response.created", "response": ["id": "old"]]))
        #expect(accepts(["type": "input_audio_buffer.speech_started"]))
        #expect(!accepts(["type": "response.audio.delta", "response_id": "old"]))
        #expect(accepts(["type": "response.created", "response": ["id": "new"]]))
        #expect(!accepts(["type": "response.function_call_arguments.done", "response_id": "old"]))
        #expect(!accepts(["type": "response.done", "response": ["id": "old"]]))
        #expect(accepts(["type": "response.output_audio.delta", "response_id": "new"]))
        #expect(accepts(["type": "response.done", "response": ["id": "new"]]))
    }

    @Test("assistant transcript deltas accumulate the visible reply")
    func assistantTranscriptUpdatesReply() {
        let audio = FakeVoiceCallAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" })

        coordinator.handle(.assistantTranscript(text: "Hel", final: false))
        coordinator.handle(.assistantTranscript(text: "lo", final: false))

        #expect(coordinator.lastReply == "Hello")

        coordinator.handle(.assistantTranscript(text: "Hello there.", final: true))

        #expect(coordinator.lastReply == "Hello there.")
    }

    @Test("tool calls run the decoded voice action and return the result")
    func toolCallRunsActionAndReturnsResult() async {
        let audio = FakeVoiceCallAudio()
        var handled: [VoiceAction] = []
        var sentResults: [(callID: String, name: String, result: String)] = []
        let coordinator = VoiceCallCoordinator(
            audio: audio,
            actionHandler: { action in
                handled.append(action)
                return "Approved payments-api."
            },
            sendToolResult: { callID, name, result in
                sentResults.append((callID, name, result))
            }
        )

        coordinator.handle(.toolCall(
            name: "approve_session",
            arguments: #"{"project":"payments-api"}"#,
            callID: "call-1"
        ))

        for _ in 0..<100 where sentResults.isEmpty { await Task.yield() }
        #expect(handled == [.approve(project: "payments-api")])
        #expect(sentResults.count == 1)
        #expect(sentResults.first?.callID == "call-1")
        #expect(sentResults.first?.name == "approve_session")
        #expect(sentResults.first?.result == "Approved payments-api.")
        #expect(coordinator.lastReply == "Approved payments-api.")
    }

    @Test("tool result waits for the asynchronous receipt and duplicate call IDs do not resend")
    func receiptWaits() async {
        let audio = FakeVoiceCallAudio()
        var receipt: CheckedContinuation<String, Never>?
        var sent: [String] = []
        var calls = 0
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in
            calls += 1
            return await withCheckedContinuation { receipt = $0 }
        }, sendToolResult: { _, _, result in sent.append(result) })
        let event = RealtimeVoiceEvent.toolCall(name: "approve_session", arguments: #"{"project":"fixture"}"#, callID: "one")
        coordinator.handle(event)
        for _ in 0..<100 where receipt == nil { await Task.yield() }
        coordinator.handle(event)
        #expect(calls == 1)
        #expect(sent.isEmpty)
        receipt?.resume(returning: "The result could not be confirmed.")
        for _ in 0..<100 where sent.isEmpty { await Task.yield() }
        #expect(sent == ["The result could not be confirmed."])
    }

    @Test("closing the call suppresses a late action receipt")
    func closeSuppressesLateReceipt() async {
        var receipt: CheckedContinuation<String, Never>?
        var sent: [String] = []
        let coordinator = VoiceCallCoordinator(audio: FakeVoiceCallAudio(), actionHandler: { _ in
            await withCheckedContinuation { receipt = $0 }
        }, sendToolResult: { _, _, result in sent.append(result) })
        coordinator.handle(.toolCall(name: "approve_session", arguments: #"{"project":"fixture"}"#, callID: "late"))
        for _ in 0..<100 where receipt == nil { await Task.yield() }
        coordinator.stop()
        receipt?.resume(returning: "Mac received the request.")
        for _ in 0..<100 { await Task.yield() }
        #expect(sent.isEmpty)
        #expect(coordinator.phase == .idle)
    }

    @Test("provider cancellation prevents queued actions and suppresses an in-flight receipt")
    func cancellationSuppressesTools() async {
        var calls = 0
        var receipt: CheckedContinuation<String, Never>?
        var sent: [String] = []
        let coordinator = VoiceCallCoordinator(audio: FakeVoiceCallAudio(), actionHandler: { _ in
            calls += 1
            return await withCheckedContinuation { receipt = $0 }
        }, sendToolResult: { _, _, result in sent.append(result) })
        coordinator.handle(.toolCall(name: "approve_session", arguments: #"{"project":"fixture"}"#, callID: "queued"))
        coordinator.handle(.toolCallsCancelled(["queued"]))
        for _ in 0..<100 { await Task.yield() }
        #expect(calls == 0)
        coordinator.handle(.toolCall(name: "approve_session", arguments: #"{"project":"fixture"}"#, callID: "running"))
        for _ in 0..<100 where receipt == nil { await Task.yield() }
        #expect(calls == 1)
        coordinator.handle(.toolCallsCancelled(["running"]))
        receipt?.resume(returning: "Already performed action receipt")
        for _ in 0..<100 { await Task.yield() }
        #expect(sent.isEmpty)
    }

    @Test("barge-in forwards the audible checkpoint to provider history")
    func forwardsPlaybackCheckpoint() {
        let audio = FakeVoiceCallAudio()
        audio.checkpoints = [.init(item: .init(id: "item-1", contentIndex: 0), audioEndMilliseconds: 120)]
        var sent: [VoicePlaybackCheckpoint] = []
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" },
                                               truncatePlayback: { sent = $0 })
        coordinator.handle(.speechStarted)
        #expect(sent.count == 1)
        #expect(sent.first?.item.id == "item-1")
        #expect(sent.first?.audioEndMilliseconds == 120)
    }

    @Test("a close phrase ends the voice call")
    func closePhraseEndsCall() {
        let audio = FakeVoiceCallAudio()
        var closed = false
        let coordinator = VoiceCallCoordinator(
            audio: audio,
            actionHandler: { _ in "" },
            closeSession: { _ in closed = true }
        )

        coordinator.handle(.connected)
        coordinator.handle(.userTranscript(text: "再见", final: true))

        #expect(coordinator.lastUserText == "再见")
        #expect(coordinator.phase == .idle)
        #expect(audio.stopped == true)
        #expect(closed == true)
    }

    @Test("provider failure exposes the error and stops the voice call")
    func providerFailureStopsCall() {
        let audio = FakeVoiceCallAudio()
        var closed = false
        let coordinator = VoiceCallCoordinator(
            audio: audio,
            actionHandler: { _ in "" },
            closeSession: { _ in closed = true }
        )

        coordinator.handle(.connected)
        coordinator.handle(.failed("provider disconnected"))

        #expect(coordinator.errorText == "provider disconnected")
        #expect(coordinator.phase == .idle)
        #expect(audio.stopped == true)
        #expect(closed == true)
    }

    @Test("a fake realtime provider stream drives a full coordinator turn")
    func fakeRealtimeProviderStreamDrivesCoordinator() async {
        let pcm = Data([0x10, 0x20])
        let provider = FakeRealtimeVoiceProvider(events: [
            .connected,
            .userTranscript(text: "Approve payments API", final: true),
            .assistantTranscript(text: "Sure, ", final: false),
            .assistantTranscript(text: "doing that.", final: false),
            .toolCall(
                name: "approve_session",
                arguments: #"{"project":"payments-api"}"#,
                callID: "call-1"
            ),
            .audioDelta(pcm),
            .responseDone,
        ])
        let audio = FakeVoiceCallAudio()
        var handled: [VoiceAction] = []
        var sentResults: [(callID: String, name: String, result: String)] = []
        let coordinator = VoiceCallCoordinator(
            audio: audio,
            actionHandler: { action in
                handled.append(action)
                return "Approved payments-api."
            },
            sendToolResult: { callID, name, result in
                sentResults.append((callID, name, result))
            }
        )

        let stream = await provider.start(
            instructions: "test instructions",
            voice: "test-voice",
            tools: VoiceTools.all
        )
        for await event in stream {
            coordinator.handle(event)
        }

        for _ in 0..<100 where sentResults.isEmpty { await Task.yield() }
        let start = await provider.startRequest
        #expect(start?.instructions == "test instructions")
        #expect(start?.voice == "test-voice")
        #expect(start?.toolCount == VoiceTools.all.count)
        #expect(coordinator.lastUserText == "Approve payments API")
        #expect(coordinator.lastReply == "Approved payments-api.")
        for _ in 0..<100 where sentResults.isEmpty { await Task.yield() }
        #expect(handled == [.approve(project: "payments-api")])
        #expect(sentResults.count == 1)
        #expect(sentResults.first?.callID == "call-1")
        #expect(audio.enqueuedAudio == [pcm])
        #expect(coordinator.phase == .speaking)

        audio.isPlaybackPending = false
        coordinator.playbackDrained()

        #expect(coordinator.phase == .listening)
    }
}

@MainActor
private final class FakeVoiceCallAudio: VoiceCallAudio {
    var isPlaybackPending = false
    var flushCount = 0
    var checkpoints: [VoicePlaybackCheckpoint] = []

    func flushPlayback() -> [VoicePlaybackCheckpoint] {
        flushCount += 1
        isPlaybackPending = false
        return checkpoints
    }
    private(set) var enqueuedAudio: [Data] = []
    private(set) var stopped = false

    func enqueue(_ pcm: Data, item: VoiceAudioItem?) {
        enqueuedAudio.append(pcm)
        isPlaybackPending = true
    }

    func stop() {
        stopped = true
    }
}

private actor FakeRealtimeVoiceProvider: RealtimeVoiceProvider {
    struct StartRequest: Sendable {
        let instructions: String
        let voice: String
        let toolCount: Int
    }

    private let events: [RealtimeVoiceEvent]
    private(set) var startRequest: StartRequest?
    private(set) var appendedAudio: [Data] = []
    private(set) var closed = false

    init(events: [RealtimeVoiceEvent]) {
        self.events = events
    }

    func start(instructions: String, voice: String, tools: [VoiceTool]) -> AsyncStream<RealtimeVoiceEvent> {
        startRequest = StartRequest(instructions: instructions, voice: voice, toolCount: tools.count)
        let events = self.events
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func appendAudio(_ pcm16k: Data) {
        appendedAudio.append(pcm16k)
    }

    func sendToolResult(callID: String, name: String, result: String) {}

    func truncatePlayback(_ checkpoints: [VoicePlaybackCheckpoint]) {}

    func close() {
        closed = true
    }
}
