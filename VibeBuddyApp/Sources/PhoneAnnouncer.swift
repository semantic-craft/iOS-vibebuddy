import AVFoundation
import Combine
import Foundation
import SwiftUI
import VibeBuddyKit

/// What one press of "Read pending" will say, decided before anything is
/// spoken: the pending queue in its own order, each item bound to the exact
/// round it describes so a later change makes it skip rather than mislead.
/// Pure — the tests exercise it without audio.
struct AnnouncementPlan: Equatable {
    struct Item: Equatable, Identifiable {
        let sessionID: String
        let title: String
        let sound: NotificationSound
        /// The completion round, or the wait, or the failure's `statusSince`.
        let round: String
        var id: String { sessionID + "/" + round }
    }

    let items: [Item]
    /// Beyond the ten the queue holds; the strip says these stay in the list.
    let overflow: Int

    static let capacity = 10

    init(pending: [AgentSession]) {
        let all = pending.compactMap(Item.init)
        items = Array(all.prefix(Self.capacity))
        overflow = max(0, all.count - Self.capacity)
    }

    /// The live session still describes the item: same round, still pending.
    /// Anything else is stale and is skipped, never re-announced as news.
    static func stillCurrent(_ item: Item, in sessions: [AgentSession]) -> AgentSession? {
        guard let live = sessions.first(where: { $0.id == item.sessionID }),
              let now = Item(live), now.round == item.round, now.sound == item.sound else { return nil }
        return live
    }
}

extension AnnouncementPlan.Item {
    init?(_ session: AgentSession) {
        switch session.presentationState {
        case .requiresInput:
            guard let wait = session.pendingQuestion?.id ?? session.pendingApproval?.id else { return nil }
            self.init(sessionID: session.id, title: session.displayTitle,
                      sound: session.pendingQuestion != nil ? .needsAnswer : .needsApproval, round: wait)
        case .error:
            self.init(sessionID: session.id, title: session.displayTitle, sound: .agentStuck,
                      round: "failed/" + String(Int(session.statusSince.timeIntervalSince1970)))
        case .completeUnread:
            guard let completion = session.completionID else { return nil }
            self.init(sessionID: session.id, title: session.displayTitle, sound: .agentDone, round: completion)
        case .thinking, .idle, .unassigned:
            return nil
        }
    }
}

