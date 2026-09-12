import Foundation
import UIKit
import VibeBuddyKit

/// Consumes the live snapshot stream and publishes grouped sessions, connection
/// state, and notifications. Reconnects automatically when the socket drops.
@MainActor
final class DashboardStore: ObservableObject {
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var groups = SessionGroups([])
    @Published private(set) var observationDiagnostics: [AgentObservationDiagnostic] = []
    /// Directories the Mac has seen sessions run in — where a new task may start.
    @Published private(set) var recentDirectories: [String] = []
    /// Agents the Mac can start a new task for right now.
    @Published private(set) var dispatchAgents: [AgentKind] = []
    /// Sessions the user has pointed the buddy at (in-memory, never persisted).
    /// Empty = the buddy sees all sessions; pruned to live IDs on every snapshot.
    @Published private(set) var buddySessionIDs: Set<String> = []
    @Published private(set) var state: ConnectionState = .connecting
    /// Bumped whenever a cue fires, so the buddy can react in step with the sound.
    @Published private(set) var cuePulse = 0
    /// Set when a Live Activity / deep link asks to open a specific session; the
    /// dashboard scrolls to and highlights it, then clears it via `clearFocus()`.
    @Published var focusedSessionId: String?
    private(set) var focusedCompletionNotificationID: String?
    @Published var completionLinkUnavailable = false

    let completionReads: PhoneCompletionReads

    @Published private(set) var phoneActions: [String: PhoneActionResult] = [:]
    private var sendingPhoneSessions: Set<String> = []
    private var phoneActionIdentity: [String: String] = [:]

    private func actionIdentity(_ session: AgentSession) -> String {
        "\(sourceID ?? "unpaired")|\(session.id)|\(session.pendingApproval?.id ?? session.pendingQuestion?.id ?? String(session.statusSince.timeIntervalSince1970))|\(session.status)|\(ApprovalEligibility.unavailableReason(for: session)?.rawValue ?? "available")"
    }

    func phoneActionState(for session: AgentSession) -> PhoneActionResult? {
        phoneActionIdentity[session.id] == actionIdentity(session) ? phoneActions[session.id] : nil
    }

    func phoneActionDisabled(for session: AgentSession) -> Bool {
        guard isDemo || state == .connected else { return true }
        guard let result = phoneActionState(for: session) else { return false }
        return result == .sending || result == .unconfirmed
            || (result == .received && (session.pendingApproval != nil || session.pendingQuestion != nil))
    }

    /// Every attempt reads authenticated authority before sending. Ambiguous POSTs
    /// are never replayed: an unchanged snapshot cannot prove non-execution.
    private func sendPhoneAction(_ session: AgentSession,
                                 send: (PairingPayload, AgentSession) async -> PhoneActionResult) async -> PhoneActionResult {
        guard !Task.isCancelled, isDemo || state == .connected else { return .failed }
        if sendingPhoneSessions.contains(session.id) { return .sending }
        if phoneActionDisabled(for: session) { return phoneActionState(for: session) ?? .unconfirmed }
        guard let pairing else { showToast(PhoneActionResult.notPaired.message); return .notPaired }
        sendingPhoneSessions.insert(session.id)
        defer { sendingPhoneSessions.remove(session.id) }
        let identity = actionIdentity(session)
        let epoch = pairingEpoch
        let generation = connectionGeneration
        phoneActionIdentity[session.id] = identity
        phoneActions[session.id] = .sending
        let result: PhoneActionResult
        if let snapshot = await decisionClient.actionSnapshot(pairing) {
            if Task.isCancelled || epoch != pairingEpoch || generation != connectionGeneration || snapshot.sourceID != sourceID || state != .connected {
                result = .expired
            } else if let current = snapshot.sessions.first(where: { $0.id == session.id }),
                      actionIdentity(current) == identity,
                      current.pendingApproval?.isAnswerable != false,
                      current.pendingQuestion?.isAnswerable != false,
                      current.pendingQuestion?.expiresAt.map({ $0 > snapshot.serverTime }) != false {
                result = Task.isCancelled ? .failed : await send(pairing, current)
            } else { result = .expired }
        } else { result = .failed }
        if epoch == pairingEpoch {
            phoneActions[session.id] = result
            showToast(result.message)
        }
        // A fresh authority read observes change, but does not turn uncertainty
        // into success and never automatically resends the operation.
        if result == .unconfirmed { _ = await decisionClient.actionSnapshot(pairing) }
        return result
    }
    /// Last fetched recent-output slice per session. Opening the pane reads;
    /// it never acknowledges a completion.
    @Published private(set) var recentOutputs: [String: RecentOutput] = [:]

