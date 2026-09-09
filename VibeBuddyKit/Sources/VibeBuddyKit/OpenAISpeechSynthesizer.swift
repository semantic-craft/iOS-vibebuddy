import Foundation

/// OpenAI `/v1/audio/speech`. Returns the encoded audio as the response body,
/// so there is nothing to decode — only the same graded failures.
public struct OpenAISpeechSynthesizer: SpeechSynthesizer {
    public static let defaultModel = "gpt-4o-mini-tts"
    public static let defaultVoice = "marin"

    let model: String
    let voice: String

    public init(model: String = defaultModel, voice: String = defaultVoice) {
        self.model = model.isEmpty ? Self.defaultModel : model
        self.voice = voice.isEmpty ? Self.defaultVoice : voice
    }

    public func synthesize(_ text: String, apiKey: String) async throws -> Data {
        let text = try SpeechSynthesisHTTP.checkedText(text, apiKey: apiKey)
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw SpeechSynthesisFailure.configuration
        }
        return try await SpeechSynthesisHTTP.post(url,
            headers: ["Authorization": "Bearer \(apiKey)", "Accept": "audio/mpeg"],
            body: ["model": model, "voice": voice, "input": text, "response_format": "mp3"])
    }
}