@MainActor
final class PhoneAnnouncer: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var isPaused = false
    /// The item being spoken and its place in the run (1-based).
    @Published private(set) var current: (item: AnnouncementPlan.Item, position: Int, total: Int)?
    @Published private(set) var status: String?
    @Published private(set) var canReplay = false
    @Published private(set) var moreInList = 0
    /// This run's plan and how far it got, for the voice page's queue list.
    @Published private(set) var items: [AnnouncementPlan.Item] = []
    @Published private(set) var spokenCount = 0

    private let queue = CompletionSpeechQueue()
    private var player: AVAudioPlayer?
    private var systemVoice: AVSpeechSynthesizer?
    private var generation = UUID()
    private var run = UUID()
    private var latest: (text: String, item: AnnouncementPlan.Item, source: UUID)?
    private var sourceIdentity: (@MainActor () -> UUID)?
    private var activeValidation: (@MainActor () -> Bool)?
    @Published private(set) var isPreviewing = false
    @Published private(set) var previewMessage: String?
    private var previewTask: Task<Void, Never>?
    var latestItem: AnnouncementPlan.Item? { latest?.item }
    /// Lives as long as the dashboard; the observer is never removed.
    private var observers: [NSObjectProtocol] = []
    private var runTotal = 0

    init() {
        queue.onBusyChanged = { [weak self] busy in
            guard let self else { return }
            self.isBusy = busy || self.player?.isPlaying == true || self.systemVoice?.isSpeaking == true
            if !busy, self.player == nil, self.systemVoice?.isSpeaking != true { self.finishRun() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.pause() }
        })
    }

    /// Read the pending queue in order. `live` is asked again before each
    /// item so a round that moved on is skipped, not announced as news.
    func announce(_ pending: [AgentSession], startPaused: Bool = false,
                  live: @escaping @MainActor () -> [AgentSession],
                  source: @escaping @MainActor () -> UUID,
                  content: @escaping @MainActor (AnnouncementPlan.Item) async throws -> DashboardStore.Announcement,
                  validate: @escaping @MainActor (DashboardStore.Announcement) -> Bool) {
        let plan = AnnouncementPlan(pending: pending)
        guard !plan.items.isEmpty else {
            status = String(localized: "Nothing pending to read")
            return
        }
        stop()
        sourceIdentity = source
        run = UUID()
        runTotal = plan.items.count
        spokenCount = 0
        items = plan.items
        moreInList = plan.overflow
        isPaused = false
        status = nil
        for (index, item) in plan.items.enumerated() {
            let runID = run
            queue.enqueue(id: runID.uuidString + "/" + item.id) { [weak self] in
                guard let self, self.run == runID else { return }
                await self.speak(item, position: index + 1, live: live, content: content, validate: validate)
            }
        }
        // A live voice call owns the audio route: the run is queued but
        // waits for the person to resume it once the call is over.
        if startPaused {
            pause()
            status = String(localized: "Paused while the voice call is live")
        }
    }

    func togglePause() {
        if isPaused { resume() } else { pause() }
    }

    func pause() {
        guard isBusy, !isPaused else { return }
        isPaused = true
        queue.pause()
        player?.pause()
        systemVoice?.pauseSpeaking(at: .word)
        status = String(localized: "Paused")
    }

    func resume() {
        guard isPaused else { return }
        if activeValidation?() == false { skip(); isPaused = false; queue.resume(); return }
        isPaused = false
        status = nil
        queue.resume()
        if let player, !player.isPlaying, player.currentTime < player.duration { player.play() }
        systemVoice?.continueSpeaking()
    }

    /// Skips the item being spoken. The result stays unread.
    func skip() {
        stopPlayback()
        generation = UUID()
        queue.skip()
        status = String(localized: "Skipped · still unread")
    }

    func replayLatest(live: @escaping @MainActor () -> [AgentSession]) {
        guard let latest else { return }
        guard sourceIdentity?() == latest.source else { sourceChanged(); return }
        cancelPreview()
        let prefix = VoiceSettings.conversationLanguage() == .chinese ? "此前播报。" : "Previous announcement. "
        let runID = run
        queue.enqueue(id: "replay/" + UUID().uuidString, priority: true) { [weak self] in
            guard let self, self.run == runID else { return }
            await self.play(text: prefix + latest.text, item: latest.item, position: nil, remember: false, label: String(localized: "Previous announcement"), validate: { self.sourceIdentity?() == latest.source })
        }
    }

    /// A live voice conversation takes the audio route; reading pauses and
    /// does not resume on its own.
    func voiceStarted() { cancelPreview(); pause() }

    func sourceChanged() {
        stop()
        latest = nil
        canReplay = false
        items = []
    }

    func preview() {
        guard !isBusy else { return }
        isPreviewing = true
        previewMessage = nil
        status = nil
        isBusy = true
        let previewGeneration = generation
        previewTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == previewGeneration else { return }
            let text = VoiceSettings.conversationLanguage() == .chinese ? "这是本机播报试听。任务已经完成，下一步请查看结果。" : "This is a voice preview. The task is complete. Please review the result."
            let item = AnnouncementPlan.Item(sessionID: "preview", title: "", sound: .agentDone, round: "preview")
            await self.play(text: text, item: item, position: nil, remember: false, validate: { true })
            guard self.generation == previewGeneration else { return }
            self.previewMessage = self.status ?? String(localized: "Preview finished")
            self.isPreviewing = false
            self.isBusy = false
            self.deactivateAudioSession()
        }
    }

    func cancelPreview() {
        previewMessage = nil
        guard isPreviewing else { return }
        previewTask?.cancel()
        previewTask = nil
        stop()
    }

    func stop() {
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        run = UUID()
        generation = UUID()
        runTotal = 0
        spokenCount = 0
        status = nil
        queue.cancel()
        stopPlayback()
        current = nil
        isPaused = false
        isBusy = false
        moreInList = 0
        deactivateAudioSession()
    }

    // MARK: - Speaking

    private func speak(_ item: AnnouncementPlan.Item, position: Int,
                       live: @escaping @MainActor () -> [AgentSession],
                       content: @escaping @MainActor (AnnouncementPlan.Item) async throws -> DashboardStore.Announcement,
                       validate: @escaping @MainActor (DashboardStore.Announcement) -> Bool) async {
        guard AnnouncementPlan.stillCurrent(item, in: live()) != nil else { return }
        let currentGeneration = generation
        status = String(localized: "Preparing summary…")
        do {
            let announcement = try await content(item)
            let isCurrent: @MainActor () -> Bool = {
                validate(announcement) && AnnouncementPlan.stillCurrent(item, in: live()) != nil
            }
            guard !Task.isCancelled, generation == currentGeneration, isCurrent() else { throw ContentRequestFailure.conflict }
            await play(text: announcement.text, item: item, position: position, remember: true,
                       label: announcement.savedFallback ? String(localized: "Saved short content · styled summary unavailable") : nil,
                       validate: isCurrent)
        } catch is CancellationError { }
        catch ContentRequestFailure.conflict {
            if generation == currentGeneration, !Task.isCancelled { status = String(localized: "Skipped · task or content style changed") }
        }
        catch {
            if generation == currentGeneration, !Task.isCancelled { status = String(localized: "Could not prepare this announcement") }
        }
    }

    private func play(text: String, item: AnnouncementPlan.Item, position: Int?, remember: Bool,
                      label: String? = nil, validate: @escaping @MainActor () -> Bool) async {
        let current = generation
        activeValidation = validate
        defer { if generation == current { activeValidation = nil } }
        if let position { self.current = (item, position, runTotal) }
        do {
            try await waitWhilePaused()
            guard !Task.isCancelled, generation == current, validate() else { return }
            try activateAudioSession()
            if case .provider(let provider) = PhoneReadAloudSelection.load() {
                guard let synthesizer = SpeechSynthesis.synthesizer(VoiceSettings.readAloudConfiguration(provider)),
                      let key = provider.apiKey, !key.isEmpty else {
                    status = String(localized: "Configure this provider’s API key or choose System speech.")
                    return
                }
                status = String(localized: "Generating speech…")
                let data = try await synthesizer.synthesize(text, apiKey: key)
                guard !Task.isCancelled, generation == current, validate() else { return }
                try await waitWhilePaused()
                guard !Task.isCancelled, generation == current, validate() else { return }
                let player = try AVAudioPlayer(data: data)
                self.player = player
                guard player.play() else { status = String(localized: "Could not play the audio."); self.player = nil; return }
                status = label
                if remember, let source = sourceIdentity?() { latest = (text, item, source); canReplay = true }
                while (player.isPlaying || isPaused) && !Task.isCancelled && generation == current {
                    try await waitWhilePaused()
                    guard validate() else { stopPlayback(); status = String(localized: "Skipped · task or content style changed"); return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                if generation == current { self.player = nil }
            } else {
                let synthesizer = AVSpeechSynthesizer()
                systemVoice = synthesizer
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: VoiceSettings.conversationLanguage() == .chinese ? "zh-CN" : "en-US")
                status = label
                if remember, let source = sourceIdentity?() { latest = (text, item, source); canReplay = true }
                synthesizer.speak(utterance)
                while (synthesizer.isSpeaking || isPaused) && !Task.isCancelled && generation == current {
                    try await waitWhilePaused()
                    guard validate() else { stopPlayback(); status = String(localized: "Skipped · task or content style changed"); return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                if generation == current { systemVoice = nil }
            }
            if generation == current { spokenCount += 1 }
        } catch let failure as SpeechSynthesisFailure {
            guard generation == current, !Task.isCancelled else { return }
            status = failure.message
        } catch is CancellationError {
            // Skipped or stopped: the owner already said why.
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            status = String(localized: "Could not play the audio.")
        }
    }

    private func waitWhilePaused() async throws {
        while isPaused {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
        }
    }

    private func stopPlayback() {
        player?.stop(); player = nil
        systemVoice?.stopSpeaking(at: .immediate); systemVoice = nil
    }

    private func finishRun() {
        current = nil
        isPaused = false
        if runTotal > 0, spokenCount > 0, status == nil {
            status = moreInList > 0
                ? String(localized: "Read \(spokenCount) · \(moreInList) more in the list")
                : String(localized: "Read \(spokenCount) · nothing marked read")
        }
        runTotal = 0
        deactivateAudioSession()
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// The strip above the composer while the phone reads: what is being said
/// and where it sits in the run, with pause, skip, replay and stop.
struct AnnouncerStrip: View {
    @ObservedObject var announcer: PhoneAnnouncer
    let replay: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: announcer.isBusy ? "speaker.wave.2" : "speaker")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CompanionPalette.ink3)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if let current = announcer.current {
                    HStack(spacing: 6) {
                        Text(current.item.title)
                            .font(CompanionType.font(13, .medium))
                            .foregroundStyle(CompanionPalette.ink)
                            .lineLimit(1)
                        Text(verbatim: "\(current.position) / \(current.total)")
                            .font(CompanionType.mono(11)).monospacedDigit()
                            .foregroundStyle(CompanionPalette.ink3)
                    }
                }
                if let status = announcer.status {
                    Text(status).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3).lineLimit(1)
                } else if announcer.current == nil, announcer.isBusy {
                    Text("Reading…").font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                }
            }
            Spacer(minLength: 4)
            if announcer.isBusy {
                PhoneCircleButton(announcer.isPaused ? "play.fill" : "pause.fill", size: 30, tint: CompanionPalette.ink2) {
                    announcer.togglePause()
                }
                .accessibilityLabel(announcer.isPaused ? "Resume reading" : "Pause reading")
                PhoneCircleButton("forward.end.fill", size: 30, tint: CompanionPalette.ink2) { announcer.skip() }
                    .accessibilityLabel("Skip")
            }
            if announcer.canReplay {
                PhoneCircleButton("arrow.counterclockwise", size: 30, tint: CompanionPalette.ink2) { replay() }
                    .accessibilityLabel("Replay last")
            }
            PhoneCircleButton("xmark", size: 30, tint: CompanionPalette.ink2) { announcer.stop() }
                .accessibilityLabel("Stop reading")
        }
        .padding(.horizontal, PhoneMetrics.gutter)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phone-announcer-strip")
    }
}
