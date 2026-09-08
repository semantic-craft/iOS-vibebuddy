import Foundation
import Testing
import VibeBuddyKit

struct QwenSpeechLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_SPEECH_E2E"] == "1"))
    func syntheticSpeech() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["SUMMARY_E2E_API_KEY"])
        let workspace = try #require(env["SUMMARY_E2E_WORKSPACE"])
        let synthesizer = QwenSpeechSynthesizer(workspaceID: workspace, useIntl: false)
        let data = try await synthesizer.synthesize("你好，我是你的工作伙伴。任务已完成，设备验证仍待进行。", apiKey: key)
        #expect(data.count > 1000)
        let output = try #require(env["QWEN_SPEECH_OUTPUT"])
        try data.write(to: URL(fileURLWithPath: output))
        print("Qwen TTS received audio bytes=\(data.count)")
    }
}
