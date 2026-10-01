import Foundation

/// MiniMax synchronous TTS. Token Plan and ordinary keys use the same China
/// endpoint; there is no automatic retry against another billing route.
public struct MiniMaxSpeechSynthesizer: SpeechSynthesizer {
    public static let defaultModel = "speech-2.8-turbo"
    public static let defaultVoice = "Chinese (Mandarin)_News_Anchor"
    let model: String
    let voice: String
    let style: VoiceStyle

    public init(model: String = defaultModel, voice: String = defaultVoice, style: VoiceStyle = .standard) {
        self.model = model.isEmpty ? Self.defaultModel : model
        self.voice = voice.isEmpty ? Self.defaultVoice : voice
        self.style = style
    }

    func requestBody(_ text: String) -> [String: Any] {
        // MiniMax has no free-form instruction channel. Voice selection and
        // the already styled summary carry the persona; these modest settings
        // are product choices, not vendor-defined equivalents of our styles.
        let speed: Double
        let pitch: Int
        switch style {
        case .standard, .serious: speed = 1; pitch = 0
        case .coquettish: speed = 1.05; pitch = 1
        case .sultry: speed = 0.9; pitch = -1
        }
        return ["model": model, "text": text, "stream": false, "output_format": "hex",
                "voice_setting": ["voice_id": voice, "speed": speed, "vol": 1, "pitch": pitch],
                "audio_setting": ["sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1]]
    }

    public func synthesize(_ text: String, apiKey: String) async throws -> Data {
        let text = try SpeechSynthesisHTTP.checkedText(text, apiKey: apiKey)
        let data = try await SpeechSynthesisHTTP.post(URL(string: "https://api.minimax.cn/v1/t2a_v2")!,
            headers: ["Authorization": "Bearer \(apiKey)"], body: requestBody(text))
        return try Self.audio(from: data)
    }

    static func audio(from data: Data) throws -> Data {
        typealias Failure = SpeechSynthesisFailure
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let base = root["base_resp"] as? [String: Any],
              let code = base["status_code"] as? Int else { throw Failure.transport }
        switch code {
        case 0: break
        case 1001: throw Failure.timedOut
        case 1002, 1039, 1041, 2045: throw Failure.rateLimited
        case 1008, 2056: throw Failure.quotaExceeded
        case 2013, 20132, 2042: throw Failure.configuration
        case 1004, 1042, 2049: throw Failure.rejected
        default: throw Failure.transport
        }
        guard let payload = root["data"] as? [String: Any] else { throw Failure.emptyAudio }
        // Non-streaming responses must be complete before the reader accepts them.
        guard payload["status"] as? Int == 2 else { throw Failure.transport }
        guard let hex = payload["audio"] as? String, !hex.isEmpty else { throw Failure.emptyAudio }
        guard hex.utf8.count <= SpeechSynthesisHTTP.maximumBytes * 2 else { throw Failure.excessiveAudio }
        let bytes = Array(hex.utf8)
        guard bytes.count.isMultiple(of: 2) else { throw Failure.transport }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var audio = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { throw Failure.transport }
            audio.append(high * 16 + low)
        }
        return audio
    }
}
