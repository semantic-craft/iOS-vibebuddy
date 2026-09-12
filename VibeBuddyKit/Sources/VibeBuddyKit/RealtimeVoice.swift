import Foundation

/// A display-level signal check, not VAD and never an audio/action gate. Live
/// streams silent PCM too; queued silence alone must not mean "speaking".
public enum VoicePCM {
    public static func hasAudibleSignal(_ pcm: Data) -> Bool {
        pcm.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count - 1, by: 2) {
                let sample = Int(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                if abs(sample) > 96 { return true }
            }
            return false
        }
    }
}

/// Provider identity of one assistant audio content part.
public struct VoiceAudioItem: Hashable, Sendable {
    public let id: String
    public let contentIndex: Int
    public init(id: String, contentIndex: Int) {
        self.id = id
        self.contentIndex = contentIndex
    }
}

/// Conservative audible checkpoint: completed playback buffers only, never
/// generated/queued bytes. A partially played buffer may be repeated, not assumed heard.
public struct VoicePlaybackCheckpoint: Sendable {
    public let item: VoiceAudioItem
    public let audioEndMilliseconds: Int
    public init(item: VoiceAudioItem, audioEndMilliseconds: Int) {
        self.item = item
        self.audioEndMilliseconds = audioEndMilliseconds
    }
}

/// A provider-agnostic event from a real-time speech-to-speech session. Qwen,
/// Gemini Live, and OpenAI Realtime all map onto this, so the audio/UI layer
/// stays the same and providers are swappable.
public enum RealtimeVoiceEvent: Sendable {
    case connected
    case userTranscript(text: String, final: Bool)       // what the user said
    case assistantTranscript(text: String, final: Bool)  // what the model says
    case transcriptFragment(VoiceTranscriptFragment)   // continuous Live captions, never a completed turn
    case audioDelta(Data, item: VoiceAudioItem? = nil)                                 // PCM 24 kHz mono 16-bit, to play
    case speechStarted                                    // server VAD: user started talking → barge-in
    case responseDone
    case toolCallsCancelled([String])
    case toolCall(name: String, arguments: String, callID: String)  // model wants to run a function tool
    case failed(String)
    case closed
}

public struct VoiceTranscriptFragment: Sendable, Equatable {
    public enum Speaker: Sendable { case user, assistant }
    public let speaker: Speaker
    public let text: String
    public let startMilliseconds: Int
    public let endMilliseconds: Int
}

/// A real-time speech-to-speech voice backend. Implementations stream 16 kHz mono
/// PCM16 at the provider's input rate up and emit events (24 kHz PCM16 audio) down.
public protocol RealtimeVoiceProvider: Actor {
    /// Open the session with a system prompt + voice + the function tools the model
    /// may call; returns the event stream.
    func start(instructions: String, voice: String, tools: [VoiceTool]) -> AsyncStream<RealtimeVoiceEvent>
    /// Append captured microphone audio at VoiceProvider.inputSampleRate, mono PCM16.
    func appendAudio(_ pcm16k: Data)
    func appendAudio(_ data: Data, ifCurrent: @escaping @Sendable () -> Bool) async
    func setInputAudioSuspended(_ suspended: Bool) async throws
    /// Return a tool call's result to the model so it can continue the turn (and
    /// speak a confirmation). `name` is required by some providers (Gemini); the
    /// OpenAI-style providers correlate on `callID` alone. Implementations must
    /// finish socket delivery before returning, or preserve and drain the result
    /// in close(); failed delivery must terminate explicitly without retrying.
    func sendToolResult(callID: String, name: String, result: String) async
    /// Synchronize any discarded playback with providers that keep audio history.
    func truncatePlayback(_ checkpoints: [VoicePlaybackCheckpoint])
    /// Tear the session down.
    func close() async
}

public extension RealtimeVoiceProvider {
    func setInputAudioSuspended(_ suspended: Bool) async throws {}
    func appendAudio(_ data: Data, ifCurrent: @escaping @Sendable () -> Bool) async {
        guard ifCurrent() else { return }
        appendAudio(data)
    }
}

/// The socket remains ordered, but cancellation can leave old response packets
/// in flight. Filter by response identity, never by a global "ignore audio" flag
/// that might also swallow the next valid turn (including function calls).
struct RealtimeResponseFilter {
    private var currentID: String?
    private var interruptedIDs: Set<String> = []
    private var itemResponses: [String: String] = [:]
    private var callResponses: [String: String] = [:]
    private var pendingCalls: Set<String> = []

    mutating func completed(callID: String) { pendingCalls.remove(callID) }
    private(set) var cancelledCalls: [String] = []
    private(set) var rejection: String?

