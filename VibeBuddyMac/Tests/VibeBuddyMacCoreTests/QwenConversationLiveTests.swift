import Foundation
import Testing
import VibeBuddyKit

struct QwenConversationLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_CONVERSATION_E2E"] == "1"))
    func syntheticAudioThroughRealProvider() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["SUMMARY_E2E_API_KEY"])
        let workspace = try #require(env["SUMMARY_E2E_WORKSPACE"])
        let inputPath = try #require(env["QWEN_CONVERSATION_INPUT"])
        var input = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        input.append(Data(repeating: 0, count: 16000 * 2 * 3))
        let session = QwenRealtimeSession(apiKey: key, workspaceID: workspace)
        let events = await session.start(instructions: "这是合成音频验收。听到语音后只说：收到，语音对话正常。不要调用工具。", voice: "longanqian", tools: VoiceTools.all)
        let deadline = Task { try? await Task.sleep(for: .seconds(35)); if !Task.isCancelled { await session.close() } }
        defer { deadline.cancel() }
        var sender: Task<Void, Never>?
        var bytes = 0
        var transcript = false
        var completed = false
        for await event in events {
            switch event {
            case .connected:
                guard sender == nil else { continue }
                let pcm = input
                sender = Task {
                    for offset in stride(from: 0, to: pcm.count, by: 3200) {
                        guard !Task.isCancelled else { return }
                        await session.appendAudio(pcm.subdata(in: offset..<min(offset + 3200, pcm.count)))
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            case .audioDelta(let data): bytes += data.count
            case .userTranscript(let text, _): transcript = !text.isEmpty
            case .responseDone: completed = true; await session.close()
            case .failed: Issue.record("Real Qwen conversation failed"); await session.close()
            default: break
            }
        }
        sender?.cancel()
        #expect(transcript)
        #expect(completed)
        #expect(bytes > 1000)
        print("Qwen conversation inputTranscript=\(transcript) responseDone=\(completed) outputAudioBytes=\(bytes)")
    }
}
