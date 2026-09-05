import SwiftUI
import AppKit
import Combine
import UserNotifications
import VibeBuddyKit
import VibeBuddyMacCore

struct PairedPhone: Codable, Equatable {
    var name: String
    var model: String?
    var systemVersion: String?
    var lastSeen: Date
    var pushRegistered: Bool

    var subtitle: String {
        [model, systemVersion].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }
}

/// Drives the menu bar: owns the server + store, polls for a snapshot, and
/// prepares the pairing QR. UI-facing state is published on the main actor.
@MainActor
final class MenuBarModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var observationDiagnostics: [AgentObservationDiagnostic] = []
    /// Directories sessions have run in, newest first — where a new task may start.
    @Published private(set) var recentDirectories: [String] = []
    /// Agents a new task can be started for from this Mac.
    @Published private(set) var dispatchAgents: [AgentKind] = []
    private let claudeLauncher = ClaudeBackgroundLauncher()
    /// The Codex app-server daemon connection (ADR-0011): on by default, and
    /// the rollout tailer + hooks keep covering Codex whenever it is off or
    /// the daemon is not running.
    @Published var codexAppServerEnabled: Bool = true
    /// Settings override for the presence policy: hold every prompt for the
    /// phone even while the person is at the Mac. Off by default.
    @Published var alwaysAskPhone: Bool = false
    static let alwaysAskPhoneKey = "alwaysAskPhone"
    @Published private(set) var codexAppServerDiagnostics = CodexAppServerMonitor.Diagnostics()
    @Published private(set) var lifecycleTimeline: [LifecycleJournalEntry] = []
    @Published private(set) var lifecycleJournalClearFailed = false
    @Published private(set) var notificationDeliveryHealth = NotificationDeliveryHealth()
    @Published private(set) var recentNotificationDeliveries: [NotificationDeliveryRecord] = []
    /// The outcome of the most recent jump per session id, shown transiently in
    /// the row that was clicked and cleared by `showJumpFeedback`.
    @Published private(set) var jumpFeedback: [String: JumpOutcome] = [:]
    /// Why the last Mac-card answer for a session went nowhere, when it did.
    @Published private(set) var answerFeedback: [String: String] = [:]
    private var jumpFeedbackClears: [String: Task<Void, Never>] = [:]
    /// Sessions the user has pointed the buddy at (in-memory, never persisted).
    /// Empty = the buddy sees all sessions; pruned to live IDs on every snapshot.
    @Published private(set) var buddySessionIDs: Set<String> = []
    @Published private(set) var pairing: PairingPayload?
    @Published private(set) var qrImage: NSImage?
    /// The most-recently paired phone's display metadata (persisted), shown in the UI.
    @Published private(set) var pairedPhone: PairedPhone?
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var glanceScale: CGFloat = 1.0
    @Published var showGlance: Bool = true
    @Published var glanceExpanded: Bool = false
    /// The cue currently unfolded under the notch (the glance's event layer).
    @Published private(set) var glanceCard: GlanceCard?
    private var glanceCards = GlanceCardQueue()
    private var glanceCardTicker: Task<Void, Never>?
    /// The pointer is on the glance: cards hold instead of timing out.
    private var glanceHeld = false
    @Published var openDashboardHotkey: Hotkey = .openDashboardDefault
    @Published var toggleGlanceHotkey: Hotkey = .toggleGlanceDefault
    /// Idle-cleanup window in hours; 0 means never. Default 2h.
    @Published var idleTimeoutHours: Double = 2
    /// Agent groups the user folded in the menu bar list (persisted). A folded
    /// group still shows its working rows — see `MenuSessionList`.
    @Published private(set) var collapsedMenuAgents: Set<AgentKind> = []
    let port: Int
    private let token: String
    private let store: SessionStore
    private let approvalRegistry = ApprovalRegistry()
    // Always-allow / allow-this-session state, shared with the embedded server so
    // the daemon's /approval path and this in-process UI agree (ADR 0010).
    private let allowStore = VibeBuddyAllowStore()
    private let sessionAllow = SessionAllowList()
    private let approvalContext = ApprovalContextStore()
    private let questionRegistry = QuestionRegistry()
    private let codexAppServerMonitor: CodexAppServerMonitor
    /// Live account usage from Claude's status line and the Codex daemon,
    /// consumed by the usage coordinator ahead of its spawning collectors.
    private let usageFeed = AccountUsageLiveFeed()
    static let codexAppServerEnabledKey = "codexAppServerEnabled"
    // Live Activity push tokens + the last content we pushed, so we only push on change.
    private let activityTokens = ActivityTokens()
    private var lastActivityKey: String?
    private let notifier = UserNotificationsNotifier()
    /// Session cues go to the glance first (a card under the notch) and only
    /// fall back to a system banner while the glance is hidden. Lazy so the
    /// router can point back at this model.
    private lazy var notificationCoordinator = NotificationCoordinator(
        notifier: GlanceAttentionRouter(banners: notifier) { [weak self] alert in
            self?.presentGlanceCard(alert) ?? false
        },
        delivery: deliveryRecorder)
    private let deliveryRecorder: NotificationDeliveryRecorder
    // Phone push: the same SoundPolicy engine, run from the Mac's perspective of
    // a backgrounded phone, so the phone hears the full pack (not just needs-you).
    private let pusher: APNsPusher?
    private let deviceTokens = DeviceTokens()
    private let budgetMonitor = BudgetMonitor()
    /// Account usage is intentionally separate from `sessions`; refresh errors
    /// never enter SessionStore or the progress notification pipeline.
    private let usage: AccountUsageCoordinator
    private var usageObserver: AnyCancellable?
    /// The voice companion (tap the buddy to talk). Lazy so `self` is fully built.
    lazy var voiceChat = VoiceChat(
        contextProvider: { [weak self] in
            guard let self else { return [] }
            return BuddyScope.included(from: self.sessions, selectedIDs: self.buddySessionIDs)
        },
        actionHandler: { [weak self] action in self?.performVoiceAction(action) ?? "" })
    private var pollTask: Task<Void, Never>?
    private var glance: GlanceWindow?
    private static let pairedPhoneInfoKey = "pairedPhoneInfo"
    private static let collapsedMenuAgentsKey = "menuCollapsedAgents"
    private static let legacyPairedPhoneKey = "pairedPhone"

    /// The live model, for callers that only hold a `@Sendable` closure (the
    /// daemon's presence check). Weak: the model owns the app's lifetime, not
    /// the other way round.
    private(set) static weak var shared: MenuBarModel?

    init(runtimeEnabled: Bool = true) {
        port = ProcessInfo.processInfo.environment["VIBEBUDDY_PORT"].flatMap(Int.init) ?? 9876
        let savedIdleTimeout = UserDefaults.standard.object(forKey: "idleTimeoutHours") as? Double ?? 2
        idleTimeoutHours = savedIdleTimeout
        store = SessionStore(
            staleAfter: Self.staleInterval(forHours: savedIdleTimeout),
            diagnosticsHome: FileManager.default.homeDirectoryForCurrentUser,
            journalURL: ProcessInfo.processInfo.environment["VIBEBUDDY_JOURNAL_PATH"].map {
                URL(fileURLWithPath: $0)
            } ?? LifecycleJournalLocation.defaultURL(),
            attentionURL: AttentionOverrides.defaultURL()
        )
        // File-based store (owner-only): no Keychain ACL, so an ad-hoc rebuild
        // never re-prompts. Shared with vibebuddyd's default store.
        token = (try? TokenStore.defaultStore().loadOrCreate()) ?? Token.generate()
        let saved = UserDefaults.standard.double(forKey: "glanceScale")
        let base: CGFloat = saved > 0 ? saved : Self.defaultGlanceScale()
        // Snap to one of the 3 presets so the menu Picker selection always matches.
        glanceScale = [0.8, 1.0, 1.2].min(by: { abs($0 - base) < abs($1 - base) }) ?? 1.0
        showGlance = UserDefaults.standard.bool(forKey: "showGlance", default: true)
        let appServerOn = UserDefaults.standard.bool(forKey: Self.codexAppServerEnabledKey, default: true)
        codexAppServerEnabled = appServerOn
        alwaysAskPhone = UserDefaults.standard.bool(forKey: Self.alwaysAskPhoneKey)
        // Presence is read on the main actor from the live snapshot; the
        // daemon and the monitor ask through this closure right before they
        // would hold a prompt for the phone.
        let presence = Presence.evaluator()
        codexAppServerMonitor = CodexAppServerMonitor(
            enabled: appServerOn, usageFeed: usageFeed,
            approvalRegistry: approvalRegistry, allowStore: allowStore, sessionAllow: sessionAllow,
            approvalContext: approvalContext, questionRegistry: questionRegistry,
            presence: presence)
        collapsedMenuAgents = Set((UserDefaults.standard.stringArray(forKey: Self.collapsedMenuAgentsKey) ?? [])
            .compactMap(AgentKind.init(rawValue:)))
        openDashboardHotkey = Hotkey.loadOpenDashboard()
        toggleGlanceHotkey = Hotkey.loadToggleGlance()
        usage = AccountUsageCoordinator(store: store, notifier: notifier, liveFeed: usageFeed)
        pairedPhone = Self.loadPairedPhone()
        let apnsConfig = APNsConfig.load()
        let deliveryURL = ProcessInfo.processInfo.environment["VIBEBUDDY_DELIVERY_LOG_PATH"].map {
            URL(fileURLWithPath: $0)
        } ?? NotificationDeliveryLogLocation.defaultURL()
        let recorder = NotificationDeliveryRecorder(
            url: deliveryURL, apnsConfigured: apnsConfig != nil)
        deliveryRecorder = recorder
        pusher = apnsConfig.flatMap { try? APNsPusher(config: $0, recorder: recorder) }
        notificationDeliveryHealth = NotificationDeliveryHealth(apnsConfigured: apnsConfig != nil)
        // The views read usage through this model's facades, so the coordinator's
        // changes have to reach the same `objectWillChange` they observe. Set up
        // after every stored property is initialized: the capture needs `self`.
        usageObserver = usage.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        Self.shared = self
        // Screenshot / exploration instance: seed sample sessions and skip the
        // server, polling, pairing, and notifications entirely. It never binds the
        // port or pushes to a phone, so it runs harmlessly alongside a real
        // instance and never touches real session data.
        let isDemo = ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1"
        if isDemo {
            sessions = MacDemoData.sessions()
            observationDiagnostics = MacDemoData.observationDiagnostics()
        } else if runtimeEnabled {
            notifier.requestAuthorization()
            startServer()
            preparePairing()
            startPolling()
            usage.start()
        }
        // Create the glance on the next main-runloop tick — NOT synchronously here.
        // Hosting/displaying a SwiftUI view that observes `self` while `init` is
        // still running trips an AttributeGraph precondition (NSHostingView.layout
        // → ViewGraph update on a half-initialized ObservableObject).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }            // throwaway @StateObject probe deallocated
            guard self.glance == nil else { return }  // create the glance exactly once
            guard runtimeEnabled || isDemo else { return }
            guard self.showGlance || isDemo else { return }  // honor the toggle (always on in demo)
            self.glance = GlanceWindow(model: self)
        }
        // Demo instance: open its own dashboard so it's ready to screenshot. The
        // notification is in-process (NotificationCenter.default), so it never
        // reaches a real instance running in another process.
        if isDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NotificationCenter.default.post(name: .openDashboard, object: nil)
            }
            // The demo never polls, so no cue is ever earned: unfold the sample
            // approval as a card once the glance exists, for screenshots / QA.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let demo = self.sessions.first(where: { $0.pendingApproval != nil }) else { return }
                _ = self.presentGlanceCard(SoundAlert(session: demo, sound: .needsApproval))
            }
        }
    }

    /// Quiet right now if the user toggled it, or the nightly window is active.
    static func effectiveQuiet(now: Date = Date()) -> Bool {
        NotificationQuietMode.isEffective(now: now)
    }

    var presentationSummary: TaskPresentationSummary { TaskPresentationSummary(sessions: sessions) }
    /// The buddy's mood, shared with the menu-bar icon and the glance so the Mac
    /// reads the same as the phone.
    var buddyState: BuddyState { BuddyState.from(SessionGroups(sessions), now: Date()) }
    var macDisplayName: String { Self.localMacName() }
    var pairingAddress: String {
        guard let pairing else { return "Not ready" }
        return "\(pairing.host):\(pairing.port)"
    }

    private func startServer() {
        // pusher: nil — push is driven from startPolling off the same cues the
        // Mac notifies on; the server only collects device tokens/prefs.
        let server = VibeBuddyServer(store: store, token: token, port: port,
                                     pusher: nil, deviceTokens: deviceTokens,
                                     activityTokens: activityTokens,
                                     codexRolloutMonitor: CodexRolloutMonitor(),
                                     codexAppServerMonitor: codexAppServerMonitor,
                                     usageFeed: usageFeed,
                                     approvalRegistry: approvalRegistry,
                                     allowStore: allowStore,
                                     sessionAllow: sessionAllow,
                                     approvalContext: approvalContext,
                                     questionRegistry: questionRegistry,
                                     presence: Presence.evaluator(),
                                     onDevicePaired: { [weak self] device in
                                         Task { @MainActor in self?.recordPairedDevice(device) }
                                     },
                                     claudeLauncher: claudeLauncher,
                                     onCompletionReminder: { [weak self] session in
                                         guard let self else { return false }
                                         return await self.deliverCompletionReminder(session)
                                     })
        Task.detached(priority: .utility) {
            do {
                try await server.runService()
                // Hummingbird consumes SIGTERM/SIGINT and returns after shutting
                // down the server and joining its rollout monitor. Finish the
                // app lifetime too, so a later open can start a healthy instance.
                await MainActor.run { NSApplication.shared.terminate(nil) }
            }
            catch { FileHandle.standardError.write(Data("server error: \(error)\n".utf8)) }
        }
    }

    private func preparePairing() {
        let host = LANAddress.primaryIPv4() ?? "127.0.0.1"
        let payload = Pairing.payload(host: host, port: port, token: token, macName: macDisplayName)
        pairing = payload
        if let cg = Pairing.qrImage(from: Pairing.qrJSONString(for: payload)) {
            qrImage = NSImage(cgImage: cg, size: NSSize(width: 220, height: 220))
        }
    }

    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.store.applyBackgroundSessions(ClaudeBackgroundSessions.load())
                let snapshot = await self.store.snapshot(now: Date())
                self.sessions = snapshot.sessions
                self.observationDiagnostics = snapshot.observationDiagnostics ?? []
                self.recentDirectories = snapshot.recentDirectories ?? []
                self.codexAppServerDiagnostics = await self.codexAppServerMonitor.diagnostics()
                var agents: [AgentKind] = []
                if await self.claudeLauncher.isSupported() { agents.append(.claudeCode) }
                if self.codexAppServerDiagnostics.connected { agents.append(.codex) }
                self.dispatchAgents = agents
                self.lifecycleTimeline = await self.store.recentLifecycle()
                self.buddySessionIDs = BuddyScope.pruned(self.buddySessionIDs, toLive: snapshot.sessions)
                self.tickGlanceCards()
                // Precise suppression: a finishing session stays silent when *its
                // own* terminal is frontmost, not just when VibeBuddy is.
                let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let focused = ForegroundTerminal.focusedSessionIDs(
                    among: snapshot.sessions, frontmostBundleID: frontmost)
                let alerts = await self.notificationCoordinator.observe(
                    snapshot.sessions,
                    appActive: NSApp.isActive,                 // user looking at VibeBuddy?
                    quietMode: Self.effectiveQuiet(),          // Focus mode (manual or nightly) → every session muted
                    focusedSessionIDs: focused,                // …or looking at the session's own terminal
                    categories: NotificationCategoryPrefs.load()) // this Mac's own switches
                await self.refreshNotificationDeliveryHealth()
                await self.pushToPhones(alerts)
                await self.pushActivityUpdates(snapshot.sessions)
                await self.checkBudget(snapshot.sessions)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshNotificationDeliveryHealth() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let authorization: NotificationAuthorization
        switch status {
        case .authorized, .provisional: authorization = .authorized
        case .denied: authorization = .denied
        case .notDetermined: authorization = .notDetermined
        default: authorization = .unknown
        }
        await deliveryRecorder.updateAuthorization(authorization)
        await deliveryRecorder.updateAPNsConfigured(pusher != nil)
        notificationDeliveryHealth = await deliveryRecorder.health()
        recentNotificationDeliveries = await deliveryRecorder.recent(limit: 8)
    }

    func setAlwaysAskPhone(_ on: Bool) {
        alwaysAskPhone = on
        UserDefaults.standard.set(on, forKey: Self.alwaysAskPhoneKey)
    }

    /// The presence policy's inputs for one session, from what this model can
    /// see: the frontmost app against the session's terminal (or Codex Desktop
    /// for a Desktop thread), the screen lock, and the system idle time.
    func presenceInput(for sessionID: String) -> PresencePolicy.Input {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var focused = ForegroundTerminal.focusedSessionIDs(among: sessions, frontmostBundleID: front).contains(sessionID)
        if let session = sessions.first(where: { $0.id == sessionID }),
           session.jumpsToDesktopThread, front == CodexDesktopJumper.chatGPTBundleID {
            focused = true
        }
        return PresencePolicy.Input(sessionSurfaceFocused: focused,
                                    screenLocked: Presence.screenIsLocked(),
                                    idleSeconds: Presence.idleSeconds(),
                                    alwaysAskPhone: alwaysAskPhone)
    }

    func setCodexAppServerEnabled(_ on: Bool) {
        codexAppServerEnabled = on
        UserDefaults.standard.set(on, forKey: Self.codexAppServerEnabledKey)
        Task { [codexAppServerMonitor] in await codexAppServerMonitor.setEnabled(on) }
    }

    func clearLifecycleJournal() {
        Task { [weak self, store] in
            let removed = await store.clearLifecycleJournal()
            let timeline = await store.recentLifecycle()
            guard let self else { return }
            self.lifecycleTimeline = timeline
            self.lifecycleJournalClearFailed = !removed
        }
    }

    func isUsageCollectionEnabled(_ provider: AccountUsageProvider) -> Bool {
        usage.isCollectionEnabled(provider)
    }

    func usageState(for provider: AccountUsageProvider) -> AccountUsageState {
        usage.state(for: provider)
    }

    func setUsageCollectionEnabled(_ enabled: Bool, provider: AccountUsageProvider) {
        usage.setCollectionEnabled(enabled, provider: provider)
    }

    /// Push a Live Activity content-state update to registered phones, but only when
    /// the displayed counts/top session actually change (dynamic-island/02). No-op
    /// without an APNs key or any registered activity token.
    private func pushActivityUpdates(_ sessions: [AgentSession]) async {
        guard let pusher else { return }
        let tokens = await activityTokens.all()
        guard !tokens.isEmpty else { return }
        let summary = TaskPresentationSummary(sessions: sessions)
        let leading = sessions.leadingPresentationSession
        let topProject = leading?.project
        let topSession = leading?.id
        let key = "\(summary)|\(topProject ?? "")|\(topSession ?? "")"
        guard key != lastActivityKey else { return }
        lastActivityKey = key
        for t in tokens {
            await pusher.sendActivityUpdate(summary: summary,
                topProject: topProject, topSessionId: topSession, to: t)
        }
    }

    /// Push the cues the Mac just decided on to paired phones. Only a cue loud
    /// enough to interrupt here is worth pulling you back from elsewhere; a
    /// list-only cue stays on the Mac. Each device then applies its own prefs:
    /// its Quiet mode reads the cue through the `muted` column, never louder
    /// than the Mac decided, and mute drops the sound. When the phone is in the
    /// foreground it suppresses the remote push itself (see willPresent).
    private func pushToPhones(_ alerts: [SoundAlert]) async {
        guard !alerts.isEmpty else { return }
        let devices = await deviceTokens.devices()
        for alert in alerts { await push(alert, to: devices) }
        await refreshNotificationDeliveryHealth()
    }

    /// One cue to every paired phone, planned by `PushFanout`: its own category
    /// switches decide whether at all, and its Quiet mode how loud, never louder
    /// than the Mac decided. Returns whether any phone was actually sent to.
    ///
    /// A cue that reaches no phone records a `skipped` delivery saying why,
    /// rather than leaving nothing behind. Every one of these silences is
    /// deliberate somewhere — but a silence you cannot tell apart from a bug is
    /// how "the Mac banners and the phone never hears about it" went unexplained.
    @discardableResult
    private func push(_ alert: SoundAlert, to devices: [DeviceRegistrationPayload]) async -> Bool {
        let fanout = PushFanout.plan(alert, devices: devices, apnsConfigured: pusher != nil)
        guard let pusher, !fanout.recipients.isEmpty else {
            await recordPushSkip(alert, reason: fanout.skip)
            return false
        }
        let (title, body) = Self.pushCopy(for: alert)
        var sent = false
        for recipient in fanout.recipients {
            guard let deviceToken = recipient.device.token else { continue }
            let sound = recipient.level.makesSound && recipient.device.playSound != false
                ? alert.sound.fileName : ""
            await pusher.send(title: title, body: body, to: deviceToken, sound: sound,
                              sessionID: alert.sessionID, soundCategory: alert.sound.rawValue)
            sent = true
        }
        return sent
    }

    private func recordPushSkip(_ alert: SoundAlert, reason: PushSkipReason?) async {
        guard let reason else { return }
        await deliveryRecorder.record(NotificationDeliveryRecord(
            channel: .apns, outcome: .skipped, sessionID: alert.sessionID,
            sound: alert.sound.rawValue, failureReason: reason.rawValue, timestamp: Date()))
    }

    /// The server's reminder schedule asks this to deliver one `agentDone`
    /// reminder for a followed, unread completion: a local banner (this Mac's
    /// categories and Focus mode permitting) and a push to every paired phone
    /// whose switches allow it. Returns whether any channel took it — a
    /// reminder nobody could show does not spend one of the session's slots.
    @MainActor
    private func deliverCompletionReminder(_ session: AgentSession) async -> Bool {
        let local = await notificationCoordinator.remind(
            session, quietMode: Self.effectiveQuiet(), categories: NotificationCategoryPrefs.load())
        let devices = await deviceTokens.devices()
        let level = DeliveryMatrix.level(for: .agentDone, attention: session.effectiveAttention)
        let pushed = await push(SoundAlert(session: session, sound: .agentDone, delivery: level), to: devices)
        if local || pushed { await refreshNotificationDeliveryHealth() }
        return local || pushed
    }

    /// Fire a one-time budget heads-up (local + push) for sessions that just
    /// crossed the user's per-session spend budget. 0 = disabled.
    private func checkBudget(_ sessions: [AgentSession]) async {
        let budget = UserDefaults.standard.double(forKey: "sessionBudgetUSD")
        let alerts = budgetMonitor.newlyOverBudget(sessions, budgetUSD: budget)
        guard !alerts.isEmpty else { return }
        let devices = pusher == nil ? [] : await deviceTokens.devices()
        for alert in alerts {
            let cost = String(format: "$%.2f", alert.estimatedUSD)
            notifier.notifyBudget(project: alert.session.project, cost: cost)
            for device in devices {
                guard let deviceToken = device.token, device.quietMode != true else { continue }  // not an approval → quiet suppresses
                let sound = device.playSound != false ? NotificationSound.longWaitNudge.fileName : ""
                await pusher?.send(title: "\(alert.session.project) over budget",
                                   body: "≈ \(cost) spent this session (estimate)",
                                   to: deviceToken, sound: sound)
            }
        }
    }

    private static func pushCopy(for alert: SoundAlert) -> (title: String, body: String) {
        let s = alert.session
        switch alert.sound {
        case .needsApproval: return ("\(s.project) needs approval", s.pendingApproval?.commandPreview ?? s.summary ?? "Approve or deny")
        case .needsAnswer:   return ("\(s.project) needs you", s.summary ?? "Waiting for your response")
        case .longWaitNudge: return ("\(s.project) is still waiting", s.summary ?? "Waiting for your response")
        case .agentDone:     return ("\(s.project) finished", s.summary ?? "Task complete")
        case .agentStuck:    return ("\(s.project) stopped", s.summary ?? "It may need a look")
        case .pairSuccess:   return ("Paired", "VibeBuddy is watching your sessions.")
        }
    }

    /// Resolve a pending approval from the Mac (Dashboard buttons / shortcuts).
    /// Mirrors the daemon's `/decision` route in-process (the Mac IS the daemon),
    /// so "always allow" / "allow this session" behave identically to the phone.
    func decide(_ approvalId: String, _ choice: ApprovalDecision) {
        Task {
            let ctx = await approvalContext.take(id: approvalId)
            switch choice {
            case .alwaysAllow:
                if let rule = ctx?.rule { await allowStore.add(rule) }
                await approvalRegistry.resolve(id: approvalId, with: .allow)
            case .allowSession:
                if let ctx { await sessionAllow.add(ctx.sessionID) }
                await approvalRegistry.resolve(id: approvalId, with: .allow)
            case .allow:
                await approvalRegistry.resolve(id: approvalId, with: .allow)
            case .deny:
                await approvalRegistry.resolve(id: approvalId, with: .deny)
            }
            if let ctx { await store.recordInteraction(sessionID: ctx.sessionID) }
        }
    }

    /// Back-compat for voice + existing callers.
    func decide(_ approvalId: String, approve: Bool) { decide(approvalId, approve ? .allow : .deny) }

    /// Answer a session's question from the Mac card, the same way `/answer`
    /// does for the phone: to the waiting agent through its own contract,
    /// else typed into a tmux pane. Reports whether it had anywhere to go.
    func answer(_ sessionID: String, answers: QuestionAnswers, text: String? = nil) {
        let dispatch = AnswerDispatch(store: store, questions: questionRegistry,
                                      inject: { ref, answer in TerminalInjector.inject(answer, into: ref) })
        Task { [weak self] in
            let delivered = await dispatch.deliver(sessionID: sessionID, text: text,
                                                   answers: answers.isEmpty ? nil : answers)
            await MainActor.run {
                self?.answerFeedback[sessionID] = delivered ? nil : "Nothing was waiting for an answer, and there is no tmux pane to type into."
            }
        }
    }

    /// Jump to where a session lives without blocking the UI: the click is
    /// acknowledged immediately and the AppleScript/`tmux`/LaunchServices work
    /// happens off the main actor, publishing what it actually achieved when it
    /// lands.
    ///
    /// Two kinds of target, and a session has at most one. A terminal session
    /// has a ref; a Codex Desktop session has only the thread it is, which
    /// ChatGPT.app opens. Never refuses. A session with neither is a real answer
    /// ("no terminal recorded"), not a dead control — that silence was the bug.
    func jump(_ session: AgentSession) {
        acknowledge(session.id)
        Task { [store] in await store.recordInteraction(sessionID: session.id) }
        if let ref = session.terminalRef {
            Task { [weak self] in
                let outcome = await TerminalJumper.jump(ref)
                self?.showJumpFeedback(outcome, for: session.id)
            }
        } else if let thread = session.desktopThreadID {
            Task { [weak self] in
                let outcome = await CodexDesktopJumper.jump(threadID: thread)
                self?.showJumpFeedback(outcome, for: session.id)
            }
        } else if session.agent == .claudeCode,
                  let job = ClaudeBackgroundSessions.find(sessionID: session.id) {
            // A background session has no window: open one attached to it.
            Task { [weak self, store] in
                let term = await store.preferredTerminalProgram()
                let outcome = await TerminalLauncher.attach(claudeJobID: job.id, preferring: term)
                self?.showJumpFeedback(outcome, for: session.id)
            }
        } else {
            showJumpFeedback(.noTerminal, for: session.id)
        }
    }

    /// Start a new task from the Mac, the same way `/dispatch` does for the
    /// phone: Codex through the app-server daemon; other agents once they have
    /// a launcher. The directory must be one a session has run in.
    func dispatch(_ request: DispatchRequest) async -> DispatchOutcome {
        guard await store.isKnownDirectory(request.cwd) else {
            return .rejected("Pick a directory a session has already run in.")
        }
        switch request.agent {
        case .codex: return await codexAppServerMonitor.dispatch(request)
        case .claudeCode: return await claudeLauncher.dispatch(request)
        default: return .unsupported("vibebuddy cannot start \(request.agent.displayName) sessions yet.")
        }
    }

    /// Publish a jump result against its session and retract it a beat later, so
    /// the row goes back to showing live activity. A second jump replaces the
    /// first one's countdown instead of inheriting its deadline.
    private func showJumpFeedback(_ outcome: JumpOutcome, for sessionID: String) {
        jumpFeedback[sessionID] = outcome
        jumpFeedbackClears[sessionID]?.cancel()
        jumpFeedbackClears[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.jumpFeedback[sessionID] = nil
            self?.jumpFeedbackClears[sessionID] = nil
        }
    }

    /// Explicitly viewing/selecting a completion clears its authoritative unread
    /// bit. Demo sessions mirror the same transition without touching the store.
    func acknowledge(_ sessionID: String) {
        if ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" {
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
                  sessions[index].hasUnreadCompletion else { return }
            sessions[index].hasUnreadCompletion = false
            return
        }
        Task { [store] in await store.acknowledgeCompletion(sessionID: sessionID) }
    }

    /// Set, or with `nil` return to automatic, how much this session may
    /// interrupt you. The daemon owns the value; demo mode mirrors it locally.
    func setAttention(_ sessionID: String, _ level: SessionAttention?) {
        if ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" {
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            sessions[index].attentionOverride = level
            sessions[index].attention = level ?? .normal
            return
        }
        Task { [store] in await store.setAttention(sessionID: sessionID, level) }
    }

    /// Include/exclude a session from the buddy's context (ephemeral). Takes effect
    /// on the next call — a live call keeps the snapshot it started with.
    func toggleBuddy(_ id: String) {
        if buddySessionIDs.contains(id) { buddySessionIDs.remove(id) }
        else { buddySessionIDs.insert(id) }
    }

    /// The session's recent output, for the detail pane's "Recent output" sheet.
    /// Reads off the store actor; empty when no transcript is known.
    func transcript(for sessionID: String) async -> [TranscriptEntry] {
        await store.recentTranscript(sessionID: sessionID)
    }

    /// Execute a voice action against the matching session; returns a spoken confirmation.
    func performVoiceAction(_ action: VoiceAction) -> String {
        switch action {
        case .approve(let project):
            guard let s = match(project), let ap = s.pendingApproval else { return "No session to approve." }
            decide(ap.id, approve: true); return "Approved \(s.project)."
        case .deny(let project):
            guard let s = match(project), let ap = s.pendingApproval else { return "No session to deny." }
            decide(ap.id, approve: false); return "Denied \(s.project)."
        case .answer(let project, let text):
            guard let s = match(project), s.pendingQuestion != nil || s.terminalRef != nil else {
                return "No matching session, or it has nothing waiting and no terminal."
            }
            answer(s.id, answers: [:], text: text)
            Task { [store] in await store.recordInteraction(sessionID: s.id) }
            return "Replied to \(s.project)."
        case .none:
            return ""
        }
    }

    private func match(_ project: String) -> AgentSession? {
        // Conservative resolution (exact-first, unique-substring, refuse ambiguous)
        // so a voice approve never lands on the wrong real command target.
        VoiceSessionMatch.match(project, in: sessions)
    }

    static func defaultGlanceScale() -> CGFloat {
        let w = NSScreen.main?.frame.width ?? 1512
        return w >= 2000 ? 1.0 : 0.8        // iMac → Medium, MacBook → Small; pick Large for bigger
    }

    func setGlanceScale(_ s: CGFloat) {
        glanceScale = s
        UserDefaults.standard.set(Double(s), forKey: "glanceScale")
    }

    /// Idle-cleanup window: how long a `needsResponse` session may sit before the
    /// daemon drops it. 0 hours = never. Applied to the store immediately.
    func setIdleTimeout(_ hours: Double) {
        idleTimeoutHours = hours
        UserDefaults.standard.set(hours, forKey: "idleTimeoutHours")
        let interval = Self.staleInterval(forHours: hours)
        Task { [store] in await store.setStaleAfter(interval) }
    }

    private static func staleInterval(forHours hours: Double) -> TimeInterval {
        hours <= 0 ? .greatestFiniteMagnitude : hours * 3600
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.set(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func setPairedPhone(_ name: String) {
        recordPairedDevice(DeviceRegistrationPayload(name: name))
    }

    func recordPairedDevice(_ device: DeviceRegistrationPayload) {
        let current = pairedPhone
        let next = PairedPhone(
            name: Self.nonEmpty(device.name) ?? current?.name ?? "iPhone",
            model: Self.nonEmpty(device.model) ?? current?.model,
            systemVersion: Self.nonEmpty(device.systemVersion) ?? current?.systemVersion,
            lastSeen: Date(),
            pushRegistered: current?.pushRegistered == true || device.hasPushToken
        )
        guard next != pairedPhone else { return }
        // A different (or first) phone pairing is the pair_success moment; the
        // same phone merely reconnecting (only `lastSeen`/push changed) is not.
        let isNewPhone = current == nil || current?.name != next.name
        pairedPhone = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.pairedPhoneInfoKey)
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyPairedPhoneKey)
        if isNewPhone { notifier.confirmPairing(deviceName: next.name) }
    }

    func forgetPairedPhone() {
        pairedPhone = nil
        UserDefaults.standard.removeObject(forKey: Self.pairedPhoneInfoKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyPairedPhoneKey)
    }

    var menuSessionList: MenuSessionList {
        MenuSessionList(sessions, collapsedAgents: collapsedMenuAgents)
    }

    func toggleMenuGroup(_ agent: AgentKind) {
        if collapsedMenuAgents.contains(agent) {
            collapsedMenuAgents.remove(agent)
        } else {
            collapsedMenuAgents.insert(agent)
        }
        UserDefaults.standard.set(collapsedMenuAgents.map(\.rawValue).sorted(), forKey: Self.collapsedMenuAgentsKey)
    }

    func setShowGlance(_ on: Bool) {
        showGlance = on
        UserDefaults.standard.set(on, forKey: "showGlance")
        if on {
            if glance == nil { glance = GlanceWindow(model: self) } else { glance?.show() }
        } else {
            glance?.hide()
        }
    }

    func setGlanceExpanded(_ expanded: Bool) {
        guard expanded != glanceExpanded else { return }
        glanceExpanded = expanded
    }

    /// The pointer entered / left the glance. A card on screen holds while the
    /// user is reading it.
    func setGlanceHeld(_ held: Bool) {
        glanceHeld = held
        tickGlanceCards()
    }

    // MARK: glance event layer

    /// Show `alert` as a card under the notch. `false` when the glance is not
    /// on screen (hidden, or not built yet), so the caller posts a banner instead.
    func presentGlanceCard(_ alert: SoundAlert) -> Bool {
        guard glance?.isVisible == true, alert.sound != .pairSuccess else { return false }
        glanceCards.enqueue(alert, now: Date())
        publishGlanceCard()
        return true
    }

    /// The user acted on (or closed) the card; the next queued one, if any, unfolds.
    func dismissGlanceCard() {
        glanceCards.dismissCurrent(now: Date())
        publishGlanceCard()
    }

    /// Expire and withdraw cards against the live sessions. Called on every
    /// snapshot and, while a card is up, from a finer ticker so the timeout
    /// lands on time rather than on the next 2s poll.
    private func tickGlanceCards() {
        glanceCards.tick(now: Date(), sessions: sessions, held: glanceHeld || glanceExpanded)
        publishGlanceCard()
    }

    private func publishGlanceCard() {
        if glanceCard != glanceCards.current { glanceCard = glanceCards.current }
        if glanceCard == nil {
            glanceCardTicker?.cancel()
            glanceCardTicker = nil
        } else if glanceCardTicker == nil {
            glanceCardTicker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    self.tickGlanceCards()
                }
            }
        }
    }

    func setHotkey(_ hotkey: Hotkey) {
        openDashboardHotkey = hotkey
        hotkey.saveAsOpenDashboard()
        GlobalHotkey.setHotkey(hotkey)
    }

    func setGlanceHotkey(_ hotkey: Hotkey) {
        toggleGlanceHotkey = hotkey
        hotkey.saveAsToggleGlance()
        GlobalHotkey.setGlanceHotkey(hotkey)
    }

    private static func loadPairedPhone() -> PairedPhone? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: pairedPhoneInfoKey),
           let phone = try? JSONDecoder().decode(PairedPhone.self, from: data) {
            return phone
        }
        if let legacyName = defaults.string(forKey: legacyPairedPhoneKey), !legacyName.isEmpty {
            return PairedPhone(name: legacyName, model: nil, systemVersion: nil,
                               lastSeen: Date(), pushRegistered: false)
        }
        return nil
    }

    private static func localMacName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    deinit {
        pollTask?.cancel()
        glanceCardTicker?.cancel()
    }
}
