import AVFoundation
import SwiftUI
import VibeBuddyKit

@MainActor
final class ReadAloud: ObservableObject {
    /// The key keeps its original name on purpose: renaming it would silently
    /// switch read-aloud off for everyone who already has it on.
    static let enabledKey = "qwenReadAloudEnabled"
    static let silenceViewedKey = "readAloudSilenceViewedTask"
    @Published private(set) var paused = false
    @Published private(set) var hasMoreResults = false
    @Published private(set) var canReplay = false
    struct QueueItem: Identifiable { let id: String; let title: String }
    @Published private(set) var currentItem: QueueItem?
    @Published private(set) var pendingItems: [QueueItem] = []
    private var itemTitles: [String: String] = [:]
    private var manualIDs: Set<String> = []
    var hasManualReading: Bool { !manualIDs.isEmpty }
    func manuallyRequested(_ id: String) -> Bool { manualIDs.contains(id) }
    func report(_ text: String) { status = text }
    func showOverflow() { hasMoreResults = true }
    func finishReadPending(orderedIDs: [String]) {
        queue.orderPending(ids: orderedIDs)
        if !paused { queue.resume() }
    }

    func beginReadPending(orderedIDs: [String]) {
        hasMoreResults = false
        queue.pause()
        queue.retainPending(ids: Set(orderedIDs))
        status = "Reading all current pending tasks"
        // A deliberate new Read pending / Resume is required after voice.
        // This action never opens a microphone or enables automatic reading.
        if canSpeak() { paused = false }
        else { paused = true; status = "Reading paused for voice; resume when ready" }
    }
    private var latest: (text: String, id: String, title: String)?
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

    init(automaticKey: @escaping @MainActor (VoiceProvider) -> String? = { provider in
        if E2ERunConfiguration.current != nil {
            let env = ProcessInfo.processInfo.environment
            switch provider {
            case .qwen: return env["DASHSCOPE_API_KEY"]
            case .openai: return env["OPENAI_API_KEY"]
            default: return nil
            }
        }
        return provider.apiKey
    },
         makeSynthesizer: @escaping @Sendable (SpeechSynthesisConfiguration) -> (any SpeechSynthesizer)? = SpeechSynthesis.synthesizer) {
        self.automaticKey = automaticKey
        self.makeSynthesizer = makeSynthesizer
    }

    var canSpeak: @MainActor () -> Bool = { true }
    private var player: AVAudioPlayer? {
        didSet { playerNeedsResume = false }
    }
    private var playerNeedsResume = false
    private lazy var queue: CompletionSpeechQueue = {
        let queue = CompletionSpeechQueue()
        queue.onBusyChanged = { [weak self] value in
            guard let self else { return }
            self.queueBusy = value
            self.updateBusy()
        }
        queue.onOverflow = { [weak self] in self?.hasMoreResults = true }
        queue.onEntriesChanged = { [weak self, weak queue] in
            guard let self, let queue else { return }
            self.currentItem = queue.currentID.map { QueueItem(id: $0, title: self.itemTitles[$0] ?? $0) }
            self.pendingItems = queue.pendingIDs.map { QueueItem(id: $0, title: self.itemTitles[$0] ?? $0) }
            let liveIDs = Set(queue.pendingIDs + [queue.currentID].compactMap { $0 })
            self.manualIDs.formIntersection(liveIDs)
            self.itemTitles = self.itemTitles.filter { liveIDs.contains($0.key) }
        }
        return queue
    }()
    private var generation = UUID()

    func togglePause() {
        paused.toggle()
        if paused { queue.pause(); pausePlayer(); status = "Read-aloud paused" }
        else { queue.resume() }
    }

    func skip() {
        player?.stop(); player = nil
        generation = UUID()
        queue.skip()
        status = "Skipped; result remains unread"
    }

    func replayLatest() {
        guard let latest else { return }
        speak((VoiceSettings.conversationLanguage() == .chinese ? "重播原播报。" : "Replaying the original announcement. ") + latest.text,
            id: "replay/" + UUID().uuidString, title: latest.title, manual: true, remember: false)
    }

    func voiceStarted() {
        cancelPreview()
        pausePlayer()
        if hasManualReading {
            paused = true
            queue.pause()
            status = "Reading paused for voice; resume when ready"
        }
    }

    private func pausePlayer() {
        guard let player, player.isPlaying else { return }
        player.pause()
        playerNeedsResume = true
    }

    private func waitUntilAllowed() async throws {
        while paused || !canSpeak() {
            pausePlayer()
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
        }
    }

    func stop() {
        cancelPreview()
        stopAutomaticReading()
    }

