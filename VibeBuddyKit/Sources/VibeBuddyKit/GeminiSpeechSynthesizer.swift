import Foundation

/// Gemini TTS through `generateContent`'s audio response modality. The audio
/// comes back as base64 headerless PCM, which no player will open, so it is
/// wrapped in a WAV container at the rate the response declares.
public struct GeminiSpeechSynthesizer: SpeechSynthesizer {
    public static let defaultModel = "gemini-3.1-flash-tts-preview"
    public static let defaultVoice = "Zephyr"
    /// What the API documents for `audio/L16` when it names no rate.
    static let defaultSampleRate = 24_000

    let model: String
    let voice: String
    let persona: VoicePersona?

    public init(model: String = defaultModel, voice: String = defaultVoice,
                persona: VoicePersona? = nil) {
        self.model = model.isEmpty ? Self.defaultModel : model
        self.voice = voice.isEmpty ? Self.defaultVoice : voice
        self.persona = persona
    }

    /// Gemini has no instruction field — `speechConfig` carries only the voice
    /// — so style is controlled from inside the prompt, which is the documented
    /// way ("Say in a spooky whisper: …"). The lead-in therefore sits ahead of
    /// the summary, and the model reads it as direction rather than content.
    func prompt(_ text: String) -> String {
        guard let persona else { return text }
        return "\(persona.leadIn)\n\(text)"
    }

    public func synthesize(_ text: String, apiKey: String) async throws -> Data {
        let text = try SpeechSynthesisHTTP.checkedText(text, apiKey: apiKey)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw SpeechSynthesisFailure.configuration
        }
        let data = try await SpeechSynthesisHTTP.post(url,
            headers: ["x-goog-api-key": apiKey, "Accept": "application/json"],
            body: ["contents": [["role": "user", "parts": [["text": prompt(text)]]]],
                   "generationConfig": [
                       "candidateCount": 1,
                       "responseModalities": ["AUDIO"],
                       "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]],
                   ]])
        return try Self.audio(from: data)
    }

    static func audio(from data: Data) throws -> Data {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SpeechSynthesisFailure.transport
        }
        if let feedback = root["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw SpeechSynthesisFailure.rejected
        }
        guard let candidates = root["candidates"] as? [[String: Any]], let candidate = candidates.first,
              let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw SpeechSynthesisFailure.transport }
        var pcm = Data()
        var rate = defaultSampleRate
        for part in parts {
            guard let inline = part["inlineData"] as? [String: Any] else { continue }
            guard let encoded = inline["data"] as? String,
                  let chunk = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                throw SpeechSynthesisFailure.transport
            }
            if let mime = inline["mimeType"] as? String, let declared = sampleRate(in: mime) { rate = declared }
            pcm.append(chunk)
            guard pcm.count <= SpeechSynthesisHTTP.maximumBytes else { throw SpeechSynthesisFailure.excessiveAudio }
        }
        guard !pcm.isEmpty else { throw SpeechSynthesisFailure.emptyAudio }
        return SpeechSynthesisHTTP.wav(pcm16: pcm, sampleRate: rate)
    }

    /// `audio/L16;codec=pcm;rate=24000`
    static func sampleRate(in mimeType: String) -> Int? {
        for field in mimeType.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "rate",
                  let rate = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  (8_000...48_000).contains(rate) else { continue }
            return rate
        }
        return nil
    }
}
