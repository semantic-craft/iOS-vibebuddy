import SwiftUI
import AppKit
import Combine
import UserNotifications
import os
import VibeBuddyKit
import VibeBuddyMacCore

struct PairedPhone: Codable, Hashable, Identifiable {
    var name: String
    var model: String?
    var systemVersion: String?
    var lastSeen: Date
    var pushRegistered: Bool
    var confirmed: Bool
    var deviceID: String? = nil
    /// Where this phone's push stands: registered, failing, parked, or no token
    /// yet. A parked phone is listed with Apple's reason rather than hidden.
    var push: DevicePushStanding = .noToken
    /// The first characters of the APNs token, for a phone without an identity.
    var tokenPrefix: String? = nil

    /// Stable across refusals and re-registrations: the phone's identity, else
    /// its token. A list row keyed on the whole value would be torn down on
    /// every counted refusal.
    var id: String { deviceID ?? tokenPrefix.map { "token:" + $0 } ?? name }

    init(name: String, model: String?, systemVersion: String?, lastSeen: Date,
         pushRegistered: Bool, confirmed: Bool, deviceID: String? = nil,
         push: DevicePushStanding = .noToken, tokenPrefix: String? = nil) {
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.lastSeen = lastSeen
        self.pushRegistered = pushRegistered
        self.confirmed = confirmed
        self.deviceID = deviceID
        self.push = push
        self.tokenPrefix = tokenPrefix
    }

    init(_ entry: DeviceRegistryEntry) {
        self.init(name: MenuBarModel.nonEmpty(entry.device.name) ?? "iPhone",
                  model: entry.device.model, systemVersion: entry.device.systemVersion,
                  lastSeen: entry.registeredAt, pushRegistered: entry.isPushable,
                  confirmed: entry.pairedAt != nil, deviceID: entry.device.deviceID,
                  push: entry.pushStanding,
                  tokenPrefix: entry.device.token.map { String($0.prefix(8)) })
    }

    /// One line for a device list: what the Mac does with this phone's pushes.
    var pushStatusText: String {
        switch push {
        case .noToken: String(localized: "Push pending")
        case .registered: String(localized: "Push registered")
        case .failing(let failure):
            String(localized: "Push failing: \(failure.reason) since \(failure.firstAt.formatted(date: .abbreviated, time: .shortened)) (\(failure.count) sends)")
        case .parked(let failure):
            String(localized: "Push stopped: \(failure.reason) since \(failure.firstAt.formatted(date: .abbreviated, time: .shortened)), \(failure.count) refused. Pushes resume when the phone reconnects.")
        }
    }

    var isParked: Bool { if case .parked = push { true } else { false } }

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
    let settingsTests = SettingsTestCoordinator()
    let settingsCredentials = SettingsCredentials()
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var recap: Recap?
    // The recap view owns a five-second TimelineView for freshness.
    private(set) var recapUpdatedAt: Date?
    @Published private(set) var recapConfirmation = RecapConfirmation()
    @Published private(set) var observationDiagnostics: [AgentObservationDiagnostic] = []
    /// Directories sessions have run in, newest first — where a new task may start.
    @Published private(set) var recentDirectories: [String] = []
    /// Agents a new task can be started for from this Mac.
    @Published private(set) var dispatchAgents: [AgentKind] = []
    /// Handoff documents found under the recent directories (ADR-0023).
    @Published private(set) var handoffs: [HandoffRecord] = []
    /// A Continue with… the dashboard should open the New task sheet for.
    @Published var continueRequest: NewTaskPrefill?
    /// Local Claude Code / Codex token spend, beside quota. Nil until the first scan.
    @Published private(set) var tokenConsumption: TokenConsumptionSnapshot?
    private let claudeLauncher: ClaudeBackgroundLauncher = {
        guard let run = E2ERunConfiguration.current else { return ClaudeBackgroundLauncher() }
        let jobs = run.file("agents").appendingPathComponent("claude/jobs", isDirectory: true)
        return ClaudeBackgroundLauncher(executable: nil, agents: ClaudeAgentsSource(
            run: { nil }, fingerprint: { "" },
            fallback: { ClaudeBackgroundSessions.loadFromJobsDirectory(jobs) }))
    }()
    /// Cursor's CLI launcher. During isolated acceptance it is given no
    /// executable, so it reports unsupported and starts nothing.
    private let cursorLauncher: CursorLauncher = {
        guard E2ERunConfiguration.current == nil else { return CursorLauncher(executable: nil) }
        return CursorLauncher(terminalProgram: { await MenuBarModel.shared?.store.preferredTerminalProgram() })
    }()
    /// Cursor's agent-transcript tailer: the source that covers a Cursor
    /// conversation when the hooks are not installed, or when the Cursor CLI
    /// does not send the event in question.
    private let cursorTranscriptMonitor: CursorTranscriptMonitor = {
        guard let run = E2ERunConfiguration.current else { return CursorTranscriptMonitor() }
        return CursorTranscriptMonitor(root: run.file("agents").appendingPathComponent("cursor/projects", isDirectory: true))
    }()
    /// Cursor's Cloud Agents API poller. A cloud agent runs on Cursor's
    /// machines, so it reaches no hook and writes no transcript; this is the
    /// only live source it has. It does nothing at all until an API key is
    /// stored, and it is skipped entirely during isolated acceptance so a run
    /// never talks to Cursor's service.
    private let cursorCloudMonitor: CursorCloudAgentMonitor? =
        E2ERunConfiguration.current == nil ? CursorCloudAgentMonitor() : nil
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
    @Published private(set) var missedThisWeek = MissedCounts.empty
    @Published private(set) var notificationDeliveryHealth = NotificationDeliveryHealth()
    /// The CloudKit cue channel a Mac without an APNs key uses (ADR-0013 D);
    /// `.notEntitled` when this build cannot use it or a `.p8` is configured.
    @Published private(set) var cloudKitStatus = CloudKitCueStatus.notEntitled
    /// Registered phones signed into this Mac's Apple Account — the ones a
    /// CloudKit cue can reach.
    @Published private(set) var cloudKitPhones = 0
    @Published private(set) var contentPresentationRevision: String?
    @Published private(set) var recentNotificationDeliveries: [NotificationDeliveryRecord] = []
    /// How many phones the Mac can push to right now, and when the newest of
    /// them last registered. Zero with APNs configured means every push is
    /// going nowhere — the state that used to be invisible.
    @Published private(set) var deviceRegistry = DeviceRegistrySummary()
    /// The outcome of the most recent jump per session id, shown transiently in
    /// the row that was clicked and cleared by `showJumpFeedback`.
    @Published private(set) var jumpFeedback: [String: JumpOutcome] = [:]
    /// Why the last Mac-card answer for a session went nowhere, when it did.
    @Published private(set) var answerFeedback: [String: String] = [:]
    private var jumpFeedbackClears: [String: Task<Void, Never>] = [:]
    /// Sessions the user has pointed the buddy at (in-memory, never persisted).
    /// Empty = the buddy sees all sessions; pruned to live IDs on every snapshot.
    @Published private(set) var buddySessionIDs: Set<String> = []
    @Published var useTailscale = UserDefaults.standard.bool(forKey: "pairing.useTailscale") {
        didSet { UserDefaults.standard.set(useTailscale, forKey: "pairing.useTailscale"); preparePairing() }
    }
    @Published var tailscaleHost = MenuBarModel.loadTailscaleHost() {
        didSet { UserDefaults.standard.set(tailscaleHost, forKey: "pairing.tailscaleHost"); preparePairing() }
    }
    @Published private(set) var pairing: PairingPayload?
    @Published private(set) var qrImage: NSImage?
    /// The most-recently paired phone's display metadata (persisted), shown in the UI.
    @Published private(set) var pairedPhone: PairedPhone?
    /// Every phone on file, newest registration first — including the ones the
    /// Mac has stopped pushing to, so Settings can say so and why.
    @Published private(set) var phones: [PairedPhone] = []
    @Published private(set) var detectedRemoteAddresses: [String] = []
    @Published private(set) var remoteTransfer: RemoteConnectionSyncStore.Transfer?
    @Published private(set) var synchronizingConnection = false
    private let connectionSync = RemoteConnectionSyncStore()

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
    @Published var nextPendingHotkey: Hotkey = Hotkey.loadNextPending()
    @Published var toggleGlanceHotkey: Hotkey = .toggleGlanceDefault
    /// Idle-cleanup window in hours; 0 means never. Default 2h.
    @Published var idleTimeoutHours: Double = 2
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
    /// Follow-ups queued for Cursor conversations; the hooks' `stop` collects
    /// them for an IDE chat, the ACP host for one it carries. One queue so a
    /// supplement can never be delivered twice.
    private let cursorFollowups = CursorFollowupQueue()
    /// Hosts `cursor-agent acp` conversations (ticket cursor-integration/11):
    /// the phone's dispatch, stop, continue, permission and question for a
    /// Cursor task all travel this pipe. Given no executable during isolated
    /// acceptance, so it reports unsupported and spawns nothing.
    private let cursorACP: CursorACPMonitor
    private let grokACP: GrokACPMonitor
    /// Live account usage from Claude's status line and the Codex daemon,
    /// consumed by the usage coordinator ahead of its spawning collectors.
    private let usageFeed = AccountUsageLiveFeed()
    static let codexAppServerEnabledKey = "codexAppServerEnabled"
    // Live Activity push tokens + the last content we pushed, so we only push on change.
    private let activityTokens = ActivityTokens()
    private var lastActivityKey: String?
    private let notifier = UserNotificationsNotifier()
    private let completionSummaryService = CompletionSummaryService()
    let readAloud = ReadAloud()
    /// Session cues go to the glance first (a card under the notch) and only
    /// fall back to a system banner while the glance is hidden. Lazy so the
    /// router can point back at this model.
    private lazy var notificationCoordinator = NotificationCoordinator(
        notifier: GlanceAttentionRouter(banners: notifier) { [weak self] alert in
            self?.presentGlanceCard(alert) ?? false
        },
        delivery: deliveryRecorder,
        onEligible: { [weak self] alert in
            Task { @MainActor in self?.enqueueAnnouncement(alert) }
        })

    private func enqueueAnnouncement(_ alert: SoundAlert) {
        guard UserDefaults.standard.bool(forKey: ReadAloud.enabledKey), !alert.isReminder,
              let sourceID = snapshotSourceID else { return }
        enqueueSpeech(alert.session, sound: alert.sound, sourceID: sourceID, manual: false)
    }