    func stopAutomaticReading() {
        generation = UUID()
        queue.cancel()
        player?.stop(); player = nil
        paused = false
        queue.resume()
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

    func speak(_ fallbackText: String, id: String = UUID().uuidString, title: String? = nil,
               manual: Bool = false, priority: Bool = false, remember: Bool = true,
               prepareText: (@MainActor () async -> String?)? = nil,
               validatePreparedText: @escaping @MainActor () -> Bool = { true },
               validate: @escaping @MainActor () async -> Bool = { true }) {
        guard E2ERunConfiguration.current?.audioEnabled ?? true else {
            status = "Audio is disabled in this isolated run"
            return
        }
        // Initialize callbacks before registering the metadata for this entry.
        let queue = self.queue
        if manual, queue.currentID != id, !queue.pendingIDs.contains(id),
           queue.pendingCount + (queue.currentID == nil ? 0 : 1) >= 10 {
            hasMoreResults = true
            return
        }
        itemTitles[id] = title ?? String(fallbackText.prefix(100))
        if manual {
            manualIDs.insert(id)
            if !canSpeak() { paused = true; queue.pause(); status = "Reading paused for voice; resume when ready" }
        }
        queue.enqueue(id: id, priority: priority, allowRepeat: manual) { [weak self] in
            guard let self else { return }
            let current = self.generation
            // Preserve queued automatic speech, but never play over a Settings preview.
            if let preview = self.previewTask { _ = await preview.value }
            do {
                try await self.waitUntilAllowed()
                guard !Task.isCancelled, self.generation == current else { return }
                guard await validate(), !Task.isCancelled, self.generation == current else {
                    if !Task.isCancelled, self.generation == current { self.status = "Skipped; task or reading eligibility changed" }
                    return
                }
                let text: String
                if let prepareText {
                    guard let prepared = await prepareText() else { return }
                    text = prepared
                } else { text = fallbackText }
                guard await validate(), !Task.isCancelled, self.generation == current else {
                    if !Task.isCancelled, self.generation == current { self.status = "Skipped; task or reading eligibility changed" }
                    return
                }
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
                guard !Task.isCancelled, self.generation == current else { return }
                guard await validate(), !Task.isCancelled, self.generation == current else {
                    if !Task.isCancelled, self.generation == current { self.status = "Skipped; task or reading eligibility changed" }
                    return
                }
                try await self.waitUntilAllowed()
                guard await validate(), self.generation == current, validatePreparedText() else { return }
                let evidenceID = UUID().uuidString
                if let run = E2ERunConfiguration.current {
                    try? data.write(to: run.file("speech-" + evidenceID + ".audio"), options: .atomic)
                    self.recordPlayback("generated", id: evidenceID, text: text)
                }
                let player = try AVAudioPlayer(data: data)
                self.player = player
                guard player.play() else { self.status = "Your Mac could not play the audio."; self.player = nil; return }
                self.recordPlayback("started", id: evidenceID, text: text)
                if remember { self.latest = (text, id, title ?? String(text.prefix(100))); self.canReplay = true }
                self.status = "Playing speech"
                while (player.isPlaying || self.playerNeedsResume || self.paused || !self.canSpeak()) && !Task.isCancelled {
                    try await self.waitUntilAllowed()
                    guard await validate(), !Task.isCancelled, self.generation == current else {
                        player.stop()
                        if self.generation == current { self.player = nil; self.status = "Read-aloud stopped" }
                        return
                    }
                    if self.paused || !self.canSpeak() { continue }
                    if self.playerNeedsResume {
                        self.playerNeedsResume = false
                        guard player.play() else { self.status = "Your Mac could not play the audio."; self.player = nil; return }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    guard await validate(), !Task.isCancelled, self.generation == current else {
                        player.stop()
                        if self.generation == current { self.player = nil; self.status = "Read-aloud stopped" }
                        return
                    }
                }
                if self.generation == current {
                    self.status = "Playback complete"; self.player = nil
                    self.recordPlayback("completed", id: evidenceID, text: text)
                }
            } catch is CancellationError { }
              catch { if self.generation == current { self.status = Self.copy(for: error) } }
        }
    }
    /// Isolated acceptance evidence only; no production audio or text is persisted.
    private func recordPlayback(_ phase: String, id: String, text: String) {
        guard let run = E2ERunConfiguration.current,
              let data = try? JSONSerialization.data(withJSONObject: ["phase": phase, "id": id,
                  "text": text, "at": Date().timeIntervalSince1970]) else { return }
        let file = run.file("speech-events.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10]))
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
