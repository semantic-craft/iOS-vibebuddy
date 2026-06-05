import Foundation
import AVFoundation
import AppKit
import Speech
import os
import VibeBuddyKit

private let voiceLog = Logger(subsystem: "com.vibebuddy.mac", category: "voice")

/// The Mac voice companion: tap the buddy to talk → speech-to-text → Qwen brain
/// (knows your live sessions, your key) → on-device text-to-speech, and it can
/// act on your agents. Recognition, reply, and voice all follow the conversation
/// language in Settings. Mirrors the iOS flow without `AVAudioSession`.
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
    private var audioPlayer: AVAudioPlayer?

    // Omni-realtime (qwen3.5-omni-flash-realtime) — the active speech-to-speech path.
    private var realtime: QwenRealtimeSession?
    private var audioIO: RealtimeAudioIO?
    private var eventTask: Task<Void, Never>?
    private var assistantBuffer = ""

    init(contextProvider: @escaping () -> [AgentSession],
         actionHandler: @escaping (VoiceAction) -> String) {
        self.contextProvider = contextProvider
        self.actionHandler = actionHandler
        super.init()
        synthesizer.delegate = self
    }

    func toggle() {
        voiceLog.info("toggle in phase=\(String(describing: self.phase), privacy: .public) available=\(self.isAvailable, privacy: .public)")
        switch phase {
        case .idle: startRealtime()
        default: stopRealtime()
        }
    }

    // MARK: Omni-realtime speech-to-speech (active path)

    private func startRealtime() {
        errorText = nil
        guard isAvailable else { errorText = "Add your Qwen (DashScope) key in Settings first."; return }
        // An accessory (menu-bar) app must be active for the mic TCC prompt to show.
        NSApp.activate(ignoringOtherApps: true)
        Self.requestPermissions { [weak self] _, micOK in
            Task { @MainActor in
                guard let self else { return }
                guard micOK else { self.errorText = "Microphone permission needed (System Settings › Privacy › Microphone)."; return }
                self.beginRealtimeSession()
            }
        }
    }

    private func beginRealtimeSession() {
        let language = VoiceSettings.conversationLanguage
        let instructions = VoicePrompt.systemPrompt(sessions: contextProvider(), language: language)
            + "\n\nThis is a live voice call. Stay silent until the user actually speaks — never start talking on your own or fill silence, and never reply to your own voice. Answer in one short, natural sentence unless asked for more, and don't repeat yourself. Speak in a calm, gentle, even tone at a steady volume; never suddenly raise your pitch, shout, or get loud."
        let session = QwenRealtimeSession(apiKey: VoiceSettings.apiKey ?? "",
                                          model: VoiceSettings.qwenRealtimeModel,
                                          useIntl: VoiceSettings.useIntl)
        let io = RealtimeAudioIO()
        realtime = session
        audioIO = io
        assistantBuffer = ""
        lastUserText = ""; lastReply = ""
        phase = .listening

        let voice = VoiceSettings.realtimeVoice
        eventTask = Task { [weak self] in
            let stream = await session.start(instructions: instructions, voice: voice)
            for await event in stream {
                await self?.handleRealtime(event)
            }
        }
        io.onAudioFrame = { @Sendable data in Task { await session.appendAudio(data) } }
        io.onPlaybackDrained = { [weak self] in
            Task { @MainActor in
                guard let self, let io = self.audioIO else { return }
                io.micMuted = false           // model finished speaking → listen again
                if self.phase == .speaking { self.phase = .listening }
            }
        }
        do {
            try io.start()
        } catch {
            voiceLog.error("realtime audio start failed: \(String(describing: error), privacy: .public)")
            errorText = "Couldn't start audio: \(error.localizedDescription)"
            stopRealtime()
        }
    }

    private func handleRealtime(_ event: RealtimeVoiceEvent) {
        switch event {
        case .connected:
            voiceLog.info("realtime connected")
        case .userTranscript(let text, _):
            lastUserText = text
        case .assistantTranscript(let text, let final):
            if final { lastReply = text; assistantBuffer = "" }
            else { assistantBuffer += text; lastReply = assistantBuffer }
        case .audioDelta(let pcm):
            audioIO?.micMuted = true        // half-duplex: don't hear ourselves
            phase = .speaking
            audioIO?.enqueue(pcm)
        case .speechStarted:           // server detected real user speech
            break
        case .responseDone:
            phase = .listening
        case .failed(let message):
            voiceLog.error("realtime failed: \(message, privacy: .public)")
            errorText = message
            stopRealtime()          // tear down cleanly so the next tap starts fresh
        case .closed:
            break
        }
    }

    private func stopRealtime() {
        eventTask?.cancel(); eventTask = nil
        audioIO?.stop(); audioIO = nil
        let session = realtime
        realtime = nil
        Task { await session?.close() }
        phase = .idle
    }

    private func requestPermissionsThenListen() {
        errorText = nil
        guard isAvailable else { errorText = "Add your Qwen (DashScope) key in Settings first."; return }
        // An accessory (menu-bar) app must be active for the mic TCC prompt to show.
        NSApp.activate(ignoringOtherApps: true)
        // TCC delivers these completion handlers on a background XPC thread, so the
        // request must run off the main actor — a main-actor-isolated closure would
        // trip Swift's executor check and trap. Results hop back to the main actor.
        Self.requestPermissions { [weak self] speechOK, micOK in
            Task { @MainActor in
                guard let self else { return }
                guard speechOK else { self.errorText = "Speech Recognition permission needed (System Settings › Privacy › Speech Recognition)."; return }
                guard micOK else { self.errorText = "Microphone permission needed (System Settings › Privacy › Microphone)."; return }
                self.startListening()
            }
        }
    }

    /// Runs the speech + microphone TCC prompts. `nonisolated` so the SDK callbacks
    /// (delivered on a background thread) are not main-actor isolated, then reports
    /// the two grants back through a `Sendable` closure.
    nonisolated private static func requestPermissions(_ done: @escaping @Sendable (_ speech: Bool, _ mic: Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { auth in
            voiceLog.info("speech auth=\(auth.rawValue, privacy: .public)")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                voiceLog.info("mic granted=\(granted, privacy: .public)")
                done(auth == .authorized, granted)
            }
        }
    }

    private func startListening() {
        let lang = VoiceSettings.conversationLanguage
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: lang.bcp47)),
              recognizer.isAvailable else { errorText = "Speech recognition is unavailable."; return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // This chat runs on online models — use Apple's server-based recognition
        // (more reliable across locales and on a fresh Mac) rather than on-device.
        req.requiresOnDeviceRecognition = false
        voiceLog.info("startListening locale=\(lang.bcp47, privacy: .public)")
        request = req

        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        // The tap fires on the audio render thread — keep the closure non-isolated
        // and capture the request directly (not `self`) so it never touches the
        // main actor.
        nonisolated(unsafe) let tapReq = req
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
            tapReq.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            errorText = "Couldn't start recording: \(error.localizedDescription)"; teardownAudio(); phase = .idle; return
        }
        phase = .listening
        lastUserText = ""
        // The result handler is also delivered off the main thread; keep it
        // non-isolated and hop back to the main actor for the @Published update.
        task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in self?.lastUserText = text }
        }
    }

    private func stopListeningAndSend() {
        teardownAudio()
        let text = lastUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceLog.info("heard \(text.count, privacy: .public) chars")
        guard !text.isEmpty else { errorText = "Didn't catch that — try again."; phase = .idle; return }
        phase = .thinking
        Task { await self.think(text) }
    }

    private func teardownAudio() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        request?.endAudio(); task?.cancel(); request = nil; task = nil
    }

    private func think(_ userText: String) async {
        let brain = QwenClient(apiKey: VoiceSettings.apiKey, model: VoiceSettings.model, useIntl: VoiceSettings.useIntl)
        var messages = [ChatMessage(role: "system",
                                    content: VoicePrompt.systemPrompt(sessions: contextProvider(),
                                                                      language: VoiceSettings.conversationLanguage))]
        messages += history.suffix(8)
        messages.append(ChatMessage(role: "user", content: userText))
        do {
            let raw = try await brain.reply(messages: messages)
            voiceLog.info("brain replied \(raw.count, privacy: .public) chars")
            let (spoken, action) = VoicePrompt.parse(raw)
            history.append(ChatMessage(role: "user", content: userText))
            history.append(ChatMessage(role: "assistant", content: raw))
            var toSpeak = spoken
            if action != .none {
                let confirm = actionHandler(action)
                if !confirm.isEmpty { toSpeak = spoken.isEmpty ? confirm : spoken }
            }
            lastReply = toSpeak
            speak(toSpeak)
        } catch VoiceBrainError.noKey { fail("Add your Qwen key in Settings first.") }
        catch VoiceBrainError.http(let code) { fail("Qwen request failed (HTTP \(code)).") }
        catch { fail("Something went wrong: \(error.localizedDescription)") }
    }

    private func fail(_ message: String) { errorText = message; phase = .idle }

    private func speak(_ text: String) {
        guard !text.isEmpty else { phase = .idle; return }
        phase = .speaking
        let language = VoiceSettings.conversationLanguage
        let tts = QwenSpeech(apiKey: VoiceSettings.apiKey, useIntl: VoiceSettings.useIntl)
        Task {
            do {
                let audio = try await tts.synthesize(text, language: language)
                voiceLog.info("qwen tts \(audio.count, privacy: .public) bytes")
                let player = try AVAudioPlayer(data: audio)
                player.delegate = self
                self.audioPlayer = player
                player.play()
            } catch {
                voiceLog.error("qwen tts failed: \(String(describing: error), privacy: .public)")
                self.errorText = "Qwen voice unavailable — using system voice."
                self.speakWithSystemVoice(text)
            }
        }
    }

    /// Fallback when Qwen TTS fails, so the reply is never silent.
    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: VoiceSettings.conversationLanguage.bcp47)
        synthesizer.speak(utterance)
    }

    private func cancelSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        phase = .idle
    }
}

extension VoiceChat: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.phase == .speaking { self.phase = .idle } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.phase == .speaking { self.phase = .idle } }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if self.phase == .speaking { self.phase = .idle } }
    }
}
