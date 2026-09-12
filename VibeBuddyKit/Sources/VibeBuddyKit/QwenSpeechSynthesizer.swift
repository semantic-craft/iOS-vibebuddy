import Foundation

/// Qwen-Audio 3.0 TTS, one bounded request. Only the supplied text leaves the app.
public struct QwenSpeechSynthesizer: SpeechSynthesizer {
    public static let defaultModel = "qwen-audio-3.0-tts-flash"
    public static let defaultVoice = "longanfengyue"

    let model: String
    let voice: String
    let workspaceID: String?
    let useIntl: Bool
    let persona: VoicePersona?

    public init(model: String = defaultModel, voice: String = defaultVoice,
                workspaceID: String?, useIntl: Bool, persona: VoicePersona? = nil) {
        self.model = model.isEmpty ? Self.defaultModel : model
        self.voice = voice.isEmpty ? Self.defaultVoice : voice
        self.workspaceID = workspaceID
        self.useIntl = useIntl
        self.persona = persona
    }

    /// `run-task` parameters. Alibaba's style lever is 指令控制 — the
    /// `instruction` field, which controls 方言、情感或角色 and which
    /// `qwen-audio-3.0-tts-plus` / `-flash` accept for any voice, system or
    /// cloned. Their examples are directives ("请用河南话表达。"), so the
    /// persona goes in as one. The name matters: `instruction` is the
    /// Qwen-Audio-TTS / CosyVoice spelling, while the older Qwen-TTS family
    /// spells it `instructions` — the docs warn against mixing them.
    func parameters() -> [String: Any] {
        var parameters: [String: Any] = ["text_type": "PlainText", "voice": voice, "format": "mp3",
                                         "sample_rate": 22050, "volume": 50, "rate": 1, "pitch": 1,
                                         "enable_ssml": false]
        if let persona { parameters["instruction"] = persona.directive }
        return parameters
    }

    public func synthesize(_ text: String, apiKey: String) async throws -> Data {
        typealias Failure = SpeechSynthesisFailure
        guard !text.isEmpty, text.count <= 180, !apiKey.isEmpty,
              let realtimeURL = QwenRealtimeSession.endpoint(model: model, workspaceID: workspaceID, useIntl: useIntl),
              var components = URLComponents(url: realtimeURL, resolvingAgainstBaseURL: false) else { throw Failure.configuration }
        components.path = "/api-ws/v1/inference"; components.query = nil
        guard let url = components.url else { throw Failure.configuration }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        let timeout = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let id = UUID().uuidString
            func send(_ action: String, _ payload: [String: Any]) async throws {
                let object: [String: Any] = ["header": ["action": action, "task_id": id, "streaming": "duplex"], "payload": payload]
                let bytes = try JSONSerialization.data(withJSONObject: object)
                try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
            }
            do {
                try await send("run-task", ["task_group": "audio", "task": "tts", "function": "SpeechSynthesizer",
                    "model": model, "parameters": parameters(), "input": [:]])
                var output = Data()
                var sentText = false
                while !Task.isCancelled {
                    switch try await socket.receive() {
                    case .data(let bytes):
                        output.append(bytes)
                        if output.count > 2_000_000 { throw Failure.excessiveAudio }
                    case .string(let message):
                        guard let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                              let header = object["header"] as? [String: Any], header["task_id"] as? String == id else { continue }
                        switch header["event"] as? String {
                        case "task-started" where !sentText:
                            sentText = true
                            try await send("continue-task", ["input": ["text": text]])
                            try await send("finish-task", ["input": [:]])
                        case "task-finished":
                            guard !output.isEmpty else { throw Failure.emptyAudio }
                            return output
                        case "task-failed": throw Failure.rejected
                        default: break
                        }
                    @unknown default: break
                    }
                }
                throw CancellationError()
            } catch let failure as Failure { throw failure }
              catch is CancellationError { throw CancellationError() }
              catch { throw Failure.transport }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}