    private let streamer: SnapshotStreaming
    private let notifier: AttentionNotifier
    private let decisionClient: DecisionClient
    private let liveActivity = LiveActivityManager()
    /// The only door to the wrist. Optional so tests and Simulator runs without
    /// a paired Watch behave exactly as they did before the companion existed.
    private let watchRelay: WatchRelay?
    /// The Mac's own clock for the last snapshot, so the relayed state says when
    /// the Mac saw the world rather than when this phone re-rendered it.
    private var lastServerTime = Date()
    private var sourceID: String?
    /// Account allowance as the Mac last reported it. The phone forwards it
    /// untouched — normalization already happened where the provider's own
    /// convention was still known.
    @Published private(set) var lastProviderQuota: [ProviderQuota] = []
    /// Local Claude Code / Codex token spend as the Mac last reported it.
    @Published private(set) var lastTokenConsumption: TokenConsumptionSnapshot?
    private var runTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    /// Decides which sound (if any) each snapshot earns. Reset per connection so
    /// the opening backlog of an already-waiting session stays silent.
    private var policy = SoundPolicy()
    /// What this phone has told you is waiting. The iPhone is the only device
    /// that schedules a notification — the Watch mirrors it — so this is also
    /// the only place that can take one back once the wait is over.
    private var notifications = WaitingNotificationLedger()
    private var pairing: PairingPayload?
    private var isDemo = false
    /// Deep links can arrive before `start(_:)` installs the pairing on a cold
    /// launch. Keep those explicit reads until they can reach the Mac authority.
    private var pairingEpoch = ConnectionStore.pairingEpoch
    /// Judges taps that arrive from the wrist against the sessions this phone
    /// actually holds. The Watch's screen is a memory of a snapshot; this is the
    /// only copy that was ever authenticated.
    private var watchActions = WatchSessionActionGate()
    /// Tells the Mac who this phone is and how to push to it. Run once per
    /// connection attempt, not once per launch: the Mac's device registry is
    /// repaired by the next reconnection after a Mac restart, without the user
    /// having to cold-launch this app.
    private let reportDevice: @MainActor (PairingPayload) -> Void

    init(streamer: SnapshotStreaming = WebSocketSnapshotClient(),
         notifier: AttentionNotifier = LocalNotifier(),
         decisionClient: DecisionClient = HTTPDecisionClient(),
         watchRelay: WatchRelay? = WatchRelay(transport: WatchConnectivityTransport()),
         completionReads: PhoneCompletionReads = PhoneCompletionReads(),
         reportDevice: @escaping @MainActor (PairingPayload) -> Void = {
             PushRegistration.shared.update(pairing: $0)
         }) {
        self.completionReads = completionReads
        self.streamer = streamer
        self.notifier = notifier
        self.decisionClient = decisionClient
        self.watchRelay = watchRelay
        self.reportDevice = reportDevice
        completionReads.onChange = { [weak self] in self?.objectWillChange.send() }
        if ProcessInfo.processInfo.environment["VIBEBUDDY_SKIP_NOTIFICATIONS"] != "1" {
            notifier.requestAuthorization()
        }
        // Report the Live Activity's push token to the Mac so it can update the
        // activity in the background (dynamic-island/02).
        liveActivity.onPushToken = { [weak self] hex in self?.uploadActivityToken(hex) }
        watchRelay?.onWaitReadRequest = { [weak self] request in
            guard let self else { return false }
            return await self.acknowledgeWaitFromWatch(request)
        }
        watchRelay?.onCompletionRequest = { [weak self] request in
            guard let self else { return WatchCompletionResult(attemptID: request.attemptID, outcome: .failed) }
            return await self.acknowledgeFromWatch(request)
        }
        // The wrist's only way to act. It asks; this decides.
        watchRelay?.onSessionAction = { [weak self] request in
            guard let self else {
                return WatchSessionActionResult(attemptId: request.attemptId, outcome: .failed)
            }
            return await self.actFromWatch(request)
        }
    }

    /// Act on one thing the Watch asked for — approve, answer, or stop — and
    /// say what happened.
    ///
    /// Everything the Watch sent is re-checked twice: once against the sessions
    /// this phone already holds, and again against a snapshot fetched from the
    /// Mac's own authority right before the action goes out. The Watch's screen
    /// is a memory, and both re-checks exist so a tap made against that memory
    /// cannot act on a world that has moved — an approval that already
    /// resolved, a question that was answered on the Mac, a turn that ended and
    /// was replaced by the next one.
    ///
    /// The Watch cannot express `alwaysAllow` or `allowSession` at all —
    /// `WatchApprovalChoice` has two cases — so no payload from the wrist can
    /// persist a permission rule (ADR-0010).
    func actFromWatch(_ request: WatchSessionActionRequest) async -> WatchSessionActionResult {
        func result(_ outcome: WatchSessionActionOutcome) -> WatchSessionActionResult {
            WatchSessionActionResult(attemptId: request.attemptId, outcome: outcome)
        }
        guard isDemo || state == .connected else { return result(.failed) }
        let admitted = watchActions.admit(request, sessions: allSessions)
        switch admitted {
        case .duplicate:
            // The same tap, twice. It already landed; do not send it again.
            return result(.accepted)
        case .refused:
            return result(.refused)
        case .decide, .answer, .stop:
            break
        }
        if isDemo {
            guard resolveWatchActionInDemo(admitted, sessionId: request.sessionId) else {
                return result(.refused)
            }
            watchActions.commit(request.attemptId)
            return result(.accepted)
        }
        guard let pairing else { return result(.failed) }
        let epoch = pairingEpoch
        let generation = connectionGeneration
        guard let snapshot = await decisionClient.actionSnapshot(pairing) else { return result(.failed) }
        // The Mac's own copy, read just now, is what the action is judged on —
        // and it has to be the same Mac, the same pairing and the same live
        // connection this phone was showing when the tap arrived.
        guard epoch == pairingEpoch, generation == connectionGeneration, state == .connected,
              snapshot.sourceID == sourceID,
              let current = snapshot.sessions.first(where: { $0.id == request.sessionId })
        else { return result(.refused) }
        let revalidated = watchActions.admit(request, sessions: snapshot.sessions)
        switch revalidated {
        case .decide(let approvalId, let decision):
            guard await decisionClient.decide(pairing, approvalId: approvalId, decision: decision)
            else { return result(.failed) }
        case .answer(_, let text):
            // Three different answers, because they mean three different things
            // on a wrist. `.expired` is the Mac saying this question is gone —
            // the same thing `refused` says for a stop, and the opposite of
            // "try again". `.unconfirmed` is a reply that never came back to a
            // request the Mac may well have carried out, which is the one case
            // where claiming it did not send would be a lie.
            switch await decisionClient.phoneAnswer(pairing, session: current, text: text,
                                                    answers: nil, requestID: request.attemptId) {
            case .received: break
            case .expired: return result(.refused)
            case .unconfirmed: return result(.unknown)
            default: return result(.failed)
            }
        case .stop:
            // `refused` and `failed` are both a 409 on the wire and they mean
            // opposite things on a wrist: one says look at the task, the other
            // says the tap can be made again. Keep them apart.
            switch await decisionClient.phoneStop(pairing, session: current,
                                                  requestID: request.attemptId) {
            case .accepted: break
            case .refused: return result(.refused)
            case .unconfirmed: return result(.unknown)
            case .failed: return result(.failed)
            }
        case .duplicate:
            // Two copies of one tap raced past the first gate; the other copy
            // committed it. It landed — saying "no longer running" here would
            // send the user to look at a task that is being stopped.
            return result(.accepted)
        case .refused:
            return result(.refused)
        }
        watchActions.commit(request.attemptId)
        return result(.accepted)
    }

