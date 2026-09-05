import Foundation
import NIOCore
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import VibeBuddyKit

/// The Mac-side HTTP server: localhost hook intake + token-gated LAN snapshot.
/// WebSocket push (`/ws`) is added later (needed by the iOS app in Phase D).
public struct VibeBuddyServer: Sendable {
    public let store: SessionStore
    public let token: String
    public let host: String
    public let port: Int
    public let pusher: APNsPusher?
    public let deviceTokens: DeviceTokens
    /// Live Activity push tokens registered by phones (dynamic-island/02).
    public let activityTokens: ActivityTokens
    /// Optional local Codex Desktop progress source. Production entry points
    /// inject it; route tests leave it nil so they never consume host state.
    public let codexRolloutMonitor: CodexRolloutMonitor?
    /// The Codex app-server daemon connection (ADR-0011). Optional so the
    /// tests and hosts that only exercise routes need not open a socket.
    public let codexAppServerMonitor: CodexAppServerMonitor?
    /// Live account usage published by `/statusline` (Claude) and the Codex
    /// monitor; the Mac app's usage coordinator consumes it.
    public let usageFeed: AccountUsageLiveFeed?
    public let approvalRegistry: ApprovalRegistry
    /// The native allow/deny rules for one agent — the sources differ per CLI
    /// (Grok also reads its own `config.toml`), so the lookup is agent-keyed.
    public let rules: @Sendable (AgentKind) -> PermissionRules
    /// vibebuddy's own "always allow" store, overlaid on the native rules (ADR 0010).
    public let allowStore: VibeBuddyAllowStore
    /// Sessions the user chose to allow wholesale for their lifetime (in-memory).
    public let sessionAllow: SessionAllowList
    /// Per-approval context so `/decision` can persist an always-allow rule.
    public let approvalContext: ApprovalContextStore
    /// Questions an agent is waiting on (Claude's AskUserQuestion hook, Codex's
    /// request_user_input), answered through `/answer` or the Mac card.
    public let questionRegistry: QuestionRegistry
    /// Whether the person is at the Mac for this session (`PresencePolicy`,
    /// evaluated by the host app). Present → the agent's own prompt takes the
    /// answer and the phone gets a read-only card. The default never claims
    /// presence, so a headless daemon always holds for the phone.
    public let presence: @Sendable (String) async -> Bool
    public let approvalTimeout: Duration
    public let approvalID: @Sendable () -> String
    public let onJump: @Sendable (TerminalRef) async -> JumpOutcome
    /// The other kind of jump: a Codex Desktop session has no terminal, only the
    /// thread it *is*, opened in ChatGPT.app.
    public let onJumpToDesktopThread: @Sendable (String) async -> JumpOutcome
    public let onAnswer: @Sendable (TerminalRef, String) -> Void
    public let onDevicePaired: @Sendable (DeviceRegistrationPayload) -> Void
    /// Claude background sessions on this Mac, for jumps into them.
    public let backgroundSessions: @Sendable () -> [ClaudeBackgroundSession]
    /// Open a terminal running `claude attach <job id>` in the preferred program.
    public let onAttach: @Sendable (String, String?) async -> JumpOutcome
    /// Start a new task. Nil means: Codex through the app-server monitor, every
    /// other agent unsupported until it has a launcher of its own.
    public let onDispatch: (@Sendable (DispatchRequest) async -> DispatchOutcome)?
    /// Starts Claude Code background sessions for dispatches.
    public let claudeLauncher: ClaudeBackgroundLauncher
    /// Deliver one completion reminder for a followed, unread, done session.
    /// Returns whether any channel actually took it, so a reminder every
    /// channel suppressed does not spend one of the session's slots. The
    /// default pushes to paired phones over APNs (the headless daemon); the
    /// menu-bar app supplies its own that also posts a local banner.
    public let onCompletionReminder: (@Sendable (AgentSession) async -> Bool)?