    mutating func accept(_ event: [String: Any]) -> Bool {
        cancelledCalls = []; rejection = nil
        let type = event["type"] as? String ?? ""
        if type == "input_audio_buffer.speech_started" {
            if let currentID {
                interruptedIDs.insert(currentID)
            }
            cancelledCalls = pendingCalls.sorted()
            for callID in pendingCalls {
                if let response = callResponses[callID] { interruptedIDs.insert(response) }
            }
            pendingCalls.removeAll()
            currentID = nil
            return true
        }
        guard type.hasPrefix("response.") else { return true }
        let explicit = event["response_id"] as? String
            ?? (event["response"] as? [String: Any])?["id"] as? String
        let item = event["item"] as? [String: Any]
        let itemID = event["item_id"] as? String ?? item?["id"] as? String
        let known = itemID.flatMap { itemResponses[$0] }
        if let explicit, let known, explicit != known {
            rejection = "Realtime tool identity conflicted. No action was executed."
            return false
        }
        let id = explicit ?? known
        if let id, interruptedIDs.contains(id) { return false }
        if let itemID, let id { itemResponses[itemID] = id }
        if type == "response.created" { currentID = id }
        // Some servers begin output before response.created. Only adopt an
        // identity when no active response is known; late packets cannot move it.
        if currentID == nil, let id { currentID = id }
        if type == "response.function_call_arguments.done" {
            guard let id, !id.isEmpty, let callID = event["call_id"] as? String, !callID.isEmpty else {
                rejection = "Realtime tool had no verifiable response identity. No action was executed."
                return false
            }
            if let previous = callResponses[callID], previous != id {
                rejection = "Realtime reused a tool identity. No action was executed."
                return false
            }
            callResponses[callID] = id
            pendingCalls.insert(callID)
        }
        return true
    }

    func canDeliverCall(_ callID: String) -> Bool { pendingCalls.contains(callID) }
}