    /// Demo Mode resolves the sample locally, so the wrist can rehearse the
    /// whole flow without a Mac. The sample then travels the same relay as real
    /// data: the button goes away because the next state says the world
    /// changed, not because a button was tapped.
    private func resolveWatchActionInDemo(_ admitted: WatchSessionActionGate.Resolution,
                                          sessionId: String) -> Bool {
        switch admitted {
        case .decide(let approvalId, _):
            return decideDemo(approvalId) == .received
        case .answer(_, let text):
            return answerDemo(sessionId, text: text)
        case .stop:
            return stopDemo(sessionId)
        case .duplicate, .refused:
            return false
        }
    }

    /// Demo Stop mirrors an acknowledged user stop: done, without error or unread completion.
    private func stopDemo(_ sessionId: String) -> Bool {
        guard let session = allSessions.first(where: { $0.id == sessionId }),
              SessionActionSupport.resolveStop(for: session).isAvailable else { return false }
        install(allSessions.map { original in
            guard original.id == sessionId else { return original }
            var stopped = original
            stopped.status = .done
            stopped.failed = false
            stopped.userStopped = true
            stopped.hasUnreadCompletion = false
            stopped.completionID = nil
            stopped.summary = "Turn interrupted"
            stopped.statusSince = Date()
            return stopped
        })
        return true
    }

    func acknowledgeWaitFromWatch(_ message: WatchWaitReadRequest) async -> Bool {
        guard message.read.sourceID == sourceID, message.pairingEpoch == pairingEpoch,
              pairingEpoch == ConnectionStore.pairingEpoch, state == .connected, let pairing else { return false }
        let accepted = await decisionClient.acknowledgeWait(pairing, request: message.read)
        return accepted && self.pairing == pairing && message.read.sourceID == sourceID
            && message.pairingEpoch == self.pairingEpoch && pairingEpoch == ConnectionStore.pairingEpoch
    }

    func acknowledgeFromWatch(_ message: WatchCompletionRequest) async -> WatchCompletionResult {
        func result(_ outcome: CompletionReadOutcome) -> WatchCompletionResult {
            WatchCompletionResult(attemptID: message.attemptID, outcome: outcome)
        }
        let link = message.link
        guard link.sourceID == sourceID, link.pairingEpoch == pairingEpoch,
              pairingEpoch == ConnectionStore.pairingEpoch else { return result(.sourceMismatch) }
        guard state == .connected, let pairing, let request = link.readRequest else { return result(.failed) }
        // The daemon is authoritative for round and read state. A stale phone
        // snapshot must not manufacture a positive or negative receipt.
        let outcome = await decisionClient.acknowledge(pairing, request: request)
        guard self.pairing == pairing, link.sourceID == sourceID,
              link.pairingEpoch == self.pairingEpoch,
              pairingEpoch == ConnectionStore.pairingEpoch else { return result(.sourceMismatch) }
        completionReads.received(outcome, request: request)
        return result(outcome)
    }

    /// Register this Live Activity's APNs push token with the Mac. Best-effort.
    private func uploadActivityToken(_ token: String) {
        guard !isDemo, let pairing,
              let url = pairing.companionURL(path: "activity") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        Task { _ = try? await URLSession.shared.data(for: request) }
    }

