import SwiftUI
import AppKit
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
    @Published private(set) var lifecycleTimeline: [LifecycleJournalEntry] = []
    @Published private(set) var lifecycleJournalClearFailed = false
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
    @Published var openDashboardHotkey: Hotkey = .openDashboardDefault
    @Published var toggleGlanceHotkey: Hotkey = .toggleGlanceDefault
    /// Idle-cleanup window in hours; 0 means never. Default 2h.
    @Published var idleTimeoutHours: Double = 2
    /// Account usage is intentionally separate from `sessions`; refresh errors
    /// never enter SessionStore or the progress notification pipeline.
    @Published private(set) var codexUsageState: CodexUsageState = .disabled
    @Published private(set) var codexUsageCollectionEnabled = true

    let port: Int
    private let token: String
    private let store: SessionStore
    private let approvalRegistry = ApprovalRegistry()
    // Always-allow / allow-this-session state, shared with the embedded server so
    // the daemon's /approval path and this in-process UI agree (ADR 0010).
    private let allowStore = VibeBuddyAllowStore()
    private let sessionAllow = SessionAllowList()
    private let approvalContext = ApprovalContextStore()
    // Live Activity push tokens + the last content we pushed, so we only push on change.
    private let activityTokens = ActivityTokens()
    private var lastActivityKey: String?
    private let notifier = UserNotificationsNotifier()
    private let notificationCoordinator: NotificationCoordinator
    // Phone push: the same SoundPolicy engine, run from the Mac's perspective of
    // a backgrounded phone, so the phone hears the full pack (not just needs-you).
    private let pusher: APNsPusher? = APNsConfig.load().flatMap { try? APNsPusher(config: $0) }
    private let deviceTokens = DeviceTokens()
    private let phonePolicy = SoundPolicy()
    private let budgetMonitor = BudgetMonitor()
    private let codexUsageCollector: CodexUsageCollector
    private var codexUsageAlertMonitor = CodexUsageAlertMonitor()
    /// The voice companion (tap the buddy to talk). Lazy so `self` is fully built.
    lazy var voiceChat = VoiceChat(
        contextProvider: { [weak self] in
            guard let self else { return [] }
            return BuddyScope.included(from: self.sessions, selectedIDs: self.buddySessionIDs)
        },
        actionHandler: { [weak self] action in self?.performVoiceAction(action) ?? "" })
    private var pollTask: Task<Void, Never>?
    private var codexUsageTask: Task<Void, Never>?
    private var codexUsageGeneration: UInt64 = 0
    private var glance: GlanceWindow?
    private static let pairedPhoneInfoKey = "pairedPhoneInfo"
    private static let legacyPairedPhoneKey = "pairedPhone"
    private static let codexUsageAlertedWindowsKey = "codexUsageAlertedWindows"

    init(runtimeEnabled: Bool = true) {
        port = ProcessInfo.processInfo.environment["VIBEBUDDY_PORT"].flatMap(Int.init) ?? 9876
        let savedIdleTimeout = UserDefaults.standard.object(forKey: "idleTimeoutHours") as? Double ?? 2
        idleTimeoutHours = savedIdleTimeout
        store = SessionStore(
            staleAfter: Self.staleInterval(forHours: savedIdleTimeout),
            diagnosticsHome: FileManager.default.homeDirectoryForCurrentUser,
            journalURL: ProcessInfo.processInfo.environment["VIBEBUDDY_JOURNAL_PATH"].map {
                URL(fileURLWithPath: $0)
            } ?? LifecycleJournalLocation.defaultURL()
        )
        // File-based store (owner-only): no Keychain ACL, so an ad-hoc rebuild
        // never re-prompts. Shared with vibebuddyd's default store.
        token = (try? TokenStore.defaultStore().loadOrCreate()) ?? Token.generate()
        let saved = UserDefaults.standard.double(forKey: "glanceScale")
        let base: CGFloat = saved > 0 ? saved : Self.defaultGlanceScale()
        // Snap to one of the 3 presets so the menu Picker selection always matches.
        glanceScale = [0.8, 1.0, 1.2].min(by: { abs($0 - base) < abs($1 - base) }) ?? 1.0
        showGlance = Self.loadBool("showGlance", default: true)
        openDashboardHotkey = Hotkey.loadOpenDashboard()
        toggleGlanceHotkey = Hotkey.loadToggleGlance()
        let usageEnabled = Self.loadBool("codexUsageCollectionEnabled", default: true)
        codexUsageCollectionEnabled = usageEnabled
        codexUsageCollector = CodexUsageCollector(
            provider: CodexAppServerUsageProvider(),
            cache: CodexUsageFileCache(),
            enabled: usageEnabled
        )
        codexUsageAlertMonitor = CodexUsageAlertMonitor(
            alertedWindowKeys: Self.loadCodexUsageAlertedWindows()
        )
        pairedPhone = Self.loadPairedPhone()
        notificationCoordinator = NotificationCoordinator(notifier: notifier)
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
            if codexUsageCollectionEnabled { startCodexUsageCollection() }
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
        }
    }

    /// A Bool default that treats an absent key as `default` (so first launch is on).
    private static func loadBool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.bool(forKey: key)
    }

    /// Quiet right now if the user toggled it, or the nightly window is active.
    static func effectiveQuiet(now: Date = Date()) -> Bool {
        NotificationQuietMode.isEffective(now: now)
    }

    var needsResponse: Int { sessions.lazy.filter { $0.status == .needsResponse }.count }
    var working: Int { sessions.lazy.filter { $0.status == .working }.count }
    var done: Int { sessions.lazy.filter { $0.status == .done }.count }
    /// The buddy's mood, shared with the menu-bar icon and the glance so the Mac
    /// reads the same as the phone.
    var buddyState: BuddyState { BuddyState.from(SessionGroups(sessions), now: Date()) }
    var macDisplayName: String { Self.localMacName() }
    var pairingAddress: String {
        guard let pairing else { return "Not ready" }
        return "\(pairing.host):\(pairing.port)"
    }

    private func startServer() {
        // pusher: nil — push is driven from startPolling via `phonePolicy` so the
        // phone gets the whole pack; the server only collects device tokens/prefs.
        let server = VibeBuddyServer(store: store, token: token, port: port,
                                     pusher: nil, deviceTokens: deviceTokens,
                                     activityTokens: activityTokens,
                                     codexRolloutMonitor: CodexRolloutMonitor(),
                                     approvalRegistry: approvalRegistry,
                                     allowStore: allowStore,
                                     sessionAllow: sessionAllow,
                                     approvalContext: approvalContext,
                                     onDevicePaired: { [weak self] device in
                                         Task { @MainActor in self?.recordPairedDevice(device) }
                                     })
        Task.detached(priority: .utility) {
            do { try await server.runService() }
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
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.store.snapshot(now: Date())
                self.sessions = snapshot.sessions
                self.observationDiagnostics = snapshot.observationDiagnostics ?? []
                self.lifecycleTimeline = await self.store.recentLifecycle()
                self.buddySessionIDs = BuddyScope.pruned(self.buddySessionIDs, toLive: snapshot.sessions)
                // Precise suppression: a finishing session stays silent when *its
                // own* terminal is frontmost, not just when VibeBuddy is.
                let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let focused = ForegroundTerminal.focusedSessionIDs(
                    among: snapshot.sessions, frontmostBundleID: frontmost)
                self.notificationCoordinator.observe(
                    snapshot.sessions,
                    appActive: NSApp.isActive,                 // user looking at VibeBuddy?
                    quietMode: Self.effectiveQuiet(),          // Focus mode (manual or nightly) → approvals only
                    focusedSessionIDs: focused)                // …or looking at the session's own terminal
                await self.pushToPhones(snapshot.sessions)
                await self.pushActivityUpdates(snapshot.sessions)
                await self.checkBudget(snapshot.sessions)
                try? await Task.sleep(for: .seconds(2))
            }
        }
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

    /// Start the independent account-usage loop. It has its own cadence,
    /// timeout/cache/backoff policy and never participates in the 2-second
    /// session snapshot poll above.
    private func startCodexUsageCollection() {
        codexUsageGeneration &+= 1
        let generation = codexUsageGeneration
        let previousTask = codexUsageTask
        previousTask?.cancel()
        codexUsageTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled,
                  let self,
                  self.codexUsageGeneration == generation,
                  self.codexUsageCollectionEnabled else { return }
            let initial = await self.codexUsageCollector.setEnabled(true)
            guard !Task.isCancelled,
                  self.codexUsageGeneration == generation,
                  self.codexUsageCollectionEnabled else { return }
            self.codexUsageState = initial

            while !Task.isCancelled,
                  self.codexUsageGeneration == generation,
                  self.codexUsageCollectionEnabled {
                let state = await self.codexUsageCollector.refresh()
                guard !Task.isCancelled,
                      self.codexUsageGeneration == generation,
                      self.codexUsageCollectionEnabled else { return }
                self.codexUsageState = state
                self.checkCodexUsageAlert(state)

                let delay = max(1, state.nextRefreshAt?.timeIntervalSinceNow ?? 60)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    func setCodexUsageCollectionEnabled(_ enabled: Bool) {
        guard enabled != codexUsageCollectionEnabled else { return }
        codexUsageCollectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "codexUsageCollectionEnabled")
        if enabled {
            startCodexUsageCollection()
        } else {
            codexUsageGeneration &+= 1
            let generation = codexUsageGeneration
            let previousTask = codexUsageTask
            previousTask?.cancel()
            codexUsageState = .disabled
            codexUsageTask = Task { [weak self] in
                await previousTask?.value
                guard !Task.isCancelled,
                      let self,
                      self.codexUsageGeneration == generation,
                      !self.codexUsageCollectionEnabled else { return }
                _ = await codexUsageCollector.setEnabled(false)
                guard !Task.isCancelled,
                      self.codexUsageGeneration == generation,
                      !self.codexUsageCollectionEnabled else { return }
                self.codexUsageState = .disabled
            }
        }
    }

    private func checkCodexUsageAlert(_ state: CodexUsageState) {
        let defaults = UserDefaults.standard
        let threshold = defaults.object(forKey: "codexUsageAlertThreshold") == nil
            ? 90
            : defaults.integer(forKey: "codexUsageAlertThreshold")
        let windows = codexUsageAlertMonitor.newlyCrossed(
            in: state,
            thresholdPercent: threshold,
            notificationsSuppressed: Self.effectiveQuiet()
        )
        Self.saveCodexUsageAlertedWindows(codexUsageAlertMonitor.alertedWindowKeys)
        for window in windows {
            notifier.notifyCodexUsage(window: window, threshold: threshold)
        }
    }

    private static func loadCodexUsageAlertedWindows() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: codexUsageAlertedWindowsKey),
              let keys = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return keys
    }

    private static func saveCodexUsageAlertedWindows(_ keys: Set<String>) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        UserDefaults.standard.set(data, forKey: codexUsageAlertedWindowsKey)
    }

    /// Push a Live Activity content-state update to registered phones, but only when
    /// the displayed counts/top session actually change (dynamic-island/02). No-op
    /// without an APNs key or any registered activity token.
    private func pushActivityUpdates(_ sessions: [AgentSession]) async {
        guard let pusher else { return }
        let tokens = await activityTokens.all()
        guard !tokens.isEmpty else { return }
        let groups = SessionGroups(sessions)
        let nr = groups.needsResponse.count, w = groups.working.count, d = groups.done.count
        let topProject = groups.needsResponse.first?.project
        let topSession = groups.focusSessionId
        let key = "\(nr)|\(w)|\(d)|\(topProject ?? "")|\(topSession ?? "")"
        guard key != lastActivityKey else { return }
        lastActivityKey = key
        for t in tokens {
            await pusher.sendActivityUpdate(needsResponse: nr, working: w, done: d,
                topProject: topProject, topSessionId: topSession, to: t)
        }
    }

    /// Push the full sound pack to paired phones, each device respecting its own
    /// prefs. `appActive: false` = the phone's backgrounded view; when the phone
    /// is actually foreground it suppresses the remote push (see willPresent).
    private func pushToPhones(_ sessions: [AgentSession]) async {
        guard let pusher else { return }
        let alerts = phonePolicy.evaluate(SoundPolicyInput(
            sessions: sessions, now: Date(), appActive: false, quietMode: false))
        guard !alerts.isEmpty else { return }
        let devices = await deviceTokens.devices()
        for alert in alerts {
            let (title, body) = Self.pushCopy(for: alert)
            for device in devices {
                guard let deviceToken = device.token else { continue }
                if device.quietMode == true && !alert.sound.survivesQuietMode { continue }  // night: approvals only
                let sound = device.playSound != false ? alert.sound.fileName : ""           // mute → silent banner
                await pusher.send(title: title, body: body, to: deviceToken, sound: sound)
            }
        }
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
            switch choice {
            case .alwaysAllow:
                if let ctx = await approvalContext.take(id: approvalId), let rule = ctx.rule {
                    await allowStore.add(rule)
                }
                await approvalRegistry.resolve(id: approvalId, with: .allow)
            case .allowSession:
                if let ctx = await approvalContext.take(id: approvalId) {
                    await sessionAllow.add(ctx.sessionID)
                }
                await approvalRegistry.resolve(id: approvalId, with: .allow)
            case .allow:
                _ = await approvalContext.take(id: approvalId)
                await approvalRegistry.resolve(id: approvalId, with: .allow)
            case .deny:
                _ = await approvalContext.take(id: approvalId)
                await approvalRegistry.resolve(id: approvalId, with: .deny)
            }
        }
    }

    /// Back-compat for voice + existing callers.
    func decide(_ approvalId: String, approve: Bool) { decide(approvalId, approve ? .allow : .deny) }

    func jump(_ session: AgentSession) {
        guard let ref = session.terminalRef else { return }
        TerminalJumper.jump(ref)
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
            guard let s = match(project), let ref = s.terminalRef else { return "No matching session, or it has no terminal." }
            TerminalInjector.inject(text, into: ref); return "Replied to \(s.project)."
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
        codexUsageTask?.cancel()
    }
}
