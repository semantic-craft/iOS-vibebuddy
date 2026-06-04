import Foundation
import AVFoundation
import Speech
import VibeBuddyKit

/// The voice companion: tap to talk → on-device speech-to-text → Qwen brain
/// (which knows your live sessions) → on-device text-to-speech, and it can act
/// on your agents ("approve the payments one"). ASR/TTS are on-device (free,
/// private); only the brain call uses your DashScope key.
@MainActor
final class VoiceChat: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastUserText = ""
    @Published private(set) var lastReply = ""
    @Published var errorText: String?

    var isListening: Bool { phase == .listening }
    var isSpeaking: Bool { phase == .speaking }
    var isAvailable: Bool { VoiceSettings.enabled && VoiceSettings.apiKey?.isEmpty == false }

    private let contextProvider: () -> [AgentSession]
    private let actionHandler: (VoiceAction) -> String
    private var history: [ChatMessage] = []

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()

    init(contextProvider: @escaping () -> [AgentSession],
         actionHandler: @escaping (VoiceAction) -> String) {
        self.contextProvider = contextProvider
        self.actionHandler = actionHandler
        super.init()
        synthesizer.delegate = self
    }

    /// One control for the whole flow: start listening, or stop and send.
    func toggle() {
        switch phase {
        case .idle: requestPermissionsThenListen()
        case .listening: stopListeningAndSend()
        case .thinking, .speaking: cancelSpeaking()
        }
    }

    // MARK: permissions

    private func requestPermissionsThenListen() {
        guard isAvailable else { errorText = "先在设置里填入 Qwen (DashScope) Key 并开启语音"; return }
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    guard let self else { return }
                    guard auth == .authorized, granted else {
                        self.errorText = "需要麦克风和语音识别权限"; return
                    }
                    self.startListening()
                }
            }
        }
    }

    // MARK: ASR (on-device)

    private func startListening() {
        guard let recognizer, recognizer.isAvailable else { errorText = "语音识别暂不可用"; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true
            request = req

            let input = audioEngine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            phase = .listening
            lastUserText = ""
            task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
                guard let self, let result else { return }
                Task { @MainActor in self.lastUserText = result.bestTranscription.formattedString }
            }
        } catch {
            errorText = "无法开始录音：\(error.localizedDescription)"
            teardownAudio()
            phase = .idle
        }
    }

    private func stopListeningAndSend() {
        teardownAudio()
        let text = lastUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { phase = .idle; return }
        phase = .thinking
        Task { await self.think(text) }
    }

    private func teardownAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    // MARK: brain

    private func think(_ userText: String) async {
        let brain = QwenClient(apiKey: VoiceSettings.apiKey,
                               model: VoiceSettings.model,
                               useIntl: VoiceSettings.useIntl)
        var messages = [ChatMessage(role: "system", content: VoicePrompt.systemPrompt(sessions: contextProvider()))]
        messages += history.suffix(8)
        messages.append(ChatMessage(role: "user", content: userText))
        do {
            let raw = try await brain.reply(messages: messages)
            let (spoken, action) = VoicePrompt.parse(raw)
            history.append(ChatMessage(role: "user", content: userText))
            history.append(ChatMessage(role: "assistant", content: raw))
            var toSpeak = spoken
            if action != .none {
                let confirm = actionHandler(action)   // execute on the dashboard
                if !confirm.isEmpty { toSpeak = spoken.isEmpty ? confirm : spoken }
            }
            lastReply = toSpeak
            speak(toSpeak)
        } catch VoiceBrainError.noKey {
            fail("先在设置里填入 Qwen Key")
        } catch VoiceBrainError.http(let code) {
            fail("Qwen 请求失败 (HTTP \(code))")
        } catch {
            fail("出错了：\(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        errorText = message
        phase = .idle
    }

    // MARK: TTS (on-device)

    private func speak(_ text: String) {
        guard !text.isEmpty else { phase = .idle; return }
        phase = .speaking
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.bcp47(for: text))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func cancelSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        phase = .idle
    }

    /// Pick a voice language from the text (Chinese if it has CJK, else English).
    private static func bcp47(for text: String) -> String {
        text.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } ? "zh-CN" : "en-US"
    }
}

extension VoiceChat: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.phase == .speaking { self.phase = .idle } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.phase == .speaking { self.phase = .idle } }
    }
}
