import Foundation
import os

private let doubaoLog = Logger(subsystem: "com.vibebuddy.voice", category: "doubao-events")

/// Doubao Realtime 3.0. Uses the formal API session.audio and tool-items schema.
/// No provider error payloads or request headers are exposed to the event stream.
public actor DoubaoRealtimeSession: RealtimeVoiceProvider {
    private let apiKey: String
    private let model: String
    private var socket: URLSessionWebSocketTask?
    private var continuation: AsyncStream<RealtimeVoiceEvent>.Continuation?
    private var generation = UUID()
    private var ready = false
    private var closing = false
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private struct Outgoing { let text: String; let sequence: UInt64; let audioGeneration: UUID? }
    private var nextSequence: UInt64 = 0
    private var sentSequence: UInt64 = 0
    private var outgoing: [Outgoing] = []
    private var frames = DoubaoPCMFrames()
    private var muted = false
    private var inputSuspended = false
    private var audioGeneration = UUID()
    private var lastAudioAt: ContinuousClock.Instant?
    private var filter = DoubaoResponseState()
    private var calls = DoubaoToolBatch()
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(apiKey: String, model: String = "1.2.6.1") {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
    }

    public func start(instructions: String, voice: String, tools: [VoiceTool]) -> AsyncStream<RealtimeVoiceEvent> {
        let (stream, cont) = AsyncStream<RealtimeVoiceEvent>.makeStream()
        guard socket == nil else {
            cont.yield(.failed("Doubao session is already open.")); cont.finish()
            return stream
        }
        guard !apiKey.isEmpty, !model.isEmpty, !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cont.yield(.failed("Check the Doubao API key, model and voice in Settings.")); cont.finish()
            return stream
        }
        generation = UUID()
        let id = generation
        continuation = cont
        ready = false; closing = false; muted = false; inputSuspended = false
        audioGeneration = UUID()
        filter = DoubaoResponseState(); calls = DoubaoToolBatch(); frames = DoubaoPCMFrames()
        lastAudioAt = nil
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue")!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        enqueue(["type": "session.create", "session": Self.sessionConfig(model: model, instructions: instructions, voice: voice, tools: tools)])
        receiveTask = Task { await self.receiveLoop(task, generation: id) }
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, self.generation == id, !self.ready else { return }
            self.fail("Doubao connection confirmation timed out.")
        }
        return stream
    }

    static func sessionConfig(model: String, instructions: String, voice: String, tools: [VoiceTool]) -> [String: Any] {
        // Doubao `pcm` output is Float32; the shared playback contract is PCM16.
        ["model": model, "instructions": instructions,
         "audio": ["input": ["format": ["type": "pcm", "rate": 16000]],
                   "output": ["format": ["type": "pcm_s16le", "rate": 24000], "voice": voice, "speed": 0, "loudness": 0]],
         "tools": tools.map { $0.functionSchema() }]
    }

    public func appendAudio(_ pcm16k: Data) {
        guard ready, !closing, !inputSuspended, !pcm16k.isEmpty else { return }
        // Fail instead of accumulating seconds of stale microphone input on a slow link.
        guard frames.byteCount + pcm16k.count <= 32_000 else {
            fail("Doubao microphone audio fell behind realtime. Reconnect to continue."); return
        }
        frames.append(pcm16k)
        lastAudioAt = .now
    }

    public func appendAudio(_ data: Data, ifCurrent: @escaping @Sendable () -> Bool) {
        guard ifCurrent() else { return }
        appendAudio(data)
    }

    /// Device recovery is an explicit discontinuity, even when shorter than the
    /// idle detector. Keep the reset and mute boundary in the audio sender FIFO.
    public func setInputAudioSuspended(_ suspended: Bool) async throws {
        guard ready, !closing else { throw CancellationError() }
        inputSuspended = true
        audioGeneration = UUID()
        let audioID = audioGeneration
        frames = DoubaoPCMFrames()
        lastAudioAt = nil
        outgoing.removeAll { $0.audioGeneration != nil }
        let type = suspended ? "input_audio_mute.commit" : "input_audio_unmute.commit"
        guard let sequence = enqueue(["type": type]) else { throw CancellationError() }
        muted = suspended
        let id = generation
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while generation == id, audioGeneration == audioID, ready, !closing,
              sentSequence < sequence, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard generation == id, audioGeneration == audioID, ready, !closing else { throw CancellationError() }
        guard sentSequence >= sequence else {
            let message = "Doubao audio recovery command timed out. Reopen the voice conversation."
            fail(message)
            throw NSError(domain: "DoubaoAudioRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        inputSuspended = suspended
    }

    /// PCM capture pauses are detected by the paced sender, not by sending silence.
    private func pumpAudio(generation id: UUID) async {
        var pacer = DoubaoAudioPacer(now: .now)
        while !Task.isCancelled, generation == id, ready, !closing {
            if !inputSuspended, let frame = frames.next() {
                if muted { enqueue(["type": "input_audio_unmute.commit"]); muted = false }
                // The same FIFO orders unmute before the next audio frame.
                enqueue(["type": "input_audio_buffer.append", "audio": frame.base64EncodedString()], audioGeneration: audioGeneration)
            } else if !inputSuspended, !muted, lastAudioAt == nil || lastAudioAt!.duration(to: .now) >= .milliseconds(100) {
                frames = DoubaoPCMFrames() // never join a partial frame across a pause
                enqueue(["type": "input_audio_mute.commit"]); muted = true
            }
            // Preserve the 20ms clock across small scheduler delays. A missed
            // interval restarts the clock instead of bursting stale frames.
            do { try await Task.sleep(until: pacer.next(after: .now), clock: .continuous) } catch { return }
        }
    }

    public func sendToolResult(callID: String, name: String, result: String) async {
        guard ready, !closing, let items = calls.complete(callID: callID, result: result,
            endingSession: name == VoiceTools.endCall.name) else { return }
        guard let sequence = enqueue(["type": "conversation.item.create", "items": items]) else { return }
        // Wait for this exact FIFO item, not merely insertion into the queue.
        // Doubao continues from the aggregated tool items; no response.create.
        let id = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while generation == id, sentSequence < sequence, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            if Task.isCancelled { break }
        }
        if generation == id, sentSequence < sequence {
            fail("Doubao tool result delivery failed; no action was retried.")
        }
    }

    // Natural interruption follows ASR started; the official demo stops local
    // playback there and sends no response.cancel. OpenAI truncate is unsupported.
    public func truncatePlayback(_ checkpoints: [VoicePlaybackCheckpoint]) {}

    public func close() async {
        guard socket != nil else { return }
        if closing { await waitUntilClosed(); return }
        closing = true; ready = false
        audioTask?.cancel(); audioTask = nil
        timeoutTask?.cancel()
        frames = DoubaoPCMFrames()
        outgoing.removeAll()
        cancelTools()
        enqueue(["type": "session.close"])
        let id = generation
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self.generation == id else { return }
            self.finish()
        }
        await waitUntilClosed()
    }

    private func waitUntilClosed() async {
        guard socket != nil else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    private func cancelTools() {
        let ids = calls.cancel()
        if !ids.isEmpty { continuation?.yield(.toolCallsCancelled(ids)) }
    }

    private func fail(_ message: String) {
        continuation?.yield(.failed(message))
        finish()
    }

    private func finish() {
        ready = false; closing = false; inputSuspended = true
        audioGeneration = UUID()
        generation = UUID()
        timeoutTask?.cancel(); timeoutTask = nil
        receiveTask?.cancel(); receiveTask = nil
        audioTask?.cancel(); audioTask = nil
        sendTask?.cancel(); sendTask = nil
        outgoing.removeAll(); frames = DoubaoPCMFrames()
        cancelTools()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        continuation?.yield(.closed); continuation?.finish(); continuation = nil
        let waiters = closeWaiters; closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    @discardableResult
    private func enqueue(_ object: [String: Any], audioGeneration: UUID? = nil) -> UInt64? {
        guard socket != nil,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // Do not let the network FIFO defeat the realtime frame pacing.
        guard outgoing.count < 8 else { fail("Doubao audio connection is too slow. Reconnect to continue."); return nil }
        nextSequence += 1
        let sequence = nextSequence
        outgoing.append(Outgoing(text: text, sequence: sequence, audioGeneration: audioGeneration))
        if sendTask == nil {
            let id = generation
            sendTask = Task { await self.flush(generation: id) }
        }
        return sequence
    }

    private func flush(generation id: UUID) async {
        while generation == id, !Task.isCancelled, let socket, !outgoing.isEmpty {
            let message = outgoing.removeFirst()
            if let audioID = message.audioGeneration, audioID != audioGeneration { continue }
            do {
                // pumpAudio alone paces capture frames. A second delay here
                // adds send latency to every frame and grows the FIFO on a healthy link.
                try await socket.send(.string(message.text))
                guard generation == id else { return }
                sentSequence = message.sequence
            }
            catch {
                guard generation == id else { return }
                if closing { finish() } else { fail("Doubao connection failed. Check your network and API access.") }
                return
            }
        }
        if generation == id { sendTask = nil }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation id: UUID) async {
        while generation == id, !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard generation == id else { return }
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { handle(object) }
            } catch {
                guard generation == id else { return }
                if closing { finish() } else { fail("Doubao connection failed. Check your network and API access.") }
                return
            }
        }
    }

    /// The provider's cumulative hypothesis replaces the previous caption.
    static func userTranscriptionEvent(_ object: [String: Any]) -> RealtimeVoiceEvent? {
        switch object["type"] as? String {
        case "conversation.item.input_audio_transcription.delta":
            return (object["delta"] as? String).map { .userTranscript(text: $0, final: false) }
        case "conversation.item.input_audio_transcription.completed":
            let text = ["transcript", "text"].compactMap { object[$0] as? String }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return text.map { .userTranscript(text: $0, final: true) }
        default: return nil
        }
    }

    private func handle(_ object: [String: Any]) {
        guard let type = object["type"] as? String else { return }
        // Only fixed protocol names and booleans; never log payloads or identifiers.
        switch type {
        case "session.created", "session.closed", "error",
             "conversation.item.input_audio_transcription.started",
             "conversation.item.input_audio_transcription.completed",
             "conversation.item.input_audio_transcription.failed",
             "response.canceled", "response.output_audio.started",
             "response.output_audio.done", "response.done":
            doubaoLog.info("event=\(type, privacy: .public) activeResponse=\(self.filter.hasActiveResponse, privacy: .public)")
        default: break
        }
        if type == "session.closed" { finish(); return }
        if type == "error" { fail("Doubao rejected the request. Check your API access, model and voice."); return }
        guard !closing else { return }
        if type == "session.created" {
            guard !ready else { return }
            ready = true
            timeoutTask?.cancel(); timeoutTask = nil
            continuation?.yield(.connected)
            let id = generation
            audioTask = Task { await self.pumpAudio(generation: id) }
            return
        }
        guard ready else { return }
        if type == "conversation.item.input_audio_transcription.started" || type == "response.canceled" {
            if filter.hasActiveResponse || calls.hasPending { filter.interrupt() }
            cancelTools()
            continuation?.yield(.speechStarted)
            return
        }
        if type.hasPrefix("response.") {
            switch filter.accept(object) {
            case .accepted: break
            case .cancelled: return
            case .ambiguous:
                doubaoLog.error("post-interruption event missing response identity")
                fail("Doubao could not identify a response after interruption. Reopen the voice conversation to continue safely.")
                return
            }
        }
        if let event = Self.userTranscriptionEvent(object) {
            continuation?.yield(event)
            return
        }
        switch type {
        case "conversation.item.input_audio_transcription.failed":
            fail("Doubao could not transcribe the audio. Reconnect to try again.")
        case "response.output_text.delta":
            if let text = object["delta"] as? String { continuation?.yield(.assistantTranscript(text: text, final: false)) }
        case "response.output_text.done":
            if let text = object["text"] as? String { continuation?.yield(.assistantTranscript(text: text, final: true)) }
        case "response.output_audio.delta":
            if let delta = object["delta"] as? String, let audio = Data(base64Encoded: delta) {
                let item = (DoubaoResponseState.nonempty(object["response_id"]) ?? filter.audioResponseID).map { VoiceAudioItem(id: $0, contentIndex: 0) }
                continuation?.yield(.audioDelta(audio, item: item))
            }
        case "response.output_audio.done", "response.done":
            filter.responseDone()
            continuation?.yield(.responseDone)
        case "response.function_call_arguments.done":
            guard let items = object["items"] as? [[String: Any]] else { return }
            for call in calls.begin(items) { continuation?.yield(.toolCall(name: call.name, arguments: call.arguments, callID: call.id)) }
        default: break
        }
    }
}

