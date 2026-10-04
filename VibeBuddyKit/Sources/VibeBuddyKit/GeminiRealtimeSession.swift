import Foundation

/// Native Developer API Live adapter. Wire fields follow google-genai 2.25.0.
/// A connection spans multiple turns; tool results are delivered before close.
public actor GeminiRealtimeSession: RealtimeVoiceProvider {
    private let model: String
    private let makeTransport: @Sendable () -> GeminiLiveTransport
    private var transport: GeminiLiveTransport?
    private var continuation: AsyncStream<RealtimeVoiceEvent>.Continuation?
    private var reader: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var ready = false
    private var suspended = false
    private var goAway = false
    private var interruptedTurn = false
    private var pending: [String: String] = [:]
    private var seen: Set<String> = []
    private var userText = ""
    private var assistantText = ""

    public init(apiKey: String, model: String = "gemini-3.8-live") {
        self.model = model
        makeTransport = { GeminiLiveTransport.connect(apiKey: apiKey) }
    }

    init(model: String, transport: GeminiLiveTransport) {
        self.model = model
        makeTransport = { transport }
    }

    public func start(instructions: String, voice: String, tools: [VoiceTool]) -> AsyncStream<RealtimeVoiceEvent> {
        close()
        let (stream, sink) = AsyncStream<RealtimeVoiceEvent>.makeStream()
        continuation = sink
        let current = generation
        let connection = makeTransport()
        transport = connection
        let setup = Self.encode(["setup": [
            "model": model.hasPrefix("models/") ? model : "models/\(model)",
            "generationConfig": ["responseModalities": ["AUDIO"], "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]]],
            "systemInstruction": ["parts": [["text": instructions]]],
            "inputAudioTranscription": [:], "outputAudioTranscription": [:],
            "tools": tools.isEmpty ? [] : [["functionDeclarations": tools.map { tool -> [String: Any] in
                var declaration = tool.functionSchema()
                declaration.removeValue(forKey: "type")
                declaration["behavior"] = "BLOCKING"
                return declaration
            }]],
        ]])
        reader = Task {
            do {
                try await connection.send(setup)
                for await message in connection.messages {
                    guard current == self.generation, !Task.isCancelled else { return }
                    self.handle(message)
                }
                guard current == self.generation, !Task.isCancelled else { return }
                if self.goAway && connection.cleanClose() { self.continuation?.yield(.providerLimitReached) }
                else { self.continuation?.yield(.failed("Gemini connection ended. Check your network, model access and quota, then reconnect.")) }
                self.close()
            } catch { self.fail(current, "Gemini connection failed. Check your API key, model access and network.") }
        }
        timeout = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, current == self.generation, !self.ready else { return }
            self.fail(current, "Gemini setup timed out. Check your API key, model and network.")
        }
        return stream
    }

    public func appendAudio(_ data: Data) {
        guard ready, !suspended else { return }
        sendAudio(data, current: generation, ifCurrent: { true })
    }

    public func appendAudio(_ data: Data, ifCurrent: @escaping @Sendable () -> Bool) async {
        guard ready, !suspended, ifCurrent() else { return }
        sendAudio(data, current: generation, ifCurrent: ifCurrent)
    }

    private func sendAudio(_ data: Data, current: UUID, ifCurrent: @escaping @Sendable () -> Bool) {
        let text = Self.encode(["realtimeInput": ["audio": ["data": data.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
        Task {
            guard current == generation, ready, !suspended, ifCurrent(), let transport else { return }
            do { try await transport.send(text) }
            catch { fail(current, "Gemini audio delivery failed. Reconnect to continue.") }
        }
    }

    public func setInputAudioSuspended(_ suspended: Bool) async throws {
        self.suspended = suspended
    }

    public func sendToolResult(callID: String, name: String, result: String) async {
        guard pending[callID] == name, let transport else { return }
        let current = generation
        // Consume identity before awaiting socket completion: duplicate delivery never retries an action.
        pending.removeValue(forKey: callID)
        let response = result.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? ["result": result]
        let text = Self.encode(["toolResponse": ["functionResponses": [["id": callID, "name": name, "response": response]]]])
        do { try await transport.send(text) }
        catch { fail(current, "Gemini tool result delivery failed; no action was retried.") }
    }

    // Gemini maintains its own interrupted audio history; no truncate API.
    public func truncatePlayback(_ checkpoints: [VoicePlaybackCheckpoint]) {}

    public func close() {
        generation = UUID()
        ready = false; suspended = false; goAway = false; interruptedTurn = false
        pending.removeAll(); seen.removeAll(); userText = ""; assistantText = ""
        timeout?.cancel(); timeout = nil
        reader?.cancel(); reader = nil
        transport?.close(); transport = nil
        continuation?.yield(.closed); continuation?.finish(); continuation = nil
    }

    private func fail(_ current: UUID, _ message: String) {
        guard current == generation else { return }
        continuation?.yield(.failed(message)); close()
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if message["error"] != nil {
            fail(generation, "Gemini rejected the session. Check your API key, model, voice and quota."); return
        }
        if message["setupComplete"] != nil, !ready {
            ready = true; timeout?.cancel(); timeout = nil; continuation?.yield(.connected)
        }
        guard ready else { return }
        if message["goAway"] != nil { goAway = true }
        if let cancellation = message["toolCallCancellation"] as? [String: Any], let ids = cancellation["ids"] as? [String] {
            ids.forEach { pending.removeValue(forKey: $0); seen.insert($0) }
            continuation?.yield(.toolCallsCancelled(ids))
        }
        if let content = message["serverContent"] as? [String: Any] {
            if content["interrupted"] as? Bool == true {
                let cancelled = Array(pending.keys).sorted(); pending.removeAll()
                continuation?.yield(.toolCallsCancelled(cancelled)); continuation?.yield(.speechStarted)
                assistantText = ""; interruptedTurn = true
            }
            if let input = content["inputTranscription"] as? [String: Any], let text = input["text"] as? String {
                userText += text
                let final = input["finished"] as? Bool == true
                continuation?.yield(.userTranscript(text: userText, final: final))
                if final { userText = "" }
            }
            if !interruptedTurn, let output = content["outputTranscription"] as? [String: Any], let text = output["text"] as? String {
                assistantText += text
                continuation?.yield(.assistantTranscript(text: text, final: false))
            }
            if !interruptedTurn, let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let blob = part["inlineData"] as? [String: Any], let b64 = blob["data"] as? String,
                       let mime = blob["mimeType"] as? String, mime.hasPrefix("audio/pcm"), let audio = Data(base64Encoded: b64) {
                        continuation?.yield(.audioDelta(audio))
                    }
                }
            }
            if content["turnComplete"] as? Bool == true {
                interruptedTurn = false
                if !userText.isEmpty { continuation?.yield(.userTranscript(text: userText, final: true)); userText = "" }
                if !assistantText.isEmpty { continuation?.yield(.assistantTranscript(text: assistantText, final: true)); assistantText = "" }
                continuation?.yield(.responseDone)
            }
        }
        if !interruptedTurn, let call = message["toolCall"] as? [String: Any], let calls = call["functionCalls"] as? [[String: Any]] {
            for call in calls {
                guard let id = call["id"] as? String, !id.isEmpty, let name = call["name"] as? String, !name.isEmpty,
                      let arguments = call["args"] as? [String: Any] else {
                    fail(generation, "Gemini sent an invalid tool identity. No action was executed."); return
                }
                guard !seen.contains(id) else { continue }
                seen.insert(id); pending[id] = name
                continuation?.yield(.toolCall(name: name, arguments: Self.encode(arguments), callID: id))
            }
        }
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Narrow injectable wire boundary for deterministic protocol replay.
struct GeminiLiveTransport: Sendable {
    let messages: AsyncStream<String>
    let send: @Sendable (String) async throws -> Void
    let close: @Sendable () -> Void
    var cleanClose: @Sendable () -> Bool = { false }

    static func connect(apiKey: String) -> Self {
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        var request = URLRequest(url: url)
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-goog-api-key")
        let socket = URLSession.shared.webSocketTask(with: request)
        let (stream, sink) = AsyncStream<String>.makeStream()
        socket.resume()
        let receive = Task {
            defer { sink.finish() }
            while !Task.isCancelled {
                do {
                    switch try await socket.receive() {
                    case .string(let text): sink.yield(text)
                    case .data(let data): if let text = String(data: data, encoding: .utf8) { sink.yield(text) }
                    @unknown default: break
                    }
                } catch { return }
            }
        }
        return Self(messages: stream, send: { text in
            let delivered = await RealtimeToolDelivery.send([text], over: socket)
            if !delivered { throw URLError(.networkConnectionLost) }
        }, close: { receive.cancel(); socket.cancel(with: .goingAway, reason: nil); sink.finish() },
        cleanClose: { socket.closeCode == .normalClosure })
    }
}