    public init(store: SessionStore, token: String, host: String = "0.0.0.0",
                port: Int = 9876, pusher: APNsPusher? = nil,
                deviceTokens: DeviceTokens = DeviceTokens(),
                activityTokens: ActivityTokens = ActivityTokens(),
                codexRolloutMonitor: CodexRolloutMonitor? = nil,
                codexAppServerMonitor: CodexAppServerMonitor? = nil,
                usageFeed: AccountUsageLiveFeed? = nil,
                approvalRegistry: ApprovalRegistry = ApprovalRegistry(),
                rules: @escaping @Sendable (AgentKind) -> PermissionRules = { PermissionRules.load(for: $0) },
                allowStore: VibeBuddyAllowStore = VibeBuddyAllowStore(),
                sessionAllow: SessionAllowList = SessionAllowList(),
                approvalContext: ApprovalContextStore = ApprovalContextStore(),
                questionRegistry: QuestionRegistry = QuestionRegistry(),
                presence: @escaping @Sendable (String) async -> Bool = { _ in false },
                approvalTimeout: Duration = .seconds(25),
                approvalID: @escaping @Sendable () -> String = { UUID().uuidString },
                onJump: @escaping @Sendable (TerminalRef) async -> JumpOutcome = { await TerminalJumper.jump($0) },
                onJumpToDesktopThread: @escaping @Sendable (String) async -> JumpOutcome = { await CodexDesktopJumper.jump(threadID: $0) },
                onAnswer: @escaping @Sendable (TerminalRef, String) -> Void = { ref, answer in TerminalInjector.inject(answer, into: ref) },
                onDevicePaired: @escaping @Sendable (DeviceRegistrationPayload) -> Void = { _ in },
                backgroundSessions: @escaping @Sendable () -> [ClaudeBackgroundSession] = { ClaudeBackgroundSessions.load() },
                onAttach: @escaping @Sendable (String, String?) async -> JumpOutcome = { id, term in
                    await TerminalLauncher.attach(claudeJobID: id, preferring: term)
                },
                onDispatch: (@Sendable (DispatchRequest) async -> DispatchOutcome)? = nil,
                claudeLauncher: ClaudeBackgroundLauncher = ClaudeBackgroundLauncher(),
                onCompletionReminder: (@Sendable (AgentSession) async -> Bool)? = nil) {
        self.store = store
        self.token = token
        self.host = host
        self.port = port
        self.pusher = pusher
        self.deviceTokens = deviceTokens
        self.activityTokens = activityTokens
        self.codexRolloutMonitor = codexRolloutMonitor
        self.codexAppServerMonitor = codexAppServerMonitor
        self.usageFeed = usageFeed
        self.approvalRegistry = approvalRegistry
        self.rules = rules
        self.allowStore = allowStore
        self.sessionAllow = sessionAllow
        self.approvalContext = approvalContext
        self.approvalTimeout = approvalTimeout
        self.approvalID = approvalID
        self.questionRegistry = questionRegistry
        self.presence = presence
        self.onJump = onJump
        self.onJumpToDesktopThread = onJumpToDesktopThread
        self.onAnswer = onAnswer
        self.backgroundSessions = backgroundSessions
        self.onAttach = onAttach
        self.onDispatch = onDispatch
        self.claudeLauncher = claudeLauncher
        self.onDevicePaired = onDevicePaired
        self.onCompletionReminder = onCompletionReminder
    }

    /// Run the HTTP service and its Codex rollout source under one lifetime.
    /// Returning or throwing from the server always cancels and joins the
    /// monitor so no watcher descriptors, debounce tasks, or store sink survive.
    /// Which agents `/dispatch` can start right now — what the "New task"
    /// entry offers, and hides itself behind when empty.
    public func dispatchAgents() async -> [AgentKind] {
        var agents: [AgentKind] = []
        if await claudeLauncher.isSupported() { agents.append(.claudeCode) }
        if let monitor = codexAppServerMonitor, await monitor.diagnostics().connected { agents.append(.codex) }
        return agents
    }

    public func runService() async throws {
        let monitorTask = codexRolloutMonitor.map { monitor in
            Task { await monitor.run(store: store) }
        }
        let appServerTask = codexAppServerMonitor.map { monitor in
            Task { await monitor.run(store: store) }
        }
        defer {
            monitorTask?.cancel()
            appServerTask?.cancel()
        }
        do {
            try await buildApplication().runService()
        } catch {
            monitorTask?.cancel()
            appServerTask?.cancel()
            await monitorTask?.value
            await appServerTask?.value
            throw error
        }
        monitorTask?.cancel()
        appServerTask?.cancel()
        await monitorTask?.value
        await appServerTask?.value
    }

