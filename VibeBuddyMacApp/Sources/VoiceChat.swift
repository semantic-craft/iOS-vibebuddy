import Foundation
import AVFoundation
import AppKit
import Speech
import os
import VibeBuddyKit

private let voiceLog = Logger(subsystem: "com.vibebuddy.mac", category: "voice")

/// The Mac voice companion: tap the buddy to talk → on-device speech-to-text →
/// Qwen brain (knows your live sessions, your key) → on-device text-to-speech,
/// and it can act on your agents. Mirrors the iOS flow without `AVAudioSession`
/// (macOS configures audio differently).
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

    func toggle() {
        voiceLog.info("toggle in phase=\(String(describing: self.phase), privacy: .public) available=\(self.isAvailable, privacy: .public)")
        switch phase {
        case .idle: requestPermissionsThenListen()
        case .listening: stopListeningAndSend()
        case .thinking, .speaking: cancelSpeaking()
        }
    }

    private func requestPermissionsThenListen() {
        errorText = nil
        guard isAvailable else { errorText = "先在设置里填入 Qwen (DashScope) Key"; return }
        // An accessory (menu-bar) app must be active for the mic TCC prompt to show.
        NSApp.activate(ignoringOtherApps: true)
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            voiceLog.info("speech auth=\(auth.rawValue, privacy: .public)")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                voiceLog.info("mic granted=\(granted, privacy: .public)")
                Task { @MainActor in
                    guard let self else { return }
                    guard auth == .authorized else { self.errorText = "需要语音识别权限（系统设置 › 隐私 › 语音识别）"; return }
                    guard granted else { self.errorText = "需要麦克风权限（系统设置 › 隐私 › 麦克风）"; return }
                    self.startListening()
                }
            }
        }
    }

    private func startListening() {
        guard let recognizer, recognizer.isAvailable else { errorText = "语音识别暂不可用"; return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Prefer on-device when the model is downloaded; otherwise let Apple's
        // server-based recognition handle it (more reliable on a fresh Mac).
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        voiceLog.info("startListening onDevice=\(recognizer.supportsOnDeviceRecognition, privacy: .public)")
        request = req

        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            errorText = "无法开始录音：\(error.localizedDescription)"; teardownAudio(); phase = .idle; return
        }
        phase = .listening
        lastUserText = ""
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            Task { @MainActor in self.lastUserText = result.bestTranscription.formattedString }
        }
    }

    private func stopListeningAndSend() {
        teardownAudio()
        let text = lastUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceLog.info("heard \(text.count, privacy: .public) chars")
        guard !text.isEmpty else { errorText = "没听清，再试一次"; phase = .idle; return }
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
        var messages = [ChatMessage(role: "system", content: VoicePrompt.systemPrompt(sessions: contextProvider()))]
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
        } catch VoiceBrainError.noKey { fail("先在设置里填入 Qwen Key") }
        catch VoiceBrainError.http(let code) { fail("Qwen 请求失败 (HTTP \(code))") }
        catch { fail("出错了：\(error.localizedDescription)") }
    }

    private func fail(_ message: String) { errorText = message; phase = .idle }

    private func speak(_ text: String) {
        guard !text.isEmpty else { phase = .idle; return }
        phase = .speaking
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.bcp47(for: text))
        synthesizer.speak(utterance)
    }

    private func cancelSpeaking() { synthesizer.stopSpeaking(at: .immediate); phase = .idle }

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
