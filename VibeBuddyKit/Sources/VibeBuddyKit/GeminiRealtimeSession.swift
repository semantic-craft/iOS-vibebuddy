import Foundation

/// Google Gemini Live API (`BidiGenerateContent`) speech-to-speech. A different
/// schema from the OpenAI-style providers: a `setup` message configures the
/// session, audio goes up as `realtimeInput.audio` (16 kHz PCM), and audio comes
/// down inside `serverContent.modelTurn.parts[].inlineData` (24 kHz PCM).
/// Verified against `gemini-3.1-flash-live-preview`.
public actor GeminiRealtimeSession: RealtimeVoiceProvider {
    private let apiKey: String
    private let model: String

    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<RealtimeVoiceEvent>.Continuation?
    private var ready = false   // gate audio until setupComplete

    public init(apiKey: String, model: String = "gemini-3.1-flash-live-preview") {
        self.apiKey = apiKey
        self.model = model
    }

    private var endpoint: URL {
        URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)")!
    }

    public func start(instructions: String, voice: String) -> AsyncStream<RealtimeVoiceEvent> {
        let (stream, cont) = AsyncStream<RealtimeVoiceEvent>.makeStream()
        continuation = cont

        let socket = URLSession.shared.webSocketTask(with: endpoint)
        task = socket
        socket.resume()

        let setup: [String: Any] = ["setup": [
            "model": "models/\(model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]],
            ],
            "systemInstruction": ["parts": [["text": instructions]]],
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:],
            // We run half-duplex (mic muted while the model speaks). Make the
            // server VAD less twitchy so any residual echo/noise doesn't get read
            // as the user barging in and cancel the model mid-sentence.
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                    "silenceDurationMs": 800,
                ],
            ],
        ]]
        send(setup)
        Task { await self.receiveLoop() }
        return stream
    }

    public func appendAudio(_ pcm16k: Data) {
        guard ready else { return }   // drop the first few frames until setup completes
        send(["realtimeInput": ["audio": [
            "mimeType": "audio/pcm;rate=16000",
            "data": pcm16k.base64EncodedString(),
        ]]])
    }

    public func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.yield(.closed)
        continuation?.finish()
        continuation = nil
    }

    private func send(_ json: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { await self?.yield(.failed("send: \(error.localizedDescription)")) }
        }
    }

    private func yield(_ event: RealtimeVoiceEvent) { continuation?.yield(event) }

    private func receiveLoop() async {
        guard let task else { return }
        while true {
            do {
                switch try await task.receive() {
                case .string(let text): handle(text)
                case .data(let data): if let t = String(data: data, encoding: .utf8) { handle(t) }
                @unknown default: break
                }
            } catch {
                continuation?.yield(.failed("recv: \(error.localizedDescription)"))
                continuation?.finish()
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if obj["setupComplete"] != nil {
            ready = true
            continuation?.yield(.connected)
            return
        }
        guard let server = obj["serverContent"] as? [String: Any] else { return }

        // Streamed audio + any text parts of the model's turn.
        if let modelTurn = server["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inline = part["inlineData"] as? [String: Any],
                   let b64 = inline["data"] as? String, let audio = Data(base64Encoded: b64) {
                    continuation?.yield(.audioDelta(audio))
                }
                if let t = part["text"] as? String, !t.isEmpty {
                    continuation?.yield(.assistantTranscript(text: t, final: false))
                }
            }
        }
        if let out = server["outputTranscription"] as? [String: Any], let t = out["text"] as? String {
            continuation?.yield(.assistantTranscript(text: t, final: false))
        }
        if let inp = server["inputTranscription"] as? [String: Any], let t = inp["text"] as? String {
            continuation?.yield(.userTranscript(text: t, final: false))
        }
        if server["interrupted"] as? Bool == true {
            continuation?.yield(.speechStarted)
        }
        if server["turnComplete"] as? Bool == true {
            continuation?.yield(.responseDone)
        }
    }
}
