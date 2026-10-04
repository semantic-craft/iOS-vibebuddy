import Foundation

/// Gemini 3.8 Interactions TTS. The transcript is separate from delivery metadata;
/// the returned complete WAV uses the same player and cancellation path as other vendors.
public struct GeminiSpeechSynthesizer: SpeechSynthesizer {
    public static let defaultModel = "gemini-3.8-flash-lite-tts"
    public static let defaultVoice = "Kore"
    private let model: String
    private let voice: String
    private let persona: VoicePersona?
    private let transport: @Sendable (URLRequest) async throws -> (Int, Data)
    // Base64 plus the response envelope, bounded before collecting the full body.
    private static let maximumResponseBytes = 3_000_000

    public init(model: String = defaultModel, voice: String = defaultVoice, persona: VoicePersona? = nil) {
        self.init(model: model, voice: voice, persona: persona, transport: Self.send)
    }

    init(model: String = defaultModel, voice: String = defaultVoice, persona: VoicePersona? = nil,
         transport: @escaping @Sendable (URLRequest) async throws -> (Int, Data)) {
        self.model = model
        self.voice = voice
        self.persona = persona
        self.transport = transport
    }

    public func synthesize(_ text: String, apiKey: String) async throws -> Data {
        try Task.checkCancellation()
        let text = try SpeechSynthesisHTTP.checkedText(text, apiKey: apiKey)
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechSynthesisFailure.configuration
        }
        var content: [String: Any] = ["type": "text", "text": text]
        if let persona {
            content["annotations"] = [["type": "speech_metadata", "style": persona.speaker]]
        }
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: SpeechSynthesisHTTP.timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "store": false,
            "input": [["type": "user_input", "content": [content]]],
            "response_format": ["type": "audio"],
            "generation_config": ["speech_config": [["voice": voice]]],
        ])
        do {
            let (status, data) = try await transport(request)
            try Task.checkCancellation()
            switch status {
            case 200..<300: break
            case 400, 404: throw SpeechSynthesisFailure.configuration
            case 401, 403: throw SpeechSynthesisFailure.rejected
            case 429: throw SpeechSynthesisFailure.rateLimited
            default: throw SpeechSynthesisFailure.transport
            }
            guard data.count <= Self.maximumResponseBytes else { throw SpeechSynthesisFailure.excessiveAudio }
            return try Self.audio(data)
        } catch is CancellationError { throw CancellationError() }
          catch let failure as SpeechSynthesisFailure { throw failure }
          catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw SpeechSynthesisFailure.timedOut
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed:
                throw SpeechSynthesisFailure.unreachable
            default: throw SpeechSynthesisFailure.transport
            }
        } catch { throw SpeechSynthesisFailure.transport }
    }

    private static func send(_ request: URLRequest) async throws -> (Int, Data) {
        let session = SpeechSynthesisHTTP.session()
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: GeminiSpeechNoRedirect())
        guard let http = response as? HTTPURLResponse else { throw SpeechSynthesisFailure.transport }
        // Error payloads are neither needed nor safe to surface.
        guard (200..<300).contains(http.statusCode) else { return (http.statusCode, Data()) }
        guard response.expectedContentLength <= maximumResponseBytes else { throw SpeechSynthesisFailure.excessiveAudio }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw SpeechSynthesisFailure.excessiveAudio }
            data.append(byte)
        }
        return (http.statusCode, data)
    }

    private static func audio(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw SpeechSynthesisFailure.emptyAudio }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["status"] as? String == "completed",
              let steps = body["steps"] as? [[String: Any]] else { throw SpeechSynthesisFailure.transport }
        let content = steps.filter { $0["type"] as? String == "model_output" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
        if content.contains(where: { $0["type"] as? String == "refusal" }) { throw SpeechSynthesisFailure.rejected }
        // Matches google-genai 2.25.0's output_audio convenience accessor.
        guard let block = content.last(where: { $0["type"] as? String == "audio" }),
              let encoded = block["data"] as? String, !encoded.isEmpty else { throw SpeechSynthesisFailure.emptyAudio }
        guard block["mime_type"] as? String == "audio/wav",
              let wav = Data(base64Encoded: encoded) else { throw SpeechSynthesisFailure.transport }
        guard !wav.isEmpty else { throw SpeechSynthesisFailure.emptyAudio }
        guard wav.count <= SpeechSynthesisHTTP.maximumBytes else { throw SpeechSynthesisFailure.excessiveAudio }
        try validateWAV(wav)
        return wav
    }

    private static func validateWAV(_ data: Data) throws {
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(bytes[offset + $1]) << (8 * $1)) }
        }
        func tag(_ offset: Int, _ value: String) -> Bool { Array(bytes[offset..<offset + 4]) == Array(value.utf8) }
        guard bytes.count >= 44, tag(0, "RIFF"), tag(8, "WAVE"), u32(4) == bytes.count - 8 else {
            throw SpeechSynthesisFailure.transport
        }
        var offset = 12
        var hasFormat = false
        var hasSamples = false
        while offset + 8 <= bytes.count {
            let length = u32(offset + 4)
            let start = offset + 8
            guard length <= bytes.count - start else { throw SpeechSynthesisFailure.transport }
            if tag(offset, "fmt ") {
                guard length >= 16, bytes[start] == 1, bytes[start + 1] == 0,
                      bytes[start + 2] == 1, bytes[start + 3] == 0,
                      u32(start + 4) == 24_000, u32(start + 8) == 48_000,
                      bytes[start + 12] == 2, bytes[start + 13] == 0,
                      bytes[start + 14] == 16, bytes[start + 15] == 0 else { throw SpeechSynthesisFailure.transport }
                hasFormat = true
            }
            if tag(offset, "data") {
                guard length > 0, length.isMultiple(of: 2) else { throw SpeechSynthesisFailure.emptyAudio }
                hasSamples = true
            }
            offset = start + length + (length % 2)
        }
        guard hasFormat, hasSamples, offset == bytes.count else { throw SpeechSynthesisFailure.transport }
    }
}

private final class GeminiSpeechNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
