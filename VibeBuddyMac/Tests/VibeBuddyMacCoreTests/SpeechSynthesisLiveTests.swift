import Foundation
import Testing
import VibeBuddyKit

/// One real request per vendor, each behind its own environment gate so a
/// normal test run never spends money or needs a key. Keys come from the
/// environment and never reach the output — only the byte count does.
struct SpeechSynthesisLiveTests {
    private static let line = "Hello, I'm your work companion. The task is complete, and device verification is still pending."

    private static func play(_ synthesizer: any SpeechSynthesizer, key: String, outputVariable: String) async throws {
        let data = try await synthesizer.synthesize(line, apiKey: key)
        #expect(data.count > 1000)
        if let output = ProcessInfo.processInfo.environment[outputVariable] {
            try data.write(to: URL(fileURLWithPath: output))
        }
        print("received audio bytes=\(data.count)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENAI_SPEECH_E2E"] == "1"))
    func openAISpeaks() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
        try await Self.play(OpenAISpeechSynthesizer(), key: key, outputVariable: "OPENAI_SPEECH_OUTPUT")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GEMINI_SPEECH_E2E"] == "1"))
    func geminiSpeaks() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["GEMINI_API_KEY"])
        try await Self.play(GeminiSpeechSynthesizer(), key: key, outputVariable: "GEMINI_SPEECH_OUTPUT")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DOUBAO_SPEECH_E2E"] == "1"))
    func doubaoSpeaks() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["DOUBAO_API_KEY"])
        try await Self.play(DoubaoSpeechSynthesizer(), key: key, outputVariable: "DOUBAO_SPEECH_OUTPUT")
    }
}
