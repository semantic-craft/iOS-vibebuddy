import Foundation
import VibeBuddyKit
import WatchConnectivity
import WidgetKit

/// Everything the Watch knows, and where it came from.
///
/// The Watch has exactly one source: the paired iPhone, over WatchConnectivity.
/// It opens no LAN socket, discovers no Mac, holds no bearer token, and calls no
/// daemon route — losing the Watch grants nobody access to anything.
///
/// Demo Mode is the one exception, and it is local: a deterministic scenario
/// rendered from a frozen clock so a screenshot of a given launch input always
/// reproduces.
@MainActor
final class WatchStateStore: NSObject, ObservableObject {
    @Published private(set) var state: WatchDashboardState?
    @Published var taskLink: WatchTaskLink?
    @Published var quotaSelection: WatchQuotaSelection?
    @Published private(set) var completionQueue = WatchCompletionQueue()
    private var completionAttempt: WatchCompletionRequest?
    private var retryTask: Task<Void, Never>?
    private var actionReplyTimeout: Task<Void, Never>?
    private var retryAfter: [WatchTaskLink: Date] = [:]
    private var retryCount: [WatchTaskLink: Int] = [:]
    /// The one action in flight — approve, deny, or stop — and everything the
    /// wrist may claim about it.
    @Published private(set) var pendingAction = WatchSessionActionState()
    /// Whether the iPhone is in range right now. It is the only way the Watch
    /// can tell "the phone stopped relaying" from "the phone is gone", and it is
    /// read live rather than relayed — a reachability flag inside a payload
    /// would be describing the moment the payload was sent. A decision is a live
    /// request and needs the phone awake, so it also gates the buttons.
    @Published private(set) var isPhoneReachable = false

    /// Sample data driven entirely by launch inputs; no relay is opened.
    let isDemo: Bool
    /// Demo Mode's frozen clock. Live state ages against the real one.
    let launchedAt: Date
    let initialPage: WatchPage
    /// Demo Mode only: an answer to open the confirmation page on at launch.
    ///
    /// That page is normally two taps deep, and it is the page this whole flow
    /// turns on — where the answer is read back and the target named. A
    /// simulator has no wrist, so without this input the one screen most worth
    /// reviewing is the one nobody can look at.
    ///
    /// Read through `consumeDemoAnswerDraft()`, which hands it over once for
    /// the whole app: the task detail is a sheet *over* the home screen, so two
    /// cards can be on screen at the same moment and only one of them may
    /// present a page.
    private var demoAnswerDraft: String?

