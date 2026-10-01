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

/// AVFAudio's delegate is Sendable; the synthesizer and utterance are not.
/// Compare identities inside callbacks and protect only the small lifecycle
/// state, without moving either audio object across actors.
private final class SystemSpeechLifecycle: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    enum State { case queued, speaking, finished, cancelled }
    enum Failure: Error { case cancelled, timedOut }
    private let synthesizerID: ObjectIdentifier
    private let utteranceID: ObjectIdentifier
    private let lock = NSLock()
    private var value = State.queued

    init(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance) {
        synthesizerID = ObjectIdentifier(synthesizer)
        utteranceID = ObjectIdentifier(utterance)
        super.init()
    }

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    private func update(_ next: State, synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance) {
        guard ObjectIdentifier(synthesizer) == synthesizerID,
              ObjectIdentifier(utterance) == utteranceID else { return }
        lock.lock()
        defer { lock.unlock() }
        guard value != .finished, value != .cancelled else { return }
        value = next
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        update(.speaking, synthesizer: synthesizer, utterance: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        update(.finished, synthesizer: synthesizer, utterance: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        update(.cancelled, synthesizer: synthesizer, utterance: utterance)
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

    @Published private(set) var canUseSystemSpeech = false
    @Published private(set) var voiceOwnsAudio = false
    private struct Recovery {
        let text: String
        let item: AnnouncementPlan.Item
        let position: Int?
        let remember: Bool
        let validate: @MainActor () -> Bool
    }
    private var recovery: Recovery?

    private let queue = CompletionSpeechQueue()
    private let providerKey: @MainActor (VoiceProvider) -> String?
    private let makeSynthesizer: @Sendable (SpeechSynthesisConfiguration) -> (any SpeechSynthesizer)?
    private let playAudio: @MainActor (AVAudioPlayer) -> Bool
    private var player: AVAudioPlayer? {
        didSet { playerNeedsResume = false }
    }
    private var playerNeedsResume = false
    // Tracks only this reader's ownership, not the shared session's global
    // state. Queue completion and explicit Stop can both request cleanup.
    private var ownsAudioSession = false
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

    init(providerKey: @escaping @MainActor (VoiceProvider) -> String? = { $0.apiKey },
         makeSynthesizer: @escaping @Sendable (SpeechSynthesisConfiguration) -> (any SpeechSynthesizer)? = SpeechSynthesis.synthesizer,
         playAudio: @escaping @MainActor (AVAudioPlayer) -> Bool = { $0.play() }) {
        self.providerKey = providerKey
        self.makeSynthesizer = makeSynthesizer
        self.playAudio = playAudio
        queue.onBusyChanged = { [weak self] busy in
            guard let self else { return }
            self.isBusy = busy || self.recovery != nil || self.player?.isPlaying == true || self.systemVoice?.isSpeaking == true
            if !busy, self.recovery == nil, self.player == nil, self.systemVoice?.isSpeaking != true { self.finishRun() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.pause(interrupted: true) }
        })
        observers.append(center.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if UIAccessibility.isVoiceOverRunning { self?.pause() } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.pause(interrupted: true) }
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
            voiceOwnsAudio = true
            pause()
            status = String(localized: "Paused while the voice call is live")
        }
    }

    func togglePause() {
        if isPaused { resume() } else { pause() }
    }

    func pause() { pause(interrupted: false) }

    private func pause(interrupted: Bool) {
        guard isBusy, !isPaused else { return }
        isPaused = true
        queue.pause()
        if let player {
            // An interruption can stop the player before its notification arrives.
            let interruptedMidAudio = interrupted && player.currentTime > 0 && player.currentTime < player.duration
            if player.isPlaying || interruptedMidAudio {
                playerNeedsResume = true
                player.pause()
            }
        }
        systemVoice?.pauseSpeaking(at: .word)
        status = String(localized: "Paused")
    }

    func resume() {
        guard isPaused, recovery == nil, !voiceOwnsAudio else { return }
        if activeValidation?() == false { skip(); isPaused = false; queue.resume(); return }
        if (player != nil && playerNeedsResume) || systemVoice != nil {
            do { try activateAudioSession() }
            catch { status = String(localized: "Could not play the audio."); return }
        }
        if let player, playerNeedsResume {
            // Do not release the playback loop or the next queued item until
            // the player actually accepts the resume. Failure remains retryable.
            guard playAudio(player) else {
                status = String(localized: "Could not play the audio.")
                return
            }
            playerNeedsResume = false
        }
        systemVoice?.continueSpeaking()
        isPaused = false
        status = String(localized: "Reading…")
        queue.resume()
    }

    /// Skips the item being spoken. The result stays unread.
    func skip() {
        recovery = nil
        canUseSystemSpeech = false
        stopPlayback()
        generation = UUID()
        // Skipping changes the item, not the user's pause decision. A call
        // ending also leaves reading paused until an explicit Resume.
        queue.skip()
        status = String(localized: "Skipped · still unread")
    }

    func replayLatest(live: @escaping @MainActor () -> [AgentSession]) {
        guard let latest else { return }
        guard sourceIdentity?() == latest.source else { sourceChanged(); return }
        cancelPreview()
        let prefix = PhoneReadAloudSelection.language() == .chinese ? "此前播报。" : "Previous announcement. "
        let runID = run
        queue.enqueue(id: "replay/" + UUID().uuidString, priority: true) { [weak self] in
            guard let self, self.run == runID else { return }
            await self.play(text: prefix + latest.text, item: latest.item, position: nil, remember: false, label: String(localized: "Previous announcement"), validate: { self.sourceIdentity?() == latest.source })
        }
    }

    /// A live voice conversation takes the audio route; reading pauses and
    /// does not resume on its own.
    func voiceStarted() {
        voiceOwnsAudio = true
        // Connecting may still be waiting for microphone permission. Keep
        // our ownership record, but suppress cleanup while takeover is pending.
        cancelPreview()
        pause()
    }
    func voiceEnded() {
        voiceOwnsAudio = false
        guard ownsAudioSession else { return }
        if AVAudioSession.sharedInstance().category == .playback {
            // Permission denial/early failure never installed RealtimeAudioIO's
            // playAndRecord category. Release our paused playback session so
            // other audio is no longer ducked; explicit Resume can reacquire it.
            deactivateAudioSession()
        } else {
            // The call did take over. Its AudioIO owns activation and cleanup.
            ownsAudioSession = false
        }
    }

    func sourceChanged() {
        stop()
        latest = nil
        canReplay = false
        items = []
    }

    func preview() {
        guard !isBusy, !voiceOwnsAudio else { return }
        cancelPreview()
        isPreviewing = true
        previewMessage = nil
        status = nil
        isBusy = true
        let previewGeneration = generation
        previewTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == previewGeneration else { return }
            let language = PhoneReadAloudSelection.language()
            let text = PhoneReadAloudSelection.load().voiceStyle.previewLine(language)
                ?? (language == .chinese ? "这是本机播报试听。任务已经完成，下一步请查看结果。" : "This is a voice preview. The task is complete. Please review the result.")
            let item = AnnouncementPlan.Item(sessionID: "preview", title: "", sound: .agentDone, round: "preview")
            await self.play(text: text, item: item, position: nil, remember: false, validate: { true })
            guard !Task.isCancelled, self.generation == previewGeneration else { return }
            self.previewMessage = self.status ?? String(localized: "Preview finished")
            self.isPreviewing = false
            self.isBusy = false
            self.deactivateAudioSession()
        }
    }

    func cancelPreview() {
        previewMessage = nil
        guard isPreviewing || recovery?.item.sessionID == "preview" else { return }
        previewTask?.cancel()
        previewTask = nil
        stop()
    }

    func stop() {
        recovery = nil
        canUseSystemSpeech = false
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        run = UUID()
        generation = UUID()
        runTotal = 0
        spokenCount = 0
        status = nil
        queue.cancel()
        queue.resume()
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
                      label: String? = nil, useSystemSpeech: Bool = false, validate: @escaping @MainActor () -> Bool) async {
        let current = generation
        let selection = PhoneReadAloudSelection.load()
        let providerReading: Bool = if case .provider = selection { !useSystemSpeech } else { false }
        activeValidation = validate
        defer { if generation == current { activeValidation = nil } }
        if let position { self.current = (item, position, runTotal) }
        do {
            try await waitWhilePaused()
            guard !Task.isCancelled, generation == current, validate() else { return }
            if providerReading, case .provider(let provider) = selection {
                guard let key = providerKey(provider), !key.isEmpty else {
                    status = String(localized: "Configure this provider’s API key or choose System speech.")
                    offerRecovery(text: text, item: item, position: position, remember: remember, validate: validate)
                    return
                }
                guard let synthesizer = makeSynthesizer(PhoneReadAloudSelection.configuration(provider)) else {
                    throw SpeechSynthesisFailure.configuration
                }
                status = String(localized: "Generating speech…")
                let data = try await synthesizer.synthesize(text, apiKey: key)
                guard !Task.isCancelled, generation == current, validate() else { return }
                try await waitWhilePaused()
                guard !Task.isCancelled, generation == current, validate() else { return }
                // Generating/failed speech needs no audio route. Activate only
                // after the request and its freshness checks have succeeded.
                try activateAudioSession()
                let player = try AVAudioPlayer(data: data)
                self.player = player
                guard playAudio(player) else { self.player = nil; throw SpeechSynthesisFailure.transport }
                status = label ?? String(localized: "Reading…")
                if remember, let source = sourceIdentity?() { latest = (text, item, source); canReplay = true }
                while (player.isPlaying || isPaused) && !Task.isCancelled && generation == current {
                    try await waitWhilePaused()
                    guard validate() else { stopPlayback(); status = String(localized: "Skipped · task or content style changed"); return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                if generation == current { self.player = nil }
            } else {
                try activateAudioSession()
                let synthesizer = AVSpeechSynthesizer()
                systemVoice = synthesizer
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: PhoneReadAloudSelection.language() == .chinese ? "zh-CN" : "en-US")
                // delegate is weak: keep this exact utterance's lifecycle alive
                // until a terminal callback, cancellation, or timeout.
                let lifecycle = SystemSpeechLifecycle(synthesizer: synthesizer, utterance: utterance)
                synthesizer.delegate = lifecycle
                defer {
                    synthesizer.delegate = nil
                    synthesizer.stopSpeaking(at: .immediate)
                    if generation == current { systemVoice = nil }
                }
                status = label ?? String(localized: "Reading…")
                if remember, let source = sourceIdentity?() { latest = (text, item, source); canReplay = true }
                synthesizer.speak(utterance)
                let clock = ContinuousClock()
                let completionLimit = max(60, Double(text.count))
                var activeTime = Duration.zero
                var started = false
                speech: while true {
                    try await waitWhilePaused()
                    try Task.checkCancellation()
                    guard generation == current else { return }
                    guard validate() else { stopPlayback(); status = String(localized: "Skipped · task or content style changed"); return }
                    switch lifecycle.state {
                    case .finished: break speech
                    case .cancelled: throw SystemSpeechLifecycle.Failure.cancelled
                    case .speaking:
                        if !started { started = true; activeTime = .zero }
                    case .queued: break
                    }
                    // A stalled system service must fail, not hold the queue
                    // forever. Paused time is excluded; long content receives
                    // a generous completion budget of one second per character.
                    let limit = started ? completionLimit : 15
                    guard activeTime < .seconds(limit) else { throw SystemSpeechLifecycle.Failure.timedOut }
                    let tick = clock.now
                    try await Task.sleep(for: .milliseconds(100))
                    activeTime += tick.duration(to: clock.now)
                }
            }
            if generation == current, !Task.isCancelled { spokenCount += 1; status = label }
        } catch let failure as SpeechSynthesisFailure {
            guard generation == current, !Task.isCancelled else { return }
            status = NSLocalizedString(failure.message, comment: "Speech failure")
            if providerReading { offerRecovery(text: text, item: item, position: position, remember: remember, validate: validate) }
        } catch is CancellationError {
            // Skipped or stopped: the owner already said why.
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            status = String(localized: "Could not play the audio.")
            if providerReading { offerRecovery(text: text, item: item, position: position, remember: remember, validate: validate) }
        }
    }

    private func offerRecovery(text: String, item: AnnouncementPlan.Item, position: Int?, remember: Bool,
                               validate: @escaping @MainActor () -> Bool) {
        recovery = Recovery(text: text, item: item, position: position, remember: remember, validate: validate)
        canUseSystemSpeech = true
        isPaused = true
        queue.pause()
        deactivateAudioSession()
    }

    /// An explicit one-item fallback. It reuses verified text, never calls a paid
    /// service, never changes the configured provider, and rechecks the round.
    func useSystemSpeech() {
        guard let recovery, !voiceOwnsAudio else { return }
        self.recovery = nil
        canUseSystemSpeech = false
        guard recovery.validate() else {
            status = String(localized: "Skipped · task or content style changed")
            isPaused = false
            queue.resume()
            return
        }
        let runID = run
        previewMessage = nil
        let preview = recovery.item.sessionID == "preview"
        if preview { isPreviewing = true }
        queue.enqueue(id: "system-recovery/" + UUID().uuidString, priority: true) { [weak self] in
            guard let self, self.run == runID else { return }
            await self.play(text: recovery.text, item: recovery.item, position: recovery.position,
                            remember: recovery.remember, useSystemSpeech: true, validate: recovery.validate)
            if preview, self.run == runID {
                self.previewMessage = self.status ?? String(localized: "Preview finished")
                self.isPreviewing = false
            }
        }
        isPaused = false
        queue.resume()
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
        ownsAudioSession = true
    }

    private func deactivateAudioSession() {
        guard ownsAudioSession, !voiceOwnsAudio else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            ownsAudioSession = false
        } catch {
            // Retain ownership so a later Stop can retry a failed release.
        }
    }
}

/// The strip above the composer while the phone reads: what is being said
/// and where it sits in the run, with pause, skip, replay and stop.
struct AnnouncerStrip: View {
    @ObservedObject var announcer: PhoneAnnouncer
    let replay: () -> Void
    /// Opens the voice page; the strip's reading is the button for it.
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
            Image(systemName: announcer.isBusy ? "speaker.wave.2" : "speaker")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CompanionPalette.ink3)
                .frame(width: 16)
                .accessibilityHidden(true)
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
            }
            // The reading is a 44pt target even when it is one short line.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            // One element that reads what is playing and opens the voice page.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Open the voice page")
            .accessibilityAction { open() }
            // 30pt keys with 44pt targets: 14pt apart so the targets don't overlap.
            HStack(spacing: 14) {
            if announcer.isBusy {
                PhoneCircleButton(announcer.isPaused ? "play.fill" : "pause.fill", size: 30, tint: CompanionPalette.ink2) {
                    announcer.togglePause()
                }
                .disabled(announcer.canUseSystemSpeech || announcer.voiceOwnsAudio)
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
        }
        .padding(.horizontal, PhoneMetrics.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.bg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phone-announcer-strip")
    }
}
