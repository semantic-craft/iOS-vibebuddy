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
    public let approvalTimeout: Duration
    public let approvalID: @Sendable () -> String
    public let onJump: @Sendable (TerminalRef) async -> JumpOutcome
    /// The other kind of jump: a Codex Desktop session has no terminal, only the
    /// thread it *is*, opened in ChatGPT.app.
    public let onJumpToDesktopThread: @Sendable (String) async -> JumpOutcome
    public let onAnswer: @Sendable (TerminalRef, String) -> Void
    public let onDevicePaired: @Sendable (DeviceRegistrationPayload) -> Void

    public init(store: SessionStore, token: String, host: String = "0.0.0.0",
                port: Int = 9876, pusher: APNsPusher? = nil,
                deviceTokens: DeviceTokens = DeviceTokens(),
                activityTokens: ActivityTokens = ActivityTokens(),
                codexRolloutMonitor: CodexRolloutMonitor? = nil,
                approvalRegistry: ApprovalRegistry = ApprovalRegistry(),
                rules: @escaping @Sendable (AgentKind) -> PermissionRules = { PermissionRules.load(for: $0) },
                allowStore: VibeBuddyAllowStore = VibeBuddyAllowStore(),
                sessionAllow: SessionAllowList = SessionAllowList(),
                approvalContext: ApprovalContextStore = ApprovalContextStore(),
                approvalTimeout: Duration = .seconds(25),
                approvalID: @escaping @Sendable () -> String = { UUID().uuidString },
                onJump: @escaping @Sendable (TerminalRef) async -> JumpOutcome = { await TerminalJumper.jump($0) },
                onJumpToDesktopThread: @escaping @Sendable (String) async -> JumpOutcome = { await CodexDesktopJumper.jump(threadID: $0) },
                onAnswer: @escaping @Sendable (TerminalRef, String) -> Void = { ref, answer in TerminalInjector.inject(answer, into: ref) },
                onDevicePaired: @escaping @Sendable (DeviceRegistrationPayload) -> Void = { _ in }) {
        self.store = store
        self.token = token
        self.host = host
        self.port = port
        self.pusher = pusher
        self.deviceTokens = deviceTokens
        self.activityTokens = activityTokens
        self.codexRolloutMonitor = codexRolloutMonitor
        self.approvalRegistry = approvalRegistry
        self.rules = rules
        self.allowStore = allowStore
        self.sessionAllow = sessionAllow
        self.approvalContext = approvalContext
        self.approvalTimeout = approvalTimeout
        self.approvalID = approvalID
        self.onJump = onJump
        self.onJumpToDesktopThread = onJumpToDesktopThread
        self.onAnswer = onAnswer
        self.onDevicePaired = onDevicePaired
    }

    /// Run the HTTP service and its Codex rollout source under one lifetime.
    /// Returning or throwing from the server always cancels and joins the
    /// monitor so no watcher descriptors, debounce tasks, or store sink survive.
    public func runService() async throws {
        let monitorTask = codexRolloutMonitor.map { monitor in
            Task { await monitor.run(store: store) }
        }
        do {
            try await buildApplication().runService()
        } catch {
            monitorTask?.cancel()
            await monitorTask?.value
            throw error
        }
        monitorTask?.cancel()
        await monitorTask?.value
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
                    for deviceToken in await deviceTokens.all() {
                        await pusher.send(title: title, body: body, to: deviceToken,
                                          sound: sound.fileName,
                                          sessionID: session.id, soundCategory: sound.rawValue)
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
            let snapshot = await store.snapshot(now: Date())
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
        // the token file and sends it). Parse the PreToolUse hook payload, run the
        // permission matcher, and either decide immediately (allow/deny) or hold
        // until the phone responds via `/decision` or the timeout fires.
        // `?agent=<source>` selects the envelope shape to decode and the decision
        // contract to answer in; no parameter means Claude Code, as before.
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
            // The blocking hook is also this agent's PreToolUse signal — ingesting
            // it is what moves the session to `working` in the dashboard.
            await store.ingest(data, agent: agent, receivedAt: Date())
            // Native deny always wins, over every vibebuddy overlay (ADR 0010).
            if PermissionMatcher.decide(tool: tool, input: input, allow: [], deny: r.deny) == .deny {
                return Self.permissionResponse("deny", agent: agent)
            }
            // Nothing to decide: a bypass-mode call, or a tool that only reads.
            // Answered here so it never becomes a pending card or a banner.
            if ApprovalShortCircuit.autoAllows(tool: tool, permissionMode: call.permissionMode) {
                return Self.permissionResponse("allow", agent: agent)
            }
            // vibebuddy overlay: a session-wide allow, or an exact always-allow rule the
            // user set — both bypass the matcher's pattern heuristics since the user
            // explicitly approved this precise tool use.
            let sessionAllowed = await sessionAllow.contains(sessionID)
            let storeRules = await allowStore.all()   // [String] is Sendable; match locally
            let storeAllowed = storeRules.contains { AllowRule.matchesExactly($0, tool: tool, input: input) }
            if sessionAllowed || storeAllowed {
                return Self.permissionResponse("allow", agent: agent)
            }
            // Otherwise the native allow/ask matching (composition-guarded).
            switch PermissionMatcher.decide(tool: tool, input: input, allow: r.allow, deny: r.deny) {
            case .allow: return Self.permissionResponse("allow", agent: agent)
            case .deny:  return Self.permissionResponse("deny", agent: agent)
            case .ask:
                let id = makeID()
                let d = ApprovalDetails.from(tool: tool, input: input)
                // Record what an "always allow" / "allow this session" would act
                // on *before* the pending card is broadcast — a decision can only
                // follow the card, so the context is always there when it lands.
                await approvalContext.set(id: id, sessionID: sessionID,
                                          rule: AllowRule.forApproval(tool: tool, input: input))
                await store.beginApproval(sessionID: sessionID,
                    PendingApproval(id: id, tool: tool,
                                    commandPreview: d.commandPreview.isEmpty ? tool : d.commandPreview,
                                    command: d.command, filePath: d.filePath,
                                    oldText: d.oldText, newText: d.newText,
                                    permissionMode: call.permissionMode), at: Date())
                let outcome = await registry.wait(id: id, timeout: timeout)
                await store.endApproval(sessionID: sessionID, at: Date())
                switch outcome {
                case .allow: return Self.permissionResponse("allow", agent: agent)
                case .deny:  return Self.permissionResponse("deny", agent: agent)
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
            switch decision {
            case "alwaysAllow":
                if let ctx = await approvalContext.take(id: id), let rule = ctx.rule {
                    await allowStore.add(rule)
                }
                await registry.resolve(id: id, with: .allow)
            case "allowSession":
                if let ctx = await approvalContext.take(id: id) {
                    await sessionAllow.add(ctx.sessionID)
                }
                await registry.resolve(id: id, with: .allow)
            case "allow":
                _ = await approvalContext.take(id: id)
                await registry.resolve(id: id, with: .allow)
            default:
                _ = await approvalContext.take(id: id)
                await registry.resolve(id: id, with: .deny)
            }
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
            } else {
                outcome = .noTerminal
            }
            let data = try JSONEncoder().encode(["outcome": outcome.rawValue])
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }

        let onAnswer = self.onAnswer
        authed.post("answer") { request, _ -> HTTPResponse.Status in
            let buffer = try await request.body.collect(upTo: 4096)
            guard let o = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let sid = o["sessionId"] as? String,
                  let rawAnswer = o["answer"] as? String
            else { throw HTTPError(.badRequest) }
            let answer = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw HTTPError(.badRequest) }
            if let ref = await store.terminalRef(for: sid) {
                onAnswer(ref, answer)
                await store.endQuestion(sessionID: sid, at: Date())
            }
            return .ok
        }

        return router
    }

    /// The PreToolUse decision, in the shape the calling agent parses.
    ///
    /// Claude Code reads `hookSpecificOutput.permissionDecision`. Grok Build
    /// accepts that form too, but its own documented contract is the flat
    /// `{"decision":…,"reason":…}` — that is what we emit for it, so the wire is
    /// unambiguous when read from a Grok transcript. Either way a timeout still
    /// answers with an empty 200 body, which both CLIs read as "no opinion".
    static func permissionResponse(_ decision: String, agent: AgentKind = .claudeCode) -> Response {
        let json: String
        if agent == .grok {
            json = decision == "deny"
                ? #"{"decision":"deny","reason":"vibebuddy"}"#
                : #"{"decision":"\#(decision)"}"#
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
