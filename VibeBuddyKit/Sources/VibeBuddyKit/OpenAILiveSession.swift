import Foundation

/// GPT-Live's continuous audio connection. Responses selects tools; the app
/// still validates and executes them. This is not the Realtime wire protocol.
public actor OpenAILiveSession: RealtimeVoiceProvider {
    public static let defaultBackendModel = "gpt-5.6-luna"
    private let apiKey: String
    private let model: String
    private let backendModel: String
    private let language: VoiceLanguage
    private var socket: URLSessionWebSocketTask?
    private var continuation: AsyncStream<RealtimeVoiceEvent>.Continuation?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var ready = false
    private var closing = false
    private var completingHangup = false
    private var toolLoop = LiveResponseTools()
    private var inputGate = LiveInputAudioGate()
    public private(set) var usageSeconds: Double?
    public private(set) var finalized = false
    public private(set) var backendInputTokens = 0
    public private(set) var backendOutputTokens = 0
    /// Backend's public answer, separate from spoken captions and private reasoning.
    public private(set) var latestBackendReply = ""

    public init(apiKey: String, model: String = "gpt-live-1",
                backendModel: String = defaultBackendModel, language: VoiceLanguage = .english) {
        self.apiKey = apiKey
        self.model = model
        self.backendModel = backendModel
        self.language = language
    }

    public func start(instructions: String, voice: String, tools: [VoiceTool]) -> AsyncStream<RealtimeVoiceEvent> {
        guard socket == nil else {
            return AsyncStream { $0.yield(.failed("OpenAI Live session is already active.")); $0.finish() }
        }
        let (stream, cont) = AsyncStream<RealtimeVoiceEvent>.makeStream()
        continuation = cont
        ready = false; closing = false; finalized = false; usageSeconds = nil
        completingHangup = false
        inputGate = LiveInputAudioGate()
        backendInputTokens = 0; backendOutputTokens = 0
        latestBackendReply = ""
        toolLoop = LiveResponseTools(allowedTools: Set(tools.map(\.name)))
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let connection = URLSession.shared.webSocketTask(with: request)
        socket = connection
        connection.resume()
        send(["type": "session.start", "session": Self.configuration(
            model: model, backendModel: backendModel, instructions: instructions,
            conversation: tools.isEmpty ? instructions : VoicePrompt.liveConversation(language: language), voice: voice, tools: tools)])
        receiver = Task { await self.receive(from: connection) }
        deadline = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, self.socket === connection, !self.ready else { return }
            self.fail("OpenAI Live connection timed out. Check network, model access and voice settings.")
        }
        return stream
    }

    static func configuration(model: String, backendModel: String, instructions: String,
                              conversation: String, voice: String, tools: [VoiceTool]) -> [String: Any] {
        ["model": model, "instructions": conversation, "store": false,
         "audio": ["format": ["type": "audio/pcm", "rate": 24000], "output": ["voice": voice]],
         "delegation": ["type": "responses", "responses": [
            "model": backendModel, "instructions": instructions,
            "tools": tools.map { tool -> [String: Any] in
                var schema = tool.functionSchema()
                schema["strict"] = false
                return schema
            },
            "tool_choice": tools.isEmpty ? "none" : "auto", "parallel_tool_calls": false,
            "max_output_tokens": 1024,
         ]]]
    }

    public func appendAudio(_ pcm24k: Data) {
        guard ready, !closing, inputGate.acceptingAudio, !pcm24k.isEmpty else { return }
        guard pcm24k.count.isMultiple(of: 2) else {
            fail("OpenAI Live requires complete PCM16 samples."); return
        }
        send(["type": "session.input_audio.append", "audio": pcm24k.base64EncodedString()], audioGeneration: inputGate.generation)
    }

    public func appendAudio(_ data: Data, ifCurrent: @escaping @Sendable () -> Bool) {
        guard ifCurrent() else { return }
        appendAudio(data)
    }

    public func setInputAudioSuspended(_ suspended: Bool) async throws {
        guard ready, !closing, let connection = socket else { throw CancellationError() }
        let command = inputGate.begin(suspended: suspended)
        send(command)
        let requestID = inputGate.pendingID
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while socket === connection, ready, !closing, inputGate.pendingID == requestID,
              ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard socket === connection, ready, !closing else { throw CancellationError() }
        guard inputGate.completedID == requestID else {
            let message = "OpenAI Live did not confirm microphone recovery. Reopen the voice conversation."
            fail(message)
            throw NSError(domain: "OpenAILiveAudioRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    public func sendToolResult(callID: String, name: String, result: String) {
        guard ready, !closing else { return }
        let commands = toolLoop.result(callID: callID, name: name, output: result)
        if name == VoiceTools.endCall.name, !commands.isEmpty { completingHangup = true }
        for command in commands { send(command) }
    }

    // Live owns speech interruption. It has no Realtime item IDs/truncate or
    // speech-start event. Transcript fragments must not cancel backend actions.
    public func truncatePlayback(_ checkpoints: [VoicePlaybackCheckpoint]) {}

    public func close() async {
        guard let connection = socket else { return }
        if !closing {
            closing = true
            inputGate.invalidate()
            deadline?.cancel()
            guard ready else { finish(); return }
            ready = false
            // The hangup receipt and its continuation must leave before close.
            // The microphone/playback have already stopped independently.
            await sender?.value
            let drainUntil = Date().addingTimeInterval(5)
            while completingHangup, socket === connection, Date() < drainUntil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard socket === connection else { return }
            send(["type": "session.close"])
            await sender?.value
            guard socket === connection else { return }
            deadline = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, self.socket === connection else { return }
                self.finish() // finalized stays false without session.closed.
            }
        }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    /// Keep audio, function outputs and response.create ordered on the wire.
    private func send(_ json: [String: Any], audioGeneration: UUID? = nil) {
        guard let connection = socket,
              let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        let previous = sender
        sender = Task {
            await previous?.value
            guard !Task.isCancelled, self.socket === connection else { return }
            if let audioGeneration, !self.inputGate.accepts(audioGeneration) { return }
            do { try await connection.send(.string(text)) }
            catch {
                guard self.socket === connection else { return }
                self.fail("OpenAI Live connection lost while sending; pending actions are not retried.")
            }
        }
    }

    private func receive(from connection: URLSessionWebSocketTask) async {
        while socket === connection {
            do {
                let message = try await connection.receive()
                guard socket === connection else { return }
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                handle(event)
            } catch {
                guard socket === connection else { return }
                let status = (connection.response as? HTTPURLResponse)?.statusCode
                fail("OpenAI Live connection failed\(status.map { " (HTTP \($0))" } ?? ""). Check network, API key and model access.")
                return
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "session.started":
            guard !ready, !closing else { return }
            deadline?.cancel(); deadline = nil; ready = true
            continuation?.yield(.connected)
        case "session.input_audio.muted", "session.input_audio.unmuted":
            guard ready, !closing else { return }
            inputGate.acknowledge(event)
        case "session.output_audio.delta":
            guard ready, !closing, let delta = event["delta"] as? String,
                  let audio = Data(base64Encoded: delta), audio.count.isMultiple(of: 2) else { return }
            continuation?.yield(.audioDelta(audio))
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard ready, !closing, let delta = event["delta"] as? String,
                  let start = event["start_ms"] as? Int, let end = event["end_ms"] as? Int else { return }
            continuation?.yield(.transcriptFragment(.init(
                speaker: event["type"] as? String == "session.input_transcript.delta" ? .user : .assistant,
                text: delta, startMilliseconds: start, endMilliseconds: end)))
        case "response.event":
            guard let nested = event["event"] as? [String: Any] else { return }
            if let type = nested["type"] as? String,
               ["response.completed", "response.failed", "response.incomplete"].contains(type) {
                completingHangup = false
            }
            if nested["type"] as? String == "response.created" { latestBackendReply = "" }
            if nested["type"] as? String == "response.output_text.delta", let delta = nested["delta"] as? String {
                latestBackendReply = String((latestBackendReply + delta).suffix(4096))
            }
            if let response = nested["response"] as? [String: Any],
               nested["type"] as? String == "response.completed", let usage = response["usage"] as? [String: Any] {
                backendInputTokens += usage["input_tokens"] as? Int ?? 0
                backendOutputTokens += usage["output_tokens"] as? Int ?? 0
            }
            guard ready, !closing else { return }
            let outcome = toolLoop.handle(event)
            if let failure = outcome.failure { fail(failure); return }
            for call in outcome.calls {
                continuation?.yield(.toolCall(name: call.name, arguments: call.arguments, callID: call.id))
            }
            for command in outcome.commands { send(command) }
        case "session.usage.updated":
            usageSeconds = (event["usage"] as? [String: Any])?["seconds"] as? Double
        case "session.closed":
            usageSeconds = (event["usage"] as? [String: Any])?["seconds"] as? Double ?? usageSeconds
            finalized = true
            finish()
        case "error":
            // Provider error bodies may echo submitted context. Don't log them.
            let rawCode = (event["error"] as? [String: Any])?["code"] as? String ?? "unknown"
            let safeCode = rawCode.count <= 80 && rawCode.utf8.allSatisfy { (97...122).contains($0) || $0 == 95 }
                ? rawCode : "unknown"
            fail("OpenAI Live rejected a request (\(safeCode)). Check the Live model, backend model, voice and account access.")
        default: break
        }
    }

    private func fail(_ message: String) {
        continuation?.yield(.failed(message))
        finish()
    }

    private func finish() {
        ready = false
        inputGate.invalidate()
        deadline?.cancel(); deadline = nil
        sender?.cancel(); sender = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        receiver?.cancel(); receiver = nil
        continuation?.yield(.closed); continuation?.finish(); continuation = nil
        let waiters = closeWaiters; closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Acknowledgments are tied to a command, not merely to the current desired
/// microphone state. Queued audio carries the generation it was captured in.
struct LiveInputAudioGate {
    private(set) var generation = UUID()
    private(set) var acceptingAudio = true
    private(set) var pendingID: String?
    private(set) var completedID: String?
    private var suspended = false

    mutating func begin(suspended: Bool) -> [String: Any] {
        generation = UUID(); acceptingAudio = false
        self.suspended = suspended
        let id = UUID().uuidString
        pendingID = id; completedID = nil
        return ["type": suspended ? "session.input_audio.mute" : "session.input_audio.unmute", "event_id": id]
    }

    mutating func acknowledge(_ event: [String: Any]) {
        guard let pendingID, event["client_event_id"] as? String == pendingID,
              event["type"] as? String == (suspended ? "session.input_audio.muted" : "session.input_audio.unmuted") else { return }
        completedID = pendingID; self.pendingID = nil
        acceptingAudio = !suspended
    }

    func accepts(_ generation: UUID) -> Bool { acceptingAudio && self.generation == generation }

    mutating func invalidate() {
        generation = UUID(); acceptingAudio = false; pendingID = nil; completedID = nil
    }
}

/// One Responses tool round at a time. Calls are not actionable until the
/// response completes successfully; every result precedes the continuation.
struct LiveResponseTools {
    struct Call {
        let id: String
        let name: String
        let arguments: String
    }
    struct Outcome {
        var calls: [Call] = []
        var commands: [[String: Any]] = []
        var failure: String?
    }
    var allowedTools: Set<String> = []
    private var responseID: String?
    private var delegationID: String?
    private var calls: [Call] = []
    private var pending: [String: String] = [:]
    private var seenCalls: Set<String> = []
    private var completedResponses: Set<String> = []

    init(allowedTools: Set<String> = []) { self.allowedTools = allowedTools }

    mutating func handle(_ envelope: [String: Any]) -> Outcome {
        guard let delegation = envelope["delegation_id"] as? String,
              let event = envelope["event"] as? [String: Any], let type = event["type"] as? String else { return .init() }
        switch type {
        case "response.created":
            guard let response = event["response"] as? [String: Any], let id = response["id"] as? String else { return .init() }
            if completedResponses.contains(id) || responseID == id { return .init() }
            guard responseID == nil, pending.isEmpty else { return .init(failure: "OpenAI Live returned overlapping tool work. Reopen the conversation; no action was retried.") }
            responseID = id; delegationID = delegation; calls = []
        case "response.output_item.done":
            guard responseID != nil, delegationID == delegation,
                  let item = event["item"] as? [String: Any], item["type"] as? String == "function_call" else { return .init() }
            guard let id = item["call_id"] as? String, !id.isEmpty,
                  let name = item["name"] as? String, allowedTools.contains(name),
                  let arguments = item["arguments"] as? String else {
                return .init(failure: "OpenAI Live returned an invalid or unavailable tool.")
            }
            guard seenCalls.insert(id).inserted else { return .init() }
            calls.append(.init(id: id, name: name, arguments: arguments))
        case "response.completed", "response.failed", "response.incomplete":
            guard let response = event["response"] as? [String: Any], let id = response["id"] as? String,
                  id == responseID, delegation == delegationID else { return .init() }
            completedResponses.insert(id); responseID = nil
            guard type == "response.completed", response["status"] as? String == "completed" else {
                calls = []; return .init(failure: "OpenAI Live backend did not complete. No pending tool action was executed.")
            }
            pending = Dictionary(uniqueKeysWithValues: calls.map { ($0.id, $0.name) })
            let result = calls; calls = []
            return .init(calls: result)
        default: break
        }
        return .init()
    }

    mutating func result(callID: String, name: String, output: String) -> [[String: Any]] {
        guard pending[callID] == name else { return [] }
        pending.removeValue(forKey: callID)
        var commands: [[String: Any]] = [["type": "response.item.create", "item": [
            "type": "function_call_output", "call_id": callID, "output": output]]]
        if pending.isEmpty { commands.append(["type": "response.create"]) }
        return commands
    }
}

public enum OpenAIVoiceSession {
    public static func usesLive(_ model: String) -> Bool {
        model == "gpt-live-1" || model.hasPrefix("gpt-live-1-")
    }

    public static func make(apiKey: String, model: String, language: VoiceLanguage = .english,
                            backendModel: String = VoiceSettings.openAILiveBackendModel()) -> any RealtimeVoiceProvider {
        if usesLive(model) {
            return OpenAILiveSession(apiKey: apiKey, model: model, backendModel: backendModel, language: language)
        }
        return OpenAIRealtimeSession(apiKey: apiKey, model: model)
    }
}
