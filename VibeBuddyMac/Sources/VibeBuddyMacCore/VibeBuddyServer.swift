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
    public let deviceTokens = DeviceTokens()
    public let approvalRegistry: ApprovalRegistry
    public let rules: @Sendable () -> PermissionRules
    public let approvalTimeout: Duration
    public let approvalID: @Sendable () -> String

    public init(store: SessionStore, token: String, host: String = "0.0.0.0",
                port: Int = 9876, pusher: APNsPusher? = nil,
                approvalRegistry: ApprovalRegistry = ApprovalRegistry(),
                rules: @escaping @Sendable () -> PermissionRules = { PermissionRules.load() },
                approvalTimeout: Duration = .seconds(25),
                approvalID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.store = store
        self.token = token
        self.host = host
        self.port = port
        self.pusher = pusher
        self.approvalRegistry = approvalRegistry
        self.rules = rules
        self.approvalTimeout = approvalTimeout
        self.approvalID = approvalID
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
        // so the dashboard's "需回应" count stays accurate.
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
                    if let approval = session.pendingApproval {
                        title = "\(session.project) needs approval"
                        body = approval.commandPreview
                    } else {
                        title = "\(session.project) needs you"
                        body = session.summary ?? "Waiting for your response"
                    }
                    for deviceToken in await deviceTokens.all() {
                        await pusher.send(title: title, body: body, to: deviceToken)
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

        // Liveness — unauthenticated, used by the app's connection screen.
        router.get("health") { _, _ -> String in "ok" }

        // Register an iOS APNs device token (uploaded by the app). Token-gated.
        router.post("device") { request, _ -> HTTPResponse.Status in
            guard request.headers[.authorization] == "Bearer \(token)" else {
                throw HTTPError(.unauthorized)
            }
            let buffer = try await request.body.collect(upTo: 4096)
            let body = String(decoding: Data(buffer: buffer), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceToken = body.hasPrefix("{")
                ? (try? JSONDecoder().decode([String: String].self, from: Data(body.utf8)))?["token"] ?? ""
                : body
            if !deviceToken.isEmpty { await deviceTokens.add(deviceToken) }
            return .ok
        }

        // Hook intake — localhost only in practice; no token. `?agent=codex`
        // tags the source (Claude Code is the default).
        router.post("hook") { request, _ -> HTTPResponse.Status in
            let agent: AgentKind = request.uri.queryParameters["agent"] == "codex" ? .codex : .claudeCode
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

        // Blocking approval intake — localhost only in practice; no token.
        // Parse the PreToolUse hook payload, run the permission matcher, and
        // either decide immediately (allow/deny) or hold until the phone
        // responds via `/decision` or the timeout fires.
        let registry = self.approvalRegistry
        let rules = self.rules
        let timeout = self.approvalTimeout
        let makeID = self.approvalID
        router.post("approval") { request, _ -> Response in
            let buffer = try await request.body.collect(upTo: 1 << 20)
            let data = Data(buffer: buffer)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let tool = obj["tool_name"] as? String ?? ""
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            let sessionID = obj["session_id"] as? String ?? ""
            let r = rules()
            let decision = PermissionMatcher.decide(tool: tool, input: input, allow: r.allow, deny: r.deny)
            await store.ingest(data, receivedAt: Date())
            switch decision {
            case .allow: return Self.permissionResponse("allow")
            case .deny:  return Self.permissionResponse("deny")
            case .ask:
                let id = makeID()
                let preview = Self.preview(tool: tool, input: input)
                await store.beginApproval(sessionID: sessionID,
                    PendingApproval(id: id, tool: tool, commandPreview: preview), at: Date())
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
            await registry.resolve(id: id, with: decision == "allow" ? .allow : .deny)
            return .ok
        }

        return router
    }

    static func permissionResponse(_ decision: String) -> Response {
        let json = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"\#(decision)","permissionDecisionReason":"vibebuddy"}}"#
        return Response(status: .ok,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: json)))
    }

    static func preview(tool: String, input: [String: Any]) -> String {
        let raw: String
        if let cmd = input["command"] as? String { raw = cmd }
        else if let path = input["file_path"] as? String { raw = path }
        else { raw = tool }
        return String(raw.prefix(120))
    }
}