    public func buildApplication() -> some ApplicationProtocol {
        let store = self.store
        let token = self.token

        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        // The upgrade handshake is not a router route, so it can't sit in the
        // authenticated group — it runs the same header-only check directly.
        let wsAuth = BearerAuth(token: token, allowsQueryToken: false)
        wsRouter.ws("/ws") { request, _ in
            wsAuth.authorizes(request) ? .upgrade() : .dontUpgrade
        } onUpgrade: { inbound, outbound, _ in
            // Push the current snapshot, then every change, until the client closes.
            let subscription = await store.subscribe()
            let writer = Task {
                for await snapshot in subscription.stream {
                    let event = ServerEvent.snapshot(snapshot)
                    guard let data = try? JSONEncoder().encode(event) else { continue }
                    do {
                        try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
                    } catch { break }
                }
            }
            do { for try await _ in inbound {} } catch {}
            writer.cancel()
            await store.unsubscribe(subscription.id)
        }

        // Self-healing: every minute, drop sessions that ended or went stale
        // without a terminal hook (force-kill, dropped POST, daemon restart),
        // so the dashboard's "Needs response" count stays accurate.
        let sweepStore = self.store
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await sweepStore.sweep(now: Date())
            }
        }

        // Followed completions (effective attention `followed`, set by hand or
        // inferred): propose reminders on a schedule, deliver through
        // the app's handler or the daemon's own APNs push, and count only what
        // was actually handed to a channel.
        let reminderServer = self
        Task {
            var schedule = CompletionReminderSchedule()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await reminderServer.remindFollowedCompletions(&schedule, now: Date())
            }
        }

        // APNs: push a "needs you" alert to registered devices on each fresh
        // needsResponse transition. Off until a pusher is configured.
        if let pusher = self.pusher {
            let deviceTokens = self.deviceTokens
            Task {
                await store.setNeedsResponseHandler { session in
                    let title: String
                    let body: String
                    let sound: NotificationSound
                    if let approval = session.pendingApproval {
                        title = "\(session.project) needs approval"
                        body = approval.commandPreview
                        sound = .needsApproval
                    } else {
                        title = "\(session.project) needs you"
                        body = session.summary ?? "Waiting for your response"
                        sound = session.waitKind == .permission ? .needsApproval : .needsAnswer
                    }
                    // Same two axes as the menu-bar app's push: the session's
                    // attention level says how loud (a muted session's wait is a
                    // silent banner), each phone's switches say whether at all,
                    // and a phone in Quiet mode reads the cue through `muted`.
                    let level = DeliveryMatrix.level(for: sound, attention: session.effectiveAttention)
                    guard level.interrupts else { return }
                    for device in await deviceTokens.devices() {
                        guard let deviceToken = device.token,
                              (device.categories ?? .default).isEnabled(sound) else { continue }
                        var deviceLevel = level
                        if device.quietMode == true {
                            deviceLevel = min(deviceLevel, DeliveryMatrix.level(for: sound, attention: .muted))
                        }
                        guard deviceLevel.interrupts else { continue }
                        let soundFile = deviceLevel.makesSound && device.playSound != false ? sound.fileName : ""
                        let result = await pusher.send(title: title, body: body, to: deviceToken,
                                                       sound: soundFile,
                                                       sessionID: session.id, soundCategory: sound.rawValue)
                        await deviceTokens.applySendResult(result, token: deviceToken)
                    }
                }
            }
        }

        return Application(
            router: router(),
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(address: .hostname(host, port: port))
        )
    }

    /// Built separately so in-process tests can exercise routes via `app.test(.router)`.
    /// One reminder pass: ask the schedule what is owed, deliver each, and spend a
    /// slot only for a session at least one channel took.
    public func remindFollowedCompletions(_ schedule: inout CompletionReminderSchedule,
                                          now: Date) async {
        let sessions = await store.snapshot(now: now).sessions
        for session in schedule.due(sessions, now: now) {
            let delivered: Bool
            if let onCompletionReminder {
                delivered = await onCompletionReminder(session)
            } else {
                delivered = await pushCompletionReminder(session, now: now)
            }
            if delivered { schedule.markReminded(session.id, now: now) }
        }
    }

    /// The daemon's own channel: the `agentDone` cue again, to every phone whose
    /// switches allow it and that is not in Quiet mode. Same collapse id as the
    /// completion, so the banner is replaced rather than stacked.
    private func pushCompletionReminder(_ session: AgentSession, now: Date) async -> Bool {
        guard let pusher else { return false }
        let sound = NotificationSound.agentDone
        var attempted = false
        for device in await deviceTokens.devices() {
            guard let token = device.token,
                  (device.categories ?? .default).isEnabled(sound),
                  device.quietMode != true else { continue }
            attempted = true
            let result = await pusher.send(
                title: "\(session.project) finished",
                body: session.summary ?? "Task complete",
                to: token, sound: device.playSound != false ? sound.fileName : "",
                now: now, sessionID: session.id, soundCategory: sound.rawValue)
            await deviceTokens.applySendResult(result, token: token)
        }
        return attempted
    }

    public func router() -> Router<BasicRequestContext> {
        let router = Router()
        let store = self.store
        let token = self.token
        let deviceTokens = self.deviceTokens
        let onDevicePaired = self.onDevicePaired

        // Liveness — unauthenticated, used by the app's connection screen. The
        // only route registered straight on the router: everything else below
        // goes through one of the two authenticated groups.
        router.get("health") { _, _ -> String in "ok" }

        // Auth lives here and nowhere else. `authed` is the phone/LAN surface:
        // `Authorization: Bearer <token>` only. `hookAuthed` is the CLI-hook
        // surface (`/hook`, `/approval`, `/terminal`), which also accepts the
        // token as a `?token=` query param for native-http hooks that cannot set
        // a header (e.g. Qwen). daemon-security/01, ADR-0009.
        let authed = router.group()
            .add(middleware: BearerAuthMiddleware(auth: BearerAuth(token: token, allowsQueryToken: false)))
        let hookAuthed = router.group()
            .add(middleware: BearerAuthMiddleware(auth: BearerAuth(token: token, allowsQueryToken: true)))

        // Register an iOS device. Token-gated. Body is `{"token","name","model",
        // "systemVersion"}` (or a raw APNs token string). `token` -> APNs
        // registry; the other fields feed the paired-device display.
        authed.post("device") { request, _ -> HTTPResponse.Status in
            let buffer = try await request.body.collect(upTo: 4096)
            let body = String(decoding: Data(buffer: buffer), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("{") {
                let payload = (try? JSONDecoder().decode(DeviceRegistrationPayload.self,
                                                          from: Data(body.utf8)))
                    ?? DeviceRegistrationPayload()
                await deviceTokens.register(payload)   // token + sound prefs (playSound/quietMode)
                if payload.hasVisibleDeviceInfo { onDevicePaired(payload) }
            } else if !body.isEmpty {
                await deviceTokens.add(body)
                onDevicePaired(DeviceRegistrationPayload(token: body))
            }
            return .ok
        }

        // Live Activity push-token registration (dynamic-island/02) — token-gated,
        // sent by the phone when its activity produces / rotates a push token.
        let activityTokens = self.activityTokens
        authed.post("activity") { request, _ -> HTTPResponse.Status in
            let buffer = try await request.body.collect(upTo: 4096)
            guard let o = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let t = o["token"] as? String, !t.isEmpty else { return .ok }
            await activityTokens.register(t)
            return .ok
        }

        // Hook intake — bearer-token gated (the forwarder reads the token file and
        // sends it). The listener is LAN-bound for the phone, so an open /hook let
        // any local process — or a browser hitting the port via DNS rebinding —
        // spoof sessions; the token closes that (daemon-security/01, ADR-0009).
        // `?agent=<source>` tags which CLI it came from (claude/codex/qwen/kimi/
        // antigravity/grok/opencode/copilot); Claude Code is the default.
        hookAuthed.post("hook") { request, _ -> HTTPResponse.Status in
            let agent = AgentKind.fromSource(request.uri.queryParameters["agent"].map(String.init))
            let buffer = try await request.body.collect(upTo: 1 << 20) // 1 MB cap
            await store.ingest(Data(buffer: buffer), agent: agent, receivedAt: Date())
            return .ok
        }

        // Full snapshot — bearer-token gated.
        authed.get("snapshot") { request, _ -> Response in
            await store.applyBackgroundSessions(backgroundSessions())
            var snapshot = await store.snapshot(now: Date())
            snapshot.dispatchAgents = await dispatchAgents()
            let data = try JSONEncoder().encode(snapshot)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(bytes: data))
            )
        }

        // Privacy-minimized local diagnostics. Token-gated because stable
        // session IDs remain local user metadata.
        authed.get("lifecycle") { _, _ -> Response in
            let data = try JSONEncoder().encode(await store.recentLifecycle())
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(bytes: data))
            )
        }

        authed.delete("lifecycle") { _, _ -> HTTPResponse.Status in
            guard await store.clearLifecycleJournal() else {
                throw HTTPError(.internalServerError)
            }
            return .ok
        }

        // Explicit read acknowledgement. Merely receiving/rendering a snapshot
        // never clears unread state; a client calls this only after selection or open.
        authed.post("acknowledge") { request, _ -> HTTPResponse.Status in
            let buffer = try await request.body.collect(upTo: 4096)
            guard let object = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let sessionID = object["sessionId"] as? String,
                  !sessionID.isEmpty else { throw HTTPError(.badRequest) }
            await store.acknowledgeCompletion(sessionID: sessionID)
            return .ok
        }

        // Blocking approval intake — bearer-token gated (the approval hook reads
        // the token file and sends it). Parse the gate payload, run the
        // permission matcher, and either decide immediately (allow/deny) or hold
        // until the phone responds via `/decision` or the timeout fires.
        // `?agent=<source>` selects the envelope shape to decode; the event the
        // payload arrived on (`PermissionRequest` — only when the agent would
        // prompt — or a `PreToolUse` gate on every call) selects the decision
        // contract to answer in. No parameter means Claude Code, as before.
        let registry = self.approvalRegistry
        let rules = self.rules
        let allowStore = self.allowStore
        let sessionAllow = self.sessionAllow
        let approvalContext = self.approvalContext
        let timeout = self.approvalTimeout
        let makeID = self.approvalID
        hookAuthed.post("approval") { request, _ -> Response in
            let agent = AgentKind.fromSource(request.uri.queryParameters["agent"].map(String.init))
            let buffer = try await request.body.collect(upTo: 1 << 20)
            let data = Data(buffer: buffer)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let call = ApprovalPayload.decode(obj, agent: agent)
            let tool = call.tool
            let input = call.input
            let sessionID = call.sessionID
            let r = rules(agent)
            // A PreToolUse gate doubles as the tool signal — ingesting it moves
            // the session to `working`. A PermissionRequest is a *wait* signal:
            // ingesting it would mark the session `needsResponse` and push a
            // "needs you" alert even when a rule decides at once, so it is
            // ingested only when the wait is real (the `.ask` arm) and the
            // session is not yet known.
            if call.event == .preToolUse {
                await store.ingest(data, agent: agent, receivedAt: Date())
            }
            // Claude asking the user something is not a permission: hold the
            // hook while the phone answers, and reply with the answers in the
            // tool's own `updatedInput` contract. Silence (no answer in time)
            // prints nothing, so Claude shows its own question UI; the card
            // stays, and a later answer types into the terminal instead.
            if agent == .claudeCode, call.event == .preToolUse, tool == "AskUserQuestion" {
                guard let question = AskUserQuestionInput.pendingQuestion(from: input, id: makeID()) else {
                    return Response(status: .ok)
                }
                if await presence(sessionID) {
                    // At the keyboard: Claude's own question UI takes the answer
                    // now; the phone sees what is being asked, read-only.
                    await store.beginQuestion(sessionID: sessionID, question.readOnly, at: Date())
                    return Response(status: .ok)
                }
                await store.beginQuestion(sessionID: sessionID, question, at: Date())
                guard let answers = await questionRegistry.wait(sessionID: sessionID, timeout: timeout) else {
                    return Response(status: .ok)
                }
                await store.endQuestion(sessionID: sessionID, at: Date())
                let updated = AskUserQuestionInput.updatedInput(original: input, question: question, answers: answers)
                return Self.questionResponse(updatedInput: updated)
            }
            // While the Codex app-server daemon reports this session, its own
            // approval request reaches the phone through the monitor; the hook
            // gate steps aside so one request never raises two cards. Empty
            // means "no opinion": the CLI shows its own prompt as usual.
            if agent == .codex, call.event == .permissionRequest,
               await store.hasFreshAppServerEvidence(sessionID: sessionID, now: Date()) {
                return Response(status: .ok)
            }
            // Native deny always wins, over every vibebuddy overlay (ADR 0010).
            if PermissionMatcher.decide(tool: tool, input: input, allow: [], deny: r.deny) == .deny {
                return Self.permissionResponse("deny", agent: agent, event: call.event)
            }
            // A PreToolUse gate fires for every call, so answer the ones nobody
            // needs to decide — a bypass-mode call, or a tool that only reads —
            // before they become a card or a banner. A PermissionRequest only
            // fires when the agent would ask, so it is never short-circuited.
            if call.event == .preToolUse,
               ApprovalShortCircuit.autoAllows(tool: tool, permissionMode: call.permissionMode) {
                return Self.permissionResponse("allow", agent: agent, event: call.event)
            }
            // vibebuddy overlay: a session-wide allow, or an exact always-allow rule the
            // user set — both bypass the matcher's pattern heuristics since the user
            // explicitly approved this precise tool use.
            let sessionAllowed = await sessionAllow.contains(sessionID)
            let storeRules = await allowStore.all()   // [String] is Sendable; match locally
            let storeAllowed = storeRules.contains { AllowRule.matchesExactly($0, tool: tool, input: input) }
            if sessionAllowed || storeAllowed {
                return Self.permissionResponse("allow", agent: agent, event: call.event)
            }
            // Otherwise the native allow/ask matching (composition-guarded) — but
            // only for a PreToolUse gate, which fires before the agent's own
            // permission check. A PermissionRequest means the agent has already
            // evaluated its rules and still decided to ask (an ask rule, an
            // uncertain auto-mode classifier); re-running our copy of its allow
            // list here could only override that decision, so it is a real wait.
            // Codex has no rule vocabulary of its own, so for it the user's path
            // and command rules are only ever applied here; that stays.
            let native: PermissionDecision = (agent == .claudeCode && call.event == .permissionRequest)
                ? .ask
                : PermissionMatcher.decide(tool: tool, input: input, allow: r.allow, deny: r.deny)
            switch native {
            case .allow: return Self.permissionResponse("allow", agent: agent, event: call.event)
            case .deny:  return Self.permissionResponse("deny", agent: agent, event: call.event)
            case .ask:
                if call.event == .permissionRequest, !(await store.hasSession(sessionID)) {
                    // Only the gate is installed (no status forwarders yet): open
                    // the session from this payload so the card has a row to land
                    // on. `beginApproval` below announces the wait — once.
                    await store.ingest(data, agent: agent, receivedAt: Date(), announcesWait: false)
                }
                let id = makeID()
                let d = ApprovalDetails.from(tool: tool, input: input)
                if call.event == .permissionRequest, await presence(sessionID) {
                    // At the keyboard: the agent's own dialog takes the answer,
                    // with no round trip; the phone still sees the request.
                    await store.beginApproval(sessionID: sessionID,
                        PendingApproval(id: id, tool: tool,
                                        commandPreview: d.commandPreview.isEmpty ? tool : d.commandPreview,
                                        command: d.command, filePath: d.filePath,
                                        oldText: d.oldText, newText: d.newText,
                                        permissionMode: call.permissionMode,
                                        suggestedRule: PermissionSuggestion.describe(call.permissionSuggestions),
                                        answerable: false), at: Date())
                    return Response(status: .ok)
                }
                // Record what an "always allow" / "allow this session" would act
                // on *before* the pending card is broadcast — a decision can only
                // follow the card, so the context is always there when it lands.
                // Claude's own allow-rule proposals ride along: "Always allow"
                // echoes them back as `updatedPermissions` so Claude persists
                // the rule itself, and the card shows the very text the terminal
                // dialog would (ADR 0010, amended).
                let suggestions = call.permissionSuggestions
                await approvalContext.set(id: id, sessionID: sessionID,
                                          rule: AllowRule.forApproval(tool: tool, input: input),
                                          nativeSuggestions: PermissionSuggestion.encode(suggestions))
                await store.beginApproval(sessionID: sessionID,
                    PendingApproval(id: id, tool: tool,
                                    commandPreview: d.commandPreview.isEmpty ? tool : d.commandPreview,
                                    command: d.command, filePath: d.filePath,
                                    oldText: d.oldText, newText: d.newText,
                                    permissionMode: call.permissionMode,
                                    suggestedRule: PermissionSuggestion.describe(suggestions)), at: Date())
                let outcome = await registry.wait(id: id, timeout: timeout)
                await store.endApproval(sessionID: sessionID, at: Date())
                switch outcome {
                case .allow:
                    let grant = await approvalContext.takeGrant(id: id)
                    return Self.permissionResponse("allow", agent: agent, event: call.event,
                                                   updatedPermissions: grant)
                case .deny:  return Self.permissionResponse("deny", agent: agent, event: call.event)
                case .pass:  return Response(status: .ok)
                }
            }
        }

        // Resolve a held approval — bearer-token gated (the phone sends this).
        authed.post("decision") { request, _ -> HTTPResponse.Status in
            let buffer = try await request.body.collect(upTo: 4096)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let id = obj["approvalId"] as? String,
                  let decision = obj["decision"] as? String
            else { throw HTTPError(.badRequest) }
            // "allow"/"deny" resolve this one prompt; "alwaysAllow" also persists a rule;
            // "allowSession" also allows the rest of this session (ADR 0010). Unknown → deny.
            let ctx = await approvalContext.take(id: id)
            switch decision {
            case "alwaysAllow":
                if let ctx {
                    if let native = ctx.nativeSuggestions {
                        // The agent proposed the rule: hand it back on the held
                        // reply and let the agent persist it. Nothing is written
                        // to the vibebuddy store, so the two never diverge.
                        await approvalContext.grant(id: id, updatedPermissions: native)
                    } else if let rule = ctx.rule {
                        await allowStore.add(rule)
                    }
                }
                await registry.resolve(id: id, with: .allow)
            case "allowSession":
                if let ctx { await sessionAllow.add(ctx.sessionID) }
                await registry.resolve(id: id, with: .allow)
            case "allow":
                await registry.resolve(id: id, with: .allow)
            default:
                await registry.resolve(id: id, with: .deny)
            }
            // Deciding is driving: the session stays followed for a while.
            if let ctx { await store.recordInteraction(sessionID: ctx.sessionID) }
            return .ok
        }

        // The user's attention choice for one session — bearer-token gated (the
        // phone and the Mac UI both send this). `attention: null` returns the
        // session to the automatic default.
        authed.post("attention") { request, _ -> HTTPResponse.Status in
            let buffer = try await request.body.collect(upTo: 4096)
            guard let o = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let sid = o["sessionId"] as? String else { throw HTTPError(.badRequest) }
            let level: SessionAttention?
            switch o["attention"] {
            case nil, is NSNull:
                level = nil
            case let raw as String:
                guard let parsed = SessionAttention(rawValue: raw) else { throw HTTPError(.badRequest) }
                level = parsed
            default:
                throw HTTPError(.badRequest)
            }
            guard await store.setAttention(sessionID: sid, level) else { throw HTTPError(.notFound) }
            return .ok
        }

        // Claude's status line JSON, forwarded by hooks/vibebuddy-statusline.sh
        // on every event — bearer-token gated like the other CLI routes. It
        // fills fields on a known session and feeds the live quota; it never
        // creates a session or moves progress, so an unknown session id is
        // still a 200 (the forwarder is fail-open and never retries).
        let usageFeed = self.usageFeed
        hookAuthed.post("statusline") { request, _ -> HTTPResponse.Status in
            let buffer = try await request.body.collect(upTo: 256 * 1024)
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(buffer: buffer))) as? [String: Any],
                  let sample = StatusLineSample.decode(obj)
            else { throw HTTPError(.badRequest) }
            let now = Date()
            await store.applyStatusLine(sample, at: now)
            if let usageFeed, let snapshot = sample.usageSnapshot(fetchedAt: now) {
                await usageFeed.publish(snapshot)
            }
            return .ok
        }

        let onJump = self.onJump
        let onJumpToDesktopThread = self.onJumpToDesktopThread
        // Terminal-ref capture — bearer-token gated (the capture hook reads the
        // token file and sends it). Without it any local process could hijack a
        // session's terminal target. (daemon-security/01, ADR-0009.)
        hookAuthed.post("terminal") { request, _ -> HTTPResponse.Status in
            let buffer = try await request.body.collect(upTo: 64 * 1024)
            let body = Data(buffer: buffer)
            // `TerminalRef` is the wire shape, so the payload decodes straight
            // into it; only the session id is envelope.
            struct Envelope: Decodable {
                let sessionID: String
                enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
            }
            guard let sid = (try? JSONDecoder().decode(Envelope.self, from: body))?.sessionID,
                  !sid.isEmpty,
                  let ref = try? JSONDecoder().decode(TerminalRef.self, from: body)
            else { return .ok }
            // A ref with no exact target, no TERM_PROGRAM and no host bundle id
            // names nothing the jumper could act on. Accept the POST (the hook
            // must never see an error) but don't store it, so `/jump` answers
            // the truthful `.noTerminal` rather than `.unsupported`.
            guard ref.isActionable else { return .ok }
            await store.setTerminalRef(sessionID: sid, ref)
            return .ok
        }
        authed.post("jump") { request, _ -> Response in
            let buffer = try await request.body.collect(upTo: 4096)
            guard let o = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let sid = o["sessionId"] as? String else { throw HTTPError(.badRequest) }
            // Jumping is an explicit return to the task, even if this terminal
            // type cannot ultimately be focused.
            await store.acknowledgeCompletion(sessionID: sid)
            await store.recordInteraction(sessionID: sid)
            // Report what actually happened so the phone can give honest feedback.
            // The jumper answers after it has run, so `focused` means the exact
            // pane/tab really came forward — not merely that a command existed.
            let outcome: JumpOutcome
            if let ref = await store.terminalRef(for: sid) {
                outcome = await onJump(ref)
            } else if let thread = await store.desktopThreadID(for: sid) {
                // Codex Desktop runs no hook, so this session will never have a
                // ref; its thread id is the target instead.
                outcome = await onJumpToDesktopThread(thread)
            } else if let job = backgroundSessions().first(where: { $0.sessionID == sid }) {
                // A Claude background session has no window: open one attached
                // to it, in the terminal the user's other sessions run in.
                outcome = await onAttach(job.id, await store.preferredTerminalProgram())
            } else {
                outcome = .noTerminal
            }
            let data = try JSONEncoder().encode(["outcome": outcome.rawValue])
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }

        // Start a new task from the phone — bearer-token gated. The directory
        // must be one a session already ran in (the snapshot's
        // `recentDirectories`), so a phone can never point an agent at an
        // arbitrary path. 200 `{sessionId}`, 400 refused, 501 unsupported
        // agent, 503 launcher unavailable.
        let dispatcher = self.onDispatch
        let dispatchMonitor = self.codexAppServerMonitor
        let claudeLauncher = self.claudeLauncher
        authed.post("dispatch") { request, _ -> Response in
            let buffer = try await request.body.collect(upTo: 64 * 1024)
            guard let o = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let cwd = o["cwd"] as? String, let prompt = o["prompt"] as? String
            else { throw HTTPError(.badRequest) }
            let agent = (o["agent"] as? String).flatMap(AgentKind.init(rawValue:)) ?? AgentKind.fromSource(o["agent"] as? String)
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            func reply(_ status: HTTPResponse.Status, _ body: [String: String]) -> Response {
                let data = (try? JSONEncoder().encode(body)) ?? Data()
                return Response(status: status, headers: [.contentType: "application/json"],
                                body: .init(byteBuffer: ByteBuffer(bytes: data)))
            }
            guard !text.isEmpty else { return reply(.badRequest, ["error": "empty prompt"]) }
            guard await store.isKnownDirectory(cwd) else {
                return reply(.badRequest, ["error": "not a directory a session has run in"])
            }
            let req = DispatchRequest(agent: agent, cwd: cwd, prompt: text,
                                      name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            let outcome: DispatchOutcome
            if let dispatcher {
                outcome = await dispatcher(req)
            } else if agent == .codex, let dispatchMonitor {
                outcome = await dispatchMonitor.dispatch(req)
            } else if agent == .claudeCode {
                outcome = await claudeLauncher.dispatch(req)
            } else {
                outcome = .unsupported("vibebuddy cannot start \(agent.displayName) sessions yet")
            }
            switch outcome {
            case .started(let id): return reply(.ok, ["sessionId": id])
            case .rejected(let why): return reply(.badRequest, ["error": why])
            case .unsupported(let why): return reply(.notImplemented, ["error": why])
            case .unavailable(let why): return reply(.serviceUnavailable, ["error": why])
            }
        }

        // `{"sessionId", "answer"?: text, "answers"?: {questionId: [labels]}}`.
        // Structured answers reach a waiting agent through its own contract;
        // plain text (voice, older phone builds) maps onto the first question,
        // or is typed into the terminal when nothing is waiting. 202 says the
        // answer had nowhere to go.
        let monitor = self.codexAppServerMonitor
        let dispatch = AnswerDispatch(store: store, questions: questionRegistry, inject: self.onAnswer,
                                      steer: { sessionID, text, active in
                                          await monitor?.steer(threadID: sessionID, text: text, isActive: active) ?? false
                                      })
        authed.post("answer") { request, _ -> HTTPResponse.Status in
            let buffer = try await request.body.collect(upTo: 64 * 1024)
            guard let o = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let sid = o["sessionId"] as? String
            else { throw HTTPError(.badRequest) }
            let text = (o["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var answers: QuestionAnswers = [:]
            if let raw = o["answers"] as? [String: Any] {
                for (key, value) in raw {
                    if let list = value as? [String] { answers[key] = list }
                    else if let one = value as? String { answers[key] = [one] }
                }
            }
            guard !(text ?? "").isEmpty || !answers.isEmpty else { throw HTTPError(.badRequest) }
            let delivered = await dispatch.deliver(sessionID: sid, text: text, answers: answers.isEmpty ? nil : answers)
            // Answering counts as driving the session (automatic attention).
            if delivered { await store.recordInteraction(sessionID: sid) }
            return delivered ? .ok : .accepted
        }

        return router
    }

    /// A PreToolUse reply that answers `AskUserQuestion` on the user's behalf:
    /// allow, with the tool's input replaced by the questions plus `answers`.
    static func questionResponse(updatedInput: [String: Any]) -> Response {
        let body: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "Answered from vibebuddy",
            "updatedInput": updatedInput,
        ]]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return Response(status: .ok)
        }
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// The PreToolUse decision, in the shape the calling agent parses.
    ///
    /// Claude Code reads `hookSpecificOutput.permissionDecision`. Grok Build
    /// accepts that form too, but its own documented contract is the flat
    /// `{"decision":…,"reason":…}` — that is what we emit for it, so the wire is
    /// unambiguous when read from a Grok transcript. Either way a timeout still
    /// answers with an empty 200 body, which both CLIs read as "no opinion".
    static func permissionResponse(_ decision: String, agent: AgentKind = .claudeCode,
                                   event: ApprovalPayload.Event = .preToolUse,
                                   updatedPermissions: Data? = nil) -> Response {
        let json: String
        if agent == .grok {
            json = decision == "deny"
                ? #"{"decision":"deny","reason":"vibebuddy"}"#
                : #"{"decision":"\#(decision)"}"#
        } else if event == .permissionRequest {
            // Claude Code and Codex answer a `PermissionRequest` hook the same
            // way: `decision.behavior` is `allow`/`deny`, and a deny may carry a
            // message the model sees. Any other field fails closed on Codex's
            // side, so send nothing beyond the contract — except an allow that
            // carries the agent's own `updatedPermissions` back (Claude only:
            // the payload is the agent's serialized proposal, never composed here).
            if decision == "deny" {
                json = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from vibebuddy"}}}"#
            } else if let updatedPermissions, let entries = String(data: updatedPermissions, encoding: .utf8) {
                json = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":\#(entries)}}}"#
            } else {
                json = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            }
        } else {
            json = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"\#(decision)","permissionDecisionReason":"vibebuddy"}}"#
        }
        return Response(status: .ok,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: json)))
    }

}

/// The daemon's single bearer-token check.
///
/// Phone/LAN routes accept the token only as an `Authorization: Bearer <token>`
/// header. The CLI-hook routes (`/hook`, `/approval`, `/terminal`) additionally
/// accept it as a `?token=<token>` query param, for native-http hooks that can't
/// set a header (e.g. Qwen). daemon-security/01, ADR-0009.
struct BearerAuth: Sendable {
    let token: String
    let allowsQueryToken: Bool

    func authorizes(_ request: Request) -> Bool {
        // An empty configured token must never authorize anything (an empty
        // `Authorization: Bearer ` header or `?token=` would otherwise match it).
        // Fail closed rather than `precondition`: empty VIBEBUDDY_TOKEN still 401s.
        guard !token.isEmpty else { return false }
        if request.headers[.authorization] == "Bearer \(token)" { return true }
        if allowsQueryToken, request.uri.queryParameters["token"].map(String.init) == token { return true }
        return false
    }
}

/// Rejects every request in its route group that doesn't carry the token.
struct BearerAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let auth: BearerAuth

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        guard auth.authorizes(request) else { throw HTTPError(.unauthorized) }
        return try await next(request, context)
    }
}
