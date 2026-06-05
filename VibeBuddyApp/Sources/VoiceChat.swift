import Foundation
import AVFoundation
import Speech
import VibeBuddyKit

/// The voice companion: tap to talk → speech-to-text → Qwen brain (which knows
/// your live sessions) → on-device text-to-speech, and it can act on your agents
/// ("approve the payments one"). Recognition, reply, and voice all follow the
/// conversation language in Settings; the brain call uses your DashScope key.
@MainActor
final class VoiceChat: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastUserText = ""
    @Published private(set) var lastReply = ""
    @Published var errorText: String?

    var isListening: Bool { phase == .listening }
    var isSpeaking: Bool { phase == .speaking }
    /// Available as soon as the user has pasted a key — no separate enable step.
    var isAvailable: Bool { VoiceSettings.apiKey?.isEmpty == false }

    private let contextProvider: () -> [AgentSession]
    private let actionHandler: (VoiceAction) -> String
    private var history: [ChatMessage] = []

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
        guard isAvailable else { errorText = "Add your Qwen (DashScope) key in Settings first."; return }
        // The TCC completion handlers fire on a background thread, so run them off
        // the main actor (a main-actor-isolated closure would trap Swift's executor
        // check), then hop back to the main actor with the result.
        Self.requestPermissions { [weak self] speechOK, micOK in
            Task { @MainActor in
                guard let self else { return }
                guard speechOK, micOK else {
                    self.errorText = "Microphone and Speech Recognition permissions are needed."; return
                }
                self.startListening()
            }
        }
    }

    /// Runs the speech + microphone permission prompts. `nonisolated` so the SDK
    /// callbacks (delivered on a background thread) are not main-actor isolated.
    nonisolated private static func requestPermissions(_ done: @escaping @Sendable (_ speech: Bool, _ mic: Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            AVAudioApplication.requestRecordPermission { granted in
                done(auth == .authorized, granted)
            }
        }
    }

    // MARK: ASR (on-device)

    private func startListening() {
        let lang = VoiceSettings.conversationLanguage
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang.bcp47)),
              recognizer.isAvailable else { errorText = "Speech recognition is unavailable."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            // This chat runs on online models — use Apple's server-based
            // recognition rather than insisting on the on-device model.
            req.requiresOnDeviceRecognition = false
            request = req

            let input = audioEngine.inputNode
            input.removeTap(onBus: 0)
            // The tap fires on the audio render thread — keep the closure
            // non-isolated and capture the request directly (not `self`).
            nonisolated(unsafe) let tapReq = req
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
                tapReq.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            phase = .listening
            lastUserText = ""
            // The result handler is delivered off the main thread; keep it
            // non-isolated and hop back to the main actor for the @Published update.
            task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, _ in
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self?.lastUserText = text }
            }
        } catch {
            errorText = "Couldn't start recording: \(error.localizedDescription)"
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
        var messages = [ChatMessage(role: "system",
                                    content: VoicePrompt.systemPrompt(sessions: contextProvider(),
                                                                      language: VoiceSettings.conversationLanguage))]
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
            fail("Add your Qwen key in Settings first.")
        } catch VoiceBrainError.http(let code) {
            fail("Qwen request failed (HTTP \(code)).")
        } catch {
            fail("Something went wrong: \(error.localizedDescription)")
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
        utterance.voice = AVSpeechSynthesisVoice(language: VoiceSettings.conversationLanguage.bcp47)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func cancelSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        phase = .idle
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
