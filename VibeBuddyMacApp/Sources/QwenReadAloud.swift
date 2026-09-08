import AVFoundation
import SwiftUI
import VibeBuddyKit

@MainActor
final class QwenReadAloud: ObservableObject {
    static let enabledKey = "qwenReadAloudEnabled"
    static let modelKey = "qwenReadAloudModel"
    static let voiceKey = "qwenReadAloudVoice"
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var previewStatus = ""
    struct PreviewConfiguration: Sendable {
        let model: String
        let voice: String
        let workspaceID: String?
        let useIntl: Bool
    }
    enum PreviewResult: Sendable { case completed, cancelled, failed(String) }
    typealias Synthesis = @Sendable (String, String, PreviewConfiguration) async throws -> Data
    private let synthesizePreview: Synthesis
    private let automaticKey: @MainActor () -> String?
    private var previewTask: Task<PreviewResult, Never>?
    private var previewGeneration = UUID()
    private var previewPlayer: AVAudioPlayer?
    private var queueBusy = false
    var automaticBusy: Bool { queueBusy }

    init(automaticKey: @escaping @MainActor () -> String? = { VoiceProvider.qwen.apiKey },
         synthesizePreview: @escaping Synthesis = { text, key, config in
        try await QwenSpeechSynthesis.synthesize(text, apiKey: key, model: config.model,
            voice: config.voice, workspaceID: config.workspaceID, useIntl: config.useIntl)
    }) { self.automaticKey = automaticKey; self.synthesizePreview = synthesizePreview }

    var canSpeak: @MainActor () -> Bool = { true }
    private var player: AVAudioPlayer?
    private lazy var queue: CompletionSpeechQueue = {
        let queue = CompletionSpeechQueue()
        queue.onBusyChanged = { [weak self] value in
            guard let self else { return }
            self.queueBusy = value
            self.updateBusy()
        }
        return queue
    }()
    private var generation = UUID()

    func stop() {
        cancelPreview()
        stopAutomaticReading()
    }

    func stopAutomaticReading() {
        generation = UUID()
        queue.cancel()
        player?.stop(); player = nil
        status = "Read-aloud stopped"
    }

    func speak(_ text: String, id: String = UUID().uuidString,
               validate: @escaping @MainActor () async -> Bool = { true }) {
        guard E2ERunConfiguration.current?.audioEnabled ?? true, canSpeak() else { return }
        queue.enqueue(id: id) { [weak self] in
            guard let self else { return }
            let current = self.generation
            // Preserve queued automatic speech, but never play over a Settings preview.
            if let preview = self.previewTask { _ = await preview.value }
            do {
                guard !Task.isCancelled, self.generation == current, self.canSpeak() else { return }
                guard await validate(), !Task.isCancelled, self.generation == current, self.canSpeak() else { return }
                guard let key = self.automaticKey(), !key.isEmpty else {
                    self.status = "Save your DashScope API key first."; return
                }
                self.status = "Generating Qwen speech…"
                let defaults = UserDefaults.standard
                let data = try await QwenSpeechSynthesis.synthesize(text, apiKey: key,
                    model: defaults.string(forKey: Self.modelKey) ?? QwenSpeechSynthesis.defaultModel,
                    voice: defaults.string(forKey: Self.voiceKey) ?? QwenSpeechSynthesis.defaultVoice,
                    workspaceID: VoiceSettings.qwenWorkspaceID, useIntl: VoiceSettings.useIntl)
                guard !Task.isCancelled, self.generation == current, self.canSpeak() else { return }
                guard await validate(), !Task.isCancelled, self.generation == current, self.canSpeak() else { return }
                let player = try AVAudioPlayer(data: data)
                self.player = player
                guard player.play() else { self.status = "Your Mac could not play the audio."; self.player = nil; return }
                self.status = "Playing Qwen speech"
                while player.isPlaying && !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                    guard await validate(), !Task.isCancelled, self.generation == current, self.canSpeak() else {
                        player.stop()
                        if self.generation == current { self.player = nil; self.status = "Read-aloud stopped" }
                        return
                    }
                }
                if self.generation == current { self.status = "Playback complete"; self.player = nil }
            } catch is CancellationError { }
              catch { if self.generation == current { self.status = "Speech generation failed. Check your DashScope model, voice and connection." } }
        }
    }
    private func updateBusy() { busy = queueBusy || previewTask != nil }

    /// Cancels only the Settings-owned preview; queued automatic speech is untouched.
    func cancelPreview() {
        previewGeneration = UUID()
        previewTask?.cancel()
        previewPlayer?.stop()
        previewPlayer = nil
        previewStatus = "Read-aloud stopped"
    }

    func preview(_ text: String, apiKey: String, configuration: PreviewConfiguration) async -> PreviewResult {
        guard E2ERunConfiguration.current?.audioEnabled ?? true else { return .cancelled }
        guard !Task.isCancelled else { return .cancelled }
        guard !busy, canSpeak() else { return .failed("Stop the current voice conversation or reading before previewing.") }
        let id = UUID()
        previewGeneration = id
        let task = Task { @MainActor [self] in
            defer { previewPlayer?.stop(); previewPlayer = nil }
            do {
                try Task.checkCancellation()
                previewStatus = "Generating Qwen speech…"
                let data = try await synthesizePreview(text, apiKey, configuration)
                guard !Task.isCancelled, previewGeneration == id, canSpeak() else { return PreviewResult.cancelled }
                let player = try AVAudioPlayer(data: data)
                previewPlayer = player
                guard player.play() else { return .failed("Your Mac could not play the audio.") }
                previewStatus = "Playing Qwen speech"
                while player.isPlaying {
                    try await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, previewGeneration == id, canSpeak() else { return .cancelled }
                }
                return .completed
            } catch is CancellationError { return .cancelled }
              catch {
                if Task.isCancelled || previewGeneration != id { return .cancelled }
                return .failed("Speech generation failed. Check your DashScope model, voice and connection.")
            }
        }
        previewTask = task // Occupy the shared reader before the first suspension.
        updateBusy()
        let result = await withTaskCancellationHandler { await task.value } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.previewGeneration == id else { return }
                self?.cancelPreview()
            }
        }
        // No new preview can start while this handle is retained.
        previewTask = nil
        updateBusy()
        previewStatus = ""
        return result
    }

}
