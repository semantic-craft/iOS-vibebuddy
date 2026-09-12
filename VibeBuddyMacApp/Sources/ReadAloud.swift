import AVFoundation
import SwiftUI
import VibeBuddyKit

@MainActor
final class ReadAloud: ObservableObject {
    /// The key keeps its original name on purpose: renaming it would silently
    /// switch read-aloud off for everyone who already has it on.
    static let enabledKey = "qwenReadAloudEnabled"
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var previewStatus = ""
    enum PreviewResult: Sendable { case completed, cancelled, failed(String) }
    private let makeSynthesizer: @Sendable (SpeechSynthesisConfiguration) -> (any SpeechSynthesizer)?
    private let automaticKey: @MainActor (VoiceProvider) -> String?
    private var previewTask: Task<PreviewResult, Never>?
    private var previewGeneration = UUID()
    private var previewPlayer: AVAudioPlayer?
    private var queueBusy = false
    var automaticBusy: Bool { queueBusy }

    init(automaticKey: @escaping @MainActor (VoiceProvider) -> String? = { $0.apiKey },
         makeSynthesizer: @escaping @Sendable (SpeechSynthesisConfiguration) -> (any SpeechSynthesizer)? = SpeechSynthesis.synthesizer) {
        self.automaticKey = automaticKey
        self.makeSynthesizer = makeSynthesizer
    }

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

    /// Why read-aloud cannot speak right now, in words the user can act on.
    static func unavailability(_ status: VoiceSettings.ReadAloudStatus) -> String? {
        switch status {
        case .waitingForSummaryProvider:
            return NSLocalizedString("Read-aloud is waiting for a completion summary provider. Choose one, or pick a read-aloud provider of its own.", comment: "Read-aloud follows an unconfigured summary provider")
        case .summaryProviderCannotSpeak(let provider):
            return String(format: NSLocalizedString("%@ is text-only, so read-aloud cannot follow it. Pick a read-aloud provider of its own.", comment: "Read-aloud follows a text-only summary provider"), provider.display)
        case .ready:
            return nil
        }
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
                let readAloud = VoiceSettings.readAloudStatus()
                guard case .ready(let provider) = readAloud else {
                    self.status = Self.unavailability(readAloud) ?? ""; return
                }
                guard let key = self.automaticKey(provider), !key.isEmpty else {
                    self.status = String(format: NSLocalizedString("Save your %@ API key first.", comment: "Read-aloud needs a key"), provider.display); return
                }
                self.status = "Generating speech…"
                guard let synthesizer = self.makeSynthesizer(VoiceSettings.readAloudConfiguration(provider)) else {
                    self.status = SpeechSynthesisFailure.configuration.message; return
                }
                let data = try await synthesizer.synthesize(text, apiKey: key)
                guard !Task.isCancelled, self.generation == current, self.canSpeak() else { return }
                guard await validate(), !Task.isCancelled, self.generation == current, self.canSpeak() else { return }
                let player = try AVAudioPlayer(data: data)
                self.player = player
                guard player.play() else { self.status = "Your Mac could not play the audio."; self.player = nil; return }
                self.status = "Playing speech"
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
              catch { if self.generation == current { self.status = Self.copy(for: error) } }
        }
    }
    /// Graded, actionable, and never the provider's own words — a raw response
    /// can carry the credential that was sent with it.
    static func copy(for error: any Error) -> String {
        NSLocalizedString((error as? SpeechSynthesisFailure ?? .transport).message,
                          comment: "Speech synthesis failure")
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

    func preview(_ text: String, apiKey: String, configuration: SpeechSynthesisConfiguration) async -> PreviewResult {
        guard E2ERunConfiguration.current?.audioEnabled ?? true else { return .cancelled }
        guard !Task.isCancelled else { return .cancelled }
        guard !busy, canSpeak() else { return .failed("Stop the current voice conversation or reading before previewing.") }
        guard let synthesizer = makeSynthesizer(configuration) else {
            return .failed(SpeechSynthesisFailure.configuration.message)
        }
        let id = UUID()
        previewGeneration = id
        let task = Task { @MainActor [self] in
            defer { previewPlayer?.stop(); previewPlayer = nil }
            do {
                try Task.checkCancellation()
                previewStatus = "Generating speech…"
                let data = try await synthesizer.synthesize(text, apiKey: apiKey)
                guard !Task.isCancelled, previewGeneration == id, canSpeak() else { return PreviewResult.cancelled }
                let player = try AVAudioPlayer(data: data)
                previewPlayer = player
                guard player.play() else { return .failed("Your Mac could not play the audio.") }
                previewStatus = "Playing speech"
                while player.isPlaying {
                    try await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, previewGeneration == id, canSpeak() else { return .cancelled }
                }
                return .completed
            } catch is CancellationError { return .cancelled }
              catch {
                if Task.isCancelled || previewGeneration != id { return .cancelled }
                return .failed(Self.copy(for: error))
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