struct DoubaoPCMFrames {
    private var bytes = Data()
    var byteCount: Int { bytes.count }
    mutating func append(_ data: Data) { bytes.append(data) }
    mutating func next() -> Data? {
        guard bytes.count >= 640 else { return nil }
        let frame = Data(bytes.prefix(640)); bytes.removeFirst(640)
        return frame
    }
}

/// Audio deltas are an ordered, identity-free stream between audio.started/done.
/// After interruption a fresh server identity must open that stream. This media
/// association never grants permission to execute an unidentified task action.
struct DoubaoResponseState {
    private var responses: Set<String> = []
    private var questions: Set<String> = []
    private var cancelledResponses: Set<String> = []
    private var cancelledQuestions: Set<String> = []
    private var interrupted = false
    private var audioSegmentOpen = false
    private(set) var audioResponseID: String?
    private(set) var hasActiveResponse = false
    mutating func responseDone() {
        hasActiveResponse = false
        audioSegmentOpen = false; audioResponseID = nil
        responses.removeAll(); questions.removeAll()
    }
    static func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
    mutating func interrupt() {
        interrupted = true; hasActiveResponse = false
        audioSegmentOpen = false; audioResponseID = nil
        cancelledResponses.formUnion(responses); cancelledQuestions.formUnion(questions)
        responses.removeAll(); questions.removeAll()
    }
    enum Acceptance: Equatable { case accepted, cancelled, ambiguous }
    mutating func accept(_ object: [String: Any]) -> Acceptance {
        let response = Self.nonempty(object["response_id"])
        let question = Self.nonempty(object["question_id"])
        if let response, cancelledResponses.contains(response) { return .cancelled }
        if let question, cancelledQuestions.contains(question) { return .cancelled }
        let type = object["type"] as? String
        if interrupted, response == nil, question == nil {
            switch type {
            case "response.output_audio.delta":
                return audioSegmentOpen ? .accepted : .cancelled
            case "response.output_text.delta", "response.output_audio.started":
                return .cancelled
            case "response.output_audio.done", "response.done":
                // Structural completion has no task side effects. It does not
                // restore trust in unidentified action calls after interruption.
                responseDone()
                return .accepted
            case "response.function_call_arguments.done":
                // A delayed read can only read the current user-selected scope.
                // Mixed batches and all task mutations retain fail-closed behavior.
                guard let items = object["items"] as? [[String: Any]], !items.isEmpty,
                      items.allSatisfy({ $0["name"] as? String == VoiceTools.status.name }) else {
                    return .ambiguous
                }
            default: return .ambiguous
            }
        }
        if type == "response.output_audio.started" {
            audioSegmentOpen = true
            audioResponseID = response
        }
        if type == "response.output_audio.done" || type == "response.done" {
            responseDone()
            return .accepted
        }
        hasActiveResponse = true
        if let response { responses.insert(response) }
        if let question { questions.insert(question) }
        return .accepted
    }
}

