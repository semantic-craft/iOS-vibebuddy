import Foundation
import Testing
@testable import VibeBuddyKit

struct GeminiSpeechTests {
    @Test func exactTextAndStyleProducePlayableWAV() async throws {
        // A valid 24 kHz PCM16 WAV containing one sample.
        let wav = Data(base64Encoded: "UklGRiYAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQIAAAAAAA==")!
        let synth = GeminiSpeechSynthesizer(persona: VoiceStyle.serious.persona(.chinese)) { request in
            #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            #expect(body["store"] as? Bool == false)
            let input = try #require(body["input"] as? [[String: Any]])
            let content = try #require(input.first?["content"] as? [[String: Any]])
            #expect(content.first?["text"] as? String == "测试通过 12 项，设备验收待完成。")
            #expect((content.first?["annotations"] as? [[String: String]])?.first?["type"] == "speech_metadata")
            return (200, try JSONSerialization.data(withJSONObject: ["status": "completed", "steps": [["type": "model_output", "content": [["type": "audio", "mime_type": "audio/wav", "data": wav.base64EncodedString()]]]]]))
        }
        #expect(try await synth.synthesize("测试通过 12 项，设备验收待完成。", apiKey: "test-key") == wav)
    }
    @Test func geminiFollowsSummaryOrKeepsIndependentPreferences() throws {
        let name = "gemini-tts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("gemini", forKey: VoiceSettings.summaryProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.gemini))
        defaults.set("gemini", forKey: VoiceSettings.readAloudProviderKey)
        defaults.set("qwen", forKey: VoiceSettings.summaryProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.gemini))
        #expect(VoiceSettings.readAloudVoice(.gemini, language: .chinese, defaults: defaults) == "Kore")
        #expect(SpeechSynthesis.supportsStyle(.gemini))
        let config = SpeechSynthesisConfiguration(provider: .gemini, model: "my-tts", voice: "Puck", style: .serious, language: .chinese)
        #expect(config.effectiveModel == "my-tts")
        #expect(config.effectiveVoice == "Puck")
    }

    @Test func rejectedMalformedOrCancelledAudioNeverReachesPlayer() async throws {
        for (status, expected) in [(400, SpeechSynthesisFailure.configuration), (401, .rejected), (429, .rateLimited), (503, .transport)] {
            let synth = GeminiSpeechSynthesizer { _ in (status, Data("secret response".utf8)) }
            await #expect(throws: expected) { try await synth.synthesize("hello", apiKey: "test") }
        }
        let wav = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQIAAAAAAA=="
        for (mime, encoded, expected) in [("audio/l16", wav, SpeechSynthesisFailure.transport),
                                           ("audio/wav", "", .emptyAudio),
                                           ("audio/wav", "bm90IGEgd2F2", .transport),
                                           ("audio/wav", Data(repeating: 0, count: 2_000_001).base64EncodedString(), .excessiveAudio)] {
            let synth = GeminiSpeechSynthesizer { _ in
                (200, try JSONSerialization.data(withJSONObject: ["status": "completed", "steps": [["type": "model_output", "content": [["type": "audio", "mime_type": mime, "data": encoded]]]]]))
            }
            await #expect(throws: expected) { try await synth.synthesize("hello", apiKey: "test") }
        }
        let task = Task {
            let synth = GeminiSpeechSynthesizer { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return (200, Data())
            }
            return try await synth.synthesize("hello", apiKey: "test")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GEMINI_SPEECH_ACCEPTANCE"] == "1"))
    func liveGeminiSpeech() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["GEMINI_API_KEY"])
        let line = "任务已完成，12 项检查通过。SwiftUI 设备验收仍待完成。"
        let data = try await GeminiSpeechSynthesizer().synthesize(line, apiKey: key)
        #expect(data.count > 1_000)
        if let output = ProcessInfo.processInfo.environment["GEMINI_SPEECH_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        print("Gemini generated WAV bytes=\(data.count); device listening not verified")
    }

}
