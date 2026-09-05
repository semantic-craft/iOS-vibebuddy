import Foundation
import VibeBuddyKit

/// Keeps one connection to the Codex app-server daemon and feeds its thread,
/// turn and item notifications into the session store as `.appserver`
/// evidence — the primary Codex source while it is fresh (ADR-0011).
///
/// Read-mostly by construction: the only methods ever called are `initialize`,
/// `thread/list`, `thread/resume` (with `excludeTurns`, to subscribe) and
/// `thread/unsubscribe`. It never starts, steers or interrupts a turn, never
/// touches config, and never answers a server-initiated request — those are
/// counted for diagnostics so ticket 03 can see what the daemon routes here.
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

        public init(enabled: Bool = true, connected: Bool = false, serverUserAgent: String? = nil,
                    lastError: String? = nil, lastEventAt: Date? = nil, subscribedThreads: Int = 0,
                    serverRequestsSeen: [String] = []) {
            self.enabled = enabled
            self.connected = connected
            self.serverUserAgent = serverUserAgent
            self.lastError = lastError
            self.lastEventAt = lastEventAt
            self.subscribedThreads = subscribedThreads
            self.serverRequestsSeen = serverRequestsSeen
        }
    }

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
    /// The items behind pending approvals: `item/started` carries the command
    /// or the file changes, the approval request only their ids.
    private var recentItems: [String: [String: Any]] = [:]
    private var recentItemOrder: [String] = []

    private struct OpenRequest: Sendable {
        enum Kind: Sendable { case approval(String), question }
        let id: JSONRPCID
        let threadID: String
        let kind: Kind
    }
    /// The last full `account/rateLimits/read` result; sparse
    /// `account/rateLimits/updated` notifications are merged into it.
    private var lastRateLimits: [String: Any]?
    private var lastUsage: [String: Any]?

    public init(
        enabled: Bool = true,
        socketPath: String = CodexAppServerClient.defaultSocketPath,
        discoveryLimit: Int = 50,
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
        if !on { disconnect(reason: nil) }
    }

    /// Runs until cancelled. Safe to call once per monitor.
    public func run(store: SessionStore) async {
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
                disconnect(reason: "\(error)")
                await store.recordSourceSignal(agent: .codex, source: .appserver,
                                               health: Self.health(for: error), at: Date())
            }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, maximumBackoff)
        }
        disconnect(reason: nil)
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
        // Keep the live sample fresh while connected; the request doubles as
        // a liveness check on an otherwise idle daemon.
        let refresh = usageRefreshInterval
        let keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: refresh)
                guard !Task.isCancelled else { break }
                await self?.readUsage(client: client)
            }
        }
        defer { keepalive.cancel() }

        for await raw in client.messages {
            guard enabled, !Task.isCancelled else { break }
            guard let message = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            if let method = CodexAppServerReducer.serverRequestMethod(message) {
                state.serverRequestsSeen.append(method)
                if state.serverRequestsSeen.count > 20 { state.serverRequestsSeen.removeFirst() }
                await handleServerRequest(method: method, message: message, client: client, store: store)
                continue
            }
            switch message["method"] as? String {
            case "account/rateLimits/updated":
                await mergeRateLimits(message["params"] as? [String: Any])
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
                for event in events { await store.ingest(event) }
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
                    for event in events { await store.ingest(event) }
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
            subscribed.insert(threadID)
            state.subscribedThreads = subscribed.count
            if let thread = result["thread"] as? [String: Any] {
                let now = Date()
                for event in reducer.seed(thread: thread, receivedAt: now) {
                    state.lastEventAt = now
                    await store.ingest(event)
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
        default:
            break
        }
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
        await store.beginApproval(sessionID: threadID, shown, at: Date())
        let outcome = await approvalRegistry.wait(id: card.id, timeout: requestTimeout)
        guard openRequests.removeValue(forKey: key) != nil else { return }   // resolved elsewhere
        await store.endApproval(sessionID: threadID, at: Date())
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
        openRequests[key] = OpenRequest(id: id, threadID: threadID, kind: .question)
        if await presence(threadID) {
            await store.beginQuestion(sessionID: threadID, question.readOnly, at: Date())
            return
        }
        await store.beginQuestion(sessionID: threadID, question, at: Date())
        let answers = await questionRegistry.wait(sessionID: threadID, timeout: timeout)
        guard openRequests.removeValue(forKey: key) != nil else { return }
        await store.endQuestion(sessionID: threadID, at: Date())
        guard let answers else { return }
        var payload: [String: Any] = [:]
        for item in items {
            payload[item.id] = ["answers": answers[item.id] ?? []]
        }
        client.respond(id: id, result: ["answers": payload])
    }

    /// Put free text into a thread (ticket 04): `turn/steer` joins a running
    /// turn, `turn/start` opens one on an idle thread, and a thread the daemon
    /// has unloaded is resumed first. Nothing about the thread's model,
    /// approval policy or sandbox is touched. False when there is no
    /// connection or the daemon refused.
    public func steer(threadID: String, text: String, isActive: Bool) async -> Bool {
        guard let client, state.connected else { return false }
        let input: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text]]]
        if reducer.threads[threadID]?.loaded != true {
            do {
                let result = try await client.request("thread/resume", params: ["threadId": threadID, "excludeTurns": true])
                subscribed.insert(threadID)
                if let thread = result["thread"] as? [String: Any] {
                    _ = reducer.seed(thread: thread, receivedAt: Date())
                }
            } catch {
                state.lastError = "thread/resume \(threadID.suffix(8)): \(error)"
                return false
            }
        }
        if isActive {
            if (try? await client.request("turn/steer", params: input)) != nil { return true }
            // The turn ended between the snapshot and the call: start one.
        }
        do {
            _ = try await client.request("turn/start", params: input)
            return true
        } catch {
            state.lastError = "turn/start \(threadID.suffix(8)): \(error)"
            return false
        }
    }

    /// Start a new thread in `cwd` and give it its first turn (ticket 05). The
    /// thread inherits the user's own defaults for model, approval policy and
    /// sandbox; `thread/start` auto-subscribes this connection, so the session
    /// surfaces through the normal notifications. Desktop lists it too.
    public func dispatch(_ request: DispatchRequest) async -> DispatchOutcome {
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
            await store.endApproval(sessionID: threadID, at: Date())
        case .question:
            await questionRegistry.cancel(sessionID: threadID)
            await store.endQuestion(sessionID: threadID, at: Date())
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

    /// `account/rateLimits/updated` is a sparse rolling update: merge what it
    /// carries into the last full read and publish the result.
    private func mergeRateLimits(_ params: [String: Any]?) async {
        guard let usageFeed, var merged = lastRateLimits,
              let update = params?["rateLimits"] as? [String: Any] else { return }
        var limits = merged["rateLimits"] as? [String: Any] ?? [:]
        for (key, value) in update { limits[key] = value }
        merged["rateLimits"] = limits
        if let id = update["limitId"] as? String,
           var byID = merged["rateLimitsByLimitId"] as? [String: Any] {
            var entry = byID[id] as? [String: Any] ?? [:]
            for (key, value) in update { entry[key] = value }
            byID[id] = entry
            merged["rateLimitsByLimitId"] = byID
        }
        lastRateLimits = merged
        if let snapshot = try? CodexUsageResponseDecoder.decode(
            rateLimits: merged, usage: lastUsage, fetchedAt: Date()) {
            await usageFeed.publish(snapshot)
        }
    }

    private func disconnect(reason: String?) {
        client?.close()
        client = nil
        subscribed = []
        state.connected = false
        state.subscribedThreads = 0
        if let reason { state.lastError = reason }
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
