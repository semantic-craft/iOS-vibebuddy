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
    private var tools: [VoiceTool] = []

    public init(apiKey: String, model: String = "gemini-3.1-flash-live-preview") {
        self.apiKey = apiKey
        self.model = model
    }

    private var endpoint: URL {
        URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)")!
    }

    public func start(instructions: String, voice: String, tools: [VoiceTool]) -> AsyncStream<RealtimeVoiceEvent> {
        let (stream, cont) = AsyncStream<RealtimeVoiceEvent>.makeStream()
        continuation = cont
        self.tools = tools

        let socket = URLSession.shared.webSocketTask(with: endpoint)
        task = socket
        socket.resume()

        var setupBody: [String: Any] = [
            "model": "models/\(model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]],
            ],
            "systemInstruction": ["parts": [["text": instructions]]],
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:],
            // Capture stays active during playback; system voice processing removes
            // echo. Retain conservative VAD sensitivity for residual noise.
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                    "silenceDurationMs": 800,
                ],
            ],
        ]
        if !tools.isEmpty {
            setupBody["tools"] = [["functionDeclarations": tools.map { $0.geminiDeclaration() }]]
        }
        send(["setup": setupBody])
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

    public func sendToolResult(callID: String, name: String, result: String) async {
        guard let socket = task else { return }
        var response: [String: Any] = ["name": name, "response": ["result": result]]
        if !callID.isEmpty { response["id"] = callID }   // correlate when the server gave an id
        let messages = RealtimeToolDelivery.encode([["toolResponse": ["functionResponses": [response]]]])
        guard await RealtimeToolDelivery.send(messages, over: socket), task === socket else {
            if task === socket { continuation?.yield(.failed("Gemini tool result delivery failed; no action was retried.")); close() }
            return
        }
    }

    // Gemini manages interrupted audio history on its server.
    public func truncatePlayback(_ checkpoints: [VoicePlaybackCheckpoint]) {}

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

        if let cancellation = obj["toolCallCancellation"] as? [String: Any],
           let ids = cancellation["ids"] as? [String] {
            continuation?.yield(.toolCallsCancelled(ids))
        }

        // Function calls arrive at the top level (not under serverContent). Args
        // come as a JSON object; serialize to a string so the event is uniform
        // with the OpenAI-style providers.
        if let toolCall = obj["toolCall"] as? [String: Any],
           let calls = toolCall["functionCalls"] as? [[String: Any]] {
            for call in calls {
                guard let name = call["name"] as? String, !name.isEmpty else { continue }
                let id = call["id"] as? String ?? ""
                let argsObject = call["args"] as? [String: Any] ?? [:]
                let argsString = (try? JSONSerialization.data(withJSONObject: argsObject))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                continuation?.yield(.toolCall(name: name, arguments: argsString, callID: id))
            }
            return
        }

        guard let server = obj["serverContent"] as? [String: Any] else { return }

        if let inp = server["inputTranscription"] as? [String: Any], let t = inp["text"] as? String {
            continuation?.yield(.userTranscript(text: t, final: false))
        }

        // An interrupted message may also carry final fragments of the old
        // model turn. Discard them and flush playback before accepting new audio.
        if server["interrupted"] as? Bool == true {
            continuation?.yield(.speechStarted)
            return
        }

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
        if server["turnComplete"] as? Bool == true {
            continuation?.yield(.responseDone)
        }
    }
}
