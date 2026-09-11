import Foundation
import Testing
@testable import VibeBuddyKit

/// Paid, explicitly enabled provider acceptance with synthetic speech and a
/// selected real snapshot. Hardware audio is verified separately.
struct OpenAILiveConversationE2ETests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_LIVE_DIALOGUE_E2E"] == "1"))
    @MainActor func queryInterruptAndHangUp() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["VIBEBUDDY_LIVE_DIALOGUE_ROOT"])
        let key = try #require(KeychainStore.get("openai.apiKey"))
        let load = { (name: String) in try Data(contentsOf: URL(fileURLWithPath: root + "/" + name)) }
        let sessions = try JSONDecoder().decode([AgentSession].self, from: load("context.json"))
        let clips = try [load("query.pcm"), load("interrupt.pcm"), load("goodbye.pcm")]
        let session = OpenAILiveSession(apiKey: key, language: .chinese)
        let state = DialogueState(clips: clips)
        let audio = DialogueAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in
            state.actions += 1
            return "No task mutation is available in this acceptance test."
        }, sendToolResult: { id, name, result in
            Task { await session.sendToolResult(callID: id, name: name, result: result) }
        }, closeSession: { result in Task {
            if let result { await session.sendToolResult(callID: result.callID, name: result.name, result: result.result) }
            await session.close()
        } }, continuousPlayback: true,
           contextProvider: { state.reads += 1; return sessions })
        coordinator.beginConnecting()
        let stream = await session.start(instructions: VoicePrompt.liveBackend(language: .chinese),
            voice: "marin", tools: [VoiceTools.status, VoiceTools.endCall])
        let timeout = Task {
            try? await Task.sleep(for: .seconds(70))
            if !Task.isCancelled { state.timedOut = true; await session.close() }
        }
        var sender: Task<Void, Never>?
        defer { sender?.cancel(); timeout.cancel() }
        for await event in stream {
            switch event {
            case .connected:
                state.note("connected")
                sender = Task {
                    while !Task.isCancelled {
                        // Exercise hangup even if the preceding interruption fails.
                        if state.stage == 1, let interrupted = state.interruptedAt,
                           Date().timeIntervalSince(interrupted) > 25 {
                            state.stage = 2; state.offset = 0
                            state.note("goodbye_sent_after_interruption_deadline")
                        }
                        await session.appendAudio(state.nextChunk())
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            case .audioDelta(let data, _):
                state.audio.append(data)
                if VoicePCM.hasAudibleSignal(data), state.reads > 0, state.stage == 0,
                   !(await session.latestBackendReply).isEmpty,
                   state.offset >= state.clips[0].count {
                    if let first = state.firstAnswerAt {
                        if Date().timeIntervalSince(first) > 1.2 {
                            state.stage = 1; state.offset = 0
                            state.interruptedAt = Date()
                            state.note("interrupt_sent_during_audible_answer")
                        }
                    } else { state.firstAnswerAt = Date() }
                }
            case .transcriptFragment(let fragment):
                state.note("\(fragment.speaker): \(fragment.text)")
                if fragment.speaker == .assistant, state.stage == 1 {
                    state.afterInterruption += fragment.text
                    if state.afterInterruption.contains("蓝莓"), state.offset >= state.clips[1].count {
                        state.blueberry = true
                        state.stage = 2; state.offset = 0
                        state.note("goodbye_sent")
                    }
                }
            case .toolCall(let name, _, _):
                state.note("tool: \(name)")
                if name == VoiceTools.endCall.name { state.hangups += 1 }
            case .failed(let message):
                state.note("failure: \(message)")
                Issue.record(Comment(rawValue: message))
            default: break
            }
            coordinator.handle(event)
        }
        sender?.cancel(); timeout.cancel()
        let finalized = await session.finalized
        let report: [String: Any] = ["statusReads": state.reads, "interruptionRecognized": state.blueberry,
            "hangupTools": state.hangups, "taskActions": state.actions, "timedOut": state.timedOut,
            "finalized": finalized, "seconds": await session.usageSeconds ?? -1,
            "coordinatorIdle": coordinator.phase == .idle, "audioStopped": audio.stopped,
            "localExplicitHangup": coordinator.endedByExplicitVoiceCommand,
            "timeline": state.timeline, "postInterruptionTranscript": state.afterInterruption]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: root + "/dialogue-report.json"))
        try state.audio.write(to: URL(fileURLWithPath: root + "/dialogue-output.pcm"))
        #expect(state.reads > 0)
        #expect(state.blueberry)
        #expect(state.hangups <= 1)
        #expect(state.hangups == 1 || coordinator.endedByExplicitVoiceCommand)
        #expect(state.actions == 0)
        #expect(!state.timedOut)
        #expect(finalized && coordinator.phase == .idle && audio.stopped)
    }
}

@MainActor private final class DialogueState {
    let clips: [Data]
    let began = Date()
    var stage = 0
    var offset = 0
    var reads = 0
    var actions = 0
    var hangups = 0
    var blueberry = false
    var timedOut = false
    var firstAnswerAt: Date?
    var interruptedAt: Date?
    var afterInterruption = ""
    var audio = Data()
    var timeline: [String] = []
    init(clips: [Data]) { self.clips = clips }
    func note(_ text: String) { timeline.append(String(format: "%.2f %@", Date().timeIntervalSince(began), text)) }
    func nextChunk() -> Data {
        guard offset < clips[stage].count else { return Data(repeating: 0, count: 4800) }
        let end = min(offset + 4800, clips[stage].count)
        let result = clips[stage].subdata(in: offset..<end)
        offset = end
        return result
    }
}

@MainActor private final class DialogueAudio: VoiceCallAudio {
    var stopped = false
    var isPlaybackPending = false
    func enqueue(_ pcm: Data, item: VoiceAudioItem?) { isPlaybackPending = true }
    func flushPlayback() -> [VoicePlaybackCheckpoint] { isPlaybackPending = false; return [] }
    func stop() { stopped = true; isPlaybackPending = false }
}