    func start(_ pairing: PairingPayload) {
        connectionGeneration = UUID()
        completionReads.pause()
        CompletionNoticePhoneContext.sessions = []
        // Reconnecting is not an explicit stop: ActivityKit keeps the current
        // activity across process death, so the first snapshot must reclaim it.
        let changedSource = isDemo || (self.pairing != nil && self.pairing != pairing)
        runTask?.cancel()
        isDemo = false
        lastProviderQuota = []
        lastTokenConsumption = nil
        if self.pairing != pairing { phoneActions = [:]; phoneActionIdentity = [:] }
        self.pairing = pairing
        ConnectionStore.observePairing(pairing)
        pairingEpoch = ConnectionStore.pairingEpoch
        completionReads.select(epoch: pairingEpoch)
        recentOutputs = [:]
        sourceID = nil
        groups = SessionGroups([])
        state = .connecting
        relayToWatch([])
        policy = SoundPolicy()                        // fresh connection → suppress the backlog
        let generation = connectionGeneration
        runTask = Task { [weak self] in
            if changedSource { await self?.liveActivity.end() }
            while !Task.isCancelled {
                guard let self else { return }
                // Every attempt, not just the first: the Mac may have restarted
                // (emptying its registry) while this app stayed alive in the
                // background, and nothing else re-uploads the APNs token.
                self.reportDevice(pairing)
                var failure = String(localized: "Disconnected — reconnecting…")
                var requiresInput = false
                do {
                    for try await snapshot in self.streamer.stream(pairing) {
                        if Task.isCancelled || self.connectionGeneration != generation { return }
                        await self.apply(snapshot, generation: generation)
                    }
                } catch CompanionConnectionFailure.authentication {
                    failure = String(localized: "Access refused. Check your pairing token, then reconnect.")
                    requiresInput = true
                } catch CompanionConnectionFailure.invalidAddress {
                    failure = String(localized: "Invalid Mac address. Pair again with a valid host and port.")
                    requiresInput = true
                } catch {
                    if (error as? URLError)?.code == .timedOut {
                        failure = String(localized: "Mac did not respond — reconnecting…")
                    }
                }
                if Task.isCancelled || self.connectionGeneration != generation { return }
                self.state = .failed(failure)
                self.relayToWatch(self.allSessions)
                await self.liveActivity.sync(sessions: self.allSessions, allowsActions: false)
                if requiresInput { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        connectionGeneration = UUID()
        completionReads.pause()
        CompletionNoticePhoneContext.sessions = []
        runTask?.cancel()
        runTask = nil
        state = .failed(String(localized: "Disconnected"))
        relayToWatch(allSessions)
        return Task { await liveActivity.end() }
    }

    func forgetPairing() {
        pendingPairingConfirmation = false
        stop()
        completionReads.clear()
        pairing = nil
        recentOutputs = [:]
        sourceID = nil
        pairingEpoch = ConnectionStore.pairingEpoch
        state = .connecting
        groups = SessionGroups([])
        lastProviderQuota = []
        lastTokenConsumption = nil
        relayToWatch([])
    }

    /// Play the pairing-success cue. Called once when a fresh pairing is saved
    /// (a QR scan or manual connect), not on automatic reconnects.
    private var pendingPairingConfirmation = false

    func confirmPairing() {
        pendingPairingConfirmation = true
    }

    private func confirmConnectedPairing() {
        guard pendingPairingConfirmation else { return }
        pendingPairingConfirmation = false
        guard SoundPrefs.categories.isEnabled(NotificationSound.pairSuccess) else { return }
        notifier.confirmPairing()
    }

    /// A flat list of all known sessions, for the voice companion's context.
    var allSessions: [AgentSession] { groups.needsResponse + groups.working + groups.done }

    /// The one place that records a new set of sessions: it groups them, feeds
    /// the widget, and hands the wrist its own compact projection.
    private func install(_ sessions: [AgentSession], serverTime: Date? = nil) {
        if let serverTime { lastServerTime = serverTime }
        groups = SessionGroups(sessions)
        WidgetSnapshotStore.save(sessions: sessions)
        relayToWatch(sessions)
        // Live Activities trigger a system authorization sheet on a fresh
        // simulator. Keep dashboard/demo acceptance deterministic and opt in
        // explicitly when the Live Activity itself is under review; once opted
        // in, every demo transition (approve, answer, open) reaches the banner
        // exactly as a Mac snapshot would.
        if isDemo, ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO_LIVE_ACTIVITY"] == "1" {
            Task { await liveActivity.sync(sessions: sessions) }
        }
    }

    /// Project the dashboard for the Watch. Demo Mode supplies sample allowance;
    /// otherwise it is whatever the Mac last reported, and nothing at all when
    /// the Mac has reported nothing — an invented percentage would be a lie
    /// about someone's account.
    private func relayToWatch(_ sessions: [AgentSession]) {
        guard let watchRelay else { return }
        let now = Date()
        var projection = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions, serverTime: lastServerTime, sourceID: sourceID),
            quotas: isDemo ? WatchDemoScenario.normal.quotas(now: now) : lastProviderQuota,
            relay: state == .connected ? .live : .disconnected,
            now: lastServerTime,
            isDemo: isDemo)
        projection.pairingEpoch = pairingEpoch
        // The Mac's own name, so a send from the wrist can say where it is
        // going. A label only — the host, port and token stay on this phone.
        projection.macName = pairing?.macName
        projection.relayRevision = ConnectionStore.nextRelayRevision()
        // The wrist plays its own haptics off this state, so it needs the same
        // switches this phone obeys. Quiet travels as settings, not as a
        // verdict: the Watch decides against its own clock.
        projection.categories = SoundPrefs.categories
        projection.quiet = WatchQuietSettings(manual: SoundPrefs.manualQuiet, hours: SoundPrefs.quietHours)
        watchRelay.publish(projection)
    }

    /// The sessions the buddy is actually grounded in, honouring the scope toggles
    /// (empty selection = all). Read by `VoiceChat`'s contextProvider at call start.
    var buddyContext: [AgentSession] { BuddyScope.included(from: allSessions, selectedIDs: buddySessionIDs) }