    /// Explicit global pending read; independent from automatic announcement
    /// preferences. This only queues speech and never acknowledges any result.
    func readPending() {
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.store.snapshot(now: Date())
            guard let sourceID = snapshot.sourceID else {
                self.readAloud.report("Task state is unavailable. Try again when connected.")
                return
            }
            let pending = PendingTasks.ordered(SessionCurrency.current(snapshot.sessions, now: Date()))
            guard !pending.isEmpty else { self.readAloud.report("No current pending tasks to read"); return }
            let batch: [(AgentSession, NotificationSound, String)] = pending.prefix(10).compactMap { session in
                let sound: NotificationSound = session.status == .needsResponse
                    ? (session.waitKind == .permission ? .needsApproval : .needsAnswer)
                    : session.isStuck ? .agentStuck : .agentDone
                guard let id = self.speechIdentity(session, sound: sound, sourceID: sourceID) else { return nil }
                return (session, sound, id)
            }
            guard !batch.isEmpty else { self.readAloud.report("No current pending tasks to read"); return }
            let ids = batch.map { $0.2 }
            self.readAloud.beginReadPending(orderedIDs: ids)
            if pending.count > 10 { self.readAloud.showOverflow() }
            // Retain First up and the first ten in the shared order. Overflow
            // remains available as text instead of evicting the first items.
            for (session, sound, _) in batch {
                self.enqueueSpeech(session, sound: sound, sourceID: sourceID, manual: true)
            }
            self.readAloud.finishReadPending(orderedIDs: ids)
        }
    }

    private func speechIdentity(_ session: AgentSession, sound: NotificationSound, sourceID: String) -> String? {
        let round: [String]
        switch sound {
        case .agentDone:
            guard let completionID = session.completionID, !completionID.isEmpty else { return nil }
            round = ["completion", completionID]
        case .needsAnswer, .needsApproval:
            let wait = WaitReadRequest(sourceID: sourceID, session: session)
            round = ["wait", wait.waitKind.rawValue, wait.pendingID ?? "", String(wait.statusSince.timeIntervalSince1970)]
        case .agentStuck:
            round = ["failure", String(session.statusSince.timeIntervalSince1970)]
        default: return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: [sourceID, session.id] + round) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func enqueueSpeech(_ original: AgentSession, sound: NotificationSound, sourceID: String, manual: Bool) {
        guard let identity = speechIdentity(original, sound: sound, sourceID: sourceID),
              let text = AnnouncementCopy.text(for: original, sound: sound, language: VoiceSettings.conversationLanguage()) else { return }
        var preparedRevision: String?
        readAloud.speak(text, id: identity, title: original.displayTitle, manual: manual,
            priority: !manual && sound != .agentDone, prepareText: { [weak self] in
            guard let self, let target = ContentPresentationTarget(session: original) else { return nil }
            let request = ContentPresentationRequest(sourceID: sourceID, target: target)
            let result = await self.store.presentation(request)
            preparedRevision = result?.revision
            return result?.text
        }, validatePreparedText: {
            preparedRevision == CompletionSummaryConfiguration.load().presentationRevision
        }) { [weak self] in
            guard let self else { return false }
            let snapshot = await self.store.snapshot(now: Date())
            guard snapshot.sourceID == sourceID,
                  let current = snapshot.sessions.first(where: { $0.id == original.id }),
                  current.historyOnly != true,
                  self.speechIdentity(current, sound: sound, sourceID: sourceID) == identity else { return false }
            let isManual = self.readAloud.manuallyRequested(identity)
            if !isManual {
                guard UserDefaults.standard.bool(forKey: ReadAloud.enabledKey),
                      !Self.effectiveQuiet(), NotificationCategoryPrefs.loadMac().isEnabled(sound),
                      current.effectiveAttention != .muted else { return false }
                if UserDefaults.standard.bool(forKey: ReadAloud.silenceViewedKey) {
                    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    let nativePresence = !Presence.screenIsLocked() && Presence.idleSeconds() < 120
                        && ForegroundTerminal.focusedSessionIDs(among: [current], frontmostBundleID: front).contains(current.id)
                    if self.isViewing(current.id) || nativePresence { return false }
                }
            }
            switch sound {
            case .agentDone: return current.status == .done && current.hasUnreadCompletion && !current.isStuck
            case .agentStuck: return current.status == .done && current.isStuck
            case .needsApproval, .needsAnswer: return current.status == .needsResponse
            default: return false
            }
        }
    }

    func replayResult(_ original: AgentSession, body: CompletionBody? = nil) {
        guard let sourceID = snapshotSourceID, let target = ContentPresentationTarget(session: original) else { return }
        let request = ContentPresentationRequest(sourceID: sourceID, target: target)
        var preparedRevision: String?
        readAloud.speak(original.displayTitle, id: "replay/" + UUID().uuidString, manual: true, remember: false,
            prepareText: { [weak self] in
                guard let self, let result = await self.store.presentation(request) else { return nil }
                preparedRevision = result.revision
                return (VoiceSettings.conversationLanguage() == .chinese ? "此前结果。" : "Previous result. ") + result.text
            }, validatePreparedText: {
                preparedRevision == CompletionSummaryConfiguration.load().presentationRevision
            }, validate: { [weak self] in
                guard let self else { return false }
                let snapshot = await self.store.snapshot(now: Date())
                return snapshot.sourceID == sourceID && snapshot.sessions.contains { target.matches($0) }
            })
    }

    func recapPresentation(for entry: RecapEntry) async -> ContentPresentation? {
        guard let sourceID = snapshotSourceID else { return nil }
        let result = await store.presentation(.init(sourceID: sourceID, target: .recap(id: entry.id), purpose: .recap))
        guard snapshotSourceID == sourceID, recap?.entries.contains(where: { $0.id == entry.id }) == true else { return nil }
        return result
    }

    var dashboardViewedSessionID: String?
    var glanceViewedSessionID: String?
    func isViewing(_ sessionID: String) -> Bool {
        let shown = (glanceExpanded && glanceViewedSessionID == sessionID)
            || (NSApp.isActive && NSApp.keyWindow?.identifier?.rawValue == "com.vibebuddy.dashboard"
                && dashboardViewedSessionID == sessionID)
        // Presence last: the poll asks this for every session every 2 s, and
        // the lock check is a WindowServer round trip. At most two sessions
        // are ever on screen.
        return shown && !Presence.screenIsLocked() && Presence.idleSeconds() < 120
    }
    private let deliveryRecorder: NotificationDeliveryRecorder
    // Phone push: the same SoundPolicy engine, run from the Mac's perspective of
    // a backgrounded phone, so the phone hears the full pack (not just needs-you).
    private let pusher: APNsPusher?
    /// Closed-app cues through the user's own iCloud private database, for a
    /// Mac with no APNs key (ADR-0013 direction D). One channel per Mac: with
    /// a `.p8` this stays nil, so a phone never gets the same cue twice.
    private let cloudKit: CloudKitCueSender?
    private let deviceTokens: DeviceTokens
    /// What each phone said it posted itself (`POST /notified`); the pusher
    /// stands its own push down for those (ADR-0012).
    private let phoneReceipts: PhoneReceipts
    private let budgetMonitor = BudgetMonitor()
    /// Account usage is intentionally separate from `sessions`; refresh errors
    /// never enter SessionStore or the progress notification pipeline.
    private let usage: AccountUsageCoordinator
    private var usageObserver: AnyCancellable?
    private var voiceActionContext = VoiceActionContext()
    private let voiceActionRequests = ActionRequestLog()
    private let voiceCursorCloud = CursorCloudAgentClient()

    /// The voice companion (tap the buddy to talk). Lazy so `self` is fully built.
    lazy var voiceChat = VoiceChat(
        contextProvider: { [weak self] in
            guard let self else { return [] }
            return self.voiceScope(self.sessions)
        },
        statusContextProvider: { [weak self] in await self?.readVoiceStatus() ?? [] },
        actionHandler: { [weak self] action in await self?.performVoiceAction(action) ?? "" },
        onStart: { [weak self] in
            self?.voiceActionContext = VoiceActionContext()
            self?.readAloud.voiceStarted()
        })
    private var pollTask: Task<Void, Never>?
    private var tokenScanTask: Task<Void, Never>?
    private var glance: GlanceWindow?
    @Published private(set) var pairingInProgress = false
    @Published private(set) var changingPairing = false
    private var pairingTimeout: Task<Void, Never>?
    private var pairingRevision = 0

    /// The live model, for callers that only hold a `@Sendable` closure (the
    /// daemon's presence check). Weak: the model owns the app's lifetime, not
    /// the other way round.
    private(set) static weak var shared: MenuBarModel?
    // The menu reads `sessions` directly. The captured menu snapshot, its round
    // identities and the lifecycle comparisons existed only so local clearing
    // could not hide a newer round; clearing is gone and nothing else read them.

    private let menuRolloutMonitor: CodexRolloutMonitor = {
        guard let run = E2ERunConfiguration.current else { return CodexRolloutMonitor() }
        return CodexRolloutMonitor(root: run.file("agents").appendingPathComponent("codex/sessions", isDirectory: true))
    }()

    private var snapshotSourceID: String?
    private var publishedCurrentSessionIDs: [String] = []
    private var publishedBuddyState: BuddyState = .sleeping

    init(runtimeEnabled: Bool = true) {
        port = E2ERunConfiguration.current?.port ?? ProcessInfo.processInfo.environment["VIBEBUDDY_PORT"].flatMap(Int.init) ?? 9876
        let savedIdleTimeout = UserDefaults.standard.object(forKey: "idleTimeoutHours") as? Double ?? 2
        idleTimeoutHours = savedIdleTimeout
        store = SessionStore(
            staleAfter: Self.staleInterval(forHours: savedIdleTimeout),
            sourceID: DaemonIdentity.load(),
            diagnosticsHome: E2ERunConfiguration.current?.file("agents") ?? FileManager.default.homeDirectoryForCurrentUser,
            diagnosticsEnvironment: E2ERunConfiguration.current == nil ? ProcessInfo.processInfo.environment : [:],
            journalURL: (E2ERunConfiguration.current == nil ? ProcessInfo.processInfo.environment["VIBEBUDDY_JOURNAL_PATH"] : nil).map {
                URL(fileURLWithPath: $0)
            } ?? LifecycleJournalLocation.defaultURL(),
            attentionURL: AttentionOverrides.defaultURL(),
            missedURL: (E2ERunConfiguration.current == nil ? ProcessInfo.processInfo.environment["VIBEBUDDY_MISSED_PATH"] : nil).map {
                URL(fileURLWithPath: $0)
            } ?? MissedLedgerLocation.defaultURL(),
            grokHome: E2ERunConfiguration.current?.file("agents").appendingPathComponent("grok"),
            copilotDatabase: E2ERunConfiguration.current?.file("agents").appendingPathComponent("copilot/session-store.db"),
            cursorDatabase: E2ERunConfiguration.current?.file("agents").appendingPathComponent("cursor/state.vscdb")
        )
        // File-based store (owner-only): no Keychain ACL, so an ad-hoc rebuild
        // never re-prompts. Shared with vibebuddyd's default store.
        if E2ERunConfiguration.current != nil {
            do { token = try TokenStore.defaultStore().loadOrCreate() }
            catch { fatalError("E2E token storage failed; refusing to start.") }
        } else {
            token = (try? TokenStore.defaultStore().loadOrCreate()) ?? Token.generate()
        }
        let saved = UserDefaults.standard.double(forKey: "glanceScale")
        let base: CGFloat = saved > 0 ? saved : Self.defaultGlanceScale()
        // Snap to one of the 3 presets so the menu Picker selection always matches.
        glanceScale = [0.8, 1.0, 1.2].min(by: { abs($0 - base) < abs($1 - base) }) ?? 1.0
        showGlance = UserDefaults.standard.bool(forKey: "showGlance", default: true)
        let appServerOn = E2ERunConfiguration.current.map { $0.codexThreadID != nil } ?? UserDefaults.standard.bool(forKey: Self.codexAppServerEnabledKey, default: true)
        codexAppServerEnabled = appServerOn
        alwaysAskPhone = UserDefaults.standard.bool(forKey: Self.alwaysAskPhoneKey)
        // Presence is read on the main actor from the live snapshot; the
        // daemon and the monitor ask through this closure right before they
        // would hold a prompt for the phone.
        let presence = Presence.evaluator()
        codexAppServerMonitor = CodexAppServerMonitor(
            enabled: appServerOn,
            acceptanceThreadID: E2ERunConfiguration.current?.codexThreadID,
            usageFeed: E2ERunConfiguration.current == nil ? usageFeed : nil,
            approvalRegistry: approvalRegistry, allowStore: allowStore, sessionAllow: sessionAllow,
            approvalContext: approvalContext, questionRegistry: questionRegistry,
            presence: presence)
        openDashboardHotkey = Hotkey.loadOpenDashboard()
        toggleGlanceHotkey = Hotkey.loadToggleGlance()
        usage = AccountUsageCoordinator(store: store, notifier: notifier, liveFeed: usageFeed)
        let cursorExecutable: URL?
        let cursorRecovery: URL?
        if let run = E2ERunConfiguration.current {
            cursorExecutable = run.cursorACPEnabled ? run.file("cursor-agent") : nil
            cursorRecovery = run.cursorACPEnabled ? run.file("cursor-acp") : nil
        } else {
            cursorExecutable = CursorCLI.resolveExecutable()
            cursorRecovery = CursorACPMonitor.defaultRecoveryDirectory
        }
        cursorACP = CursorACPMonitor(
            store: store, approvals: approvalRegistry, approvalContext: approvalContext,
            questions: questionRegistry, allowStore: allowStore, sessionAllow: sessionAllow,
            followups: cursorFollowups,
            executable: cursorExecutable, recoveryDirectory: cursorRecovery)
        let grokExecutable: URL?
        let grokRecovery: URL?
        if let run = E2ERunConfiguration.current {
            grokExecutable = run.grokACPEnabled ? run.file("grok") : nil
            grokRecovery = run.grokACPEnabled ? run.file("grok-acp") : nil
        } else {
            grokExecutable = GrokUsageProvider.resolveGrokExecutable()
            grokRecovery = GrokACPMonitor.defaultRecoveryDirectory
        }
        grokACP = GrokACPMonitor(
            store: store, approvals: approvalRegistry, approvalContext: approvalContext,
            questions: questionRegistry, allowStore: allowStore, sessionAllow: sessionAllow,
            executable: grokExecutable, recoveryDirectory: grokRecovery)
        let apnsConfig = APNsConfig.load()
        let deliveryURL = (E2ERunConfiguration.current == nil ? ProcessInfo.processInfo.environment["VIBEBUDDY_DELIVERY_LOG_PATH"] : nil).map {
            URL(fileURLWithPath: $0)
        } ?? NotificationDeliveryLogLocation.defaultURL()
        let recorder = NotificationDeliveryRecorder(
            url: deliveryURL, apnsConfigured: apnsConfig != nil)
        deliveryRecorder = recorder
        let receipts = PhoneReceipts(recorder: recorder)
        phoneReceipts = receipts
        pusher = apnsConfig.flatMap { try? APNsPusher(config: $0, recorder: recorder, receipts: receipts) }
        // Demo and E2E instances never reach the real user's iCloud.
        let isolatedInstance = E2ERunConfiguration.current != nil
            || ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1"
        cloudKit = pusher == nil && !isolatedInstance
            ? CloudKitCueSender.makeIfEntitled(recorder: recorder, receipts: receipts) : nil
        notificationDeliveryHealth = NotificationDeliveryHealth(apnsConfigured: apnsConfig != nil)
        // The APNs registry outlives this process. Without the file, every Mac
        // restart emptied it and no push reached a closed phone until the phone
        // happened to cold-launch. The demo instance stays in memory so it can
        // never touch (or push to) the real user's phones.
        deviceTokens = DeviceTokens(url: (E2ERunConfiguration.current == nil && ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1")
            ? nil
            : ((E2ERunConfiguration.current == nil ? ProcessInfo.processInfo.environment["VIBEBUDDY_DEVICE_REGISTRY_PATH"] : nil).map {
                URL(fileURLWithPath: $0)
            } ?? DeviceRegistryLocation.defaultURL()),
            recorder: recorder)
        // The views read usage through this model's facades, so the coordinator's
        // changes have to reach the same `objectWillChange` they observe. Set up
        // after every stored property is initialized: the capture needs `self`.
        usage.onUsageAlert = { [weak self] provider, window, threshold in
            guard let self else { return }
            let copy = UserNotificationsNotifier.usageCopy(
                provider: provider, window: window, threshold: threshold)
            Task { await self.deliverQuotaNotice(title: copy.title, body: copy.body, id: copy.id,
                                                 sessionID: nil) }
        }
        usageObserver = usage.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        Self.shared = self
        readAloud.canSpeak = { [weak self] in self?.voiceChat.isActive == false }
        notifier.validateCompletion = { [weak self] alert in
            guard let self else { return false }
            return await self.isCurrentCompletion(alert)
        }
        notifier.onBannerAction = { [weak self] action, sessionId, approvalId, text in
            Task { @MainActor in
                self?.handleBannerAction(action, sessionId: sessionId, approvalId: approvalId, text: text)
            }
        }
        // Screenshot / exploration instance: seed sample sessions and skip the
        // server, polling, pairing, and notifications entirely. It never binds the
        // port or pushes to a phone, so it runs harmlessly alongside a real
        // instance and never touches real session data.
        let isDemo = (E2ERunConfiguration.current == nil && ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1")
        if isDemo {
            sessions = MacDemoData.sessions()
            observationDiagnostics = MacDemoData.observationDiagnostics()
            tokenConsumption = TokenConsumptionSnapshot.demo()
            usage.seedDemoStates(MacDemoData.usageStates())
        } else if runtimeEnabled {
            notifier.requestAuthorization()
            startServer()
            preparePairing()
            startPolling()
            usage.start()
            startTokenConsumptionScan()
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
                guard let self else { return }
                if let demo = self.sessions.first(where: { $0.pendingApproval != nil }) {
                    _ = self.presentGlanceCard(SoundAlert(session: demo, sound: .needsApproval))
                }
                // Glance card replaces the banner when the glance is up; still
                // post the sample banners so Demo mode shows Approve / Deny / Reply.
                self.postDemoBanners()
            }
        }
    }

    /// Quiet right now if the user toggled it, or the nightly window is active.
    static func effectiveQuiet(now: Date = Date()) -> Bool {
        NotificationQuietMode.isEffective(now: now)
    }

    /// The counts every Mac surface states (menu-bar badge, Glance, panel):
    /// current sessions only (`SessionCurrency`), like the phone and the Watch.
    var presentationSummary: TaskPresentationSummary { TaskPresentationSummary(currentIn: sessions, now: Date()) }
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
        let server = VibeBuddyServer(store: store, token: token, host: E2ERunConfiguration.current?.host ?? "0.0.0.0", port: port,
                                     pusher: nil, phoneReceipts: phoneReceipts,
                                     deviceTokens: deviceTokens,
                                     connectionSync: connectionSync,
                                     activityTokens: activityTokens,
                                     codexRolloutMonitor: menuRolloutMonitor,
                                     codexAppServerMonitor: E2ERunConfiguration.current == nil || codexAppServerEnabled ? codexAppServerMonitor : nil,
                                     usageFeed: usageFeed,
                                     approvalRegistry: approvalRegistry,
                                     rules: { agent in
                                         E2ERunConfiguration.current == nil ? PermissionRules.load(for: agent) : PermissionRules(allow: [], deny: [])
                                     },
                                     allowStore: allowStore,
                                     sessionAllow: sessionAllow,
                                     approvalContext: approvalContext,
                                     questionRegistry: questionRegistry,
                                     presence: Presence.evaluator(),
                                     onJump: { ref in
                                         guard E2ERunConfiguration.current == nil else { return .noTerminal }
                                         return await TerminalJumper.jump(ref)
                                     },
                                     onJumpToDesktopThread: { id in
                                         guard E2ERunConfiguration.current == nil else { return .noTerminal }
                                         return await CodexDesktopJumper.jump(threadID: id)
                                     },
                                     onJumpToCursor: { project in
                                         guard E2ERunConfiguration.current == nil else { return .noTerminal }
                                         return await CursorJumper.jump(project: project)
                                     },
                                     onDevicePaired: { [weak self] _ in
                                         Task { @MainActor in await self?.refreshPairedPhone(notify: true) }
                                     },
                                     backgroundSessions: {
                                         E2ERunConfiguration.current == nil ? ClaudeBackgroundSessions.load() : []
                                     },
                                     findBackgroundSession: { id in
                                         E2ERunConfiguration.current == nil ? await ClaudeBackgroundSessions.find(sessionID: id) : nil
                                     },
                                     onAttach: { id, term in
                                         guard E2ERunConfiguration.current == nil else { return .noTerminal }
                                         return await TerminalLauncher.attach(claudeJobID: id, preferring: term)
                                     },
                                     claudeLauncher: claudeLauncher,
                                     cursorLauncher: cursorLauncher,
                                     cursorACP: cursorACP,
                                     grokACP: grokACP,
                                     cursorTranscriptMonitor: cursorTranscriptMonitor,
                                     cursorCloudMonitor: cursorCloudMonitor,
                                     onCompletionReminder: { [weak self] session in
                                         guard let self else { return false }
                                         return await self.deliverCompletionReminder(session)
                                     },
                                     cursorFollowups: cursorFollowups)
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
        let host = E2ERunConfiguration.current?.host ?? (useTailscale ? tailscaleHost : LANAddress.primaryIPv4() ?? "127.0.0.1")
        guard let endpoint = CompanionEndpoint(host: host, port: port), !useTailscale || endpoint.isTailscale else {
            pairing = nil
            qrImage = nil
            return
        }
        let payload = Pairing.payload(host: endpoint.host, port: port, token: token, macName: macDisplayName)
        pairing = payload
        if let cg = Pairing.qrImage(from: Pairing.qrJSONString(for: payload)) {
            qrImage = NSImage(cgImage: cg, size: NSSize(width: 220, height: 220))
        }
    }

    /// Independent of the 2s session poll: reading transcripts is slow and must
    /// not stall approvals. Isolated from the reducer the same way quota is.
    private func startTokenConsumptionScan() {
        tokenScanTask?.cancel()
        let claudeHomes: [URL]
        let codexHome: URL
        if let run = E2ERunConfiguration.current {
            claudeHomes = [run.file("agents").appendingPathComponent("claude", isDirectory: true)]
            codexHome = run.file("agents").appendingPathComponent("codex", isDirectory: true)
        } else {
            claudeHomes = TokenConsumptionScan.defaultClaudeHomes()
            codexHome = TokenConsumptionScan.defaultCodexHome()
        }
        tokenScanTask = Task { [weak self, store] in
            // The memo lives across refreshes: only transcripts whose size or
            // mtime moved are read again, so the steady-state scan costs a few
            // files instead of every file in the window.
            var cache = TokenConsumptionCache()
            while !Task.isCancelled {
                let scanned = await Task.detached(priority: .utility) { [cache] in
                    var carried = cache
                    let snapshot = TokenConsumptionScan.snapshot(
                        claudeHomes: claudeHomes, codexHome: codexHome,
                        now: Date(), cache: &carried)
                    return (snapshot, carried)
                }.value
                cache = scanned.1
                await store.setTokenConsumption(scanned.0)
                self?.tokenConsumption = scanned.0
                try? await Task.sleep(for: .seconds(TokenConsumptionScan.refreshInterval))
            }
        }
    }

    /// Explicit recap actions require a recent authority snapshot. Browsing
    /// cached entries remains available while this action is unavailable.
    var recapAuthorityAvailable: Bool {
        guard snapshotSourceID != nil, let updated = recapUpdatedAt else { return false }
        return Date().timeIntervalSince(updated) <= 10
    }

    func confirmRecap(_ displayed: Recap, sourceID: String?) {
        guard sourceID == snapshotSourceID,
              recapConfirmation.begin(recap: displayed, sourceID: sourceID,
                                      available: recapAuthorityAvailable) else { return }
        driveRecapConfirmation()
    }

    func retryRecapConfirmation() {
        guard recapConfirmation.retry(sourceID: snapshotSourceID, available: recapAuthorityAvailable) else { return }
        driveRecapConfirmation()
    }

    private func driveRecapConfirmation() {
        guard let batch = recapConfirmation.batch, let attemptID = recapConfirmation.attemptID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recapConfirmation.finish(attemptID: attemptID) }
            @MainActor func current() -> Bool {
                self.recapConfirmation.observeSource(self.snapshotSourceID)
                return !Task.isCancelled && self.recapConfirmation.isRunning
                    && self.recapConfirmation.attemptID == attemptID
                    && self.snapshotSourceID == batch.sourceID
            }
            guard current() else { return }
            // Capture the retry remainder once; incoming recap entries never
            // expand this intent, even if another device empties the recap.
            let pending = self.recapConfirmation.pendingCompletions
            for request in pending {
                guard current() else { return }
                let response = await self.store.acknowledgeCompletion(request)
                guard current() else { return }
                self.recapConfirmation.receiveCompletion(response.outcome, request: request, attemptID: attemptID)
            }
            guard current() else { return }
            // Read first. A failed write keeps the horizon untouched and this
            // exact batch retryable; missing/stale rounds are explicitly skipped.
            if let request = self.recapConfirmation.pendingHorizonRequest {
                let outcome = await self.store.advanceRecapHorizon(request)
                guard current() else { return }
                self.recapConfirmation.receiveHorizon(outcome, attemptID: attemptID)
            }
            // Receipts only describe the operation. The polling snapshot owns
            // the recap list, unread badges, and cross-device state.
        }
    }

    // Keep the authority clock current without invalidating every observing window.
    // MacRecapView polls that clock; recovery and source changes publish immediately.
    func applySnapshot(_ snapshot: Snapshot, observedAt: Date) {
        let nextAuthorityAvailable = snapshot.sourceID != nil && Date().timeIntervalSince(observedAt) <= 10
        let authorityChanged = snapshotSourceID != snapshot.sourceID || recapAuthorityAvailable != nextAuthorityAvailable
        let currentSessionIDs = SessionCurrency.current(snapshot.sessions, now: observedAt).map(\.id)
        let nextBuddyState = BuddyState.from(SessionGroups(snapshot.sessions), now: observedAt)
        if authorityChanged || currentSessionIDs != publishedCurrentSessionIDs || nextBuddyState != publishedBuddyState {
            objectWillChange.send()
        }
        publishedCurrentSessionIDs = currentSessionIDs
        publishedBuddyState = nextBuddyState
        snapshotSourceID = snapshot.sourceID
        recapUpdatedAt = observedAt
        if sessions != snapshot.sessions { sessions = snapshot.sessions }
        if recap != snapshot.recap { recap = snapshot.recap }
        if let sourceID = snapshot.sourceID, let batch = recapConfirmation.batch,
           sourceID != batch.sourceID, !recapConfirmation.sourceChanged {
            recapConfirmation.observeSource(sourceID)
        }
        let diagnostics = snapshot.observationDiagnostics ?? []
        if observationDiagnostics != diagnostics { observationDiagnostics = diagnostics }
        let directories = snapshot.recentDirectories ?? []
        if recentDirectories != directories { recentDirectories = directories }
        let nextHandoffs = snapshot.handoffs ?? []
        if handoffs != nextHandoffs { handoffs = nextHandoffs }
        if tokenConsumption != snapshot.tokenConsumption { tokenConsumption = snapshot.tokenConsumption }
        if contentPresentationRevision != snapshot.contentPresentationRevision {
            contentPresentationRevision = snapshot.contentPresentationRevision
        }
    }

    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let noticeURL = LifecycleJournalLocation.defaultURL().deletingLastPathComponent().appendingPathComponent("completion-notices.json")
            await self.store.configureCompletionNotices(url: noticeURL,
                enabled: { CompletionSummaryConfiguration.load().enabled },
                generate: { [weak self] session in await self?.generateCompletionNotice(session) })
            while !Task.isCancelled {
                if E2ERunConfiguration.current == nil {
                    // Never wait for the CLI here: this loop also carries
                    // approvals; the next pass picks up a refresh.
                    let background = ClaudeBackgroundSessions.load()
                    await self.store.applyBackgroundSessions(background)
                }
                let snapshot = await self.store.snapshot(now: Date())
                self.applySnapshot(snapshot, observedAt: Date())
                let nextCodexAppServerDiagnostics = await self.codexAppServerMonitor.diagnostics()
                if self.codexAppServerDiagnostics != nextCodexAppServerDiagnostics { self.codexAppServerDiagnostics = nextCodexAppServerDiagnostics }
                var agents: [AgentKind] = []
                if await self.claudeLauncher.isSupported() { agents.append(.claudeCode) }
                if self.codexAppServerDiagnostics.connected { agents.append(.codex) }
                var cursorReady = await self.cursorACP.isSupported()
                await self.store.setCursorModels(cursorReady ? await self.cursorACP.models() : [])
                if !cursorReady { cursorReady = await self.cursorLauncher.isSupported() }
                if cursorReady { agents.append(.cursor) }
                if await self.grokACP.isSupported() { agents.append(.grok) }
                // Once per launch: hosted Grok sessions an earlier run left.
                await self.grokACP.registerRecoverableSessions()
                if self.dispatchAgents != agents { self.dispatchAgents = agents }
                let nextLifecycleTimeline = await self.store.recentLifecycle()
                if self.lifecycleTimeline != nextLifecycleTimeline { self.lifecycleTimeline = nextLifecycleTimeline }
                let nextMissedThisWeek = await self.store.missedCounts()
                if self.missedThisWeek != nextMissedThisWeek { self.missedThisWeek = nextMissedThisWeek }
                let nextBuddySessionIDs = BuddyScope.pruned(self.buddySessionIDs, toLive: snapshot.sessions)
                if self.buddySessionIDs != nextBuddySessionIDs { self.buddySessionIDs = nextBuddySessionIDs }
                self.tickGlanceCards()
                // Only a positively identified task view can silence its cue.
                // Source-app presence still routes approvals, but cannot tell
                // which Codex/terminal tab the person is reading.
                let viewed = Set(snapshot.sessions.filter { self.isViewing($0.id) }.map(\.id))
                let focused: Set<String> = self.alwaysAskPhone ? [] : viewed
                let alerts = await self.notificationCoordinator.observe(
                    snapshot.sessions,
                    appActive: NSApp.isActive,                 // user looking at VibeBuddy?
                    quietMode: Self.effectiveQuiet(),          // Focus mode (manual or nightly) → every session muted
                    focusedSessionIDs: focused,                // exact task view, not app presence
                    viewedSessionIDs: viewed,
                    categories: NotificationCategoryPrefs.loadMac()) // this Mac's own switches
                await self.refreshNotificationDeliveryHealth()
                // Off the loop: a push may hold for the phone's receipt, and the
                // glance must not wait with it.
                Task { await self.pushToPhones(alerts, focused: focused) }
                await self.pushActivityUpdates(snapshot.sessions)
                await self.checkBudget(snapshot.sessions)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func isCurrentCompletion(_ alert: SoundAlert, deviceToken: String? = nil) async -> Bool {
        guard !alert.isReminder, alert.sound == .agentDone, let notice = alert.session.completionNotice else { return true }
        let devices = deviceToken == nil ? [] : await deviceTokens.devices()
        let snapshot = await store.snapshot(now: Date())
        guard let current = snapshot.sessions.first(where: { $0.id == alert.sessionID }),
              current.completionNotice?.permitsDelivery(of: notice) == true, current.status == .done,
              current.hasUnreadCompletion, !current.isStuck, current.effectiveAttention == .followed,
              CompletionSummaryConfiguration.load().enabled, !Self.effectiveQuiet() else { return false }
        let focused: Set<String> = !alwaysAskPhone && isViewing(current.id) ? [current.id] : []
        guard !focused.contains(current.id) else { return false }
        if let deviceToken {
            let targets = pushTargets(devices)
            return PushFanout.plan(alert, devices: targets.devices, apnsConfigured: targets.configured,
                focusedSessionIDs: focused).recipients.contains { $0.device.token == deviceToken }
        }
        return NotificationCategoryPrefs.loadMac().isEnabled(NotificationSound.agentDone)
    }

    private func generateCompletionNotice(_ session: AgentSession) async -> String? {
        let log = Logger(subsystem: "com.vibebuddy.mac", category: "completionSummary")
        let config = CompletionSummaryConfiguration.load()
        guard config.configurationFailure == nil, let completionID = session.completionID,
              !Self.effectiveQuiet() else { log.notice("Skipped: configuration or quiet mode"); return nil }
        let focused: Set<String> = !alwaysAskPhone && isViewing(session.id) ? [session.id] : []
        guard !focused.contains(session.id) else { log.notice("Skipped: source is focused"); return nil }
        let alert = SoundAlert(session: session, sound: .agentDone,
                               delivery: DeliveryMatrix.level(for: .agentDone, attention: session.effectiveAttention))
        let targets = pushTargets(await deviceTokens.devices())
        let fanout = PushFanout.plan(alert, devices: targets.devices, apnsConfigured: targets.configured, focusedSessionIDs: focused)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let local = (UserDefaults.standard.object(forKey: "notifyOnNeedsResponse") as? Bool ?? true)
            && NotificationCategoryPrefs.loadMac().isEnabled(NotificationSound.agentDone)
            && (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            && !NSApp.isActive
        guard local || fanout.recipients.contains(where: { $0.device.supportsCompletionNotices == true }) else { log.notice("Skipped: no eligible receiver"); return nil }
        guard case .ready(let result) = await store.completionResult(sessionID: session.id, completionID: completionID) else { log.notice("Skipped: final result unavailable"); return nil }
        let input = CompletionSummaryInput(sourceID: result.sourceID, sessionID: result.sessionID,
            completionID: result.completionID, turnID: result.turnID, title: session.displayTitle,
            finalText: result.finalText, completedAt: result.completedAt, observedAt: result.observedAt)
        let summary = await completionSummaryService.generate(input, configuration: config)
        guard !Task.isCancelled, config == CompletionSummaryConfiguration.load(), !Self.effectiveQuiet() else { return nil }
        log.notice("Generation outcome: \(summary.failure?.rawValue ?? "success", privacy: .public)")
        return summary.text
    }

    /// The phones the closed-app channel reaches, and whether there is a
    /// channel at all. With an APNs key: every registered phone. With CloudKit:
    /// the phones that reported this Mac's own iCloud user — a phone on another
    /// Apple Account would never see the record.
    private func pushTargets(_ devices: [DeviceRegistrationPayload]) -> (devices: [DeviceRegistrationPayload], configured: Bool) {
        if pusher != nil { return (devices, true) }
        guard cloudKit != nil, cloudKitStatus.state == .available, let user = cloudKitStatus.userRecordName else {
            return (devices, false)
        }
        return (devices.filter { $0.cloudKitUser == user }, true)
    }

    func refreshNotificationDeliveryHealth() async {
        if let cloudKit {
            let status = await cloudKit.refreshStatus()
            if cloudKitStatus != status { cloudKitStatus = status }
            let phones = pushTargets(await deviceTokens.devices()).devices.filter(\.hasPushToken).count
            if cloudKitPhones != phones { cloudKitPhones = phones }
        }
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
        let nextNotificationDeliveryHealth = await deliveryRecorder.health()
        if notificationDeliveryHealth != nextNotificationDeliveryHealth { notificationDeliveryHealth = nextNotificationDeliveryHealth }
        let nextRecentNotificationDeliveries = await deliveryRecorder.recent(limit: 8)
        if recentNotificationDeliveries != nextRecentNotificationDeliveries { recentNotificationDeliveries = nextRecentNotificationDeliveries }
        let nextDeviceRegistry = await deviceTokens.summary()
        if deviceRegistry != nextDeviceRegistry { deviceRegistry = nextDeviceRegistry }
        await refreshPairedPhone()
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
        guard E2ERunConfiguration.current == nil else { return }
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

    /// False when Claude's status line is not forwarding to vibebuddy — the
    /// one source of its account quota, so the quota surfaces say that rather
    /// than blaming a missing session.
    var claudeStatusLineWired: Bool { usage.isClaudeStatusLineWired() }

    /// True for the one provider whose readings can only arrive through a
    /// forwarder that is currently not installed.
    func usageStatusLineUnwired(_ provider: AccountUsageProvider) -> Bool {
        provider == .claude && !claudeStatusLineWired
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
        // The island shows current sessions (`SessionCurrency`); the approval
        // target below still looks at all of them — a wait is always current.
        let current = SessionCurrency.current(sessions, now: Date())
        let summary = TaskPresentationSummary(sessions: current)
        let leading = current.leadingPresentationSession
        let topProject = leading?.project
        let topSession = leading?.id
        // The first pending approval, not necessarily the leading session (an
        // error outranks it) — the island's keys answer this one.
        let target = ActivityApprovalTarget.select(from: sessions)
        let key = "\(summary)|\(topProject ?? "")|\(topSession ?? "")|\(target?.approvalID ?? "")|\(target?.title ?? "")|\(target?.detail ?? "")"
        guard key != lastActivityKey else { return }
        lastActivityKey = key
        for t in tokens {
            await pusher.sendActivityUpdate(summary: summary,
                topProject: topProject, topSessionId: topSession,
                approvalId: target?.approvalID, approvalTitle: target?.title,
                approvalDetail: target?.detail, to: t)
        }
    }

    /// Push the cues the Mac just decided on to paired phones. Only a cue loud
    /// enough to interrupt here is worth pulling you back from elsewhere; a
    /// list-only cue stays on the Mac. Each device then applies its own prefs:
    /// its Quiet mode reads the cue through the `muted` column, never louder
    /// than the Mac decided, and mute drops the sound. When the phone is in the
    /// foreground it suppresses the remote push itself (see willPresent).
    private func pushToPhones(_ alerts: [SoundAlert], focused: Set<String>) async {
        guard !alerts.isEmpty else { return }
        let devices = await deviceTokens.devices()
        for alert in alerts { await push(alert, to: devices, focused: focused) }
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
    private func push(_ alert: SoundAlert, to devices: [DeviceRegistrationPayload],
                      focused: Set<String> = [], recordSkips: Bool = true,
                      standDownForPhone: Bool = true) async -> Bool {
        let targets = pushTargets(devices)
        let fanout = PushFanout.plan(alert, devices: targets.devices, apnsConfigured: targets.configured,
                                     focusedSessionIDs: focused)
        guard !fanout.recipients.isEmpty else {
            if recordSkips { await recordPushSkip(alert, reason: fanout.skip) }
            return false
        }
        guard let pusher else {
            guard let cloudKit else { return false }
            return await pushThroughCloudKit(alert, fanout: fanout, via: cloudKit,
                                             standDownForPhone: standDownForPhone)
        }
        // A phone with a live stream may be posting this cue itself right now:
        // hold each push briefly for its receipt (ADR-0012), all devices side
        // by side. A reminder says the same cue again on purpose, so it never
        // stands down (`standDownForPhone: false`).
        let hold: Bool = if standDownForPhone { await store.subscriberCount > 0 } else { false }
        let waitSince: Date? = standDownForPhone ? alert.session.statusSince : nil
        let registry = deviceTokens
        var sent = false
        await withTaskGroup(of: Void.self) { group in
            for recipient in fanout.recipients {
                guard let deviceToken = recipient.device.token else { continue }
                if standDownForPhone, alert.sound == .agentDone, let notice = alert.session.completionNotice,
                   !(await CompletionNoticeAttempts.shared.claim(notice, recipient: "apns/" + deviceToken)) { continue }
                var recipientSession = alert.session
                if alert.sound == .agentDone, alert.session.completionNotice != nil,
                   recipient.device.supportsCompletionNotices != true {
                    // An installed phone must opt into the pending/decision wire contract.
                    // Its existing completion path still receives ordinary wording and identity.
                    let live = await store.snapshot(now: Date()).sessions.first { $0.id == alert.sessionID }
                    recipientSession.summary = live?.summary
                    recipientSession.completionNotice = nil
                }
                let recipientAlert = SoundAlert(session: recipientSession, sound: alert.sound,
                    delivery: recipient.level, isReminder: alert.isReminder)
                let copy = PushCopy.copy(for: alert.sound, session: recipientSession)
                let sound = recipient.level.makesSound && recipient.device.playSound != false
                    ? alert.sound.fileName : ""
                sent = true
                group.addTask {
                    let result = await pusher.send(title: copy.title, body: copy.body, to: deviceToken, sound: sound,
                                                   sessionID: alert.sessionID, soundCategory: alert.sound.rawValue,
                                                   localized: PushLocalization(copy),
                                                   category: alert.actionCategory?.rawValue,
                                                   timeSensitive: alert.isTimeSensitive && recipient.level == .bannerSound,
                                                   approvalId: alert.actionCategory == .approval ? alert.session.pendingApproval?.id : nil,
                                                   questionId: alert.actionCategory == .question ? alert.session.pendingQuestion?.id : nil,
                                                   waitSince: waitSince, holdForPhone: hold,
                                                   notificationID: recipientAlert.notificationID,
                                                   validate: { [weak self] in
                                                       guard let self else { return false }
                                                       return await self.isCurrentCompletion(alert, deviceToken: deviceToken)
                                                   })
                    await registry.applySendResult(result, token: deviceToken)
                }
            }
        }
        return sent
    }

    /// One record for the whole Apple Account: every phone signed into it gets
    /// the same push, so the loudest recipient decides the sound, and each
    /// phone's extension quiets it again for its own Quiet mode. A completion
    /// notice is claimed once for the account, not per phone.
    private func pushThroughCloudKit(_ alert: SoundAlert, fanout: PushFanout, via cloudKit: CloudKitCueSender,
                                     standDownForPhone: Bool) async -> Bool {
        guard let level = fanout.recipients.map(\.level).max() else { return false }
        if standDownForPhone, alert.sound == .agentDone, let notice = alert.session.completionNotice,
           !(await CompletionNoticeAttempts.shared.claim(notice, recipient: "cloudkit")) { return false }
        var session = alert.session
        if alert.sound == .agentDone, alert.session.completionNotice != nil,
           !fanout.recipients.allSatisfy({ $0.device.supportsCompletionNotices == true }) {
            let live = await store.snapshot(now: Date()).sessions.first { $0.id == alert.sessionID }
            session.summary = live?.summary
            session.completionNotice = nil
        }
        let sent = SoundAlert(session: session, sound: alert.sound, delivery: level, isReminder: alert.isReminder)
        let copy = PushCopy.copy(for: alert.sound, session: session)
        let wantsSound = level.makesSound && fanout.recipients.contains { $0.device.playSound != false }
        let category = alert.actionCategory
        let cue = CloudKitCueOutgoing(
            kind: CloudKitCue.Kind(category: category), notificationID: sent.notificationID,
            sessionID: alert.sessionID,
            requestID: category == .approval ? session.pendingApproval?.id
                : category == .question ? session.pendingQuestion?.id : nil,
            title: copy.title, body: copy.body, localization: PushLocalization(copy),
            sound: wantsSound ? alert.sound.fileName : "",
            timeSensitive: alert.isTimeSensitive && level == .bannerSound,
            soundCategory: alert.sound.rawValue)
        let hold: Bool = if standDownForPhone { await store.subscriberCount > 0 } else { false }
        let result = await cloudKit.send(
            cue, tokens: fanout.recipients.compactMap(\.device.token),
            waitSince: standDownForPhone ? alert.session.statusSince : nil, holdForPhone: hold,
            validate: { [weak self] in
                guard let self else { return false }
                return await self.isCurrentCompletion(alert, deviceToken: fanout.recipients.first?.device.token)
            })
        return result.outcome == .accepted
    }

    private func recordPushSkip(_ alert: SoundAlert, reason: CueSkipReason?) async {
        guard let reason else { return }
        await deliveryRecorder.record(NotificationDeliveryRecord(
            channel: pusher == nil && cloudKit != nil ? .cloudkit : .apns, outcome: .skipped, sessionID: alert.sessionID,
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
            session, quietMode: Self.effectiveQuiet(), categories: NotificationCategoryPrefs.loadMac())
        let devices = await deviceTokens.devices()
        let level = DeliveryMatrix.level(for: .agentDone, attention: session.effectiveAttention)
        // `recordSkips: false`: an undelivered reminder is re-proposed on every
        // pass of the server's 30s loop until something takes it, so recording
        // each one would bury the log. The completion's own cue already said why.
        let pushed = await push(SoundAlert(session: session, sound: .agentDone, delivery: level, isReminder: true),
                                to: devices, recordSkips: false, standDownForPhone: false)
        if local || pushed { await refreshNotificationDeliveryHealth() }
        return local || pushed
    }

    /// Fire a one-time budget heads-up (local + push) for sessions that just
    /// crossed the user's per-session spend budget. 0 = disabled.
    private func checkBudget(_ sessions: [AgentSession]) async {
        let budget = UserDefaults.standard.double(forKey: "sessionBudgetUSD")
        let alerts = budgetMonitor.newlyOverBudget(sessions, budgetUSD: budget)
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            let cost = String(format: "$%.2f", alert.estimatedUSD)
            await deliverQuotaNotice(
                title: "\(alert.session.project) over budget",
                body: "≈ \(cost) spent this session (estimate)",
                id: "budget-\(alert.session.project)",
                sessionID: alert.session.id)
        }
    }

    private func handleBannerAction(_ action: NotificationActionID, sessionId: String,
                                    approvalId: String?, text: String?) {
        switch action {
        case .approve:
            if let approvalId { decide(approvalId, .allow) }
        case .deny:
            if let approvalId { decide(approvalId, .deny) }
        case .answer:
            if let text { answer(sessionId, answers: [:], text: text) }
        }
    }

    /// Sample approval / question banners carry the same actions a live cue does.
    private func postDemoBanners() {
        for session in sessions {
            if session.pendingApproval != nil {
                notifier.notifyDetached(SoundAlert(session: session, sound: .needsApproval))
            } else if session.waitKind == .question {
                notifier.notifyDetached(SoundAlert(session: session, sound: .needsAnswer))
            }
        }
    }

    /// Local banner (this Mac's quota switch) and APNs (each phone's uploaded
    /// switch). Quota is not a session cue: the attention matrix is not applied.
    private func deliverQuotaNotice(title: String, body: String, id: String,
                                    sessionID: String?) async {
        let attempt = await notifier.notifyQuota(title: title, body: body, id: id)
        let localSkip = QuotaNoticeFanout.localSkip(categories: NotificationCategoryPrefs.loadMac())
        if let reason = localSkip {
            await deliveryRecorder.record(NotificationDeliveryRecord(
                channel: .local, outcome: .skipped, sessionID: sessionID,
                sound: NotificationCategory.quota.rawValue,
                failureReason: reason.rawValue, timestamp: Date()))
        } else if attempt.shouldRecord {
            await deliveryRecorder.record(NotificationDeliveryRecord(
                channel: .local, outcome: attempt.outcome, sessionID: sessionID,
                sound: NotificationCategory.quota.rawValue,
                failureReason: attempt.failureReason, timestamp: Date()))
        }

        let devices = pusher == nil ? [] : await deviceTokens.devices()
        let plan = QuotaNoticeFanout.plan(devices: devices, apnsConfigured: pusher != nil)
        guard let pusher, !plan.recipients.isEmpty else {
            if let reason = plan.skip {
                await deliveryRecorder.record(NotificationDeliveryRecord(
                    channel: .apns, outcome: .skipped, sessionID: sessionID,
                    sound: NotificationCategory.quota.rawValue,
                    failureReason: reason.rawValue, timestamp: Date()))
            }
            await refreshNotificationDeliveryHealth()
            return
        }
        for device in plan.recipients {
            guard let deviceToken = device.token else { continue }
            let sound = device.playSound != false ? "default" : ""
            let result = await pusher.send(
                title: title, body: body, to: deviceToken, sound: sound,
                sessionID: sessionID, soundCategory: NotificationCategory.quota.rawValue)
            await deviceTokens.applySendResult(result, token: deviceToken)
        }
        await refreshNotificationDeliveryHealth()
    }

    /// Resolve a pending approval from the Mac (Dashboard buttons / shortcuts).
    /// Mirrors the daemon's `/decision` route in-process (the Mac IS the daemon),
    /// so "always allow" / "allow this session" behave identically to the phone.
    func decide(_ approvalId: String, _ choice: ApprovalDecision) {
        Task {
            let snapshot = await store.snapshot(now: Date())
            guard let pending = snapshot.sessions.compactMap(\.pendingApproval).first(where: { $0.id == approvalId }),
                  pending.supports(choice),
                  let ctx = await approvalContext.take(id: approvalId),
                  await approvalRegistry.claim(id: approvalId) else { return }
            switch choice {
            case .alwaysAllow:
                if let rule = ctx.rule { await allowStore.add(rule) }
                await approvalRegistry.resolve(id: approvalId, with: .allow)
            case .allowSession:
                await sessionAllow.add(ctx.sessionID)
                await approvalRegistry.resolve(id: approvalId, with: .allow)
            case .allow:
                await approvalRegistry.resolve(id: approvalId, with: .allow)
            case .deny:
                await approvalRegistry.resolve(id: approvalId, with: .deny)
            }
            await store.recordInteraction(sessionID: ctx.sessionID)
        }
    }

    /// Answer or advance a session from the Mac card, the same contract as
    /// `/answer`: waiting questions go to the agent; Codex steer / continue
    /// are explicit and never rewrite each other.
    func answer(_ sessionID: String, answers: QuestionAnswers, text: String? = nil) {
        let monitor = codexAppServerMonitor
        let acp = cursorACP
        let grok = grokACP
        let followups = cursorFollowups
        let store = store
        let session = sessions.first { $0.id == sessionID }
        let support = session.map(SessionActionSupport.resolve(for:))
        let dispatch = AnswerDispatch(
            store: store, questions: questionRegistry,
            inject: { ref, answer in await TerminalInjector.inject(answer, into: ref) },
            steer: { id, text in
                if await grok.hosts(id) { return await grok.queueFollowup(sessionID: id, text: text) }
                return await monitor.steer(threadID: id, text: text)
            },
            startTurn: { id, text in
                if await grok.owns(id) { return await grok.prompt(sessionID: id, text: text) }
                return await monitor.startTurn(threadID: id, text: text)
            },
            queueCursorFollowup: { id, text in
                await followups.queue(conversationID: id, text: text) != nil
            },
            resumeCursor: { session, text in
                if await acp.owns(session.id) { return await acp.prompt(sessionID: session.id, text: text) }
                guard E2ERunConfiguration.current == nil else { return false }
                return await CursorCLI.resume(conversationID: session.id, text: text, cwd: session.project,
                    preferring: await store.preferredTerminalProgram())
            })
        Task { [weak self] in
            let result = await dispatch.deliver(SessionActionRequest(
                sessionID: sessionID,
                intent: support?.intent,
                questionID: session?.pendingQuestion?.id,
                text: text,
                answers: answers.isEmpty ? nil : answers))
            if case .accepted = result { await self?.store.recordInteraction(sessionID: sessionID) }
            await MainActor.run {
                if case .unknown = result {
                    self?.answerFeedback[sessionID] = "Result unknown — check the task before sending again"
                } else if case .failed(let why) = result {
                    self?.answerFeedback[sessionID] = why
                } else {
                    self?.answerFeedback[sessionID] = nil
                }
            }
        }
    }

    /// Stop exactly the turn shown by the card; a changed status is refused
    /// by the same dispatch guard used by the HTTP route.
    func stop(_ session: AgentSession) {
        let monitor = codexAppServerMonitor
        let acp = cursorACP
        let grok = grokACP
        let cloud = voiceCursorCloud
        let store = store
        let dispatch = AnswerDispatch(
            store: store, questions: questionRegistry,
            inject: { _, _ in },
            interrupt: { id in
                if await acp.hosts(id) { return await acp.cancel(sessionID: id) }
                if await grok.hosts(id) { return await grok.cancel(sessionID: id) }
                return await monitor.interrupt(threadID: id)
            },
            cancelCursorCloud: { id in
                guard E2ERunConfiguration.current == nil else {
                    return .notSent("Cloud actions are disabled during isolated acceptance.")
                }
                guard let run = await store.cursorCloudLatestRun(for: id) else {
                    return .notSent("This run has already finished.")
                }
                return await cloud.cancel(agentID: id, runID: run)
            })
        Task { [weak self] in
            let result = await dispatch.deliver(SessionActionRequest(
                sessionID: session.id, intent: .stop,
                expectedStatusSince: session.statusSince.timeIntervalSince1970))
            if case .accepted = result { await store.recordInteraction(sessionID: session.id) }
            switch result {
            case .accepted: self?.answerFeedback[session.id] = nil
            case .failed(let reason), .refused(let reason): self?.answerFeedback[session.id] = reason
            case .unknown: self?.answerFeedback[session.id] = "Result unknown — check the task before sending again"
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
        guard E2ERunConfiguration.current == nil else {
            showJumpFeedback(.noTerminal, for: session.id)
            return
        }
        Task { [store] in await store.recordInteraction(sessionID: session.id) }
        if session.resumesInTerminal {
            // A hosted Grok session whose process is gone: `grok --resume` in a terminal.
            Task { [weak self, store, grokACP] in
                let outcome = await grokACP.resumeInTerminal(sessionID: session.id,
                                                             preferring: await store.preferredTerminalProgram())
                self?.showJumpFeedback(outcome, for: session.id)
            }
        } else if let ref = session.terminalRef {
            Task { [weak self] in
                let outcome = await TerminalJumper.jump(ref)
                self?.showJumpFeedback(outcome, for: session.id)
            }
        } else if let thread = session.desktopThreadID {
            Task { [weak self] in
                let outcome = await CodexDesktopJumper.jump(threadID: thread)
                self?.showJumpFeedback(outcome, for: session.id)
            }
        } else if session.agent == .claudeCode {
            // A background session has no window: open one attached to it.
            // The lookup may run `claude agents`, so it stays off the main actor.
            Task { [weak self, store] in
                guard let job = await ClaudeBackgroundSessions.find(sessionID: session.id) else {
                    self?.showJumpFeedback(.noTerminal, for: session.id); return
                }
                let term = await store.preferredTerminalProgram()
                let outcome = await TerminalLauncher.attach(claudeJobID: job.id, preferring: term)
                self?.showJumpFeedback(outcome, for: session.id)
            }
        } else {
            showJumpFeedback(.noTerminal, for: session.id)
        }
    }

    /// End every `cursor-agent acp` process this app is hosting. Called on quit:
    /// the CLI has no detached mode over ACP, so a turn cannot outlive the host.
    func shutdownCursorHosts() async {
        await cursorACP.shutdown()
        await grokACP.shutdown()
    }

    /// Start a new task from the Mac, the same way `/dispatch` does for the
    /// phone: Codex through the app-server daemon; other agents once they have
    /// a launcher. The directory must be one a session has run in, unless the
    /// user picked it in this Mac's open panel just now (`userChoseDirectory`):
    /// that choice is the authorization the known-directory rule stands in
    /// for when a request arrives from the phone.
    /// Continue with…: prefill the New task sheet from a finished session and
    /// its newest handoff, if one names it. The dashboard presents the sheet.
    func requestContinue(_ session: AgentSession, with agent: AgentKind) {
        guard let key = ContinueWith.sessionKey(for: session) else { return }
        let handoff = ContinueWith.handoff(for: session, in: handoffs)
        continueRequest = NewTaskPrefill(
            agent: agent,
            // Only what the Mac observed; unknown stays empty and the person picks.
            directory: session.checkoutPath ?? session.terminalRef?.cwd ?? "",
            name: ContinueWith.taskName(for: session),
            prompt: ContinueWith.prompt(sessionKey: key, handoffPath: handoff?.path,
                                        checkout: session.checkoutPath ?? session.terminalRef?.cwd),
            continuing: NewTaskPrefill.Continuation(sessionID: session.id, sourceKey: key, handoffPath: handoff?.path))
    }

    func dispatch(_ request: DispatchRequest, userChoseDirectory: Bool = false) async -> DispatchOutcome {
        let dispatcher = TaskDispatcher(store: store, codex: codexAppServerMonitor,
                                        claude: claudeLauncher, cursor: cursorLauncher, cursorACP: cursorACP,
                                        grokACP: grokACP)
        switch await dispatcher.dispatch(request, directory: userChoseDirectory ? .userSelected : .knownSession) {
        case .success(let outcome): return outcome
        case .failure(.directoryUnavailable): return .rejected("That folder is no longer available.")
        case .failure(.unknownDirectory): return .rejected("Pick a directory a session has already run in.")
        case .failure(.staleContinuation):
            return .rejected("That handoff is no longer a scanned document for the source session. Open Continue with… again.")
        case .failure(.unsupportedAgent(let agent)):
            return .unsupported("VibeBuddy cannot start \(agent.displayName) sessions yet.")
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
    func acknowledge(_ sessionID: String, displayedCompletionID: String? = nil) {
        if (E2ERunConfiguration.current == nil && ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1") {
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
                  sessions[index].hasUnreadCompletion else { return }
            sessions[index].hasUnreadCompletion = false
            return
        }
        guard let sourceID = snapshotSourceID,
              let session = sessions.first(where: { $0.id == sessionID }) else { return }
        if session.status == .needsResponse {
            let read = WaitReadRequest(sourceID: sourceID, session: session)
            Task { [store] in _ = await store.acknowledgeWait(read) }
            return
        }
        guard session.hasUnreadCompletion, let completionID = session.completionID,
              completionID == displayedCompletionID else { return }
        let request = CompletionReadRequest(sourceID: sourceID, sessionID: sessionID, completionID: completionID)
        Task { [store] in _ = await store.acknowledgeCompletion(request) }
    }

    func markUnread(_ session: AgentSession) {
        guard let sourceID = snapshotSourceID, let completionID = session.completionID else { return }
        let request = CompletionReadRequest(sourceID: sourceID, sessionID: session.id, completionID: completionID, markUnread: true)
        Task { [store] in _ = await store.acknowledgeCompletion(request) }
    }

    /// Set, or with `nil` return to automatic, how much this session may
    /// interrupt you. The daemon owns the value; demo mode mirrors it locally.
    func setAttention(_ sessionID: String, _ level: SessionAttention?) {
        if (E2ERunConfiguration.current == nil && ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1") {
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            sessions[index].attentionOverride = level
            sessions[index].attention = level ?? .normal
            return
        }
        Task { [store] in await store.setAttention(sessionID: sessionID, level) }
    }

    /// Include/exclude a session from the buddy's context (ephemeral). Takes effect
    /// on the next status read and at each action scope check.
    func toggleBuddy(_ id: String) {
        if buddySessionIDs.contains(id) { buddySessionIDs.remove(id) }
        else { buddySessionIDs.insert(id) }
    }

    /// The session's recent output, for the detail pane's "Recent output" sheet.
    /// Reads off the store actor; empty when no transcript is known.
    func transcript(for sessionID: String) async -> [TranscriptEntry] {
        await recentOutput(for: sessionID).entries.map { TranscriptEntry(role: $0.role, text: $0.text) }
    }

    func workspaceChanges(for session: AgentSession, scope: ChangesScope, baseline: String?, file: String?) async -> WorkspaceChanges {
        // `VIBEBUDDY_DEMO_WORKSPACE=<repo path>` gives the demo's approval
        // session a real, read-only Git workspace so the Changes pane can be
        // screenshotted with content; demo only, never a production session.
        if E2ERunConfiguration.current == nil, ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1",
           session.id == "demo-edit", let path = ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO_WORKSPACE"] {
            return await WorkspaceChangesReader.readInBackground(cwd: path, scope: scope, baseline: baseline, file: file, shared: false)
        }
        return await store.workspaceChanges(sessionID: session.id, scope: scope, baseline: baseline, file: file)
    }

    var completionSourceID: String? { snapshotSourceID }

    func completionBody(for session: AgentSession) async -> CompletionBody? {
        guard let id = session.completionID else { return nil }
        return await store.completionBody(sessionID: session.id, completionID: id)
    }

    func recentOutput(for sessionID: String) async -> RecentOutput {
        await store.recentOutput(sessionID: sessionID)
    }

    /// Execute a voice action against the matching session; returns a spoken confirmation.
    func performVoiceAction(_ action: VoiceAction) async -> String {
        guard !Task.isCancelled else { return "Action cancelled before submission." }
        switch action {
        case .approve(let project), .deny(let project):
            guard let s = match(project), let ap = s.pendingApproval else { return "No pending approval." }
            let live = await store.snapshot(now: Date())
            let choice: ApprovalDecision
            if case .approve = action { choice = .allow } else { choice = .deny }
            guard !Task.isCancelled,
                  let pending = live.sessions.first(where: { $0.id == s.id })?.pendingApproval,
                  pending.id == ap.id, pending.supports(choice),
                  let context = await approvalContext.context(id: ap.id), context.sessionID == s.id else {
                return "The approval changed or the action was cancelled."
            }
            let outcome: ApprovalRegistry.Outcome
            if case .approve = action { outcome = .allow } else { outcome = .deny }
            guard await approvalRegistry.resolveVoice(id: ap.id, with: outcome) else {
                return "The approval was not submitted."
            }
            _ = await approvalContext.take(id: ap.id)
            await store.recordInteraction(sessionID: s.id)
            return "Decision submitted for \(s.project); command execution is not yet confirmed."
        case .answer(let project, let text), .instruct(let project, let text):
            let snapshot = await store.snapshot(now: Date())
            guard !Task.isCancelled,
                  let observed = voiceActionContext.target(project, sourceID: snapshot.sourceID,
                      currentScope: voiceScope(snapshot.sessions)),
                  let current = snapshot.sessions.first(where: { $0.id == observed.id }) else {
                return "No unique task in the voice status you read. Ask for current status and specify the task in your voice scope; nothing was sent."
            }
            let support = SessionActionSupport.resolve(for: current)
            guard support.isAvailable else { return support.unsupportedReason ?? "This task cannot take an instruction here." }
            let answerOnly: Bool
            if case .answer = action { answerOnly = true } else { answerOnly = false }
            guard let request = voiceActionContext.instructionRequest(for: observed, current: current,
                text: text, answerOnly: answerOnly) else {
                return "The question, turn or control channel changed, or the request is unavailable. Ask for current status before making a new request; nothing was sent."
            }
            let monitor = codexAppServerMonitor
            let followups = cursorFollowups
            let acp = cursorACP
            let grok = grokACP
            let cloud = voiceCursorCloud
            let store = store
            let dispatch = AnswerDispatch(store: store, questions: questionRegistry,
                inject: { ref, text in await TerminalInjector.inject(text, into: ref) },
                steer: { id, text in
                    if await grok.hosts(id) { return await grok.queueFollowup(sessionID: id, text: text) }
                    return await monitor.steer(threadID: id, text: text)
                },
                startTurn: { id, text in
                    if await grok.owns(id) { return await grok.prompt(sessionID: id, text: text) }
                    return await monitor.startTurn(threadID: id, text: text)
                },
                queueCursorFollowup: { id, text in
                    await followups.queue(conversationID: id, text: text) != nil
                },
                resumeCursor: { session, text in
                    if await acp.owns(session.id) { return await acp.prompt(sessionID: session.id, text: text) }
                    guard E2ERunConfiguration.current == nil else { return false }
                    return await CursorCLI.resume(conversationID: session.id, text: text, cwd: session.project,
                        preferring: await store.preferredTerminalProgram())
                },
                continueCursorCloud: { id, text in
                    guard E2ERunConfiguration.current == nil else { return .refused("Cloud actions are disabled during isolated acceptance.") }
                    return await cloud.continueAgent(id: id, text: text)
                },
                requests: voiceActionRequests)
            guard !Task.isCancelled,
                  snapshot.sourceID == snapshotSourceID,
                  voiceScope(sessions).contains(where: { $0.id == observed.id }) else {
                return "The source or voice scope changed, or the action was cancelled; nothing was sent."
            }
            let result = await dispatch.deliver(request)
            switch result {
            case .accepted:
                await store.recordInteraction(sessionID: observed.id)
                return "Request accepted for \(observed.project); agent execution is not yet confirmed. \(support.note ?? "")"
            case .failed(let reason): return "Request failed: \(reason)"
            case .refused(let reason): return "Request refused: \(reason)"
            case .unknown: return "Result unknown. Check the task before sending again; this request will not be automatically resent."
            }
        case .markRead(let project):
            let snapshot = await store.snapshot(now: Date())
            guard !Task.isCancelled,
                  let observed = voiceActionContext.target(project, sourceID: snapshot.sourceID,
                      currentScope: voiceScope(snapshot.sessions)),
                  let current = snapshot.sessions.first(where: { $0.id == observed.id }),
                  let request = voiceActionContext.completionRequest(for: observed, current: current) else {
                return "The result is missing, unfinished, ambiguous or changed since the voice status you read. Ask for current status and identify the result; nothing was marked read."
            }
            guard !Task.isCancelled, snapshot.sourceID == snapshotSourceID,
                  voiceScope(sessions).contains(where: { $0.id == observed.id }) else {
                return "The source or voice scope changed, or the action was cancelled; nothing was marked read."
            }
            let result = await store.acknowledgeCompletion(request)
            switch result.outcome {
            case .accepted, .alreadyAcknowledged:
                return "This exact result for \(observed.project) is marked read. It has not been reviewed or accepted."
            case .staleCompletion: return "That result round changed; the newer result was not marked read."
            case .sourceMismatch: return "The source changed; nothing was marked read."
            case .unavailable: return "The result is no longer available; nothing was marked read."
            case .failed: return "Could not save the reading state. Nothing was marked read."
            }
        case .none: return ""
        }
    }

    private func match(_ project: String) -> AgentSession? {
        // Conservative resolution (exact-first, unique-substring, refuse ambiguous)
        // so a voice approve never lands on the wrong real command target.
        VoiceSessionMatch.match(project, in: voiceScope(sessions))
    }

    private func readVoiceStatus() async -> [AgentSession] {
        let snapshot = await store.snapshot(now: Date())
        guard !Task.isCancelled else { return [] }
        let scope = voiceScope(snapshot.sessions)
        // VoicePrompt returns at most 40 individual rows. Counts do not expose
        // omitted identities and cannot authorize those tasks.
        voiceActionContext.observe(sourceID: snapshot.sourceID, sessions: Array(scope.prefix(40)))
        return scope
    }

    private func voiceScope(_ sessions: [AgentSession]) -> [AgentSession] {
        buddySessionIDs.isEmpty ? sessions : sessions.filter { buddySessionIDs.contains($0.id) }
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

    /// A stored address that cannot be a hostname is dropped on read rather
    /// than kept and offered to pairing. `preparePairing` already refuses to
    /// build a payload from it, but a junk value left in place keeps the field
    /// occupied, so `discoverRemoteAddress` will not fill in the real address
    /// and the Mac reads as merely unprepared. Only the persisted value is
    /// checked: a half-typed address never reaches here.
    private static func loadTailscaleHost() -> String {
        let defaults = UserDefaults.standard
        guard let stored = defaults.string(forKey: "pairing.tailscaleHost"), !stored.isEmpty else { return "" }
        guard let host = CompanionEndpoint.normalizedHost(stored) else {
            defaults.removeObject(forKey: "pairing.tailscaleHost")
            return ""
        }
        return host
    }

    var remoteAddressIsValid: Bool {
        CompanionEndpoint(host: tailscaleHost, port: port)?.isTailnetIPv4 == true
    }

    var canSyncConnection: Bool {
        useTailscale && remoteAddressIsValid && pairedPhone?.confirmed == true
            && pairedPhone?.deviceID?.isEmpty == false && !synchronizingConnection && !changingPairing
    }

    func discoverRemoteAddress() {
        detectedRemoteAddresses = LANAddress.tailnetIPv4Addresses()
        if tailscaleHost.isEmpty, detectedRemoteAddresses.count == 1 {
            let hasPreference = UserDefaults.standard.object(forKey: "pairing.useTailscale") != nil
            tailscaleHost = detectedRemoteAddresses[0]
            if !hasPreference { useTailscale = true }
        }
    }

    func refreshConnectionCenter() async {
        await refreshPairedPhone()
        if let deviceID = pairedPhone?.deviceID {
            remoteTransfer = await connectionSync.transfer(for: deviceID)
        } else {
            remoteTransfer = nil
        }
    }

    func syncConnectionToPhone() {
        guard canSyncConnection, let deviceID = pairedPhone?.deviceID else { return }
        let host = tailscaleHost
        synchronizingConnection = true
        Task {
            defer { synchronizingConnection = false }
            guard await deviceTokens.isConfirmed(deviceID: deviceID), let sourceID = await store.sourceID else { return }
            await connectionSync.propose(deviceID: deviceID, sourceID: sourceID, host: host, port: port)
            await refreshConnectionCenter()
        }
    }

    func cancelConnectionSync() {
        guard let deviceID = remoteTransfer?.proposal.deviceID else { return }
        Task {
            await connectionSync.cancel(for: deviceID)
            await refreshConnectionCenter()
        }
    }

    func openConnectionSettings() {
        NotificationCenter.default.post(name: .openAppSettings, object: SettingsPageID.phone)
    }

    /// User action only. Preparing a QR at launch never authorizes registration.
    func beginPairing() {
        preparePairing()
        guard pairing != nil, !changingPairing else { return }
        changingPairing = true
        pairingRevision += 1
        pairingTimeout?.cancel()
        Task {
            await deviceTokens.acceptNewRegistrations()
            pairingInProgress = true
            changingPairing = false
            pairingTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                self?.endPairing()
            }
        }
    }

    func endPairing() {
        guard !changingPairing else { return }
        changingPairing = true
        pairingRevision += 1
        pairingTimeout?.cancel()
        pairingInProgress = false
        Task {
            await deviceTokens.endPairing()
            changingPairing = false
        }
    }

    private func refreshPairedPhone(notify: Bool = false) async {
        guard !changingPairing else { return }
        let revision = pairingRevision
        let entries = await deviceTokens.pairedPhones()
        guard revision == pairingRevision, !changingPairing else { return }
        let all = entries.sorted { $0.registeredAt > $1.registeredAt }.map(PairedPhone.init)
        // The phone the connection centre speaks for: the newest one the Mac
        // still pushes to, or, when every phone is parked, the newest parked one
        // — so a stood-down phone is shown with its reason, never hidden.
        let next = all.first { !$0.isParked } ?? all.first
        let newlyConfirmed = pairedPhone?.confirmed != true && next?.confirmed == true
        if phones != all { phones = all }
        if pairedPhone != next { pairedPhone = next }
        if notify && pairingInProgress && newlyConfirmed, let next { notifier.confirmPairing(deviceName: next.name) }
    }

    func forgetPairedPhone() {
        guard !changingPairing else { return }
        changingPairing = true
        pairingRevision += 1
        pairingTimeout?.cancel()
        pairingInProgress = false
        pairedPhone = nil
        phones = []
        Task {
            await connectionSync.cancelAll()
            remoteTransfer = nil
            await deviceTokens.forgetAll()
            deviceRegistry = await deviceTokens.summary()
            changingPairing = false
        }
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

    func setNextPendingHotkey(_ hotkey: Hotkey) {
        nextPendingHotkey = hotkey
        hotkey.saveAsNextPending()
        GlobalHotkey.setNextPendingHotkey(hotkey)
    }

    func setGlanceHotkey(_ hotkey: Hotkey) {
        toggleGlanceHotkey = hotkey
        hotkey.saveAsToggleGlance()
        GlobalHotkey.setGlanceHotkey(hotkey)
    }

    private static func localMacName() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    nonisolated fileprivate static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    deinit {
        pollTask?.cancel()
        tokenScanTask?.cancel()
        glanceCardTicker?.cancel()
    }
}
