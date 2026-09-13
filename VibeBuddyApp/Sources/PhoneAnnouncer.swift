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

/// The phone's read-aloud (ticket 04, `.scratch/iphone-board`): the Kit's
/// `CompletionSpeechQueue` and `AnnouncementCopy` hosted on the phone. Speech
/// comes from the voice companion's provider when it has a key, otherwise
/// from the system voice, so a phone with nothing configured still reads.
/// Nothing here marks a result read; a live voice conversation pauses it.
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
    private var latest: (text: String, item: AnnouncementPlan.Item)?
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
    func announce(_ pending: [AgentSession], live: @escaping @MainActor () -> [AgentSession]) {
        let plan = AnnouncementPlan(pending: pending)
        guard !plan.items.isEmpty else {
            status = String(localized: "Nothing pending to read")
            return
        }
        stop()
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
                await self.speak(item, position: index + 1, live: live)
            }
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
        let prefix = VoiceSettings.conversationLanguage() == .chinese ? "此前一条。" : "Previous item. "
        let runID = run
        queue.enqueue(id: "replay/" + UUID().uuidString, priority: true) { [weak self] in
            guard let self, self.run == runID else { return }
            await self.play(text: prefix + latest.text, item: latest.item, position: nil, remember: false)
        }
    }

    /// A live voice conversation takes the audio route; reading pauses and
    /// does not resume on its own.
    func voiceStarted() { pause() }

    func stop() {
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
                       live: @escaping @MainActor () -> [AgentSession]) async {
        guard let session = AnnouncementPlan.stillCurrent(item, in: live()) else {
            status = String(localized: "Skipped \(item.title) · no longer pending")
            return
        }
        guard let text = AnnouncementCopy.text(for: session, sound: item.sound,
                                                language: VoiceSettings.conversationLanguage()) else { return }
        await play(text: text, item: item, position: position, remember: true)
    }

    private func play(text: String, item: AnnouncementPlan.Item, position: Int?, remember: Bool) async {
        let current = generation
        if let position { self.current = (item, position, runTotal) }
        do {
            try await waitWhilePaused()
            guard !Task.isCancelled, generation == current else { return }
            try activateAudioSession()
            if let synthesizer = providerSynthesizer(), let key = VoiceSettings.provider.apiKey, !key.isEmpty {
                status = String(localized: "Generating speech…")
                let data = try await synthesizer.synthesize(text, apiKey: key)
                guard !Task.isCancelled, generation == current else { return }
                try await waitWhilePaused()
                let player = try AVAudioPlayer(data: data)
                self.player = player
                guard player.play() else { status = String(localized: "Could not play the audio."); self.player = nil; return }
                status = nil
                if remember { latest = (text, item); canReplay = true }
                while (player.isPlaying || isPaused) && !Task.isCancelled && generation == current {
                    try await waitWhilePaused()
                    try await Task.sleep(for: .milliseconds(100))
                }
                if generation == current { self.player = nil }
            } else {
                let synthesizer = AVSpeechSynthesizer()
                systemVoice = synthesizer
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: VoiceSettings.conversationLanguage() == .chinese ? "zh-CN" : "en-US")
                status = nil
                if remember { latest = (text, item); canReplay = true }
                synthesizer.speak(utterance)
                while (synthesizer.isSpeaking || isPaused) && !Task.isCancelled && generation == current {
                    try await waitWhilePaused()
                    try await Task.sleep(for: .milliseconds(100))
                }
                if generation == current { systemVoice = nil }
            }
            if generation == current { spokenCount += 1 }
        } catch let failure as SpeechSynthesisFailure {
            status = failure.message
        } catch is CancellationError {
            // Skipped or stopped: the owner already said why.
        } catch {
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

    /// The voice companion's provider, when it can speak and has a key; the
    /// read-aloud model, voice and style follow the shared keys.
    private func providerSynthesizer() -> (any SpeechSynthesizer)? {
        let provider = VoiceSettings.provider
        guard provider.supportsVoice, provider.apiKey?.isEmpty == false else { return nil }
        return SpeechSynthesis.synthesizer(VoiceSettings.readAloudConfiguration(provider))
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
