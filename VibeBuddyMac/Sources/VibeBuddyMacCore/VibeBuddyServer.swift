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
    public let rules: @Sendable () -> PermissionRules
    /// vibebuddy's own "always allow" store, overlaid on the native rules (ADR 0010).
    public let allowStore: VibeBuddyAllowStore
    /// Sessions the user chose to allow wholesale for their lifetime (in-memory).
    public let sessionAllow: SessionAllowList
    /// Per-approval context so `/decision` can persist an always-allow rule.
    public let approvalContext: ApprovalContextStore
    public let approvalTimeout: Duration
    public let approvalID: @Sendable () -> String
    public let onJump: @Sendable (TerminalRef) -> Void
    public let onAnswer: @Sendable (TerminalRef, String) -> Void
    public let onDevicePaired: @Sendable (DeviceRegistrationPayload) -> Void

    public init(store: SessionStore, token: String, host: String = "0.0.0.0",
                port: Int = 9876, pusher: APNsPusher? = nil,
                deviceTokens: DeviceTokens = DeviceTokens(),
                activityTokens: ActivityTokens = ActivityTokens(),
                codexRolloutMonitor: CodexRolloutMonitor? = nil,
                approvalRegistry: ApprovalRegistry = ApprovalRegistry(),
                rules: @escaping @Sendable () -> PermissionRules = { PermissionRules.load() },
                allowStore: VibeBuddyAllowStore = VibeBuddyAllowStore(),
                sessionAllow: SessionAllowList = SessionAllowList(),
                approvalContext: ApprovalContextStore = ApprovalContextStore(),
                approvalTimeout: Duration = .seconds(25),
                approvalID: @escaping @Sendable () -> String = { UUID().uuidString },
                onJump: @escaping @Sendable (TerminalRef) -> Void = { TerminalJumper.jump($0) },
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
        wsRouter.ws("/ws") { request, _ in
            request.headers[.authorization] == "Bearer \(token)" ? .upgrade() : .dontUpgrade
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
                        await pusher.send(title: title, body: body, to: deviceToken, sound: sound.fileName)
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

        // Liveness — unauthenticated, used by the app's connection screen.
        router.get("health") { _, _ -> String in "ok" }

        // Register an iOS device. Token-gated. Body is `{"token","name","model",
        // "systemVersion"}` (or a raw APNs token string). `token` -> APNs
        // registry; the other fields feed the paired-device display.
        router.post("device") { request, _ -> HTTPResponse.Status in
            guard request.headers[.authorization] == "Bearer \(token)" else {
                throw HTTPError(.unauthorized)
            }
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
        router.post("activity") { request, _ -> HTTPResponse.Status in
            guard request.headers[.authorization] == "Bearer \(token)" else { throw HTTPError(.unauthorized) }
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
        router.post("hook") { request, _ -> HTTPResponse.Status in
            guard Self.hookAuthorized(request, token: token) else { throw HTTPError(.unauthorized) }
            let agent = AgentKind.fromSource(request.uri.queryParameters["agent"].map(String.init))
            let buffer = try await request.body.collect(upTo: 1 << 20) // 1 MB cap
            await store.ingest(Data(buffer: buffer), agent: agent, receivedAt: Date())
            return .ok
        }

        // Full snapshot — bearer-token gated.
        router.get("snapshot") { request, _ -> Response in
            guard request.headers[.authorization] == "Bearer \(token)" else {
                throw HTTPError(.unauthorized)
            }
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
        router.get("lifecycle") { request, _ -> Response in
            guard request.headers[.authorization] == "Bearer \(token)" else {
                throw HTTPError(.unauthorized)
            }
            let data = try JSONEncoder().encode(await store.recentLifecycle())
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(bytes: data))
            )
        }

        router.delete("lifecycle") { request, _ -> HTTPResponse.Status in
            guard request.headers[.authorization] == "Bearer \(token)" else {
                throw HTTPError(.unauthorized)
            }
            guard await store.clearLifecycleJournal() else {
                throw HTTPError(.internalServerError)
            }
            return .ok
        }

        // Explicit read acknowledgement. Merely receiving/rendering a snapshot
        // never clears unread state; a client calls this only after selection or open.
        router.post("acknowledge") { request, _ -> HTTPResponse.Status in
            guard request.headers[.authorization] == "Bearer \(token)" else {
                throw HTTPError(.unauthorized)
            }
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
        let registry = self.approvalRegistry
        let rules = self.rules
        let allowStore = self.allowStore
        let sessionAllow = self.sessionAllow
        let approvalContext = self.approvalContext
        let timeout = self.approvalTimeout
        let makeID = self.approvalID
        router.post("approval") { request, _ -> Response in
            guard Self.hookAuthorized(request, token: token) else { throw HTTPError(.unauthorized) }
            let buffer = try await request.body.collect(upTo: 1 << 20)
            let data = Data(buffer: buffer)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let tool = obj["tool_name"] as? String ?? ""
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            let sessionID = obj["session_id"] as? String ?? ""
            let r = rules()
            await store.ingest(data, receivedAt: Date())
            // Native deny always wins, over every vibebuddy overlay (ADR 0010).
            if PermissionMatcher.decide(tool: tool, input: input, allow: [], deny: r.deny) == .deny {
                return Self.permissionResponse("deny")
            }
            // vibebuddy overlay: a session-wide allow, or an exact always-allow rule the
            // user set — both bypass the matcher's pattern heuristics since the user
            // explicitly approved this precise tool use.
            let sessionAllowed = await sessionAllow.contains(sessionID)
            let storeRules = await allowStore.all()   // [String] is Sendable; match locally
            let storeAllowed = storeRules.contains { AllowRule.matchesExactly($0, tool: tool, input: input) }
            if sessionAllowed || storeAllowed {
                return Self.permissionResponse("allow")
            }
            // Otherwise the native allow/ask matching (composition-guarded).
            switch PermissionMatcher.decide(tool: tool, input: input, allow: r.allow, deny: r.deny) {
            case .allow: return Self.permissionResponse("allow")
            case .deny:  return Self.permissionResponse("deny")
            case .ask:
                let id = makeID()
                let d = ApprovalDetails.from(tool: tool, input: input)
                await store.beginApproval(sessionID: sessionID,
                    PendingApproval(id: id, tool: tool,
                                    commandPreview: d.commandPreview.isEmpty ? tool : d.commandPreview,
                                    command: d.command, filePath: d.filePath,
                                    oldText: d.oldText, newText: d.newText), at: Date())
                // Record what an "always allow" / "allow this session" would act on.
                await approvalContext.set(id: id, sessionID: sessionID,
                                          rule: AllowRule.forApproval(tool: tool, input: input))
                let outcome = await registry.wait(id: id, timeout: timeout)
                await store.endApproval(sessionID: sessionID, at: Date())
                switch outcome {
                case .allow: return Self.permissionResponse("allow")
                case .deny:  return Self.permissionResponse("deny")
                case .pass:  return Response(status: .ok)
                }
            }
        }

        // Resolve a held approval — bearer-token gated (the phone sends this).
        router.post("decision") { request, _ -> HTTPResponse.Status in
            guard request.headers[.authorization] == "Bearer \(token)" else { throw HTTPError(.unauthorized) }
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

        let onJump = self.onJump
        // Terminal-ref capture — bearer-token gated (the capture hook reads the
        // token file and sends it). Without it any local process could hijack a
        // session's terminal target. (daemon-security/01, ADR-0009.)
        router.post("terminal") { request, _ -> HTTPResponse.Status in
            guard Self.hookAuthorized(request, token: token) else { throw HTTPError(.unauthorized) }
            let buffer = try await request.body.collect(upTo: 64 * 1024)
            guard let o = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let sid = o["session_id"] as? String, let tp = o["term_program"] as? String
            else { return .ok }
            func nz(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            let ref = TerminalRef(termProgram: tp, tty: nz("tty"), tmux: nz("tmux"), tmuxPane: nz("tmux_pane"))
            await store.setTerminalRef(sessionID: sid, ref)
            return .ok
        }
        router.post("jump") { request, _ -> Response in
            guard request.headers[.authorization] == "Bearer \(token)" else { throw HTTPError(.unauthorized) }
            let buffer = try await request.body.collect(upTo: 4096)
            guard let o = try? JSONSerialization.jsonObject(with: Data(buffer: buffer)) as? [String: Any],
                  let sid = o["sessionId"] as? String else { throw HTTPError(.badRequest) }
            // Jumping is an explicit return to the task, even if this terminal
            // type cannot ultimately be focused.
            await store.acknowledgeCompletion(sessionID: sid)
            // Report what actually happened so the phone can give honest feedback:
            // focused (ran), unsupported (known terminal type → no command), or none.
            let ref = await store.terminalRef(for: sid)
            let hasRunnable = ref.map { !TerminalJumper.commands(for: $0).isEmpty } ?? false
            let outcome = JumpOutcome.decide(hasRef: ref != nil, hasRunnableCommand: hasRunnable)
            if outcome == .focused, let ref { onJump(ref) }
            let data = try JSONEncoder().encode(["outcome": outcome.rawValue])
            return Response(status: .ok, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }

        let onAnswer = self.onAnswer
        router.post("answer") { request, _ -> HTTPResponse.Status in
            guard request.headers[.authorization] == "Bearer \(token)" else { throw HTTPError(.unauthorized) }
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

    /// CLI-hook routes (`/hook`, `/approval`, `/terminal`) accept the bearer token
    /// as an `Authorization: Bearer` header (script hooks) OR a `?token=` query
    /// param (native-http hooks that can't set a header, e.g. Qwen). The phone
    /// routes stay header-only. daemon-security/01, ADR-0009.
    static func hookAuthorized(_ request: Request, token: String) -> Bool {
        if request.headers[.authorization] == "Bearer \(token)" { return true }
        if request.uri.queryParameters["token"].map(String.init) == token { return true }
        return false
    }

    static func permissionResponse(_ decision: String) -> Response {
        let json = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"\#(decision)","permissionDecisionReason":"vibebuddy"}}"#
        return Response(status: .ok,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: json)))
    }

}