    private var inbox = WatchStateInbox()
    private var session: WCSession?
    /// Which state boundaries have already been felt. Every arriving state is
    /// recorded here whether or not it is played, so a transition the wrist
    /// slept through is history by the time the app comes forward.
    private var haptics = WatchHapticTransitions()
    /// Only a wrist that is actually looking gets tapped. The iPhone's mirrored
    /// notification owns the other moment, and its short-look haptic belongs to
    /// the system.
    ///
    /// It starts false and is only ever raised by the window scene reporting
    /// itself active. The process is started for reasons that are not someone
    /// looking at the app — rendering a long look, taking a WatchConnectivity
    /// delivery — and a scene-phase observer cannot correct an optimistic guess
    /// because it never fires for a scene that does not appear. False also
    /// makes the first live state after a cold launch a baseline rather than
    /// news: whatever it says, the phone announced it hours ago.
    private var isForeground = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         now: Date = Date()) {
        launchedAt = now
        isDemo = environment["VIBEBUDDY_DEMO"] == "1"
        initialPage = environment["VIBEBUDDY_WATCH_PAGE"]
            .flatMap(WatchPage.init(rawValue:)) ?? .home
        demoAnswerDraft = isDemo
            ? environment["VIBEBUDDY_WATCH_ANSWER"].flatMap { $0.isEmpty ? nil : $0 }
            : nil
        super.init()

        if isDemo {
            let scenario = environment["VIBEBUDDY_WATCH_SCENARIO"]
                .flatMap(WatchDemoScenario.init(rawValue:)) ?? .normal
            state = scenario.state(now: now)
            isPhoneReachable = scenario.phoneReachable
            // Task detail is normally reached from a complication, which reads
            // a cache Demo Mode deliberately never writes. This is the launch
            // input that opens it anyway, so the screens that only exist there
            // — Stop, and its confirmation — are reviewable in a simulator.
            if let sessionID = environment["VIBEBUDDY_WATCH_TASK"], !sessionID.isEmpty {
                taskLink = WatchTaskLink(sourceID: WatchDemoScenario.sourceID,
                                         pairingEpoch: WatchDemoScenario.pairingEpoch,
                                         sessionID: sessionID, completionID: nil)
            }
            if let sample = state { seedHaptics(sample) }
            if environment["VIBEBUDDY_WATCH_HAPTIC_DEMO"] == "1" {
                rehearseHapticTransition()
            }
        } else {
            // A cold launch shows the last state the iPhone managed to deliver.
            // Its age is recomputed from the current clock, never restored as a
            // verdict, so old numbers cannot masquerade as live ones.
            if let saved = WatchComplicationStore.loadState() {
                completionQueue = saved.queue
                inbox = WatchStateInbox(state: saved.state)
                state = saved.state
                seedHaptics(saved.state)
                completionQueue.reconcile(with: saved.state)
            }
            activate()
            retryTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.flushCompletions()
                }
            }
        }
    }

    deinit {
        retryTask?.cancel()
        actionReplyTimeout?.cancel()
    }

    /// The launch input's answer, for the one card in front of the wearer.
    ///
    /// The task detail is a sheet *over* the home screen, so both cards exist
    /// at once and both would ask to present a page — which presents neither.
    /// Only the focused session gets it, and only once.
    func consumeDemoAnswerDraft(for sessionId: String) -> String? {
        guard let draft = demoAnswerDraft else { return nil }
        let focused = taskLink?.sessionID ?? state?.topAlert?.sessionId
        guard focused == sessionId else { return nil }
        demoAnswerDraft = nil
        return draft
    }

    func openTask(_ url: URL) {
        if let selection = WatchQuotaSelection(url: url) {
            taskLink = nil
            quotaSelection = selection
            return
        }
        guard let link = WatchTaskLink(url: url) else { return }
        quotaSelection = nil
        taskLink = link
    }

    /// Called only by the exact detail body after it has appeared.
    func viewed(_ link: WatchTaskLink) {
        if !isDemo, let task = link.task(in: state), task.presentation == .requiresInput,
           let session, isPhoneReachable {
            let request = WatchWaitReadRequest(pairingEpoch: link.pairingEpoch,
                read: WaitReadRequest(sourceID: link.sourceID, sessionID: link.sessionID,
                                      statusSince: task.statusSince, waitKind: task.waitKind ?? .question,
                                      pendingID: task.pendingID))
            if let payload = try? JSONEncoder().encode(request) {
                // Best effort only: no approval and no claim that an offline read synced.
                session.sendMessage([WatchWaitReadRequest.messageKey: payload],
                                    replyHandler: { @Sendable _ in }, errorHandler: { @Sendable _ in })
            }
        }
        completionQueue.viewed(link, state: state)
        persistCompletions()
        flushCompletions()
    }

    private func persistCompletions() {
        // Demo interactions must never replace the live cache or pending reads.
        guard !isDemo else { return }
        retryAfter = retryAfter.filter { completionQueue.links.contains($0.key) }
        retryCount = retryCount.filter { completionQueue.links.contains($0.key) }
        if let state, WatchComplicationStore.save(state, queue: completionQueue) {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationStore.kind)
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationStore.quotaKind)
        }
    }

    private func flushCompletions() {
        guard !isDemo, completionAttempt == nil, isPhoneReachable,
              let session, session.isReachable, let state,
              let link = completionQueue.links.first(where: {
                  $0.sourceID == state.sourceID && $0.pairingEpoch == state.pairingEpoch
                    && (retryAfter[$0] ?? .distantPast) <= Date()
              }) else { return }
        let request = WatchCompletionRequest(attemptID: UUID().uuidString, link: link)
        guard let payload = try? JSONEncoder().encode(request) else { return }
        completionAttempt = request
        session.sendMessage([WatchCompletionRequest.messageKey: payload], replyHandler: { @Sendable [weak self] reply in
            let data = reply[WatchCompletionResult.messageKey] as? Data
            let result = data.flatMap { try? JSONDecoder().decode(WatchCompletionResult.self, from: $0) }
            Task { @MainActor [weak self] in self?.completionReturned(result, request: request) }
        }, errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.completionReturned(nil, request: request) }
        })
        // WatchConnectivity replies are not guaranteed to arrive. Release only
        // this attempt; the persisted exact-round record remains retryable.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.completionReturned(nil, request: request)
        }
    }

    private func completionReturned(_ result: WatchCompletionResult?, request: WatchCompletionRequest) {
        guard completionAttempt?.attemptID == request.attemptID else { return }
        guard result == nil || result?.attemptID == request.attemptID else { return }
        completionAttempt = nil
        let tries = min(4, (retryCount[request.link] ?? 0) + 1)
        retryCount[request.link] = tries
        retryAfter[request.link] = Date().addingTimeInterval(min(60, 5 * pow(2, Double(tries - 1))))
        // Even accepted/alreadyAcknowledged is only a receipt. Reconciliation
        // with the Mac's next snapshot clears this record and the face candidate.
        if let state { completionQueue.reconcile(with: state); persistCompletions() }
        flushCompletions()
    }

    /// Whether a decision could be sent at all. Demo Mode resolves its samples
    /// locally, so it needs no phone.
    var canReachPhone: Bool { isDemo || isPhoneReachable }

    /// Ask the iPhone to resolve this approval. A second tap while an action is
    /// in flight does nothing — `WatchSessionActionState` refuses to start a
    /// new attempt — so the decision cannot be submitted twice.
    func submit(_ alert: WatchAlert, _ choice: WatchApprovalChoice) {
        guard let state, isLive(state),
              state.alerts.contains(where: { $0.sessionId == alert.sessionId && $0.approvalId == alert.approvalId }),
              let request = pendingAction.begin(alert: alert, choice: choice,
                                                attemptId: UUID().uuidString)
        else { return }
        send(request)
    }

    /// Ask the iPhone to answer the question this text was written for.
    ///
    /// The binding is the argument, not the screen. `pendingId` comes from the
    /// draft — captured when the words were made — and is matched against the
    /// alert the *current* state holds. A confirmation page left open while the
    /// Mac answered the question and the agent asked the next one therefore
    /// sends nothing, rather than delivering an answer to a question nobody
    /// read. Returns false in exactly that case, so the page can say so instead
    /// of closing as though it had worked.
    ///
    /// A second tap while one is in flight sends nothing — the state machine
    /// refuses a new attempt — so a question cannot be answered twice.
    @discardableResult
    func submitAnswer(sessionId: String, pendingId: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let state, !trimmed.isEmpty, !pendingId.isEmpty,
              let current = state.alerts.first(where: {
                  $0.sessionId == sessionId && $0.isAnswerable && $0.pendingId == pendingId
              })
        else { return false }
        guard let request = pendingAction.begin(alert: current, answer: trimmed,
                                                attemptId: UUID().uuidString)
        // Keep this draft open when another action owns the in-flight slot.
        else { return false }
        // Same order as a stop: the attempt exists before the link is judged,
        // so a confirmation tapped over a dead link leaves a sentence on screen
        // instead of dismissing in silence.
        guard isLive(state) else {
            pendingAction.fail(attemptId: request.attemptId)
            return true
        }
        send(request)
        return true
    }

    /// Ask the iPhone to answer every question of the prompt these picks were
    /// made for.
    ///
    /// Same binding as `submitAnswer`: the prompt's identity comes from the
    /// walk, captured when it began, and is matched against the alert the
    /// *current* state holds. A walk left open while the Mac answered the
    /// prompt and the agent asked the next one sends nothing, and says so.
    /// The set is checked here as the iPhone will check it, so nothing partial
    /// ever leaves the wrist.
    @discardableResult
    func submitAnswers(sessionId: String, pendingId: String, answers: QuestionAnswers) -> Bool {
        guard let state, !pendingId.isEmpty,
              let current = state.alerts.first(where: {
                  $0.sessionId == sessionId && $0.isAnswerable && $0.pendingId == pendingId
              })
        else { return false }
        guard let request = pendingAction.begin(alert: current, answers: answers,
                                                attemptId: UUID().uuidString)
        else { return false }
        guard isLive(state) else {
            pendingAction.fail(attemptId: request.attemptId)
            return true
        }
        send(request)
        return true
    }

    /// Ask the iPhone to end the turn this confirmation was opened about.
    ///
    /// The turn is the argument, not the screen. `statusSince` comes from the
    /// intent captured by the first tap, and is matched against the task the
    /// *current* state holds — a confirmation page is exactly the window in
    /// which one turn can end and the next begin, and the wrist must not carry
    /// a stop across that boundary. Returns false when it would have, so the
    /// page says so instead of closing as though it had worked.
    ///
    /// Destructive, and confirmed on its own screen before it gets here.
    @discardableResult
    func submitStop(sessionID: String, statusSince: Date) -> Bool {
        guard let state,
              let current = state.followedTasks.first(where: { $0.sessionID == sessionID }),
              current.stop?.isOffered == true,
              abs(current.statusSince.timeIntervalSince1970 - statusSince.timeIntervalSince1970)
                  < WatchSessionActionGate.statusSinceTolerance
        else { return false }
        guard let request = pendingAction.begin(stop: current, attemptId: UUID().uuidString)
        // A different in-flight action must not dismiss this confirmation.
        else { return false }
        // The attempt is started before the link is judged, so a confirmation
        // tapped while the phone or the Mac is unreachable leaves something on
        // screen. A destructive action that dismisses its own sheet in silence
        // is indistinguishable, from the wrist, from one that worked.
        guard isLive(state) else {
            pendingAction.fail(attemptId: request.attemptId)
            return true
        }
        send(request)
        return true
    }

    /// Whether an action could actually travel right now: the phone in range,
    /// and the phone still talking to the Mac.
    private func isLive(_ state: WatchDashboardState) -> Bool {
        canReachPhone && state.connection(now: Date(), phoneReachable: canReachPhone) == .live
    }

    private func send(_ request: WatchSessionActionRequest) {
        if isDemo {
            resolveLocally(request)
            return
        }
        guard let session, session.isReachable,
              let payload = try? JSONEncoder().encode(request) else {
            pendingAction.fail(attemptId: request.attemptId)
            return
        }
        // Bound the wait independently of WCSession, as Home Assistant does.
        // Allow the phone's snapshot + action HTTP requests (10s + 15s), plus
        // wake-up and transport time. A missing receipt is not a failed action.
        actionReplyTimeout?.cancel()
        actionReplyTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
            self?.pendingAction.lost(attemptId: request.attemptId)
        }
        session.sendMessage(
            [WatchSessionActionRequest.messageKey: payload],
            replyHandler: { @Sendable [weak self] reply in
                // The message went out. A reply we cannot read says nothing
                // about whether the Mac acted, so it is a lost receipt rather
                // than a delivery failure — the wrist must not claim either way.
                let data = reply[WatchSessionActionResult.messageKey] as? Data
                let result = data.flatMap { try? JSONDecoder().decode(WatchSessionActionResult.self, from: $0) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.pendingAction.action?.attemptId == request.attemptId {
                        self.actionReplyTimeout?.cancel()
                    }
                    if let result { self.pendingAction.apply(result) }
                    else { self.pendingAction.lost(attemptId: request.attemptId) }
                }
            },
            errorHandler: { @Sendable [weak self] error in
                // WatchConnectivity reports both endings through this one
                // handler, and they are not the same thing to say out loud. A
                // reply that timed out or a delivery that failed means the
                // message may well have arrived; anything else — not reachable,
                // session not activated, no paired device, payload too large —
                // means it never left, and that one may plainly be tried again.
                let lost = Self.receiptWasLost(error)
                Task { @MainActor [weak self] in
                    if self?.pendingAction.action?.attemptId == request.attemptId {
                        self?.actionReplyTimeout?.cancel()
                    }
                    if lost { self?.pendingAction.lost(attemptId: request.attemptId) }
                    else { self?.pendingAction.fail(attemptId: request.attemptId) }
                }
            })
    }

    /// Whether this `sendMessage` error leaves the outcome genuinely unknown.
    ///
    /// A failed or timed-out reply may follow a delivered action. An unrecognised
    /// error is read as *lost* rather than
    /// as *not sent*: claiming a message never left is the assertion that costs
    /// something when it is wrong.
    nonisolated private static func receiptWasLost(_ error: Error) -> Bool {
        guard let code = (error as? WCError)?.code else { return true }
        switch code {
        case .notReachable, .sessionNotActivated, .sessionInactive, .sessionMissingDelegate,
             .deviceNotPaired, .watchAppNotInstalled, .payloadTooLarge, .payloadUnsupportedTypes,
             .invalidParameter:
            return false
        default:
            return true
        }
    }

    /// Demo Mode: the sample resolves the way a real one does — the action is
    /// accepted, and the button goes away only when the next state says the
    /// world changed, not because it was tapped.
    private func resolveLocally(_ request: WatchSessionActionRequest) {
        pendingAction.apply(WatchSessionActionResult(attemptId: request.attemptId, outcome: .accepted))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let current = self.state else { return }
            switch request.action {
            case .approval(let id, _): self.install(current.resolvingApproval(id))
            case .stop: self.install(current.resolvingStop(request.sessionId))
            case .answer(let pendingId, _), .answerAll(let pendingId, _):
                self.install(current.resolvingAnswer(pendingId))
            }
        }
    }

    /// Record a new state and let any in-flight decision see it.
    private func install(_ next: WatchDashboardState) {
        if state?.sourceID != next.sourceID || state?.pairingEpoch != next.pairingEpoch {
            // A different Mac or a different pairing: nothing in flight was
            // ever about this world. Clear it rather than let it describe one.
            pendingAction = WatchSessionActionState()
        }
        state = next
        pendingAction.reconcile(with: next)
        completionQueue.reconcile(with: next)
        persistCompletions()
        if let request = completionAttempt,
           request.link.sourceID != next.sourceID || request.link.pairingEpoch != next.pairingEpoch {
            completionAttempt = nil
        }
        flushCompletions()
        feel(next)
    }

    /// The state that was already on screen before this launch. It is the
    /// baseline every later boundary is measured against, and it is never
    /// itself played: a backlog is not news.
    private func seedHaptics(_ state: WatchDashboardState) {
        _ = haptics.advance(to: state, now: Date())
    }

    /// Demo Mode only, behind its own launch input: hand the store a second
    /// state a moment after launch so a transition — and the tap it earns —
    /// can be exercised in the Simulator, which has neither a paired iPhone nor
    /// a haptic engine. Nothing else in Demo Mode changes.
    private func rehearseHapticTransition() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, let current = self.state else { return }
            var next = current
            next.alerts.append(WatchAlert(
                sessionId: "demo-watch-haptic", agent: .codex, project: "haptic-rehearsal",
                waitKind: .question, summary: "Waiting on an answer",
                request: "Which rhythm did you just feel?",
                handling: .remoteAvailable, waitingSince: Date()))
            next.counts.needsResponse += 1
            next.presentation.requiresInput += 1
            self.install(next)
        }
    }

    /// Say — in a rhythm rather than in words — what just changed.
    ///
    /// The boundary is recorded before anything is played, so a state that
    /// arrives while the wrist is down is remembered as already-known rather
    /// than replayed as news later.
    private func feel(_ state: WatchDashboardState) {
        let now = Date()
        let earned = haptics.advance(to: state, now: now)
        guard isForeground, !earned.isEmpty else { return }
        guard let cue = WatchHaptics.cue(forAnyOf: earned,
                                         categories: state.effectiveCategories,
                                         quiet: state.isQuiet(at: now)) else {
            WatchHapticPlayer.shared.play([], reason: "snapshot \(earned.map(\.rawValue).joined(separator: "+"))")
            return
        }
        WatchHapticPlayer.shared.play(cue.beats, reason: "snapshot \(cue.category.rawValue)")
    }

    func becameActive() {
        guard !isDemo, let session else { isForeground = true; return }
        // Incorporate the actual latest context before sending persisted work.
        // This one is taken while still counted as background on purpose: what
        // the phone wrote before you raised your wrist is the backlog, and its
        // mirrored notification has already said it. Only what arrives *after*
        // the app is up is news the wrist should tap out.
        receive(session.receivedApplicationContext[WatchStateInbox.contextKey] as? Data)
        isForeground = true
        linkChanged(reachable: session.isReachable)
    }

    func resignedActive() {
        isForeground = false
    }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    fileprivate func linkChanged(reachable: Bool) {
        isPhoneReachable = reachable
        flushCompletions()
    }

    /// Take a payload from the relay. A payload that cannot be decoded leaves
    /// the last known good state on screen rather than blanking the Watch.
    fileprivate func receive(_ payload: Data?) {
        guard inbox.accept(payload), let accepted = inbox.state else { return }
        install(accepted)
    }
}

extension WatchStateStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // WatchConnectivity holds the newest context across launches; take it
        // now rather than waiting for the iPhone to have something new to say.
        // Only the payload crosses the actor boundary — `[String: Any]` is not
        // Sendable, and nothing else in the context is ours.
        let payload = session.receivedApplicationContext[WatchStateInbox.contextKey] as? Data
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.receive(payload)
            self?.linkChanged(reachable: reachable)
        }
    }

    /// The iPhone's newest state. It arrives whether the phone wrote it from the
    /// foreground, from behind a locked screen, or just before it was suspended:
    /// the system carries the context on after the sending app exits.
    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        let payload = applicationContext[WatchStateInbox.contextKey] as? Data
        Task { @MainActor [weak self] in self?.receive(payload) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in self?.linkChanged(reachable: reachable) }
    }
}