/// Alibaba Bailian / DashScope **Qwen-Audio 3.0 Realtime** over its
/// OpenAI-Realtime-style WebSocket (`wss://…/api-ws/v1/realtime`). One duplex
/// speech model handles ears + brain + mouth: 16 kHz PCM in, 24 kHz PCM out,
/// server-side `smart_turn` turn detection, input transcription always on.
/// Verified against `qwen-audio-3.0-realtime-plus`.
public actor QwenRealtimeSession: RealtimeVoiceProvider {
    private let apiKey: String
    private let model: String
    private let workspaceID: String?
    private let useIntl: Bool

    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<RealtimeVoiceEvent>.Continuation?
    private var tools: [VoiceTool] = []
    private var responseFilter = RealtimeResponseFilter()
    private var ready = false
    private var connectionTimeout: Task<Void, Never>?
    private var instructions = ""
    private var voice = ""

    /// - Parameters:
    ///   - workspaceID: Bailian workspace ID. When given, connects through the
    ///     workspace-specific `{id}.<region>.maas.aliyuncs.com` endpoint that
    ///     Alibaba recommends; `nil` uses the shared `dashscope` domain.
    ///   - useIntl: Singapore (international) region instead of Beijing.
    public init(apiKey: String, model: String = "qwen-audio-3.0-realtime-plus",
                workspaceID: String? = nil, useIntl: Bool = false) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.workspaceID = workspaceID
        self.useIntl = useIntl
    }

    private var endpoint: URL? { Self.endpoint(model: model, workspaceID: workspaceID, useIntl: useIntl) }

    /// `nil` when the user-typed workspace ID is not a valid hostname label or
    /// the model ID is not a plain identifier — both come from free-text
    /// Settings fields, so they must never reach a force-unwrapped `URL`.
    static func endpoint(model: String, workspaceID: String?, useIntl: Bool) -> URL? {
        guard isIdentifier(model, extra: "._-") else { return nil }
        let host: String
        if let workspaceID {
            guard isIdentifier(workspaceID, extra: "-") else { return nil }
            host = "\(workspaceID).\(useIntl ? "ap-southeast-1" : "cn-beijing").maas.aliyuncs.com"
        } else {
            host = useIntl ? "dashscope-intl.aliyuncs.com" : "dashscope.aliyuncs.com"
        }
        return URL(string: "wss://\(host)/api-ws/v1/realtime?model=\(model)")
    }

    /// Non-empty ASCII letters/digits plus `extra` punctuation only.
    private static func isIdentifier(_ s: String, extra: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || extra.unicodeScalars.contains(c))
        }
    }

    public func start(instructions: String, voice: String, tools: [VoiceTool]) -> AsyncStream<RealtimeVoiceEvent> {
        let (stream, cont) = AsyncStream<RealtimeVoiceEvent>.makeStream()
        continuation = cont
        self.tools = tools
        self.instructions = instructions
        self.voice = voice
        ready = false

        guard let endpoint else {
            cont.yield(.failed("Invalid Qwen model ID or workspace ID — check Settings"))
            cont.finish()
            return stream
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        task = socket
        socket.resume()

        connectionTimeout = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self.continuation?.yield(.failed("Qwen connection timed out. Check your network, API key region and workspace in Settings."))
            self.close()
        }
        Task { await self.receiveLoop() }
        return stream
    }

    private func configureSession(instructions: String, voice: String) {
        send(["event_id": "ev_\(UUID().uuidString)", "type": "session.update",
              "session": Self.sessionConfig(instructions: instructions, voice: voice, tools: tools)])
    }

    /// Audio format is fixed by the model (PCM 16 kHz in / 24 kHz out) and input
    /// transcription is on by default, so neither is declared. `smart_turn` fuses
    /// acoustics + semantics so filler and noise don't end the user's turn; it
    /// takes no threshold / silence fields.
    static func sessionConfig(instructions: String, voice: String, tools: [VoiceTool]) -> [String: Any] {
        var session: [String: Any] = [
            "modalities": ["text", "audio"],
            "voice": voice,
            "instructions": instructions,
            "turn_detection": ["type": "smart_turn"],
        ]
        if !tools.isEmpty {
            session["tools"] = tools.map { $0.qwenFunctionSchema() }
            session["tool_choice"] = "auto"
        }
        return session
    }

    public func appendAudio(_ data: Data, ifCurrent: @escaping @Sendable () -> Bool) async {
        guard ifCurrent() else { return }
        appendAudio(data)
    }

    public func appendAudio(_ pcm16k: Data) {
        guard ready else { return }
        send(["type": "input_audio_buffer.append", "audio": pcm16k.base64EncodedString()])
    }

    public func sendToolResult(callID: String, name: String, result: String) async {
        guard let socket = task, responseFilter.canDeliverCall(callID) else { return }
        let messages: [[String: Any]] = [
            ["type": "conversation.item.create",
             "item": ["type": "function_call_output", "call_id": callID, "output": result]],
            ["type": "response.create"],
        ]
        for message in messages {
            guard task === socket, responseFilter.canDeliverCall(callID) else { return }
            guard await RealtimeToolDelivery.send(RealtimeToolDelivery.encode([message]), over: socket), task === socket else {
                if task === socket { continuation?.yield(.failed("Qwen tool result delivery failed; no action was retried.")); close() }
                return
            }
        }
        responseFilter.completed(callID: callID)
    }

    // Qwen smart_turn handles server interruption; its current API does not
    // expose conversation.item.truncate.
    public func truncatePlayback(_ checkpoints: [VoicePlaybackCheckpoint]) {}

    public func close() {
        ready = false
        connectionTimeout?.cancel()
        connectionTimeout = nil
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
                let status = (task.response as? HTTPURLResponse)?.statusCode
                continuation?.yield(.failed(Self.connectionFailure(status: status, detail: error.localizedDescription)))
                close()
                return
            }
        }
    }

    static func connectionFailure(status: Int?, detail: String) -> String {
        switch status {
        case 101: return "Qwen connection interrupted: \(detail). Check your network and reconnect."
        case 401: return "Qwen HTTP 401: API key rejected. Check that this is a DashScope API key for the selected region."
        case 403: return "Qwen HTTP 403: access denied. Check model access and the API key's workspace permissions."
        case 404: return "Qwen HTTP 404: endpoint or model not found. Check the workspace ID, region and realtime model."
        case 429: return "Qwen HTTP 429: quota or rate limit reached. Check your provider account."
        case let code?: return "Qwen HTTP \(code): \(detail). Check the API key, workspace, region and network."
        case nil: return "Qwen connection failed: \(detail). Check the API key, workspace, region and network."
        }
    }

    func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        guard responseFilter.accept(obj) else {
            if let rejection = responseFilter.rejection { continuation?.yield(.failed(rejection)) }
            return
        }
        if !responseFilter.cancelledCalls.isEmpty {
            continuation?.yield(.toolCallsCancelled(responseFilter.cancelledCalls))
        }
        switch type {
        case "session.created":
            configureSession(instructions: instructions, voice: voice)
        case "session.updated":
            guard !ready else { return }
            ready = true
            connectionTimeout?.cancel()
            connectionTimeout = nil
            continuation?.yield(.connected)
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
            let code = (obj["error"] as? [String: Any])?["code"] as? String ?? "error"
            continuation?.yield(.failed("Qwen (\(code)): \(message). Check the model, voice, API key region and workspace in Settings."))
            close()
        default:
            break
        }
    }
}

public struct VoiceToolResult: Sendable {
    public let callID: String
    public let name: String
    public let result: String
    public init(callID: String, name: String, result: String) {
        self.callID = callID; self.name = name; self.result = result
    }
}

/// A tool receipt must finish socket delivery before its caller closes the session.
/// Timeouts resolve once and cancel the affected socket; payloads never enter errors.
enum RealtimeToolDelivery {
    static func encode(_ messages: [[String: Any]]) -> [String]? {
        try? messages.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
    }

    static func send(_ messages: [String]?, over socket: URLSessionWebSocketTask) async -> Bool {
        guard let messages else { return false }
        for text in messages {
            let sent = await wait(start: { done in
                socket.send(.string(text)) { error in done(error == nil) }
            }, onTimeout: { socket.cancel(with: .goingAway, reason: nil) })
            if !sent { return false }
        }
        return true
    }

    static func wait(timeout: TimeInterval = 2,
                     start: (@escaping @Sendable (Bool) -> Void) -> Void,
                     onTimeout: @escaping @Sendable () -> Void = {}) async -> Bool {
        await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if completion.finish(false) { onTimeout() }
            }
            start { _ = completion.finish($0) }
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func finish(_ value: Bool) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
            return pending != nil
        }
    }
}
