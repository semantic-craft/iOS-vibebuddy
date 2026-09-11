import Foundation
import Testing
@testable import VibeBuddyKit

struct OpenAILiveSessionTests {
    private func envelope(_ event: [String: Any], delegation: String = "delegation-1") -> [String: Any] {
        ["type": "response.event", "delegation_id": delegation, "event": event]
    }
    private func created(_ id: String) -> [String: Any] {
        envelope(["type": "response.created", "response": ["id": id]])
    }
    private func call(_ id: String) -> [String: Any] {
        envelope(["type": "response.output_item.done", "item": ["type": "function_call",
            "call_id": id, "name": "get_session_status", "arguments": "{}"]])
    }
    private func completed(_ id: String, status: String = "completed") -> [String: Any] {
        // Live deliberately empties response.output: do not use it to collect calls.
        envelope(["type": "response.completed", "response": ["id": id, "status": status, "output": []]])
    }

    @Test func lateExplicitResponseCannotContaminateNextResponse() {
        var loop = LiveResponseTools(allowedTools: ["get_session_status"])
        _ = loop.handle(created("old")); _ = loop.handle(completed("old"))
        _ = loop.handle(created("new"))
        var old = call("old-call")["event"] as! [String: Any]
        old["response_id"] = "old"
        _ = loop.handle(envelope(old))
        var fresh = call("new-call")["event"] as! [String: Any]
        fresh["response_id"] = "new"
        _ = loop.handle(envelope(fresh))
        #expect(loop.handle(completed("new")).calls.map(\.id) == ["new-call"])
    }

    @Test func routesLiveSeparatelyAndKeepsTheConfiguredRealtimeModel() {
        #expect(VoiceProvider.openai.defaultModel == "gpt-live-1")
        #expect(OpenAIVoiceSession.make(apiKey: "test", model: "gpt-live-1") is OpenAILiveSession)
        #expect(OpenAIVoiceSession.make(apiKey: "test", model: "gpt-realtime-2.1") is OpenAIRealtimeSession)
        let config = OpenAILiveSession.configuration(model: "gpt-live-1", backendModel: "gpt-5.6-luna",
            instructions: "backend-only", conversation: "voice-only", voice: "marin", tools: VoiceTools.conversation)
        #expect(config["instructions"] as? String == "voice-only")
        #expect(config["store"] as? Bool == false)
        let backend = (config["delegation"] as? [String: Any])?["responses"] as? [String: Any]
        #expect(backend?["instructions"] as? String == "backend-only")
        #expect((backend?["tools"] as? [[String: Any]])?.count == VoiceTools.conversation.count)
        #expect(config["turn_detection"] == nil)
    }

    @Test func allFunctionResultsPrecedeOneContinuation() {
        var loop = LiveResponseTools(allowedTools: ["get_session_status"])
        _ = loop.handle(created("r1"))
        #expect(loop.handle(call("a")).calls.isEmpty)
        _ = loop.handle(call("b"))
        _ = loop.handle(call("a")) // duplicate event cannot execute again
        let done = loop.handle(completed("r1"))
        #expect(done.calls.map(\.id) == ["a", "b"])
        #expect(loop.handle(completed("r1")).calls.isEmpty)
        #expect(loop.result(callID: "a", name: "wrong", output: "wrong").isEmpty)
        let first = loop.result(callID: "a", name: "get_session_status", output: "first")
        #expect(first.compactMap { $0["type"] as? String } == ["response.item.create"])
        let last = loop.result(callID: "b", name: "get_session_status", output: "second")
        #expect(last.compactMap { $0["type"] as? String } == ["response.item.create", "response.create"])
        #expect(last.last?.count == 1)
        #expect(loop.result(callID: "b", name: "get_session_status", output: "repeat").isEmpty)
    }

    @Test func failedOrOverlappingResponsesNeverReleaseActions() {
        var loop = LiveResponseTools(allowedTools: ["get_session_status"])
        _ = loop.handle(created("r1")); _ = loop.handle(call("a"))
        let failed = loop.handle(completed("r1", status: "cancelled"))
        #expect(failed.calls.isEmpty)
        #expect(failed.failure != nil)
        #expect(loop.result(callID: "a", name: "get_session_status", output: "late").isEmpty)
        _ = loop.handle(created("r2"))
        #expect(loop.handle(created("r3")).failure != nil)
    }