struct DoubaoToolBatch {
    struct Call { let id: String; let name: String; let arguments: String }
    private var batches: [[String]] = []
    private var results: [String: String] = [:]
    private var seen: Set<String> = []
    var hasPending: Bool { !batches.isEmpty }
    mutating func begin(_ items: [[String: Any]]) -> [Call] {
        let calls = items.compactMap { item -> Call? in
            guard let id = DoubaoResponseState.nonempty(item["call_id"]),
                  let name = DoubaoResponseState.nonempty(item["name"]),
                  let arguments = item["arguments"] as? String else { return nil }
            return Call(id: id, name: name, arguments: arguments)
        }
        let ids = calls.map(\.id)
        // A malformed or partially duplicated batch must not execute a subset.
        guard calls.count == items.count, !calls.isEmpty, Set(ids).count == ids.count,
              ids.allSatisfy({ !seen.contains($0) }) else { return [] }
        seen.formUnion(ids); batches.append(ids)
        return calls
    }
    mutating func complete(callID: String, result: String, endingSession: Bool = false) -> [[String: Any]]? {
        guard let index = batches.firstIndex(where: { $0.contains(callID) }), results[callID] == nil else { return nil }
        results[callID] = result
        let ids: [String]
        if endingSession {
            // The coordinator cancels remaining tasks on hangup. Resolve every
            // outstanding result without claiming that a sent action was undone.
            ids = batches.flatMap { $0 }
            for id in ids where results[id] == nil {
                results[id] = "Voice call ended; pending result collection was cancelled. Any prior action outcome is unconfirmed."
            }
            batches.removeAll()
        } else {
            ids = batches[index]
            guard ids.allSatisfy({ results[$0] != nil }) else { return nil }
            batches.remove(at: index)
        }
        return ids.map { id in
            let value = results.removeValue(forKey: id)!
            return ["call_id": id, "role": "tool", "content": [["type": "input_text", "text": value]]]
        }
    }
    mutating func cancel() -> [String] {
        let ids = batches.flatMap { $0 }; batches.removeAll(); results.removeAll()
        return ids
    }
}

/// One wall-clock interval per frame; small scheduling delays do not accumulate.
struct DoubaoAudioPacer {
    private var deadline: ContinuousClock.Instant
    init(now: ContinuousClock.Instant) { deadline = now }

    mutating func next(after now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        let scheduled = deadline.advanced(by: .milliseconds(20))
        deadline = scheduled > now ? scheduled : now.advanced(by: .milliseconds(20))
        return deadline
    }
}
