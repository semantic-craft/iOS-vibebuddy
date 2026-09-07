import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("VoiceCallCoordinator — shared realtime call behavior")
@MainActor
struct VoiceCallCoordinatorTests {

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

    @Test("model audio mutes the mic and enters speaking")
    func modelAudioMutesMic() {
        let audio = FakeVoiceCallAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" })
        let pcm = Data([0x01, 0x02, 0x03])

        coordinator.handle(.audioDelta(pcm))

        #expect(coordinator.phase == .speaking)
        #expect(audio.micMuted == true)
        #expect(audio.enqueuedAudio == [pcm])
    }

    @Test("mic reopens only after the model turn is done and playback drains")
    func responseDoneWaitsForPlaybackDrain() {
        let audio = FakeVoiceCallAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" })

        coordinator.handle(.audioDelta(Data([0x01])))
        coordinator.handle(.responseDone)

        #expect(coordinator.phase == .speaking)
        #expect(audio.micMuted == true)

        coordinator.playbackDrained()

        #expect(coordinator.phase == .listening)
        #expect(audio.micMuted == false)
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

    @Test("a close phrase ends the voice call")
    func closePhraseEndsCall() {
        let audio = FakeVoiceCallAudio()
        var closed = false
        let coordinator = VoiceCallCoordinator(
            audio: audio,
            actionHandler: { _ in "" },
            closeSession: { closed = true }
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
            closeSession: { closed = true }
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
        #expect(audio.micMuted == true)

        coordinator.playbackDrained()

        #expect(coordinator.phase == .listening)
        #expect(audio.micMuted == false)
    }
}

@MainActor
private final class FakeVoiceCallAudio: VoiceCallAudio {
    var micMuted = false
    private(set) var enqueuedAudio: [Data] = []
    private(set) var stopped = false

    func enqueue(_ pcm: Data) {
        enqueuedAudio.append(pcm)
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

    func close() {
        closed = true
    }
}