    @Test @MainActor func continuousCaptionsDoNotCancelActionsAndPlaybackDrivesPhase() async {
        let audio = LiveTestAudio()
        var statusReads = 0
        var results: [String] = []
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "" },
            sendToolResult: { _, _, value in results.append(value) }, continuousPlayback: true,
            contextProvider: { statusReads += 1; return [] })
        coordinator.handle(.connected)
        coordinator.handle(.audioDelta(Data([0xe8, 0x03])))
        #expect(coordinator.phase == .speaking)
        coordinator.handle(.transcriptFragment(.init(speaker: .user, text: "再见", startMilliseconds: 0, endMilliseconds: 50)))
        coordinator.handle(.transcriptFragment(.init(speaker: .user, text: "是什么意思？", startMilliseconds: 50, endMilliseconds: 100)))
        #expect(coordinator.lastUserText == "再见是什么意思？")
        #expect(!audio.stopped)
        #expect(audio.flushes == 0)
        coordinator.handle(.transcriptFragment(.init(speaker: .assistant, text: "Hello", startMilliseconds: 0, endMilliseconds: 80)))
        coordinator.handle(.transcriptFragment(.init(speaker: .assistant, text: " again", startMilliseconds: 80, endMilliseconds: 150)))
        #expect(coordinator.lastReply == "Hello again")
        audio.isAudiblePlaybackPending = false; coordinator.playbackDrained()
        #expect(coordinator.phase == .listening) // no synthetic responseDone needed
        #expect(audio.isPlaybackPending) // silent audio can still be queued
        coordinator.handle(.audioDelta(Data(repeating: 0, count: 4800)))
        #expect(coordinator.phase == .listening)
        coordinator.handle(.toolCall(name: VoiceTools.status.name, arguments: "{}", callID: "status"))
        for _ in 0..<100 where results.isEmpty { await Task.yield() }
        #expect(statusReads == 1)
        #expect(results.first?.contains("sessions") == true)
    }

    @Test @MainActor func resumedTasksDoNotResurfaceAnOldWaitOrAllowOutOfScopeActions() async throws {
        let now = Date()
        let running = AgentSession(id: "test", agent: .codex, project: "selected", status: .working,
            summary: "Please confirm the key before I can proceed.", statusSince: now, updatedAt: now)
        let context = VoicePrompt.sessionContext([running])
        #expect(!context.contains("confirm the key"))
        var actions = 0
        var results: [String] = []
        let coordinator = VoiceCallCoordinator(audio: LiveTestAudio(), actionHandler: { _ in actions += 1; return "sent" },
            sendToolResult: { _, _, value in results.append(value) }, continuousPlayback: true,
            contextProvider: { [running] })
        coordinator.handle(.toolCall(name: "approve_session", arguments: #"{"project":"not-selected"}"#, callID: "out"))
        for _ in 0..<100 where results.isEmpty { await Task.yield() }
        #expect(actions == 0)
        #expect(results.first?.contains("no action was sent") == true)
    }

    @Test @MainActor func hangupStopsAudioAndCarriesOneReceiptIntoClose() async {
        let audio = LiveTestAudio()
        var receipts: [VoiceToolResult] = []
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "unexpected" },
            closeSession: { result in
                #expect(audio.stopped)
                if let result { receipts.append(result) }
            }, continuousPlayback: true)
        coordinator.handle(.connected)
        coordinator.handle(.toolCall(name: VoiceTools.endCall.name, arguments: "{}", callID: "hangup"))
        for _ in 0..<100 where receipts.isEmpty { await Task.yield() }
        coordinator.stop()
        #expect(coordinator.phase == .idle)
        #expect(receipts.count == 1)
        #expect(receipts.first?.callID == "hangup")
        #expect(receipts.first?.name == VoiceTools.endCall.name)
    }

    @Test @MainActor func explicitLiveHangupReleasesAudioWithoutAProviderTool() async {
        let audio = LiveTestAudio()
        var closes = 0
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "unexpected" },
            closeSession: { _ in closes += 1 }, continuousPlayback: true)
        coordinator.handle(.connected)
        coordinator.handle(.transcriptFragment(.init(speaker: .user,
            text: "请立即挂断这次语音通话", startMilliseconds: 0, endMilliseconds: 2400)))
        #expect(!audio.stopped)
        try? await Task.sleep(for: .milliseconds(900))
        #expect(audio.stopped && coordinator.phase == .idle && closes == 1)
        #expect(coordinator.endedByExplicitVoiceCommand)
    }

    @Test @MainActor func continuingAQuotedHangupDoesNotCloseTheCall() async {
        let audio = LiveTestAudio()
        let coordinator = VoiceCallCoordinator(audio: audio, actionHandler: { _ in "unexpected" }, continuousPlayback: true)
        coordinator.handle(.connected)
        coordinator.handle(.transcriptFragment(.init(speaker: .user,
            text: "挂断通话", startMilliseconds: 0, endMilliseconds: 400)))
        coordinator.handle(.transcriptFragment(.init(speaker: .user,
            text: "是什么意思？", startMilliseconds: 400, endMilliseconds: 900)))
        try? await Task.sleep(for: .milliseconds(900))
        #expect(!audio.stopped && !coordinator.endedByExplicitVoiceCommand)
    }

    /// Opt-in actual provider check. Credentials never enter assertions/logs;
    /// input is a synthetic spoken query and the context is a scoped local snapshot.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_LIVE_E2E"] == "1"))
    func realLiveConversationAndDelegation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = KeychainStore.get("openai.apiKey"), !key.isEmpty else {
            Issue.record("Existing OpenAI credential is unavailable"); return
        }
        let inputPath = try #require(env["VIBEBUDDY_LIVE_AUDIO"])
        let contextPath = try #require(env["VIBEBUDDY_LIVE_CONTEXT"])
        let audio = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let sessions = try JSONDecoder().decode([AgentSession].self, from: Data(contentsOf: URL(fileURLWithPath: contextPath)))
        let context = VoicePrompt.sessionContext(sessions)
        let session = OpenAILiveSession(apiKey: key,
            backendModel: env["VIBEBUDDY_LIVE_BACKEND"] ?? OpenAILiveSession.defaultBackendModel, language: .chinese)
        let events = await session.start(instructions: VoicePrompt.liveBackend(language: .chinese),
                                         voice: "marin", tools: [VoiceTools.status])
        let timeout = Task {
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled { await session.close() }
        }
        defer { timeout.cancel() }
        var sender: Task<Void, Never>?
        var outputBytes = 0
        var heardUser = false
        var saidAnswer = false
        var tools = 0
        var firstToolAt: Date?
        var answer = ""
        var receivedAudio = Data()
        for await event in events {
            switch event {
            case .connected:
                sender = Task {
                    // Keep silence flowing after the query: Live advances with audio.
                    for index in 0..<400 {
                        guard !Task.isCancelled else { return }
                        let offset = index * 4800
                        let chunk = offset < audio.count ? audio.subdata(in: offset..<min(offset + 4800, audio.count)) : Data(repeating: 0, count: 4800)
                        await session.appendAudio(chunk)
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            case .audioDelta(let data, _): outputBytes += data.count; receivedAudio.append(data)
            case .transcriptFragment(let fragment):
                if fragment.speaker == .user { heardUser = true }
                if fragment.speaker == .assistant {
                    answer += fragment.text
                    if tools > 0 { saidAnswer = true }
                }
            case .toolCall(let name, _, let callID):
                #expect(name == VoiceTools.status.name)
                tools += 1
                if firstToolAt == nil { firstToolAt = Date() }
                await session.sendToolResult(callID: callID, name: name, result: context)
            case .failed(let message): Issue.record(Comment(rawValue: message))
            default: break
            }
            if saidAnswer, outputBytes > 1000, let firstToolAt, Date().timeIntervalSince(firstToolAt) > 24 {
                await session.close()
            }
        }
        sender?.cancel()
        #expect(heardUser && saidAnswer && tools > 0 && outputBytes > 1000)
        #expect(await session.finalized)
        if let output = env["VIBEBUDDY_LIVE_OUTPUT"] {
            try receivedAudio.write(to: URL(fileURLWithPath: output + ".pcm"))
            try answer.write(toFile: output + ".txt", atomically: true, encoding: .utf8)
            try await session.latestBackendReply.write(toFile: output + "-backend.txt", atomically: true, encoding: .utf8)
        }
        print("Live E2E userTranscript=\(heardUser) delegatedTools=\(tools) answerTranscript=\(saidAnswer) outputAudioBytes=\(outputBytes) finalized=\(await session.finalized) seconds=\(await session.usageSeconds ?? -1)")
    }
}

@MainActor private final class LiveTestAudio: VoiceCallAudio {
    var isPlaybackPending = false
    var isAudiblePlaybackPending = false
    var stopped = false
    var flushes = 0
    func enqueue(_ pcm: Data, item: VoiceAudioItem?) {
        isPlaybackPending = true
        isAudiblePlaybackPending = isAudiblePlaybackPending || VoicePCM.hasAudibleSignal(pcm)
    }
    func flushPlayback() -> [VoicePlaybackCheckpoint] { flushes += 1; isPlaybackPending = false; return [] }
    func stop() { stopped = true }
}
