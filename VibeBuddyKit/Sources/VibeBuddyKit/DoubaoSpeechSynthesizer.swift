import Foundation

/// Doubao 语音合成大模型 2.0 over the unidirectional streaming HTTP endpoint.
///
/// Auth is the header `X-Api-Key` holding the same key Doubao realtime already
/// uses, so read-aloud needs no credential of its own — the accounts table
/// keeps one field per provider. `X-Api-Resource-Id` is a fixed model-version
/// constant, not a secret. Accounts still on the legacy console need an appid
/// and access token instead; that is deliberately not offered here, and such a
/// key simply comes back rejected.
public struct DoubaoSpeechSynthesizer: SpeechSynthesizer {
    /// The header value, not a model the user types — Doubao's "model" is the
    /// resource id, and the voice carries the rest.
    public static let defaultModel = "seed-tts-2.0"
    public static let defaultVoice = "zh_female_vv_uranus_bigtts"

    let model: String
    let voice: String

    public init(model: String = defaultModel, voice: String = defaultVoice) {
        self.model = model.isEmpty ? Self.defaultModel : model
        self.voice = voice.isEmpty ? Self.defaultVoice : voice
    }

    public func synthesize(_ text: String, apiKey: String) async throws -> Data {
        let text = try SpeechSynthesisHTTP.checkedText(text, apiKey: apiKey)
        guard let url = URL(string: "https://openspeech.bytedance.com/api/v3/tts/unidirectional") else {
            throw SpeechSynthesisFailure.configuration
        }
        let data = try await SpeechSynthesisHTTP.post(url,
            headers: ["X-Api-Key": apiKey,
                      "X-Api-Resource-Id": model,
                      "X-Api-Request-Id": UUID().uuidString,
                      "Accept": "application/json"],
            body: ["req_params": ["text": text, "speaker": voice,
                                  "audio_params": ["format": "mp3", "sample_rate": 24_000]]])
        return try Self.audio(from: data)
    }

    /// The endpoint streams a sequence of JSON objects, one per audio chunk;
    /// the body therefore holds several concatenated objects, not one.
    static func audio(from data: Data) throws -> Data {
        var audio = Data()
        var sawObject = false
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty,
                  let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            else { continue }
            sawObject = true
            if let code = object["code"] as? Int, code != 0 {
                // Their codes distinguish auth from quota; nothing they said is repeated.
                throw code == 401 || code == 403 ? SpeechSynthesisFailure.rejected
                    : code == 429 ? .rateLimited : .transport
            }
            guard let encoded = object["data"] as? String, !encoded.isEmpty else { continue }
            guard let chunk = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                throw SpeechSynthesisFailure.transport
            }
            audio.append(chunk)
            guard audio.count <= SpeechSynthesisHTTP.maximumBytes else { throw SpeechSynthesisFailure.excessiveAudio }
        }
        guard sawObject else { throw SpeechSynthesisFailure.transport }
        guard !audio.isEmpty else { throw SpeechSynthesisFailure.emptyAudio }
        return audio
    }
}
