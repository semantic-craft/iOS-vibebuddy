import Foundation
import VibeBuddyKit

/// Keeps one connection to the Codex app-server daemon and feeds its thread,
/// turn and item notifications into the session store as `.appserver`
/// evidence — the primary Codex source while it is fresh (ADR-0011).
///
/// Read-mostly by construction: observation only calls `initialize`,
/// `thread/list`, `thread/resume` (with `excludeTurns`, to subscribe) and
/// `thread/unsubscribe`, and never touches config, fs, process or plugin
/// methods. The writes are the ones the ADR's amendments opened, each on the
/// user's own action: answering a request the agent itself raised,
/// `thread/start` + `turn/start` for a dispatch, `turn/steer` for a
/// supplement, and `turn/interrupt` for a stop.
///
/// The daemon's absence is not an error: the monitor waits for the control
/// socket to appear and the rollout tailer / hooks keep covering Codex until
/// it does. Disabled, it closes its connection and records nothing.
public actor CodexAppServerMonitor {
    public struct Diagnostics: Sendable, Equatable {
        public var enabled: Bool
        public var connected: Bool
        /// The daemon's `userAgent` from `initialize`, e.g. `Codex Desktop/0.145.0 (…)`.
        public var serverUserAgent: String?
        public var lastError: String?
        public var lastEventAt: Date?
        public var subscribedThreads: Int
        /// Methods of server-initiated requests seen on this connection, most
        /// recent last (bounded). Empty means the daemon never routed an
        /// approval or user-input request to a second subscriber.
        public var serverRequestsSeen: [String]
        /// Which of our own hooks the daemon says it will run (`hooks/list`).
        /// Nil until it answers; the hook source is unjudged until then.
        public var hookTrust: CodexHookTrust?

        public init(enabled: Bool = true, connected: Bool = false, serverUserAgent: String? = nil,
                    lastError: String? = nil, lastEventAt: Date? = nil, subscribedThreads: Int = 0,
                    serverRequestsSeen: [String] = [], hookTrust: CodexHookTrust? = nil) {
            self.enabled = enabled
            self.connected = connected
            self.serverUserAgent = serverUserAgent
            self.lastError = lastError
            self.lastEventAt = lastEventAt
            self.subscribedThreads = subscribedThreads
            self.serverRequestsSeen = serverRequestsSeen
            self.hookTrust = hookTrust
        }
    }

    private let acceptanceThreadID: String?
    private let socketPath: String
    private let makeClient: @Sendable (String) -> any CodexAppServerConnecting
    private let discoveryLimit: Int
    private let minimumBackoff: Duration
    private let maximumBackoff: Duration
    /// Where live account usage goes (ticket 02). Nil hosts read no quota here.
    private let usageFeed: AccountUsageLiveFeed?
    /// How often a connected monitor re-reads the rate limits so the live
    /// sample stays fresh and the spawning collector stays idle.
    private let usageRefreshInterval: Duration
    /// Shared with the daemon's `/approval`, `/decision` and `/answer` routes so
    /// a card raised here is answered by the same phone tap as a hook's would be.
    private let approvalRegistry: ApprovalRegistry
    private let allowStore: VibeBuddyAllowStore
    private let sessionAllow: SessionAllowList
    private let approvalContext: ApprovalContextStore
    private let questionRegistry: QuestionRegistry
    private let approvalID: @Sendable () -> String
    /// Whether the person is at the Mac for this thread (`PresencePolicy`).
    /// Present → Desktop's own dialog takes the answer, the phone gets a
    /// read-only card, and this connection never responds.
    private let presence: @Sendable (String) async -> Bool
    /// How long a card stays answerable from the phone. Codex keeps the request
    /// open until someone answers, so this only bounds a forgotten one.
    private let requestTimeout: Duration
    private var enabled: Bool
    private var client: (any CodexAppServerConnecting)?
    private var reducer = CodexAppServerReducer()
    private var subscribed: Set<String> = []
    private var state = Diagnostics()
    /// Server-initiated requests this connection is holding for the phone,
    /// keyed by thread + request id, so `serverRequest/resolved` (someone
    /// answered in Desktop or the TUI) can withdraw the card silently.
    private var openRequests: [String: OpenRequest] = [:]
    /// The store `run(store:)` was given, so a disconnect can withdraw the
    /// cards of requests this connection was holding.
    private var boundStore: SessionStore?
    /// Threads this connection asked Codex to interrupt, and when. The entry is
    /// made *before* the call goes out, so the `turn/completed` that answers it
    /// cannot arrive while the request is still in flight and be read as a
    /// crash. Consumed by the first ending for that thread, and dropped after
    /// `stopClaimWindow` so a stop whose ending never came cannot mislabel the
    /// next one.
    private var stopsRequested: [String: Date] = [:]
    private static let stopClaimWindow: TimeInterval = 60
    /// The items behind pending approvals: `item/started` carries the command
    /// or the file changes, the approval request only their ids.
    private var recentItems: [String: [String: Any]] = [:]
    private var recentItemOrder: [String] = []

    private struct OpenRequest: Sendable {
        enum Kind: Sendable { case approval(String), question(String) }
        let id: JSONRPCID
        let threadID: String
        let kind: Kind
    }
    /// The last full result supplies identity/plan metadata, never old window readings.
    private var lastRateLimits: [String: Any]?
    private var lastUsage: [String: Any]?

    public init(
        enabled: Bool = true,
        socketPath: String = CodexAppServerClient.defaultSocketPath,
        discoveryLimit: Int = 50,
        acceptanceThreadID: String? = nil,
        minimumBackoff: Duration = .seconds(2),
        maximumBackoff: Duration = .seconds(30),
        usageFeed: AccountUsageLiveFeed? = nil,
        usageRefreshInterval: Duration = .seconds(10 * 60),
        approvalRegistry: ApprovalRegistry = ApprovalRegistry(),
        allowStore: VibeBuddyAllowStore = VibeBuddyAllowStore(),
        sessionAllow: SessionAllowList = SessionAllowList(),
        approvalContext: ApprovalContextStore = ApprovalContextStore(),
        questionRegistry: QuestionRegistry = QuestionRegistry(),
        approvalID: @escaping @Sendable () -> String = { UUID().uuidString },
        presence: @escaping @Sendable (String) async -> Bool = { _ in false },
        requestTimeout: Duration = .seconds(60 * 60),
        makeClient: @escaping @Sendable (String) -> any CodexAppServerConnecting = { CodexAppServerClient(socketPath: $0) }
    ) {
        self.enabled = enabled
        self.acceptanceThreadID = acceptanceThreadID
        self.socketPath = socketPath
        self.discoveryLimit = discoveryLimit
        self.minimumBackoff = minimumBackoff
        self.maximumBackoff = maximumBackoff
        self.usageFeed = usageFeed
        self.usageRefreshInterval = usageRefreshInterval
        self.approvalRegistry = approvalRegistry
        self.allowStore = allowStore
        self.sessionAllow = sessionAllow
        self.approvalContext = approvalContext
        self.questionRegistry = questionRegistry
        self.approvalID = approvalID
        self.presence = presence
        self.requestTimeout = requestTimeout
        self.makeClient = makeClient
        state.enabled = enabled
    }

    public func diagnostics() -> Diagnostics { state }

    /// Turning the monitor off closes the connection; the run loop then idles
    /// until it is turned on again.
    public func setEnabled(_ on: Bool) {
        enabled = on
        state.enabled = on
        if !on { Task { await disconnect(reason: nil) } }
    }

    /// Runs until cancelled. Safe to call once per monitor.
    public func run(store: SessionStore) async {
        boundStore = store
        var backoff = minimumBackoff
        while !Task.isCancelled {
            guard enabled else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            guard FileManager.default.fileExists(atPath: socketPath) else {
                // No daemon: not a failure, just nothing to read yet.
                state.connected = false
                state.lastError = nil
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, maximumBackoff)
                continue
            }
            do {
                try await session(store: store)
                backoff = minimumBackoff
            } catch {
                await disconnect(reason: "\(error)")
                await store.recordSourceSignal(agent: .codex, source: .appserver,
                                               health: Self.health(for: error), at: Date())
            }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, maximumBackoff)
        }
        await disconnect(reason: nil)
    }

    // MARK: - One connection

    private func session(store: SessionStore) async throws {
        let client = makeClient(socketPath)
        try client.connect()
        self.client = client
        reducer = CodexAppServerReducer()
        subscribed = []
        // `experimentalApi` is required for `thread/resume.excludeTurns`, the
        // documented way to subscribe without replaying a thread's history; the
        // monitor still only calls the four read-side methods listed above.
        let hello = try await client.request("initialize", params: [
            "clientInfo": ["name": "vibebuddy", "version": Self.version],
            "capabilities": ["experimentalApi": true],
        ])
        client.notify("initialized")
        state.connected = true
        state.lastError = nil
        state.serverUserAgent = hello["userAgent"] as? String
        state.serverRequestsSeen = []
        await store.recordSourceSignal(agent: .codex, source: .appserver, health: .healthy, at: Date())

        try await discover(client: client, store: store)
        await readUsage(client: client)
        await readHookTrust(client: client)
        // Keep the live sample fresh while connected; the request doubles as
        // a liveness check on an otherwise idle daemon. Hook trust rides along
        // so the Settings verdict follows the user trusting them in `/hooks`.
        let refresh = usageRefreshInterval
        let keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: refresh)
                guard !Task.isCancelled else { break }
                await self?.readUsage(client: client)
                await self?.readHookTrust(client: client)
            }
        }
        defer { keepalive.cancel() }

        for await raw in client.messages {
            guard enabled, !Task.isCancelled else { break }
            guard let message = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            if let acceptanceThreadID, Self.threadID(of: message) != acceptanceThreadID { continue }
            if let method = CodexAppServerReducer.serverRequestMethod(message) {
                state.serverRequestsSeen.append(method)
                if state.serverRequestsSeen.count > 20 { state.serverRequestsSeen.removeFirst() }
                await handleServerRequest(method: method, message: message, client: client, store: store)
                continue
            }
            switch message["method"] as? String {
            case "account/rateLimits/updated":
                await publishRateLimits(message["params"] as? [String: Any])
                continue
            case "serverRequest/resolved":
                await requestResolved(message["params"] as? [String: Any], store: store)
                continue
            case "item/started":
                rememberItem(message["params"] as? [String: Any])
            default:
                break
            }
            let now = Date()
            let events = reducer.handle(message, receivedAt: now)
            if !events.isEmpty {
                state.lastEventAt = now
                await forward(events, to: store, now: now)
            }
            // A thread we did not subscribe to has started or come alive:
            // subscribe so its turn/item stream reaches us too.
            if let threadID = Self.threadID(of: message),
               reducer.threads[threadID]?.loaded == true, !subscribed.contains(threadID) {
                await subscribe(threadID, client: client, store: store)
            }
        }
        // The stream ends only when the socket closed under us.
        guard enabled, !Task.isCancelled else { return }
        throw CodexAppServerClient.ClientError.closed
    }

    /// Page the daemon's stored threads once and subscribe to every loaded one.
    private func discover(client: any CodexAppServerConnecting, store: SessionStore) async throws {
        if let acceptanceThreadID {
            await subscribe(acceptanceThreadID, client: client, store: store)
            return
        }
        var cursor: String?
        var pages = 0
        repeat {
            var params: [String: Any] = ["limit": discoveryLimit]
            if let cursor { params["cursor"] = cursor }
            let page = try await client.request("thread/list", params: params)
            let threads = page["data"] as? [[String: Any]] ?? []
            let now = Date()
            for thread in threads {
                let events = reducer.seed(thread: thread, receivedAt: now)
                if !events.isEmpty {
                    state.lastEventAt = now
                    await forward(events, to: store, now: now)
                }
                if let id = thread["id"] as? String, reducer.threads[id]?.loaded == true {
                    await subscribe(id, client: client, store: store)
                }
            }
            cursor = page["nextCursor"] as? String
            pages += 1
        } while cursor != nil && pages < 4
    }

    /// `thread/resume` with `excludeTurns` is how a second client subscribes to
    /// a loaded thread's notifications without replaying its history. The
    /// resume result carries the thread's current facts, so it is seeded again.
    private func subscribe(_ threadID: String, client: any CodexAppServerConnecting, store: SessionStore) async {
        do {
            let result = try await client.request("thread/resume",
                                                  params: ["threadId": threadID, "excludeTurns": true])
            if let acceptanceThreadID,
               (result["thread"] as? [String: Any])?["id"] as? String != acceptanceThreadID {
                state.lastError = "Acceptance subscription returned a different task"
                return
            }
            subscribed.insert(threadID)
            state.subscribedThreads = subscribed.count
            if let thread = result["thread"] as? [String: Any] {
                let now = Date()
                let events = reducer.seed(thread: thread, receivedAt: now)
                if !events.isEmpty {
                    state.lastEventAt = now
                    await forward(events, to: store, now: now)
                }
            }
        } catch {
            // A thread that unloaded between listing and resuming, or a
            // protocol mismatch on this one call: keep the connection, note it.
            state.lastError = "thread/resume \(threadID.suffix(8)): \(error)"
        }
    }

    // MARK: - Approvals and questions (ticket 03)

    /// Route a server-initiated request to a phone card. Codex delivers each
    /// request to every subscribed connection and takes the first answer, so
    /// Desktop's own dialog stays live; whichever side answers first wins and
    /// the other is withdrawn on `serverRequest/resolved`.
    private func handleServerRequest(method: String, message: [String: Any],
                                     client: any CodexAppServerConnecting, store: SessionStore) async {
        guard let id = JSONRPCID(message["id"]),
              let params = message["params"] as? [String: Any],
              let threadID = params["threadId"] as? String else { return }
        // Each hold runs on its own task: the message loop must keep reading
        // so `serverRequest/resolved` (someone answered elsewhere) and later
        // requests are seen while the phone is still deciding.
        let reason = params["reason"] as? String
        switch method {
        case "item/commandExecution/requestApproval":
            let command = (params["command"] as? String) ?? (recentItems[params["itemId"] as? String ?? ""]?["command"] as? String) ?? ""
            let cwd = (params["cwd"] as? String) ?? (recentItems[params["itemId"] as? String ?? ""]?["cwd"] as? String)
            let details = ApprovalDetails.from(tool: "Bash", input: ["command": command])
            let preview = details.commandPreview.isEmpty ? "Shell command" : details.commandPreview
            let card = PendingApproval(id: approvalID(), tool: "Bash", commandPreview: preview,
                                       command: command, filePath: cwd)
            Task { [weak self] in
                await self?.holdApproval(id: id, threadID: threadID, tool: "Bash", input: ["command": command],
                                         card: card, reason: reason, client: client, store: store)
            }
        case "item/fileChange/requestApproval":
            let item = recentItems[params["itemId"] as? String ?? ""] ?? [:]
            let changes = (item["changes"] as? [[String: Any]]) ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            let diff = changes.compactMap { $0["diff"] as? String }.joined(separator: "\n")
            let preview = paths.isEmpty ? "File changes" : "Edit \(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))"
            let card = PendingApproval(id: approvalID(), tool: "Edit", commandPreview: String(preview.prefix(120)),
                                       filePath: paths.first,
                                       newText: diff.isEmpty ? nil : String(diff.prefix(6 * 1024)))
            let path = paths.first ?? ""
            Task { [weak self] in
                await self?.holdApproval(id: id, threadID: threadID, tool: "Edit", input: ["file_path": path],
                                         card: card, reason: reason, client: client, store: store)
            }
        case "item/tool/requestUserInput":
            let items = Self.questionItems(params["questions"] as? [[String: Any]] ?? [])
            let blocking = params["isBlocking"] as? Bool ?? true
            let questionID = params["itemId"] as? String ?? approvalID()
            Task { [weak self] in
                await self?.holdQuestion(id: id, threadID: threadID, questionID: questionID,
                                         items: items, blocking: blocking, client: client, store: store)
            }
        case "item/permissions/requestApproval":
            // The agent asking to widen its own sandbox: extra filesystem
            // paths, or network access. Answered by granting a profile rather
            // than a decision word, so it has its own hold.
            let requested = params["permissions"] as? [String: Any] ?? [:]
            let card = PendingApproval(id: approvalID(), tool: "Permissions",
                                       commandPreview: Self.permissionPreview(requested),
                                       filePath: params["cwd"] as? String,
                                       newText: Self.permissionDetail(requested, reason: reason))
            // Carried as JSON so an approval echoes back byte for byte what was
            // asked for, and so the payload crosses into the task Sendable.
            let encoded = (try? JSONSerialization.data(withJSONObject: requested)) ?? Data("{}".utf8)
            Task { [weak self] in
                await self?.holdPermissions(id: id, threadID: threadID, requested: encoded,
                                            card: card, client: client, store: store)
            }
        case "mcpServer/elicitation/request":
            // An MCP server asking the person for structured input. vibebuddy
            // has no way to fill an arbitrary form, so this is shown and never
            // answered: the wait becomes visible, the answer stays where the
            // session runs.
            let server = params["serverName"] as? String ?? "An MCP server"
            let message = (params["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "is waiting for your input"
            Task { [weak self] in
                await self?.showElicitation(id: id, threadID: threadID,
                                            server: server, message: message, store: store)
            }
        default:
            break
        }
    }

    /// One line naming what the agent wants added to its sandbox.
    static func permissionPreview(_ profile: [String: Any]) -> String {
        var parts: [String] = []
        let paths = permissionPaths(profile)
        if !paths.isEmpty {
            parts.append("\(paths.count) path\(paths.count == 1 ? "" : "s")")
        }
        if (profile["network"] as? [String: Any])?["enabled"] as? Bool == true {
            parts.append("network access")
        }
        return parts.isEmpty ? "Widen the sandbox" : "Allow " + parts.joined(separator: " + ")
    }

    /// The full escalation, one line each, so the card shows exactly what an
    /// approval grants. The agent's own `reason` leads when it gave one.
    static func permissionDetail(_ profile: [String: Any], reason: String?) -> String? {
        var lines: [String] = []
        if let reason, !reason.isEmpty { lines.append(reason) }
        lines += permissionPaths(profile).map { "\($0.access): \($0.path)" }
        if let network = profile["network"] as? [String: Any], let enabled = network["enabled"] as? Bool {
            lines.append(enabled ? "network: enabled" : "network: disabled")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// `fileSystem.entries` plus the `read`/`write` arrays Codex still accepts.
    private static func permissionPaths(_ profile: [String: Any]) -> [(access: String, path: String)] {
        guard let fileSystem = profile["fileSystem"] as? [String: Any] else { return [] }
        var result: [(access: String, path: String)] = []
        for entry in fileSystem["entries"] as? [[String: Any]] ?? [] {
            let access = entry["access"] as? String ?? "access"
            let described: String?
            switch entry["path"] {
            case let path as [String: Any]:
                described = (path["path"] as? String) ?? (path["pattern"] as? String)
                    ?? (path["value"] as? String)
            case let path as String: described = path
            default: described = nil
            }
            if let described, !described.isEmpty { result.append((access, described)) }
        }
        for legacy in ["read", "write"] {
            for path in fileSystem[legacy] as? [String] ?? [] where !path.isEmpty {
                result.append((legacy, path))
            }
        }
        return result
    }

    /// Hold a sandbox escalation for the phone.
    ///
    /// Deliberately not routed through `holdApproval`: a standing session allow
    /// or an always-allow rule is about one tool call, and must never silently
    /// widen the sandbox. This one always asks, and an approval grants exactly
    /// what was requested, for this turn only.
    private func holdPermissions(id: JSONRPCID, threadID: String, requested: Data,
                                 card: PendingApproval,
                                 client: any CodexAppServerConnecting, store: SessionStore) async {
        let key = Self.requestKey(threadID: threadID, id: id)
        openRequests[key] = OpenRequest(id: id, threadID: threadID, kind: .approval(card.id))
        if await presence(threadID) {
            await store.beginApproval(sessionID: threadID, card.readOnly, at: Date())
            return
        }
        // No rule: "Always allow" on this card resolves the one request and
        // persists nothing, because there is no safe rule to persist.
        await approvalContext.set(id: card.id, sessionID: threadID, rule: nil)
        await approvalRegistry.prepare(id: card.id)
        await store.beginApproval(sessionID: threadID, card, at: Date())
        let outcome = await approvalRegistry.wait(id: card.id, timeout: requestTimeout)
        guard openRequests.removeValue(forKey: key) != nil else { return }   // resolved elsewhere
        await store.endApproval(sessionID: threadID, approvalID: card.id, at: Date())
        switch outcome {
        case .allow:
            let profile = (try? JSONSerialization.jsonObject(with: requested)) as? [String: Any] ?? [:]
            client.respond(id: id, result: ["permissions": profile, "scope": "turn"])
        case .deny:
            // Granting nothing is how this request is refused; there is no
            // decision word for it.
            client.respond(id: id, result: ["permissions": [String: Any]()])
        case .pass:
            break   // answered where the session runs
        }
    }

    /// Show an MCP elicitation as a read-only wait and never answer it.
    private func showElicitation(id: JSONRPCID, threadID: String, server: String, message: String,
                                 store: SessionStore) async {
        let questionID = "elicitation:\(id.description)"
        let question = PendingQuestion(id: questionID, prompt: "\(server): \(message)",
                                       options: [], questions: [], isBlocking: true)
        openRequests[Self.requestKey(threadID: threadID, id: id)] =
            OpenRequest(id: id, threadID: threadID, kind: .question(questionID))
        await store.beginQuestion(sessionID: threadID, question.readOnly, at: Date())
    }

    private func holdApproval(id: JSONRPCID, threadID: String, tool: String, input: [String: Any],
                              card: PendingApproval, reason: String?,
                              client: any CodexAppServerConnecting, store: SessionStore) async {
        // The same overlays the hook gate honours (ADR 0010): a session-wide
        // allow or an exact always-allow rule answers at once, no card.
        if await sessionAllow.contains(threadID) {
            client.respond(id: id, result: ["decision": "acceptForSession"])
            return
        }
        let rules = await allowStore.all()
        if rules.contains(where: { AllowRule.matchesExactly($0, tool: tool, input: input) }) {
            client.respond(id: id, result: ["decision": "accept"])
            return
        }
        let key = Self.requestKey(threadID: threadID, id: id)
        openRequests[key] = OpenRequest(id: id, threadID: threadID, kind: .approval(card.id))
        var shown = card
        if let reason, !reason.isEmpty, shown.newText == nil, shown.command == nil {
            shown = PendingApproval(id: card.id, tool: card.tool, commandPreview: card.commandPreview,
                                    command: nil, filePath: card.filePath, oldText: nil, newText: reason)
        }
        if await presence(threadID) {
            // At the Mac: Desktop's dialog is right there. Show, don't hold;
            // `serverRequest/resolved` clears the card once it is answered.
            await store.beginApproval(sessionID: threadID, shown.readOnly, at: Date())
            return
        }
        await approvalContext.set(id: card.id, sessionID: threadID,
                                  rule: AllowRule.forApproval(tool: tool, input: input))
        await approvalRegistry.prepare(id: card.id)
        await store.beginApproval(sessionID: threadID, shown, at: Date())
        let outcome = await approvalRegistry.wait(id: card.id, timeout: requestTimeout)
        guard openRequests.removeValue(forKey: key) != nil else { return }   // resolved elsewhere
        await store.endApproval(sessionID: threadID, approvalID: card.id, at: Date())
        switch outcome {
        case .allow:
            let forSession = await sessionAllow.contains(threadID)
            client.respond(id: id, result: ["decision": forSession ? "acceptForSession" : "accept"])
        case .deny:
            client.respond(id: id, result: ["decision": "decline"])
        case .pass:
            break   // nobody answered here; Desktop's dialog is still open
        }
    }

    /// Codex's `request_user_input` questions: `{id, header, question,
    /// isOther, isSecret, options: [{label, description}] | null}`.
    static func questionItems(_ raw: [[String: Any]]) -> [QuestionItem] {
        raw.compactMap { q in
            guard let qid = q["id"] as? String, let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = ((q["options"] as? [[String: Any]]) ?? []).compactMap { o -> QuestionOption? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return QuestionOption(id: label, label: label, value: label, description: o["description"] as? String)
            }
            return QuestionItem(id: qid, header: q["header"] as? String, text: text, options: options,
                                multiSelect: false, allowsOther: (q["isOther"] as? Bool ?? true) || options.isEmpty)
        }
    }

    private func holdQuestion(id: JSONRPCID, threadID: String, questionID: String, items: [QuestionItem],
                              blocking: Bool, client: any CodexAppServerConnecting, store: SessionStore) async {
        guard let first = items.first else {
            client.respond(id: id, result: ["answers": [:]])
            return
        }
        let timeout = blocking ? requestTimeout : .seconds(60)
        let question = PendingQuestion(id: questionID,
                                       prompt: first.text, options: first.options, questions: items,
                                       isBlocking: blocking,
                                       expiresAt: blocking ? nil : Date().addingTimeInterval(60))
        let key = Self.requestKey(threadID: threadID, id: id)
        openRequests[key] = OpenRequest(id: id, threadID: threadID, kind: .question(questionID))
        if await presence(threadID) {
            await store.beginQuestion(sessionID: threadID, question.readOnly, at: Date())
            return
        }
        await store.beginQuestion(sessionID: threadID, question, at: Date())
        let answers = await questionRegistry.wait(sessionID: threadID, questionID: questionID, timeout: timeout)
        guard openRequests.removeValue(forKey: key) != nil else { return }
        await store.endQuestion(sessionID: threadID, questionID: questionID, at: Date())
        guard let answers else { return }
        var payload: [String: Any] = [:]
        for item in items {
            payload[item.id] = ["answers": answers[item.id] ?? []]
        }
        client.respond(id: id, result: ["answers": payload])
    }

    /// Join a running turn. Does not start a new one when steer fails (Q35).
    /// Sends `expectedTurnId` when the reducer still knows the active turn.
    public func steer(threadID: String, text: String) async -> Bool {
        guard acceptanceThreadID == nil || acceptanceThreadID == threadID else { return false }
        guard let client, state.connected else { return false }
        guard await resumeIfNeeded(threadID: threadID) else { return false }
        var input: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text]]]
        if let turnID = reducer.threads[threadID]?.activeTurnID {
            input["expectedTurnId"] = turnID
        }
        do {
            _ = try await client.request("turn/steer", params: input)
            return true
        } catch {
            state.lastError = "turn/steer \(threadID.suffix(8)): \(error)"
            return false
        }
    }

    /// Every event this connection produces goes to the store through here, so
    /// the ending of a turn we were asked to stop is labelled wherever it shows
    /// up — a `turn/completed` notification, or an idle status seen on a
    /// re-seed after a reconnect.
    private func forward(_ events: [HookEvent], to store: SessionStore, now: Date) async {
        for event in events {
            guard event.kind == .stop, let asked = stopsRequested[event.sessionID] else {
                await store.ingest(event)
                continue
            }
            stopsRequested[event.sessionID] = nil
            let ours = now.timeIntervalSince(asked) < Self.stopClaimWindow
            await store.ingest(ours ? event.markingUserStop() : event)
        }
    }

    /// The running turn this connection knows about — set by `turn/started`,
    /// cleared when the turn completes. `turn/interrupt` cannot be sent
    /// without it.
    func activeTurnID(threadID: String) -> String? { reducer.threads[threadID]?.activeTurnID }

    /// What became of a stop. A `Bool` would fold "we never sent it" into
    /// "we don't know", and those are different answers for the person
    /// holding the watch: one is final, the other is worth checking on.
    public enum InterruptOutcome: Equatable, Sendable {
        /// The daemon accepted `turn/interrupt`.
        case sent
        /// Nothing went out, or the daemon rejected it outright. Retrying the
        /// same stop cannot change this answer; the reason says why.
        case notSent(String)
        /// It went out and the connection died before the answer came back.
        /// Whether the turn was interrupted is genuinely unknown.
        case unconfirmed
    }

    /// Interrupt the running turn (ADR-0011, third amendment). One call and
    /// one only: no resume, no retry, no other method when it fails, so a
    /// stop that did not land stays a stop that did not land.
    ///
    /// `turn/interrupt` *requires* the turn id, so a thread whose turn this
    /// connection never saw start (it attached mid-turn) cannot be stopped
    /// from here — and says so, rather than reporting an unknown.
    public func interrupt(threadID: String) async -> InterruptOutcome {
        guard acceptanceThreadID == nil || acceptanceThreadID == threadID else {
            return .notSent("This task is outside the acceptance run")
        }
        guard let client, state.connected else {
            return .notSent(String(localized: "Your Mac isn't connected to Codex right now."))
        }
        guard let turnID = reducer.threads[threadID]?.activeTurnID else {
            state.lastError = "turn/interrupt \(threadID.suffix(8)): no running turn on this connection"
            return .notSent(String(localized: "Your Mac isn't following this task's current turn."))
        }
        // Claimed before the call: the ending can arrive while we are awaiting
        // the answer, and an ending we asked for must never be read as a crash.
        stopsRequested[threadID] = Date()
        do {
            _ = try await client.request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
            return .sent
        } catch {
            stopsRequested[threadID] = nil
            state.lastError = "turn/interrupt \(threadID.suffix(8)): \(error)"
            // A JSON-RPC error is the daemon's own answer: it arrived and was
            // refused. Anything else (socket gone, timeout) leaves the fate of
            // the request open.
            if case CodexAppServerClient.ClientError.rpc(_, let message) = error {
                return .notSent(String(localized: "Codex refused the stop: \(message)"))
            }
            return .unconfirmed
        }
    }

    /// Open the next turn on an idle or cold thread. Resume first when the
    /// daemon has unloaded it. Nothing about model, approval or sandbox.
    public func startTurn(threadID: String, text: String) async -> Bool {
        guard acceptanceThreadID == nil || acceptanceThreadID == threadID else { return false }
        guard let client, state.connected else { return false }
        guard await resumeIfNeeded(threadID: threadID) else { return false }
        let input: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text]]]
        do {
            // A failed RPC may already have reached the daemon. Never replay it
            // as a new turn; the phone must report uncertainty and reconcile.
            _ = try await client.request("turn/start", params: input)
            return true
        } catch {
            state.lastError = "turn/start \(threadID.suffix(8)): \(error)"
            return false
        }
    }

    private func resumeIfNeeded(threadID: String) async -> Bool {
        guard let client else { return false }
        guard reducer.threads[threadID]?.loaded != true else { return true }
        do {
            let result = try await client.request("thread/resume", params: ["threadId": threadID, "excludeTurns": true])
            subscribed.insert(threadID)
            if let thread = result["thread"] as? [String: Any] {
                _ = reducer.seed(thread: thread, receivedAt: Date())
            }
            return true
        } catch {
            state.lastError = "thread/resume \(threadID.suffix(8)): \(error)"
            return false
        }
    }

    /// Start a new thread in `cwd` and give it its first turn (ticket 05). The
    /// thread inherits the user's own defaults for model, approval policy and
    /// sandbox; `thread/start` auto-subscribes this connection, so the session
    /// surfaces through the normal notifications. Desktop lists it too.
    public func dispatch(_ request: DispatchRequest) async -> DispatchOutcome {
        guard acceptanceThreadID == nil else { return .unavailable("Use the designated acceptance task") }
        guard let client, state.connected else {
            return .unavailable("The Codex app-server daemon is not connected")
        }
        do {
            let started = try await client.request("thread/start", params: ["cwd": request.cwd])
            guard let thread = started["thread"] as? [String: Any], let threadID = thread["id"] as? String else {
                return .unavailable("thread/start returned no thread")
            }
            subscribed.insert(threadID)
            state.subscribedThreads = subscribed.count
            _ = reducer.seed(thread: thread, receivedAt: Date())
            if let name = request.name {
                // A name is a courtesy; a daemon without the method still runs the task.
                _ = try? await client.request("thread/name/set", params: ["threadId": threadID, "name": name])
            }
            _ = try await client.request("turn/start", params: [
                "threadId": threadID,
                "input": [["type": "text", "text": request.prompt]],
            ])
            return .started(sessionID: threadID)
        } catch {
            state.lastError = "dispatch: \(error)"
            return .unavailable("\(error)")
        }
    }

    /// Someone else answered (or the turn moved on): withdraw the card without
    /// a second notification and stop waiting.
    private func requestResolved(_ params: [String: Any]?, store: SessionStore) async {
        guard let threadID = params?["threadId"] as? String,
              let id = JSONRPCID(params?["requestId"]),
              let open = openRequests.removeValue(forKey: Self.requestKey(threadID: threadID, id: id)) else { return }
        switch open.kind {
        case .approval(let approvalID):
            _ = await approvalContext.take(id: approvalID)
            await approvalRegistry.resolve(id: approvalID, with: .pass)
            await store.endApproval(sessionID: threadID, approvalID: approvalID, at: Date())
        case .question(let questionID):
            await questionRegistry.cancelExact(sessionID: threadID, questionID: questionID)
            await store.endQuestion(sessionID: threadID, questionID: questionID, at: Date())
        }
    }

    private func rememberItem(_ params: [String: Any]?) {
        guard let item = params?["item"] as? [String: Any], let id = item["id"] as? String,
              ["commandExecution", "fileChange"].contains(item["type"] as? String ?? "") else { return }
        recentItems[id] = item
        recentItemOrder.append(id)
        while recentItemOrder.count > 64 {
            recentItems.removeValue(forKey: recentItemOrder.removeFirst())
        }
    }

    private static func requestKey(threadID: String, id: JSONRPCID) -> String { "\(threadID)#\(id.description)" }

    // MARK: - Account usage (ticket 02)

    /// `account/rateLimits/read` plus, best effort, `account/usage/read`, into
    /// the same snapshot the spawned adapter produces — published live.
    private func readUsage(client: any CodexAppServerConnecting) async {
        guard let usageFeed else { return }
        do {
            let limits = try await client.request("account/rateLimits/read", params: [:])
            lastRateLimits = limits
            if let usage = try? await client.request("account/usage/read", params: [:]) {
                lastUsage = usage
            }
            let snapshot = try CodexUsageResponseDecoder.decode(
                rateLimits: limits, usage: lastUsage, fetchedAt: Date())
            await usageFeed.publish(snapshot)
        } catch {
            state.lastError = "rate limits: \(error)"
        }
    }

    /// The script basenames `install-codex-hooks.py` writes into `hooks.json`.
    /// A hook naming one of these is ours; everything else in the list belongs
    /// to the user or another tool and is none of our business.
    private static let hookMarkers = ["vibebuddy-forward.sh", "approval-hook.sh", "capture-terminal.sh"]
    /// `HookTrustStatus` values that let Codex run a hook. `modified` (edited
    /// since it was trusted) and `untrusted` (never trusted) are skipped
    /// silently — writing hooks.json does not make a hook run.
    private static let hookTrustRunning: Set<String> = ["trusted", "managed"]

    /// Ask the daemon which of our hooks it will actually run. Read-only, and
    /// never fatal: a daemon that does not answer leaves the verdict unknown
    /// rather than accusing a working installation.
    private func readHookTrust(client: any CodexAppServerConnecting) async {
        guard let result = try? await client.request("hooks/list", params: [:]) else { return }
        let entries = result["data"] as? [[String: Any]] ?? []
        var seen: Set<String> = []
        var installed = 0
        var blocked = 0
        var blockedEvents: Set<String> = []
        for entry in entries {
            for hook in entry["hooks"] as? [[String: Any]] ?? [] {
                guard let command = hook["command"] as? String,
                      Self.hookMarkers.contains(where: command.contains) else { continue }
                // The same hook is reported once per working directory it
                // applies to; its key identifies the definition, not the cwd.
                let key = (hook["key"] as? String) ?? command
                guard seen.insert(key).inserted else { continue }
                installed += 1
                let trusted = Self.hookTrustRunning.contains((hook["trustStatus"] as? String) ?? "")
                guard hook["enabled"] as? Bool == false || !trusted else { continue }
                blocked += 1
                if let event = hook["eventName"] as? String { blockedEvents.insert(event) }
            }
        }
        guard installed > 0 else { return }
        state.hookTrust = CodexHookTrust(installed: installed,
                                         blockedEvents: blockedEvents.sorted(),
                                         blocked: blocked)
    }

    /// Missing windows in an update are unknown. Reusing old window values here
    /// would renew their observation time whenever an unrelated bucket changes.
    private func publishRateLimits(_ params: [String: Any]?) async {
        guard let usageFeed, var update = params?["rateLimits"] as? [String: Any] else { return }
        let id = update["limitId"] as? String
        if let id {
            guard id == "codex" else { return }
        } else {
            // An unlabelled update is only meaningful for a single-main source.
            guard let lastRateLimits, lastRateLimits["rateLimitsByLimitId"] == nil,
                  let main = lastRateLimits["rateLimits"] as? [String: Any],
                  main["limitId"] == nil || main["limitId"] as? String == "codex" else { return }
        }
        let previous = (lastRateLimits?["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any]
            ?? lastRateLimits?["rateLimits"] as? [String: Any]
        if update["planType"] == nil { update["planType"] = previous?["planType"] }
        let payload: [String: Any] = id == "codex"
            ? ["rateLimitsByLimitId": ["codex": update]] : ["rateLimits": update]
        if let snapshot = try? CodexUsageResponseDecoder.decode(
            rateLimits: payload, usage: lastUsage, fetchedAt: Date()) {
            await usageFeed.publish(snapshot)
        }
    }

    private func disconnect(reason: String?) async {
        client?.close()
        client = nil
        subscribed = []
        state.connected = false
        state.subscribedThreads = 0
        if let reason { state.lastError = reason }
        await withdrawOpenRequests()
    }

    /// A request this connection was holding cannot be answered once the
    /// socket is gone: the reply would go to a closed client and Codex would
    /// stay blocked on its own dialog. Stop every wait and take the cards down,
    /// so a later phone tap lands nowhere and a reconnect starts clean.
    private func withdrawOpenRequests() async {
        guard !openRequests.isEmpty else { return }
        let open = openRequests
        openRequests = [:]
        for request in open.values {
            switch request.kind {
            case .approval(let approvalID):
                _ = await approvalContext.take(id: approvalID)
                await approvalRegistry.resolve(id: approvalID, with: .pass)
                await boundStore?.endApproval(sessionID: request.threadID, approvalID: approvalID, at: Date())
            case .question(let questionID):
                await questionRegistry.cancelExact(sessionID: request.threadID, questionID: questionID)
                await boundStore?.endQuestion(sessionID: request.threadID, questionID: questionID, at: Date())
            }
        }
    }

    private static func health(for error: Error) -> ObservationHealth {
        switch error as? CodexAppServerClient.ClientError {
        case .rpc?, .malformed?: return .unknownVersion
        default: return .sourceUnreadable
        }
    }

    private static func threadID(of message: [String: Any]) -> String? {
        let params = message["params"] as? [String: Any]
        if let id = params?["threadId"] as? String { return id }
        return (params?["thread"] as? [String: Any])?["id"] as? String
    }

    private static let version: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }()
}