    /// Include/exclude a session from the buddy's context (ephemeral). Takes effect
    /// on the next call — a live call keeps the snapshot it started with.
    func toggleBuddy(_ id: String) {
        if buddySessionIDs.contains(id) { buddySessionIDs.remove(id) }
        else { buddySessionIDs.insert(id) }
    }

    /// Execute a voice action on the matching session; returns a spoken confirmation.
    func performVoiceAction(_ action: VoiceAction) async -> String {
        guard !Task.isCancelled else { return "Cancelled before sending." }
        guard isDemo || pairing != nil else { return PhoneActionResult.notPaired.message }
        switch action {
        case .approve(let project), .deny(let project):
            guard let s = match(project), let ap = s.pendingApproval, ap.isAnswerable else {
                return "No matching remotely answerable approval. Check the current task on Mac."
            }
            let decision: ApprovalDecision
            if case .approve = action { decision = .allow } else { decision = .deny }
            return await decideConfirmed(ap.id, decision).message
        case .answer(let project, let text):
            guard let s = match(project) else { return "No unique matching session." }
            return await answer(s.id, answer: text).message
        case .none: return ""
        }
    }

    private func match(_ project: String) -> AgentSession? {
        // Conservative resolution (exact-first, unique-substring, refuse ambiguous)
        // so a voice approve never lands on the wrong real command target.
        VoiceSessionMatch.match(project, in: allSessions)
    }

    /// Populate the dashboard with sample sessions and no network, so the app is
    /// reviewable / explorable without a paired Mac.
    func startDemo() {
        stop()
        isDemo = true
        lastProviderQuota = []
        lastTokenConsumption = TokenConsumptionSnapshot.demo()
        pairing = nil
        state = .connected
        let demo = Self.demoSessions()
        buddySessionIDs = BuddyScope.pruned(buddySessionIDs, toLive: demo)
        install(demo, serverTime: Date())
        Task { await postDemoBanners(demo) }
    }

    /// Sample approval / question banners carry the same actions a live cue does.
    private func postDemoBanners(_ sessions: [AgentSession]) async {
        for session in sessions {
            if session.pendingApproval != nil {
                _ = await notifier.notify(SoundAlert(session: session, sound: .needsApproval))
            } else if session.waitKind == .question {
                _ = await notifier.notify(SoundAlert(session: session, sound: .needsAnswer))
            }
        }
    }

    func decide(_ approvalId: String, _ decision: ApprovalDecision) {
        if isDemo {
            _ = decideDemo(approvalId)
            return
        }
        Task { _ = await decideConfirmed(approvalId, decision) }
    }

    func decideConfirmed(_ approvalId: String, _ decision: ApprovalDecision) async -> PhoneActionResult {
        if isDemo { return decideDemo(approvalId) }
        guard let session = allSessions.first(where: { $0.pendingApproval?.id == approvalId }),
              ApprovalEligibility.approval(for: session) != nil else { return .expired }
        return await sendPhoneAction(session) { pairing, current in
            guard ApprovalEligibility.approval(for: current)?.id == approvalId else { return .expired }
            return await self.decisionClient.phoneDecision(pairing, approvalId: approvalId, decision: decision)
        }
    }

    @discardableResult
    private func answerDemo(_ sessionId: String, text: String) -> Bool {
        guard allSessions.contains(where: { $0.id == sessionId }) else { return false }
        install(allSessions.map { original in
            guard original.id == sessionId else { return original }
            var answered = original
            answered.pendingQuestion = nil
            answered.waitKind = nil
            answered.status = .working
            answered.summary = "Answered from phone: \(text)"
            return answered
        })
        return true
    }

    private func decideDemo(_ approvalId: String) -> PhoneActionResult {
        guard let session = allSessions.first(where: { $0.pendingApproval?.id == approvalId }),
              ApprovalEligibility.approval(for: session) != nil else { return .expired }
        install(allSessions.map { original in
            guard original.id == session.id else { return original }
            var s = original; s.pendingApproval = nil; s.waitKind = nil; s.status = .working
            return s
        })
        return .received
    }

    @discardableResult
    func answer(_ sessionId: String, answers: QuestionAnswers, expected: AgentSession? = nil) async -> PhoneActionResult {
        guard !answers.isEmpty else { return .failed }
        return await sendAnswer(sessionId, text: nil, answers: answers, expected: expected)
    }

