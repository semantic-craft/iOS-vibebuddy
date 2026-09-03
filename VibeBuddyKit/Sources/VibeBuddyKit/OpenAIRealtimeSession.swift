import Foundation

// URLSessionWebSocketTask is Apple-platform Foundation only; the realtime voice
// clients are excluded from the Linux build of the shared package.
#if canImport(Darwin)

/// OpenAI Realtime (GA) speech-to-speech over `wss://api.openai.com/v1/realtime`.
/// The GA API nests audio config under `session.audio.input/output` and renames
/// the audio events to `response.output_audio.*` (the beta shape is disabled).
/// Audio is 24 kHz PCM16 in **and** out. Verified against `gpt-realtime`.
public actor OpenAIRealtimeSession: RealtimeVoiceProvider {
    private let apiKey: String
    private let model: String

    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<RealtimeVoiceEvent>.Continuation?
    private var tools: [VoiceTool] = []

    public init(apiKey: String, model: String = "gpt-realtime") {
        self.apiKey = apiKey
        self.model = model
    }

    private var endpoint: URL {
        URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!
    }

    public func start(instructions: String, voice: String, tools: [VoiceTool]) -> AsyncStream<RealtimeVoiceEvent> {
        let (stream, cont) = AsyncStream<RealtimeVoiceEvent>.makeStream()
        continuation = cont
        self.tools = tools

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")  // GA: no beta header
        let socket = URLSession.shared.webSocketTask(with: request)
        task = socket
        socket.resume()

        configureSession(instructions: instructions, voice: voice)
        Task { await self.receiveLoop() }
        return stream
    }

    private func configureSession(instructions: String, voice: String) {
        let pcm: [String: Any] = ["type": "audio/pcm", "rate": 24000]
        var session: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "instructions": instructions,
            "audio": [
                "input": [
                    "format": pcm,
                    "turn_detection": ["type": "server_vad"],
                    "transcription": ["model": "whisper-1"],
                ],
                "output": ["format": pcm, "voice": voice],
            ],
        ]
        if !tools.isEmpty {
            session["tools"] = tools.map { $0.functionSchema() }
            session["tool_choice"] = "auto"
        }
        send(["type": "session.update", "session": session])
        continuation?.yield(.connected)
    }

    public func appendAudio(_ pcm24k: Data) {
        send(["type": "input_audio_buffer.append", "audio": pcm24k.base64EncodedString()])
    }

    public func sendToolResult(callID: String, name: String, result: String) {
        send(["type": "conversation.item.create",
              "item": ["type": "function_call_output", "call_id": callID, "output": result]])
        send(["type": "response.create"])
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
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "response.output_audio.delta":
            if let b64 = obj["delta"] as? String, let audio = Data(base64Encoded: b64) {
                continuation?.yield(.audioDelta(audio))
            }
        case "response.output_audio_transcript.delta":
            if let d = obj["delta"] as? String { continuation?.yield(.assistantTranscript(text: d, final: false)) }
        case "response.output_audio_transcript.done":
            if let t = obj["transcript"] as? String { continuation?.yield(.assistantTranscript(text: t, final: true)) }
        case "conversation.item.input_audio_transcription.completed":
            if let t = obj["transcript"] as? String { continuation?.yield(.userTranscript(text: t, final: true)) }
        case "input_audio_buffer.speech_started":
            continuation?.yield(.speechStarted)
        case "response.function_call_arguments.done":
            let name = obj["name"] as? String ?? ""
            let callID = obj["call_id"] as? String ?? ""
            let args = obj["arguments"] as? String ?? "{}"
            if !name.isEmpty, !callID.isEmpty {
                continuation?.yield(.toolCall(name: name, arguments: args, callID: callID))
            }
        case "response.done":
            continuation?.yield(.responseDone)
        case "error":
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "realtime error"
            continuation?.yield(.failed(message))
        default:
            break
        }
    }
}

#endif
