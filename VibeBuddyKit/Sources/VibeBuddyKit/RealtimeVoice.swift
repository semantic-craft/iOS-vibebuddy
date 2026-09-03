import Foundation

/// A provider-agnostic event from a real-time speech-to-speech session. Qwen,
/// Gemini Live, and OpenAI Realtime all map onto this, so the audio/UI layer
/// stays the same and providers are swappable.
public enum RealtimeVoiceEvent: Sendable {
    case connected
    case userTranscript(text: String, final: Bool)       // what the user said
    case assistantTranscript(text: String, final: Bool)  // what the model says
    case audioDelta(Data)                                 // PCM 24 kHz mono 16-bit, to play
    case speechStarted                                    // server VAD: user started talking → barge-in
    case responseDone
    case toolCall(name: String, arguments: String, callID: String)  // model wants to run a function tool
    case failed(String)
    case closed
}

/// A real-time speech-to-speech voice backend. Implementations stream 16 kHz mono
/// PCM16 up and emit `RealtimeVoiceEvent`s (including 24 kHz PCM16 audio) down.
public protocol RealtimeVoiceProvider: Actor {
    /// Open the session with a system prompt + voice + the function tools the model
    /// may call; returns the event stream.
    func start(instructions: String, voice: String, tools: [VoiceTool]) -> AsyncStream<RealtimeVoiceEvent>
    /// Append captured microphone audio (16 kHz mono PCM16).
    func appendAudio(_ pcm16k: Data)
    /// Return a tool call's result to the model so it can continue the turn (and
    /// speak a confirmation). `name` is required by some providers (Gemini); the
    /// OpenAI-style providers correlate on `callID` alone.
    func sendToolResult(callID: String, name: String, result: String)
    /// Tear the session down.
    func close()
}

// URLSessionWebSocketTask is Apple-platform Foundation only; the concrete
// realtime voice client is excluded from the Linux build. The provider-agnostic
// `RealtimeVoiceEvent`/`RealtimeVoiceProvider` types above remain cross-platform.
#if canImport(Darwin)

/// Alibaba Bailian / DashScope Qwen-Omni-Realtime over its OpenAI-Realtime-style
/// WebSocket (`wss://…/api-ws/v1/realtime`). One model handles ears + brain +
/// mouth: 16 kHz PCM in, 24 kHz PCM out, server-side semantic VAD.
public actor QwenRealtimeSession: RealtimeVoiceProvider {
    private let apiKey: String
    private let model: String
    private let useIntl: Bool

    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<RealtimeVoiceEvent>.Continuation?
    private var tools: [VoiceTool] = []

    public init(apiKey: String, model: String = "qwen3.5-omni-plus-realtime", useIntl: Bool = false) {
        self.apiKey = apiKey
        self.model = model
        self.useIntl = useIntl
    }

    private var endpoint: URL {
        let host = useIntl ? "dashscope-intl.aliyuncs.com" : "dashscope.aliyuncs.com"
        return URL(string: "wss://\(host)/api-ws/v1/realtime?model=\(model)")!
    }

    public func start(instructions: String, voice: String, tools: [VoiceTool]) -> AsyncStream<RealtimeVoiceEvent> {
        let (stream, cont) = AsyncStream<RealtimeVoiceEvent>.makeStream()
        continuation = cont
        self.tools = tools

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        task = socket
        socket.resume()

        configureSession(instructions: instructions, voice: voice)
        Task { await self.receiveLoop() }
        return stream
    }

    private func configureSession(instructions: String, voice: String) {
        var session: [String: Any] = [
            "modalities": ["text", "audio"],
            "voice": voice,
            "input_audio_format": "pcm",
            "output_audio_format": "pcm",
            "instructions": instructions,
            "input_audio_transcription": ["enable": true],
            "turn_detection": [
                "type": "semantic_vad",
                "threshold": 0.5,
                "silence_duration_ms": 800,
            ],
        ]
        if !tools.isEmpty {
            session["tools"] = tools.map { $0.functionSchema() }
            session["tool_choice"] = "auto"
        }
        send(["event_id": "ev_\(UUID().uuidString)", "type": "session.update", "session": session])
        continuation?.yield(.connected)
    }

    public func appendAudio(_ pcm16k: Data) {
        send(["type": "input_audio_buffer.append", "audio": pcm16k.base64EncodedString()])
    }

    public func sendToolResult(callID: String, name: String, result: String) {
        // OpenAI-Realtime shape: append the function result as a conversation item,
        // then ask the model to continue so it can speak its confirmation.
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
                let message = try await task.receive()
                switch message {
                case .string(let text): handle(text)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { handle(text) }
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
        case "response.audio.delta":
            if let b64 = obj["delta"] as? String, let audio = Data(base64Encoded: b64) {
                continuation?.yield(.audioDelta(audio))
            }
        case "response.audio_transcript.delta":
            if let delta = obj["delta"] as? String { continuation?.yield(.assistantTranscript(text: delta, final: false)) }
        case "response.audio_transcript.done":
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