    @discardableResult
    func answer(_ sessionId: String, answer: String, expected: AgentSession? = nil) async -> PhoneActionResult {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failed }
        return await sendAnswer(sessionId, text: answer, answers: nil, expected: expected)
    }

    private func sendAnswer(_ sessionId: String, text: String?, answers: QuestionAnswers?, expected: AgentSession?) async -> PhoneActionResult {
        guard let session = allSessions.first(where: { $0.id == sessionId }),
              expected.map({ actionIdentity($0) == actionIdentity(session) }) != false,
              session.pendingApproval == nil,
              session.pendingQuestion?.isAnswerable != false,
              session.pendingQuestion != nil || (session.agent == .codex && session.status != .needsResponse),
              answers == nil || session.pendingQuestion != nil else {
            showToast(PhoneActionResult.expired.message)
            return .expired
        }
        if isDemo {
            let spoken = text ?? answers?.values.flatMap { $0 }.joined(separator: ", ") ?? ""
            return answerDemo(sessionId, text: spoken) ? .received : .expired
        }
        return await sendPhoneAction(session) { pairing, current in
            await self.decisionClient.phoneAnswer(pairing, session: current, text: text, answers: answers)
        }
    }

    private static func demoSessions() -> [AgentSession] {
        let now = Date()
        return [
            AgentSession(
                id: "demo-edit", agent: .claudeCode, project: "todo-app", branch: "feat/reminders",
                model: "claude-opus-4-8", status: .needsResponse, waitKind: .permission,
                pendingApproval: PendingApproval(
                    id: "demo-ap", tool: "Edit", commandPreview: "src/reminders.ts",
                    filePath: "src/reminders.ts",
                    oldText: "todos.sort((a, b) => a.id - b.id)",
                    newText: "todos.sort((a, b) => a.dueDate - b.dueDate)"),
                summary: "Sort reminders by due date",
                tokens: 4200, contextTokens: 128_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-40), updatedAt: now.addingTimeInterval(-40)),
            // A permission whose exact command travelled in full: the one shape
            // the Watch may resolve one-shot. The Edit above deliberately stays
            // display-only there — its diff never leaves the phone.
            AgentSession(
                id: "demo-build", agent: .codex, project: "search-indexer", branch: "main",
                model: "gpt-5-codex", status: .needsResponse, waitKind: .permission,
                pendingApproval: PendingApproval(
                    id: "demo-ap-build", tool: "Bash",
                    commandPreview: "swift test --filter Index…",
                    command: "swift test --filter IndexWriterTests"),
                summary: "Run the index writer tests",
                tokens: 900, contextTokens: 22_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-18), updatedAt: now.addingTimeInterval(-18)),
            // Followed, Codex, and carried by the app-server connection: the one
            // shape a running turn can be ended remotely in, so the Watch's
            // Stop is rehearsable against sample data too.
            AgentSession(
                id: "demo-work", agent: .codex, project: "ios-vibebuddy", branch: "main",
                model: "gpt-5-codex", status: .working, summary: "Running the test suite…",
                tokens: 1500, contextTokens: 64_000, contextWindow: 200_000,
                observations: [ObservationEvidence(source: .appserver,
                                                   lastObservedAt: now.addingTimeInterval(-8),
                                                   health: .healthy)],
                attention: .followed,
                statusSince: now.addingTimeInterval(-8), updatedAt: now.addingTimeInterval(-8)),
            AgentSession(
                id: "demo-subagents", agent: .claudeCode, project: "web-dashboard", branch: "feat/auth",
                model: "claude-opus-4-8", status: .working, summary: "Refactoring the auth middleware…",
                tokens: 6300, contextTokens: 151_000, contextWindow: 200_000,
                activeTool: "Edit",
                childAgents: [
                    ChildAgent(id: "subagent:demo-explore", kind: .subagent, name: "Explore",
                               status: .running, lastActivity: "Grep",
                               updatedAt: now.addingTimeInterval(-12)),
                    ChildAgent(id: "task:demo-auth", kind: .task, name: "implementer",
                               type: "implementer", status: .running,
                               updatedAt: now.addingTimeInterval(-9)),
                ],
                statusSince: now.addingTimeInterval(-15), updatedAt: now.addingTimeInterval(-15)),
            AgentSession(
                id: "demo-grok", agent: .grok, project: "glaux-book", branch: "main",
                model: "grok-4.6", status: .working, summary: "Running the build script…",
                tokens: 2800, contextTokens: 96_000, contextWindow: 500_000,
                activeTool: "run_terminal_command",
                statusSince: now.addingTimeInterval(-6), updatedAt: now.addingTimeInterval(-6)),
            AgentSession(
                id: "demo-question", agent: .claudeCode, project: "docs-review",
                model: "claude-sonnet-4-5", status: .needsResponse, waitKind: .question,
                pendingQuestion: PendingQuestion(
                    id: "tone",
                    prompt: "Which revision style should I use?",
                    options: [
                        QuestionOption(id: "tight", label: "Tighten", value: "Tighten the draft without changing the argument."),
                        QuestionOption(id: "plain", label: "Plain language", value: "Make it plainer and keep the citations intact."),
                    ]),
                summary: "Which revision style should I use?",
                tokens: 2100, contextTokens: 92_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-24), updatedAt: now.addingTimeInterval(-24)),
            AgentSession(
                id: "demo-done", agent: .claudeCode, project: "docs-site",
                model: "claude-haiku-4-5", status: .done, summary: "Deployed to production.",
                tokens: 900, contextTokens: 20_000, contextWindow: 200_000,
                hasUnreadCompletion: true,
                statusSince: now.addingTimeInterval(-300), updatedAt: now.addingTimeInterval(-300)),
            AgentSession(
                id: "demo-error", agent: .codex, project: "release-check",
                model: "gpt-5-codex", status: .done, summary: "Build failed with two signing errors.",
                tokens: 3100, contextTokens: 48_000, contextWindow: 200_000,
                failed: true,
                statusSince: now.addingTimeInterval(-180), updatedAt: now.addingTimeInterval(-180)),
            AgentSession(
                id: "demo-idle", agent: .claudeCode, project: "api-notes",
                model: "claude-sonnet-4-5", status: .done, summary: "No unread updates.",
                tokens: 700, contextTokens: 12_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-420), updatedAt: now.addingTimeInterval(-420)),
        ]
    }

    /// A brief, self-clearing status line for one-shot actions (e.g. jump result).
    @Published var toast: String?
    private var toastTask: Task<Void, Never>?

    /// Start a new task on the Mac. Returns the Mac's answer as a toast-ready
    /// line; nil when it could not be reached.
    func dispatch(_ request: DispatchRequest) async -> String? {
        if isDemo {
            showToast(String(localized: "Demo mode: nothing was started"))
            return nil
        }
        guard let pairing else { showToast(String(localized: "Couldn't reach your Mac")); return nil }
        let result = await decisionClient.dispatch(pairing, request: request)
        switch result {
        case .started: showToast(String(localized: "Started — it will appear in Working"))
        case .rejected(let why), .unsupported(let why), .unavailable(let why): showToast(why)
        case nil: showToast(String(localized: "Couldn't reach your Mac"))
        }
        return result.map { "\($0)" }
    }

    func jump(_ sessionId: String) {
        guard let pairing else { showToast(String(localized: "Couldn't reach your Mac")); return }
        let session = allSessions.first { $0.id == sessionId }
        let desktopThread = session?.jumpsToDesktopThread ?? false
        let grokBot = session?.agent == .grokBot
        Task {
            let outcome = await decisionClient.jump(pairing, sessionId: sessionId)
            showToast(Self.jumpMessage(outcome, desktopThread: desktopThread, grokBot: grokBot))
        }
    }

    /// A user explicitly opened/selected this task. The Mac remains the source
    /// of truth; demo mode mirrors the same transition locally.
    func acknowledge(_ sessionId: String, displayedCompletion: CompletionReadRequest? = nil) {
        if isDemo {
            let sessions = allSessions.map { session -> AgentSession in
                guard session.id == sessionId else { return session }
                var session = session
                session.hasUnreadCompletion = false
                return session
            }
            install(sessions)
            return
        }
        guard let pairing, let sourceID,
              let session = allSessions.first(where: { $0.id == sessionId }) else { return }
        if session.status == .needsResponse {
            let read = WaitReadRequest(sourceID: sourceID, session: session)
            Task { _ = await decisionClient.acknowledgeWait(pairing, request: read) }
            return
        }
        guard session.status == .done, session.hasUnreadCompletion, session.failed != true,
              let request = displayedCompletion, request == completionRequest(for: session) else { return }
        do {
            try completionReads.viewed(request, epoch: pairingEpoch)
            completionReads.resume(pairing: pairing, sourceID: sourceID, epoch: pairingEpoch, client: decisionClient)
        } catch {
            showToast(String(localized: "Couldn't save read status — reopen this result to retry"))
        }

    }

    func completionRequest(for session: AgentSession) -> CompletionReadRequest? {
        guard let sourceID, session.status == .done, session.failed != true,
              let completionID = session.completionID else { return nil }
        return CompletionReadRequest(sourceID: sourceID, sessionID: session.id, completionID: completionID)
    }

    func completionReadStatus(for session: AgentSession) -> String? {
        guard let request = completionRequest(for: session) else { return nil }
        if completionReads.confirmed.contains(request) || !session.hasUnreadCompletion {
            return String(localized: "Read — confirmed by Mac")
        }
        if completionReads.entries.contains(where: { $0.request == request }) {
            return String(localized: "Viewed — waiting to sync with Mac")
        }
        return nil
    }

    /// Fetch the bounded recent-output slice. Does not acknowledge completions.
    func loadRecentOutput(_ sessionId: String) async {
        if isDemo {
            recentOutputs[sessionId] = Self.demoRecentOutput(sessionId, from: allSessions)
            return
        }
        guard let pairing else { return }
        let epoch = pairingEpoch
        let source = sourceID
        let generation = connectionGeneration
        if let output = await decisionClient.recentOutput(pairing, sessionId: sessionId),
           self.pairing == pairing, epoch == pairingEpoch, source == sourceID,
           generation == connectionGeneration, output.sessionId == sessionId {
            recentOutputs[sessionId] = output
        }
    }

    private static func demoRecentOutput(_ sessionId: String, from sessions: [AgentSession]) -> RecentOutput {
        guard let session = sessions.first(where: { $0.id == sessionId }) else {
            return .unavailable(sessionId: sessionId, reason: .unknownSession)
        }
        if let summary = session.summary, !summary.isEmpty {
            return RecentOutput(
                sessionId: sessionId, source: .transcript, updatedAt: session.updatedAt,
                entries: [RecentOutputEntry(role: "assistant", text: summary)])
        }
        return RecentOutput(sessionId: sessionId, source: .transcript, updatedAt: session.updatedAt)
    }

    /// Set, or with `nil` return to automatic, how much a session may interrupt
    /// you. The list flips at once; the Mac stays authoritative and the next
    /// snapshot either confirms it or puts it back. Demo Mode mirrors it locally.
    func setAttention(_ sessionId: String, _ level: SessionAttention?) {
        install(allSessions.map { session in
            guard session.id == sessionId else { return session }
            var session = session
            session.attentionOverride = level
            session.attention = level ?? .normal
            return session
        })
        guard !isDemo, let pairing else { return }
        Task { await decisionClient.setAttention(pairing, sessionId: sessionId, level: level) }
    }

    /// Honest feedback for a jump — success lands on the Mac, so the phone has to
    /// say so; `nil` means the Mac wasn't reachable. `activatedApp` is the case
    /// worth naming: the right app is now in front, but the session's own window
    /// wasn't reachable, so the user still has to find the tab themselves.
    static func jumpMessage(_ outcome: JumpOutcome?, desktopThread: Bool = false, grokBot: Bool = false) -> String {
        if grokBot {
            switch outcome {
            case .activatedApp: return String(localized: "Opened Grok Bot on your Mac — select the task in the app")
            case nil: return String(localized: "Couldn't reach your Mac")
            default: return String(localized: "Couldn't open Grok Bot on your Mac")
            }
        }
        // A Codex Desktop session has no terminal at either end: the Mac opened
        // its thread in ChatGPT, so saying "terminal" here would name a thing
        // the user never had.
        if desktopThread {
            switch outcome {
            case .focused:      return String(localized: "Opened the thread in ChatGPT on your Mac")
            case .activatedApp: return String(localized: "Opened ChatGPT on your Mac — find the thread there")
            case .unsupported:  return String(localized: "Couldn't open the thread — is ChatGPT running on your Mac?")
            case .noTerminal:   return String(localized: "No thread for this session")
            case .attached:     return String(localized: "Opened a terminal on your Mac attached to this session")
            case nil:           return String(localized: "Couldn't reach your Mac")
            }
        }
        switch outcome {
        case .focused:      return String(localized: "Focused the terminal on your Mac")
        case .activatedApp: return String(localized: "Opened the app on your Mac — find the tab there")
        case .unsupported:  return String(localized: "Can't focus this terminal type yet")
        case .noTerminal:   return String(localized: "No terminal for this session")
        case .attached:     return String(localized: "Opened a terminal on your Mac attached to this session")
        case nil:           return String(localized: "Couldn't reach your Mac")
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.toast = nil
        }
    }

    private func apply(_ incoming: Snapshot, generation: UUID) async {
        guard generation == connectionGeneration, !Task.isCancelled else { return }
        var snapshot = incoming
        snapshot.sessions = incoming.sessions.map { $0.validatingCompletionNotice(sourceID: incoming.sourceID) }
        CompletionNoticePhoneContext.sessions = snapshot.sessions
        // The shared policy owns all the sounding rules; we just supply context.
        // The category switches then drop whatever this phone does not want to
        // hear about — and what the phone never posts, the Watch never mirrors.
        let alerts = SoundPrefs.categories.filter(policy.evaluate(SoundPolicyInput(
            sessions: snapshot.sessions,
            now: Date(),
            appActive: UIApplication.shared.applicationState == .active,
            quietMode: SoundPrefs.effectiveQuiet())))
        var rang = false
        for alert in alerts {
            // A cue a push already delivered is not posted again (ADR-0012), and
            // then it earns no tap and no buddy reaction either.
            let notified = await notifier.notify(alert)
            guard generation == connectionGeneration, !Task.isCancelled else { return }
            guard notified, alert.delivery.interrupts else { continue }
            Haptics.play(for: alert.sound)   // a tasteful tap to go with the cue
            rang = true
        }
        if rang { cuePulse += 1 }   // let the buddy react
        // Answered on the Mac, or gone entirely: the banner it left on the phone
        // and on the wrist is describing something nobody is blocked on.
        notifications.record(alerts)
        notifier.withdraw(notifications.withdrawals(for: snapshot.sessions))
        guard !Task.isCancelled else { return }
        observationDiagnostics = snapshot.observationDiagnostics ?? []
        recentDirectories = snapshot.recentDirectories ?? []
        dispatchAgents = snapshot.dispatchAgents ?? []
        // A cancelled stream may resume after awaiting notification delivery.
        // Never let its old Mac readings repopulate a newly selected source.
        guard !Task.isCancelled else { return }
        lastProviderQuota = snapshot.providerQuota ?? []
        lastTokenConsumption = snapshot.tokenConsumption
        buddySessionIDs = BuddyScope.pruned(buddySessionIDs, toLive: snapshot.sessions)
        state = .connected
        confirmConnectedPairing()
        if sourceID != snapshot.sourceID { completionReads.pause() }
        if sourceID != snapshot.sourceID { recentOutputs = [:] }
        sourceID = snapshot.sourceID
        completionReads.reconcile(snapshot, epoch: pairingEpoch)
        if let pairing, let sourceID {
            completionReads.resume(pairing: pairing, sourceID: sourceID, epoch: pairingEpoch, client: decisionClient)
        }
        install(snapshot.sessions, serverTime: snapshot.serverTime)
        await liveActivity.sync(sessions: snapshot.sessions)
    }

    /// Handle a `vibebuddy://session?id=…` deep link from the Live Activity.
    func open(_ url: URL) {
        guard let id = VibeBuddyDeepLink.sessionId(from: url) else { return }
        focusedCompletionNotificationID = VibeBuddyDeepLink.completionNotificationID(from: url)
        focusedSessionId = id
    }

    func matchesCompletionNotification(_ notificationID: String, sessionID: String) -> Bool {
        allSessions.first { $0.id == sessionID }?
            .matchesCompletionNotification(notificationID, sourceID: sourceID) == true
    }

    func acknowledgeDisplayedCompletion(_ displayed: AgentSession) {
        guard displayed.status == .done, let completionID = displayed.completionID,
              allSessions.first(where: { $0.id == displayed.id })?.completionID == completionID else { return }
        acknowledge(displayed.id, displayedCompletion: completionRequest(for: displayed))
    }

    func clearFocus() {
        focusedSessionId = nil
        focusedCompletionNotificationID = nil
    }
}
