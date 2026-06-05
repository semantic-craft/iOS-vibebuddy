import Foundation
import AVFoundation
import os
import VibeBuddyKit

private let voiceLog = Logger(subsystem: "com.vibebuddy.app", category: "voice")

/// The phone's voice companion: tap the pet to hold a **realtime speech-to-speech**
/// conversation with the agent companion using the provider you picked
/// (Qwen / OpenAI / Gemini). Audio streams directly to that provider via your own
/// key; the companion knows your live sessions. This is the iOS twin of the Mac
/// `VoiceChat` — the provider sessions and config live in `VibeBuddyKit` and are
/// reused as-is; only the audio I/O (`RealtimeAudioIO`, which adds `AVAudioSession`)
/// and this thin controller are iOS-specific.
@MainActor
final class VoiceChat: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastUserText = ""
    @Published private(set) var lastReply = ""
    @Published private(set) var activeProvider: VoiceProvider?
    @Published var errorText: String?

    var isListening: Bool { phase == .listening }
    var isSpeaking: Bool { phase == .speaking }
    var isActive: Bool { phase != .idle }
    /// Available once the selected provider has a key — no separate enable step.
    var isAvailable: Bool { VoiceSettings.provider.apiKey?.isEmpty == false }

    private let contextProvider: () -> [AgentSession]
    private let actionHandler: (VoiceAction) -> String

    // Realtime speech-to-speech — the only path. Provider chosen in Settings.
    private var realtime: (any RealtimeVoiceProvider)?
    private var audioIO: RealtimeAudioIO?
    private var eventTask: Task<Void, Never>?
    private var assistantBuffer = ""
    /// Keeps the mic muted for the whole model turn (un-mutes only when the turn
    /// is complete AND playback drained) so the model never hears its own echo.
    private var gate = HalfDuplexGate()

    init(contextProvider: @escaping () -> [AgentSession],
         actionHandler: @escaping (VoiceAction) -> String) {
        self.contextProvider = contextProvider
        self.actionHandler = actionHandler
    }

    /// One control for the whole flow: tap to start a live call, tap again to end.
    func toggle() {
        voiceLog.info("toggle phase=\(String(describing: self.phase), privacy: .public) available=\(self.isAvailable, privacy: .public)")
        switch phase {
        case .idle: startRealtime()
        default: stopRealtime()
        }
    }

    // MARK: Realtime speech-to-speech

    private func startRealtime() {
        errorText = nil
        guard isAvailable else {
            errorText = "Add your \(VoiceSettings.provider.display) API key in Settings first."; return
        }
        // The mic permission prompt is delivered on a background thread, so request
        // it off the main actor, then hop back to begin the session.
        Self.requestMic { [weak self] micOK in
            Task { @MainActor in
                guard let self else { return }
                guard micOK else {
                    self.errorText = "Microphone permission needed (Settings › Privacy › Microphone)."; return
                }
                self.beginRealtimeSession()
            }
        }
    }

    /// `nonisolated` so the system callback (off the main thread) is not
    /// main-actor isolated; reports the grant back through a `Sendable` closure.
    nonisolated private static func requestMic(_ done: @escaping @Sendable (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            voiceLog.info("mic granted=\(granted, privacy: .public)")
            done(granted)
        }
    }

    private func beginRealtimeSession() {
        let provider = VoiceSettings.provider
        guard let key = provider.apiKey, !key.isEmpty else {
            errorText = "Add your \(provider.display) API key in Settings first."
            phase = .idle; return
        }
        let language = VoiceSettings.conversationLanguage
        let instructions = VoicePrompt.systemPrompt(sessions: contextProvider(), language: language)
            + "\n\nThis is a live voice call. Stay silent until the user actually speaks — never start talking on your own or fill silence, and never reply to your own voice. Answer in one short, natural sentence unless asked for more, and don't repeat yourself. Speak in a calm, gentle, even tone at a steady volume; never suddenly raise your pitch, shout, or get loud."
        let model = VoiceSettings.model(provider)
        let voice = VoiceSettings.voice(provider, language)
        voiceLog.info("realtime start provider=\(provider.rawValue, privacy: .public) model=\(model, privacy: .public) voice=\(voice, privacy: .public)")

        let session: any RealtimeVoiceProvider
        switch provider {
        case .qwen:   session = QwenRealtimeSession(apiKey: key, model: model, useIntl: VoiceSettings.useIntl)
        case .openai: session = OpenAIRealtimeSession(apiKey: key, model: model)
        case .gemini: session = GeminiRealtimeSession(apiKey: key, model: model)
        }
        let io = RealtimeAudioIO(inputSampleRate: provider.inputSampleRate)
        realtime = session
        audioIO = io
        activeProvider = provider
        assistantBuffer = ""
        lastUserText = ""; lastReply = ""
        gate = HalfDuplexGate()
        phase = .listening

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
                self.gate.playbackDrained()    // only re-opens if the turn is also complete
                io.micMuted = self.gate.micMuted
                if !self.gate.micMuted, self.phase == .speaking { self.phase = .listening }
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
            if VoiceCloseIntent.shouldClose(text) {     // "再见 / 关闭 / bye" → hang up hands-free
                voiceLog.info("voice close phrase heard — ending call")
                stopRealtime()
            }
        case .assistantTranscript(let text, let final):
            if final { lastReply = text; assistantBuffer = "" }
            else { assistantBuffer += text; lastReply = assistantBuffer }
        case .audioDelta(let pcm):
            gate.modelAudioReceived()       // half-duplex: mute for the whole turn
            audioIO?.micMuted = gate.micMuted
            phase = .speaking
            audioIO?.enqueue(pcm)
        case .speechStarted:                // server detected real user speech
            break
        case .responseDone:
            gate.turnDidComplete()          // un-mutes once playback also drains
            audioIO?.micMuted = gate.micMuted
            if !gate.micMuted { phase = .listening }
        case .failed(let message):
            voiceLog.error("realtime failed: \(message, privacy: .public)")
            errorText = message
            stopRealtime()                  // tear down cleanly so the next tap starts fresh
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
        activeProvider = nil
        phase = .idle
    }

    /// Called when the provider (or its model/voice) changes in Settings: if a
    /// session is live, restart it so the new provider takes effect immediately —
    /// no manual close-then-reopen. A no-op when idle.
    func reloadProviderIfActive() {
        guard isActive else { return }
        stopRealtime()
        startRealtime()
    }
}
