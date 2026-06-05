import Foundation

/// Qwen text-to-speech (DashScope `qwen3-tts-flash`) — gives the companion a
/// natural voice instead of the platform's robotic synthesizer. One POST returns
/// a short-lived audio URL; we download the WAV bytes and hand them back to the
/// caller to play. Shared by iOS and Mac.
public struct QwenSpeech: Sendable {
    public var apiKey: String?
    public var useIntl: Bool
    public var model: String
    public var voice: String

    /// `Cherry` is a warm multilingual voice; `qwen3-tts-flash` speaks the same
    /// voice across languages, so one voice covers both EN and ZH.
    public init(apiKey: String?, useIntl: Bool,
                model: String = "qwen3-tts-flash", voice: String = "Cherry") {
        self.apiKey = apiKey
        self.useIntl = useIntl
        self.model = model
        self.voice = voice
    }

    private var endpoint: URL {
        let host = useIntl ? "dashscope-intl.aliyuncs.com" : "dashscope.aliyuncs.com"
        return URL(string: "https://\(host)/api/v1/services/aigc/multimodal-generation/generation")!
    }

    /// Synthesize `text` and return the WAV audio bytes.
    public func synthesize(_ text: String, language: VoiceLanguage) async throws -> Data {
        guard let apiKey, !apiKey.isEmpty else { throw VoiceBrainError.noKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model,
            input: .init(text: text, voice: voice, language_type: language.qwenTTSLanguage)))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceBrainError.badResponse }
        guard http.statusCode == 200 else { throw VoiceBrainError.http(http.statusCode) }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let urlString = decoded.output.audio?.url, let audioURL = URL(string: urlString) else {
            throw VoiceBrainError.badResponse
        }
        let (audio, audioResponse) = try await URLSession.shared.data(from: audioURL)
        guard (audioResponse as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceBrainError.badResponse }
        return audio
    }

    private struct RequestBody: Encodable {
        let model: String
        let input: Input
        struct Input: Encodable {
            let text: String
            let voice: String
            let language_type: String
        }
    }
    private struct ResponseBody: Decodable {
        struct Output: Decodable {
            struct Audio: Decodable { let url: String? }
            let audio: Audio?
        }
        let output: Output
    }
}
