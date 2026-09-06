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
    private var lastProviderQuota: [ProviderQuota] = []
    private var runTask: Task<Void, Never>?
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
    private var watchApprovals = WatchApprovalGate()
    /// Tells the Mac who this phone is and how to push to it. Run once per
    /// connection attempt, not once per launch: the Mac's device registry is
    /// repaired by the next reconnection after a Mac restart, without the user
    /// having to cold-launch this app.
    private let reportDevice: @MainActor (PairingPayload) -> Void

    init(streamer: SnapshotStreaming = WebSocketSnapshotClient(),
         notifier: AttentionNotifier = LocalNotifier(),
         decisionClient: DecisionClient = HTTPDecisionClient(),
         watchRelay: WatchRelay? = WatchRelay(transport: WatchConnectivityTransport()),
         reportDevice: @escaping @MainActor (PairingPayload) -> Void = {
             PushRegistration.shared.update(pairing: $0)
         }) {
        self.streamer = streamer
        self.notifier = notifier
        self.decisionClient = decisionClient
        self.watchRelay = watchRelay
        self.reportDevice = reportDevice
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
        watchRelay?.onApprovalRequest = { [weak self] request in
            guard let self else {
                return WatchApprovalResult(attemptId: request.attemptId, outcome: .failed)
            }
            return await self.decideFromWatch(request)
        }
    }

    /// Act on a one-shot decision the Watch asked for, and say what happened.
    ///
    /// Everything the Watch sent is re-checked here: the session must still be
    /// waiting, the approval id must still be the pending one, and the detail
    /// must still be the kind a wrist may decide on. The Watch cannot express
    /// `alwaysAllow` or `allowSession` at all — `WatchApprovalChoice` has two
    /// cases — so no payload from the wrist can persist a permission rule
    /// (ADR-0010).
    func decideFromWatch(_ request: WatchApprovalRequest) async -> WatchApprovalResult {
        func result(_ outcome: WatchApprovalOutcome) -> WatchApprovalResult {
            WatchApprovalResult(attemptId: request.attemptId, outcome: outcome)
        }
        switch watchApprovals.admit(request, sessions: allSessions) {
        case .duplicate:
            // The same tap, twice. It already landed; do not send it again.
            return result(.accepted)
        case .refused:
            return result(.refused)
        case .send(let approvalId, let decision):
            if isDemo {
                decide(approvalId, decision)
                watchApprovals.commit(request.attemptId)
                return result(.accepted)
            }
            guard let pairing else { return result(.failed) }
            guard await decisionClient.decide(pairing, approvalId: approvalId, decision: decision)
            else { return result(.failed) }
            watchApprovals.commit(request.attemptId)
            return result(.accepted)
        }
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
        return result(outcome)
    }

    /// Register this Live Activity's APNs push token with the Mac. Best-effort.
    private func uploadActivityToken(_ token: String) {
        guard !isDemo, let pairing,
              let url = URL(string: "http://\(pairing.host):\(pairing.port)/activity") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        Task { _ = try? await URLSession.shared.data(for: request) }
    }

    func start(_ pairing: PairingPayload) {
        stop()
        isDemo = false
        self.pairing = pairing
        ConnectionStore.observePairing(pairing)
        pairingEpoch = ConnectionStore.pairingEpoch
        sourceID = nil
        groups = SessionGroups([])
        state = .connecting
        relayToWatch([])
        policy = SoundPolicy()                        // fresh connection → suppress the backlog
        runTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Every attempt, not just the first: the Mac may have restarted
                // (emptying its registry) while this app stayed alive in the
                // background, and nothing else re-uploads the APNs token.
                self.reportDevice(pairing)
                for await snapshot in self.streamer.stream(pairing) {
                    if Task.isCancelled { return }
                    await self.apply(snapshot)
                }
                if Task.isCancelled { return }
                self.state = .failed(String(localized: "Disconnected — reconnecting…"))
                self.relayToWatch(self.allSessions)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        Task { await liveActivity.end() }
    }

    func forgetPairing() {
        stop()
        pairing = nil
        sourceID = nil
        pairingEpoch = ConnectionStore.pairingEpoch
        state = .connecting
        groups = SessionGroups([])
        lastProviderQuota = []
        relayToWatch([])
    }

    /// Play the pairing-success cue. Called once when a fresh pairing is saved
    /// (a QR scan or manual connect), not on automatic reconnects.
    func confirmPairing() {
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
        projection.relayRevision = ConnectionStore.nextRelayRevision()
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
    func performVoiceAction(_ action: VoiceAction) -> String {
        switch action {
        case .approve(let project):
            guard let s = match(project), let ap = s.pendingApproval else { return "No session to approve." }
            decide(ap.id, approve: true); return "Approved \(s.project)."
        case .deny(let project):
            guard let s = match(project), let ap = s.pendingApproval else { return "No session to deny." }
            decide(ap.id, approve: false); return "Denied \(s.project)."
        case .answer(let project, let text):
            guard let s = match(project) else { return "No matching session." }
            answer(s.id, answer: text); return "Replied to \(s.project)."
        case .none:
            return ""
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
            // Resolve locally so a reviewer sees the approval card dismiss (any choice).
            let resolved = (groups.needsResponse + groups.working + groups.done).map { s -> AgentSession in
                guard s.pendingApproval?.id == approvalId else { return s }
                var s = s; s.pendingApproval = nil; s.waitKind = nil; s.status = .working
                return s
            }
            install(resolved)
            return
        }
        guard let pairing else { return }
        Task { await decisionClient.decide(pairing, approvalId: approvalId, decision: decision) }
    }


    /// Back-compat for the voice companion's approve/deny intents.
    func decide(_ approvalId: String, approve: Bool) { decide(approvalId, approve ? .allow : .deny) }

    /// Answers from the question card, keyed by question id.
    func answer(_ sessionId: String, answers: QuestionAnswers) {
        guard !answers.isEmpty else { return }
        if isDemo {
            let flat = answers.values.flatMap { $0 }.joined(separator: ", ")
            answer(sessionId, answer: flat)
            return
        }
        guard let pairing else { return }
        Task { await decisionClient.answer(pairing, sessionId: sessionId, answers: answers) }
    }

    func answer(_ sessionId: String, answer: String) {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isDemo {
            let resolved = (groups.needsResponse + groups.working + groups.done).map { s -> AgentSession in
                guard s.id == sessionId else { return s }
                var s = s
                s.pendingQuestion = nil
                s.waitKind = nil
                s.status = .working
                s.summary = "Answered from phone: \(answer)"
                return s
            }
            install(resolved)
            return
        }
        guard let pairing else { return }
        Task { await decisionClient.answer(pairing, sessionId: sessionId, answer: answer) }
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
            AgentSession(
                id: "demo-work", agent: .codex, project: "ios-vibebuddy", branch: "main",
                model: "gpt-5-codex", status: .working, summary: "Running the test suite…",
                tokens: 1500, contextTokens: 64_000, contextWindow: 200_000,
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
        acknowledge(sessionId)
        let desktopThread = allSessions.first { $0.id == sessionId }?.jumpsToDesktopThread ?? false
        Task {
            let outcome = await decisionClient.jump(pairing, sessionId: sessionId)
            showToast(Self.jumpMessage(outcome, desktopThread: desktopThread))
        }
    }

    /// A user explicitly opened/selected this task. The Mac remains the source
    /// of truth; demo mode mirrors the same transition locally.
    func acknowledge(_ sessionId: String) {
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
        guard session.hasUnreadCompletion, let completionID = session.completionID else { return }
        let request = CompletionReadRequest(sourceID: sourceID, sessionID: sessionId, completionID: completionID)
        Task { _ = await decisionClient.acknowledge(pairing, request: request) }

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
    static func jumpMessage(_ outcome: JumpOutcome?, desktopThread: Bool = false) -> String {
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

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.toast = nil
        }
    }

    private func apply(_ snapshot: Snapshot) async {
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
            guard await notifier.notify(alert), alert.delivery.interrupts else { continue }
            Haptics.play(for: alert.sound)   // a tasteful tap to go with the cue
            rang = true
        }
        if rang { cuePulse += 1 }   // let the buddy react
        // Answered on the Mac, or gone entirely: the banner it left on the phone
        // and on the wrist is describing something nobody is blocked on.
        notifications.record(alerts)
        notifier.withdraw(notifications.withdrawals(for: snapshot.sessions))
        observationDiagnostics = snapshot.observationDiagnostics ?? []
        recentDirectories = snapshot.recentDirectories ?? []
        dispatchAgents = snapshot.dispatchAgents ?? []
        lastProviderQuota = snapshot.providerQuota ?? []
        buddySessionIDs = BuddyScope.pruned(buddySessionIDs, toLive: snapshot.sessions)
        state = .connected
        sourceID = snapshot.sourceID
        install(snapshot.sessions, serverTime: snapshot.serverTime)
        await liveActivity.sync(sessions: snapshot.sessions)
    }

    /// Handle a `vibebuddy://session?id=…` deep link from the Live Activity.
    func open(_ url: URL) {
        guard let id = VibeBuddyDeepLink.sessionId(from: url) else { return }
        focusedSessionId = id
    }

    func clearFocus() { focusedSessionId = nil }
}
