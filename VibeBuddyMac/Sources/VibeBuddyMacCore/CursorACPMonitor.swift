import Foundation
import VibeBuddyKit

/// Hosts Cursor CLI conversations over ACP and turns them into sessions the
/// phone and the Watch can fully act on.
///
/// A Cursor chat in the IDE is reached through its hooks, which can answer a
/// gate and hand over a follow-up but can interrupt nothing (ADR-0016). A
/// `cursor-agent acp` process vibebuddy spawns itself is a different animal:
/// the Agent Client Protocol carries `session/prompt`, `session/cancel`,
/// `session/request_permission` and Cursor's own `cursor/ask_question` and
/// `cursor/create_plan` over one pipe (cursor.com/docs/cli/acp). So a
/// conversation this monitor hosts is the Cursor analogue of a Codex thread on
/// the app-server daemon (ADR-0011): observed and controlled through the same
/// connection, with `ControlChannel.acp` stamped on its row.
///
/// Rules that keep it honest:
///
/// - **One process per conversation, alive as long as the daemon is.** The CLI
///   has no detached mode over ACP; when vibebuddy quits, the turn ends. The
///   phone is told so at dispatch time.
/// - **No mid-turn steer.** `session/prompt` is sequential, so a supplement for
///   a running turn is queued in the same `CursorFollowupQueue` the hooks use
///   and sent as the next prompt the moment the current one returns.
/// - **A cancelled turn is a stop the user asked for.** ACP answers
///   `session/cancel` with `stopReason: "cancelled"`; that ending is marked
///   `userStopped` so the failure cue stays quiet.
/// - **Cards are always answerable.** An ACP session has no Cursor UI of its
///   own, so presence never makes them read-only; and a request that goes
///   unanswered blocks the turn, exactly as the protocol says it will.
/// What one `agent … acp` process is started with: the directory, and the
/// model / mode / worktree the dispatch chose as the CLI's global options.
public struct CursorACPLaunch: Sendable, Equatable {
    public var cwd: String
    public var options: CursorLaunchOptions

    public init(cwd: String, options: CursorLaunchOptions = CursorLaunchOptions()) {
        self.cwd = cwd
        self.options = options
    }

    /// The argv in front of `acp`: global options apply to every command
    /// (cursor.com/docs/cli/reference/parameters), so `--model`, `--mode`
    /// and `-w` set the conversation up before the ACP server starts. Modes
    /// could also be set per session over ACP; the flag is the simpler path
    /// and is enough.
    public var leadingArguments: [String] { options.arguments }
}

public actor CursorACPMonitor {
    public static var defaultRecoveryDirectory: URL { CursorACPRecovery.directory }

    /// How long a card may wait before the agent is told the request was
    /// cancelled. ACP blocks the turn until it hears back, so this is the
    /// upper bound on a turn nobody is answering, not a UI timeout.
    public static let decisionTimeout: Duration = .seconds(6 * 3600)

    private struct Hosted {
        let client: CursorACPClient
        let cwd: String
        var running = false
        var finishing = false
        var turnID = UUID()
        var stopRequestedAt: Date?
        var text = ""
        var tools: [String: ToolCallRecord] = [:]
        var openApprovals: [String: JSONRPCID] = [:]
        var openQuestions: [String: JSONRPCID] = [:]
    }

    private let store: SessionStore
    private let approvals: ApprovalRegistry
    private let approvalContext: ApprovalContextStore
    private let questions: QuestionRegistry
    private let allowStore: VibeBuddyAllowStore
    private let sessionAllow: SessionAllowList
    private let followups: CursorFollowupQueue
    private let rules: @Sendable (AgentKind) -> PermissionRules
    private let makeID: @Sendable () -> String
    private let spawn: @Sendable (CursorACPLaunch) throws -> CursorACPClient
    private let executable: URL?
    private let signInProbe: @Sendable () async -> Bool
    private let modelsProbe: @Sendable () async -> [String]
    private var signedIn: Bool?
    /// Cached with the sign-in verdict: `--list-models` is a subprocess and
    /// runs once per verdict, not once per snapshot.
    private var models: [String]?
    private var hosted: [String: Hosted] = [:]
    private let recoveryDirectory: URL?
    private var recoveries: [String: CursorACPRecovery] = [:]
    private var loading: Set<String> = []
    private var preparing: [String: CursorACPClient] = [:]
    private var stopping = false
    private var recoveryRegistered = false

    public func owns(_ sessionID: String) -> Bool { hosted[sessionID] != nil || recoveries[sessionID] != nil }

    /// Register historical rows without launching processes or replaying events.
    public func registerRecoverableSessions() async {
        guard !recoveryRegistered, let recoveryDirectory else { return }
        recoveryRegistered = true
        for record in CursorACPRecovery.read(in: recoveryDirectory) {
            recoveries[record.sessionID] = record
            await store.registerACPRecovery(sessionID: record.sessionID, cwd: record.cwd,
                model: record.options.model, unavailable: record.unavailable, updatedAt: record.updatedAt ?? record.createdAt)
        }
    }

    private func restore(_ sessionID: String) async -> Bool {
        guard !stopping else { return false }
        if let entry = hosted[sessionID] { return !entry.client.isClosed }
        guard !stopping, !loading.contains(sessionID), let record = recoveries[sessionID],
              let recoveryDirectory else { return false }
        guard record.unavailable == nil else { return false }
        loading.insert(sessionID)
        defer { loading.remove(sessionID); preparing[sessionID] = nil }
        var client: CursorACPClient?
        do {
            let lease = try CursorACPLease(directory: recoveryDirectory, record: record)
            var options = record.options
            options.worktree = false
            let connection = try spawn(CursorACPLaunch(cwd: record.cwd, options: options))
            client = connection
            preparing[sessionID] = connection
            try connection.retainLease(lease)
            wire(connection)
            connection.suppressUpdates()
            connection.start()
            let hello = try await connection.request("initialize", params: [
                "protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "vibebuddy", "version": "1"]])
            guard (hello["protocolVersion"] as? Int) == 1,
                  (hello["agentCapabilities"] as? [String: Any])?["loadSession"] as? Bool == true else {
                throw NSError(domain: "CursorACP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cursor CLI does not support ACP session loading"])
            }
            _ = try await connection.request("authenticate", params: ["methodId": "cursor_login"])
            _ = try await connection.request("session/load", params: ["sessionId": sessionID, "cwd": record.cwd, "mcpServers": []])
            guard !stopping, !connection.isClosed else { throw CursorACPClient.ClientError.closed }
            hosted[sessionID] = Hosted(client: connection, cwd: record.cwd)
            connection.enableUpdates()
            await store.setACPHosted(sessionID: sessionID, true)
            return true
        } catch {
            client?.close()
            await store.registerACPRecovery(sessionID: sessionID, cwd: record.cwd, model: record.options.model,
                unavailable: "Cursor session could not be restored: \(error.localizedDescription)", updatedAt: record.updatedAt ?? record.createdAt, retryable: true)
            return false
        }
    }

    public init(store: SessionStore,
                approvals: ApprovalRegistry,
                approvalContext: ApprovalContextStore,
                questions: QuestionRegistry,
                allowStore: VibeBuddyAllowStore,
                sessionAllow: SessionAllowList,
                followups: CursorFollowupQueue,
                rules: @escaping @Sendable (AgentKind) -> PermissionRules = { PermissionRules.load(for: $0) },
                makeID: @escaping @Sendable () -> String = { UUID().uuidString },
                executable: URL? = CursorCLI.resolveExecutable(),
                signInProbe: (@Sendable () async -> Bool)? = nil,
                modelsProbe: (@Sendable () async -> [String])? = nil,
                spawn: (@Sendable (CursorACPLaunch) throws -> CursorACPClient)? = nil,
                recoveryDirectory: URL? = nil) {
        self.recoveryDirectory = recoveryDirectory
        self.store = store
        self.approvals = approvals
        self.approvalContext = approvalContext
        self.questions = questions
        self.allowStore = allowStore
        self.sessionAllow = sessionAllow
        self.followups = followups
        self.rules = rules
        self.makeID = makeID
        self.executable = executable
        let resolved = executable
        self.signInProbe = signInProbe ?? { await CursorCLI.isSignedIn(executable: resolved) }
        self.modelsProbe = modelsProbe ?? { await CursorCLI.listModels(executable: resolved) }
        self.spawn = spawn ?? { launch in
            guard let resolved else { throw CursorACPClient.ClientError.closed }
            return try CursorACPClient.spawn(executable: resolved, cwd: launch.cwd,
                                             leadingArguments: launch.leadingArguments)
        }
    }

    // MARK: - Availability

    /// Installed and signed in. Cached like `CursorLauncher`: the probe is a
    /// subprocess and must not run on every snapshot.
    public func isSupported() async -> Bool {
        if let signedIn { return signedIn }
        guard executable != nil else { signedIn = false; return false }
        let ok = await signInProbe()
        signedIn = ok
        return ok
    }

    public func invalidate() {
        signedIn = nil
        models = nil
    }

    /// The models a dispatch may name, from `cursor-agent --list-models`.
    /// Empty when the CLI is missing or signed out — the list needs an
    /// account (`--list-models` "requires a signed-in CLI") — and after a
    /// probe that returned nothing, until `invalidate()`.
    public func models() async -> [String] {
        guard await isSupported() else { return [] }
        if let models { return models }
        let listed = await modelsProbe()
        models = listed
        return listed
    }

    /// Whether this monitor is carrying the conversation right now.
    public func hosts(_ sessionID: String) -> Bool { hosted[sessionID] != nil }

    /// Whether a turn is running on a hosted conversation.
    public func isRunning(_ sessionID: String) -> Bool { hosted[sessionID]?.running == true }

    // MARK: - Dispatch

    /// Start a conversation in `cwd` and give it its first prompt. Returns once
    /// the prompt has been accepted; the turn itself reports through the store.
    public func dispatch(_ request: DispatchRequest) async -> DispatchOutcome {
        guard !stopping else { return .unavailable("The Cursor host is shutting down") }
        guard request.agent == .cursor else { return .unsupported("This host only starts Cursor sessions") }
        guard executable != nil else {
            return .unavailable("The Cursor CLI (cursor-agent) is not installed on this Mac")
        }
        guard await isSupported() else {
            return .unavailable("The Cursor CLI is not signed in — run `cursor-agent login` on this Mac")
        }
        let options: CursorLaunchOptions
        switch CursorLaunchOptions.from(request) {
        case .success(let parsed): options = parsed
        case .failure(let why): return .rejected(why.message)
        }
        let client: CursorACPClient
        do { client = try spawn(CursorACPLaunch(cwd: request.cwd, options: options)) } catch {
            return .unavailable("Couldn't start cursor-agent: \(error)")
        }
        let preparationID = UUID().uuidString
        preparing[preparationID] = client
        defer { preparing[preparationID] = nil }
        wire(client)
        client.start()
        do {
            let hello = try await client.request("initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "vibebuddy", "version": "1"],
            ])
            let version = (hello["protocolVersion"] as? NSNumber)?.intValue
            guard version == 1 else {
                client.close()
                await store.recordSourceSignal(agent: .cursor, source: .acp, health: .unknownVersion, at: Date())
                return .unavailable("cursor-agent speaks ACP version \(version.map(String.init) ?? "?"), not 1")
            }
            // The CLI advertises `cursor_login`; an already signed-in CLI
            // answers at once, a signed-out one refuses and says so.
            do { _ = try await client.request("authenticate", params: ["methodId": "cursor_login"]) } catch {
                client.close()
                signedIn = nil
                return .unavailable("The Cursor CLI is not signed in — run `cursor-agent login` on this Mac")
            }
            let created = try await client.request("session/new", params: ["cwd": request.cwd, "mcpServers": []])
            guard let sessionID = created["sessionId"] as? String, !sessionID.isEmpty else {
                client.close()
                return .unavailable("session/new returned no session id")
            }
            guard !stopping else { client.close(); return .unavailable("The Cursor host is shutting down") }
            if let recoveryDirectory {
                let actualCwd = created["cwd"] as? String
                let record = CursorACPRecovery(sessionID: sessionID, cwd: actualCwd ?? request.cwd,
                    options: options, createdAt: Date(), origin: "vibebuddy-acp",
                    unavailable: options.worktree && actualCwd == nil ? "Cursor did not report the created worktree path; recovery is unavailable." : nil)
                let lease = try CursorACPLease(directory: recoveryDirectory, record: record)
                try client.retainLease(lease)
                try record.save(in: recoveryDirectory)
                recoveries[sessionID] = record
                await store.registerACPRecovery(sessionID: sessionID, cwd: record.cwd, model: options.model, unavailable: record.unavailable, updatedAt: record.createdAt)
            }
            hosted[sessionID] = Hosted(client: client, cwd: request.cwd)
            client.enableUpdates()
            await store.setACPHosted(sessionID: sessionID, true)
            let now = Date()
            // The chosen model names the row from the start; ACP's updates
            // never say which model answers.
            await store.ingest(HookEvent(kind: .sessionStart, sessionID: sessionID, agent: .cursor,
                                         cwd: request.cwd, sessionName: request.name,
                                         model: options.model, observationSource: .acp, timestamp: now))
            await store.recordSourceSignal(agent: .cursor, source: .acp, health: .healthy, at: now)
            startTurn(sessionID: sessionID, text: request.prompt)
            return .started(sessionID: sessionID)
        } catch {
            client.close()
            await store.recordSourceSignal(agent: .cursor, source: .acp, health: .sourceUnreadable, at: Date())
            return .unavailable("cursor-agent did not accept the session: \(error)")
        }
    }

    // MARK: - Actions

    /// Continue a hosted conversation that is idle. False when it is running
    /// (a supplement belongs in the follow-up queue) or not hosted here.
    public func prompt(sessionID: String, text: String) async -> Bool {
        guard await restore(sessionID), let entry = hosted[sessionID], !entry.running, !entry.finishing, !entry.client.isClosed else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        startTurn(sessionID: sessionID, text: trimmed)
        return true
    }

    /// End the running turn. One notification, no retry: ACP promises the
    /// prompt returns `cancelled` once everything has been aborted, and that
    /// ending is marked as the user's.
    public func cancel(sessionID: String) async -> CodexAppServerMonitor.InterruptOutcome {
        guard var entry = hosted[sessionID] else {
            return .notSent(String(localized: "This Mac isn't running this Cursor task."))
        }
        guard entry.running else {
            return .notSent(String(localized: "This task has already finished."))
        }
        guard !entry.client.isClosed else {
            return .notSent(String(localized: "The Cursor CLI behind this task has exited."))
        }
        entry.stopRequestedAt = Date()
        hosted[sessionID] = entry
        entry.client.notify("session/cancel", params: ["sessionId": sessionID])
        await followups.cancel(conversationID: sessionID)
        guard hosted[sessionID]?.client === entry.client, hosted[sessionID]?.turnID == entry.turnID else { return .sent }
        // The protocol requires every open permission request to be answered
        // `cancelled` once the turn is; the cards come down with them.
        await withdrawOpenRequests(sessionID: sessionID, expectedClient: entry.client, expectedTurnID: entry.turnID)
        return .sent
    }

    /// End every hosted process. Called when the daemon shuts down.
    public func shutdown() async {
        stopping = true
        for client in preparing.values { client.close() }
        preparing = [:]
        for (sessionID, entry) in hosted {
            await followups.cancel(conversationID: sessionID)
            await withdrawOpenRequests(sessionID: sessionID, expectedClient: entry.client, expectedTurnID: entry.turnID)
            entry.client.close()
            await store.setACPHosted(sessionID: sessionID, false)
        }
        hosted = [:]
    }

    // MARK: - Turns

    private func startTurn(sessionID: String, text: String) {
        guard var entry = hosted[sessionID] else { return }
        entry.running = true
        entry.turnID = UUID()
        if var record = recoveries[sessionID], let recoveryDirectory {
            record.updatedAt = Date()
            try? record.save(in: recoveryDirectory)
            recoveries[sessionID] = record
        }
        entry.text = ""
        entry.tools = [:]
        entry.stopRequestedAt = nil
        hosted[sessionID] = entry
        let client = entry.client
        Task { [weak self] in
            guard let self else { return }
            let now = Date()
            await self.store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: sessionID, agent: .cursor,
                                              cwd: entry.cwd, message: String(text.prefix(220)),
                                              observationSource: .acp, timestamp: now))
            var stopReason = "error"
            var failure: String?
            do {
                let result = try await client.request("session/prompt", params: [
                    "sessionId": sessionID,
                    "prompt": [["type": "text", "text": text]],
                ], timeout: nil)
                stopReason = (result["stopReason"] as? String) ?? "end_turn"
            } catch CursorACPClient.ClientError.rpc(_, let message) {
                failure = message
            } catch {
                failure = "the Cursor CLI exited before the turn ended"
            }
            await self.turnEnded(sessionID: sessionID, client: client, stopReason: stopReason, failure: failure)
        }
    }

    private func turnEnded(sessionID: String, client: CursorACPClient, stopReason: String, failure: String?) async {
        guard var entry = hosted[sessionID], entry.client === client else { return }
        // The prompt reply fixes this turn's outcome before cleanup yields.
        // No cancel or next prompt can change a turn that is already ending.
        entry.running = false
        entry.finishing = true
        hosted[sessionID] = entry
        await withdrawOpenRequests(sessionID: sessionID, expectedClient: client, expectedTurnID: entry.turnID)
        entry.openApprovals = [:]
        entry.openQuestions = [:]
        let now = Date()
        let asked = entry.stopRequestedAt != nil
        let cancelled = stopReason == "cancelled" || asked
        let succeeded = failure == nil && stopReason == "end_turn"
        let message: String?
        switch (failure, stopReason) {
        case (let text?, _): message = "Turn failed: \(text)"
        case (nil, "cancelled"): message = "Turn stopped"
        case (nil, "end_turn"): message = entry.text.isEmpty ? nil : String(entry.text.suffix(220))
        case (nil, "refusal"): message = "Cursor refused to continue"
        case (nil, "max_tokens"): message = "Turn hit the token limit"
        case (nil, "max_turn_requests"): message = "Turn hit the request limit"
        default: message = "Turn ended: \(stopReason)"
        }
        guard hosted[sessionID]?.client === client, hosted[sessionID]?.turnID == entry.turnID else { return }
        entry.finishing = false
        hosted[sessionID] = entry
        // A failed ending carries `toolError` as well as its wording, so the
        // stuck cue does not hang on the failure heuristic recognising a phrase.
        let ending = HookEvent(kind: .stop, sessionID: sessionID, agent: .cursor, cwd: entry.cwd,
                               message: message, observationSource: .acp,
                               toolError: !cancelled && !succeeded, timestamp: now,
                               completionText: succeeded && !entry.text.isEmpty ? entry.text : nil,
                               completionSucceeded: cancelled ? false : succeeded)
        await store.ingest(cancelled ? ending.markingUserStop() : ending)
        guard hosted[sessionID]?.client === client, hosted[sessionID]?.turnID == entry.turnID else { return }
        if cancelled || entry.client.isClosed { await followups.cancel(conversationID: sessionID) }
        if entry.client.isClosed {
            guard hosted[sessionID]?.client === client, hosted[sessionID]?.turnID == entry.turnID else { return }
            hosted[sessionID] = nil
            await store.setACPHosted(sessionID: sessionID, false)
            await store.recordSourceSignal(agent: .cursor, source: .acp, health: .temporarilySilent, at: now)
            return
        }
        // A supplement the phone queued while the turn ran goes out now, as
        // the next prompt — the same moment the hooks' `stop` would have
        // handed it to Cursor.
        if !cancelled, let next = await followups.take(conversationID: sessionID, now: now) {
            guard hosted[sessionID]?.client === client, hosted[sessionID]?.turnID == entry.turnID else { return }
            await store.noteCursorFollowupHandoff(sessionID: sessionID, loopCount: nil, source: .acp, at: now)
            guard hosted[sessionID]?.client === client, hosted[sessionID]?.turnID == entry.turnID else { return }
            startTurn(sessionID: sessionID, text: next)
        }
    }

    // MARK: - Incoming

    /// JSON-RPC params are `[String: Any]`, which Swift cannot prove Sendable;
    /// they are parsed fresh from one line and handed to exactly one task, so
    /// the hop onto the actor is the only place they cross an isolation line.
    private struct Payload: @unchecked Sendable { let value: [String: Any]? }

    private func wire(_ client: CursorACPClient) {
        client.onNotification = { [weak self, weak client] method, params in
            guard let self, let client else { return }
            let payload = Payload(value: params)
            await self.handleNotification(method: method, params: payload.value, client: client)
        }
        client.onRequest = { [weak self, weak client] id, method, params in
            guard let self, let client else { return }
            let payload = Payload(value: params)
            Task { await self.handleRequest(id: id, method: method, params: payload.value, client: client) }
        }
        client.onClose = { [weak self, weak client] in
            guard let self, let client else { return }
            Task { await self.clientClosed(client) }
        }
    }

    private func clientClosed(_ client: CursorACPClient) async {
        for (sessionID, entry) in hosted where entry.client === client {
            await followups.cancel(conversationID: sessionID)
            guard hosted[sessionID]?.client === entry.client else { continue }
            await withdrawOpenRequests(sessionID: sessionID, expectedClient: entry.client, expectedTurnID: entry.turnID)
            guard hosted[sessionID]?.client === client else { continue }
            if hosted[sessionID]?.running == true || hosted[sessionID]?.finishing == true { continue } // `turnEnded` finishes the turn.
            hosted[sessionID] = nil
            await store.setACPHosted(sessionID: sessionID, false)
        }
    }

    private func handleNotification(method: String, params: [String: Any]?, client: CursorACPClient) async {
        guard method == "session/update",
              let sessionID = params?["sessionId"] as? String,
              var entry = hosted[sessionID], entry.client === client,
              let update = params?["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else { return }
        let now = Date()
        switch kind {
        case "agent_message_chunk":
            if let text = (update["content"] as? [String: Any])?["text"] as? String {
                entry.text = String((entry.text + text).suffix(4000))
                hosted[sessionID] = entry
            }
        case "tool_call", "tool_call_update":
            // Updates are partial; Cursor sends the path separately from the
            // initial call and later sends only its terminal status. Preserve
            // the provider ID verbatim (real IDs can contain a newline).
            guard let callID = update["toolCallId"] as? String, !callID.isEmpty else { return }
            let old = entry.tools[callID]
            let name = update["kind"] != nil
                ? Self.canonicalTool(kind: update["kind"] as? String, title: update["title"] as? String)
                : old?.tool ?? Self.canonicalTool(kind: nil, title: update["title"] as? String)
            let input = update["rawInput"] as? [String: Any] ?? [:]
            let locations = (update["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            let paths = locations + [input["path"] as? String, input["file_path"] as? String].compactMap { $0 }
            let status = update["status"] as? String
            let result: ToolCallRecord.Result = status == "completed" ? .succeeded
                : status == "failed" ? .failed : old?.result ?? .unconfirmed
            let record = ToolCallRecord(id: callID, tool: name,
                command: input["command"] as? String ?? old?.command,
                files: (old?.files ?? []) + paths, result: result, observedAt: now, source: "acp",
                coverage: "ACP-reported tool status; output and edit volume not retained")
            if old == nil, entry.tools.count >= 100,
               let oldest = entry.tools.min(by: { $0.value.observedAt < $1.value.observedAt })?.key {
                entry.tools[oldest] = nil
            }
            entry.tools[callID] = record
            hosted[sessionID] = entry
            var event = HookEvent(kind: result == .unconfirmed ? .preToolUse : .postToolUse,
                sessionID: sessionID, agent: .cursor, cwd: entry.cwd, toolName: name,
                message: update["title"] as? String, observationSource: .acp,
                toolError: result == .failed, timestamp: now)
            event.toolCall = record
            await store.ingest(event)
        case "usage_update":
            guard let used = (update["used"] as? NSNumber)?.intValue,
                  let size = (update["size"] as? NSNumber)?.intValue else { return }
            await store.ingest(HookEvent(kind: .sessionMetadataChanged, sessionID: sessionID, agent: .cursor,
                                         cwd: entry.cwd, observationSource: .acp, timestamp: now,
                                         enrichment: TranscriptInfo(contextTokens: used, contextWindow: size)))
        default:
            // plan, agent_thought_chunk, user_message_chunk (replay), config
            // changes: understood, and none of them moves the three states.
            return
        }
    }

    private func handleRequest(id: JSONRPCID, method: String, params: [String: Any]?, client: CursorACPClient) async {
        let sessionID = (params?["sessionId"] as? String)
            ?? hosted.first(where: { $0.value.client === client })?.key
        guard let sessionID, hosted[sessionID]?.client === client else {
            client.respondError(id: id, code: -32602, message: "unknown session")
            return
        }
        guard let current = hosted[sessionID], current.running, !current.finishing, current.stopRequestedAt == nil else {
            client.respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
            return
        }
        switch method {
        case "session/request_permission":
            await permission(id: id, sessionID: sessionID, params: params ?? [:], client: client)
        case "cursor/ask_question":
            await askQuestion(id: id, sessionID: sessionID, params: params ?? [:], client: client)
        case "cursor/create_plan":
            await createPlan(id: id, sessionID: sessionID, params: params ?? [:], client: client)
        case "cursor/update_todos", "cursor/task", "cursor/generate_image":
            // Cursor documents these as notifications, not client-executed
            // requests. An unexpected request must not invent execution or
            // image-generation outcomes. Notification handling remains unknown
            // until captured evidence establishes the actual event shape.
            client.respondError(id: id, code: -32601, message: "This Cursor extension is notification-only; no execution outcome is available")
        default:
            // `fs/*` and `terminal/*` were declared unsupported at initialize;
            // anything else is a method this client does not know.
            client.respondError(id: id, code: -32601, message: "method not supported by vibebuddy: \(method)")
        }
    }

    // MARK: - Permission

    private func permission(id: JSONRPCID, sessionID: String, params: [String: Any], client: CursorACPClient) async {
        guard let entry = hosted[sessionID] else { return }
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let callID = toolCall["toolCallId"] as? String ?? ""
        let title = toolCall["title"] as? String
        let tool = entry.tools[callID]?.tool
            ?? Self.canonicalTool(kind: toolCall["kind"] as? String, title: title)
        var input = CursorToolVocabulary.canonicalInput(toolCall["rawInput"] as? [String: Any] ?? [:])
        if tool == "Bash", input["command"] == nil, let title { input["command"] = title }
        let options = Self.permissionOptions(params["options"])

        // Native deny always wins (ADR-0010); an exact vibebuddy always-allow
        // or a session-wide allow answers without a card.
        let r = rules(.cursor)
        if PermissionMatcher.decide(tool: tool, input: input, allow: [], deny: r.deny) == .deny {
            client.respond(id: id, result: Self.selected(options.reject))
            return
        }
        let storeRules = await allowStore.all()
        if await sessionAllow.contains(sessionID)
            || storeRules.contains(where: { AllowRule.matchesExactly($0, tool: tool, input: input) }) {
            client.respond(id: id, result: Self.selected(options.allow))
            return
        }

        let approvalID = makeID()
        let details = ApprovalDetails.from(tool: tool, input: input)
        await approvalContext.set(id: approvalID, sessionID: sessionID,
                                  rule: AllowRule.forApproval(tool: tool, input: input))
        await approvals.prepare(id: approvalID)
        if var live = hosted[sessionID] { live.openApprovals[approvalID] = id; hosted[sessionID] = live }
        await store.beginApproval(sessionID: sessionID,
            PendingApproval(id: approvalID, tool: tool,
                            commandPreview: details.commandPreview.isEmpty ? (title ?? tool) : details.commandPreview,
                            command: details.command, filePath: details.filePath,
                            oldText: details.oldText, newText: details.newText), at: Date(), source: .acp)
        let outcome = await approvals.wait(id: approvalID, timeout: Self.decisionTimeout)
        guard var live = hosted[sessionID], live.openApprovals.removeValue(forKey: approvalID) != nil else {
            return   // Withdrawn by a cancel, which already answered the agent.
        }
        hosted[sessionID] = live
        await store.endApproval(sessionID: sessionID, approvalID: approvalID, at: Date(), source: .acp)
        switch outcome {
        case .allow: client.respond(id: id, result: Self.selected(options.allow))
        case .deny: client.respond(id: id, result: Self.selected(options.reject))
        case .pass: client.respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
        }
    }

    // MARK: - Questions and plans

    private func askQuestion(id: JSONRPCID, sessionID: String, params: [String: Any], client: CursorACPClient) async {
        // Cursor's ACP question is the same shape as its `AskQuestion` tool
        // input, so the hook path's adapter reads it unchanged.
        guard let question = CursorAskQuestionInput.pendingQuestion(from: params, id: makeID()) else {
            client.respond(id: id, result: ["outcome": ["outcome": "skipped", "reason": "no questions"]])
            return
        }
        if var live = hosted[sessionID] { live.openQuestions[question.id] = id; hosted[sessionID] = live }
        await store.beginQuestion(sessionID: sessionID, question, at: Date(), source: .acp)
        let answers = await questions.wait(sessionID: sessionID, questionID: question.id, timeout: Self.decisionTimeout)
        guard var live = hosted[sessionID], live.openQuestions.removeValue(forKey: question.id) != nil else { return }
        hosted[sessionID] = live
        await store.endQuestion(sessionID: sessionID, questionID: question.id, at: Date(), source: .acp)
        guard let answers else {
            client.respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
            return
        }
        client.respond(id: id, result: Self.questionResponse(question: question, answers: answers))
    }

    private func createPlan(id: JSONRPCID, sessionID: String, params: [String: Any], client: CursorACPClient) async {
        let name = (params["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Self.planText(params)
        let options = [QuestionOption(id: "accept", label: "Accept"), QuestionOption(id: "reject", label: "Reject")]
        let item = QuestionItem(id: "plan", header: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Plan",
                                text: body,
                                options: options, multiSelect: false, allowsOther: false)
        let question = PendingQuestion(id: makeID(), prompt: item.text, options: options,
                                       questions: [item], isBlocking: true)
        if var live = hosted[sessionID] { live.openQuestions[question.id] = id; hosted[sessionID] = live }
        await store.beginQuestion(sessionID: sessionID, question, at: Date(), source: .acp)
        let answers = await questions.wait(sessionID: sessionID, questionID: question.id, timeout: Self.decisionTimeout)
        guard var live = hosted[sessionID], live.openQuestions.removeValue(forKey: question.id) != nil else { return }
        hosted[sessionID] = live
        await store.endQuestion(sessionID: sessionID, questionID: question.id, at: Date(), source: .acp)
        guard let answers else {
            client.respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
            return
        }
        let choices = answers["plan"] ?? answers.values.first ?? []
        let chosen = choices.joined(separator: " ")
        let accepted = choices.count == 1 && choices[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "accept"
        client.respond(id: id, result: ["outcome": accepted
            ? ["outcome": "accepted"]
            : ["outcome": "rejected", "reason": chosen.isEmpty ? "rejected from vibebuddy" : chosen]])
    }

    /// The plan capture contains an independent full markdown body and a
    /// short overview. Keep the body byte-for-byte inside the existing question
    /// text; single-question cards do not render the header, so include its name.
    static func planText(_ params: [String: Any]) -> String {
        func nonempty(_ value: Any?) -> String? {
            guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        let body = nonempty(params["plan"]) ?? nonempty(params["overview"]) ?? "Approve this plan?"
        var parts = [String]()
        if let name = nonempty(params["name"]) { parts.append(name) }
        parts.append(body)
        let todos = (params["todos"] as? [[String: Any]] ?? []).compactMap { todo -> String? in
            guard let content = nonempty(todo["content"]) else { return nil }
            let status = nonempty(todo["status"]) ?? "unknown"
            return "- [\(status)] \(content)"
        }
        if !todos.isEmpty { parts.append("Plan tasks (agent-reported)\n" + todos.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    private func withdrawOpenRequests(sessionID: String, expectedClient: CursorACPClient, expectedTurnID: UUID) async {
        guard var entry = hosted[sessionID], entry.client === expectedClient, entry.turnID == expectedTurnID else { return }
        let approvalsOpen = entry.openApprovals
        let questionsOpen = entry.openQuestions
        entry.openApprovals = [:]
        entry.openQuestions = [:]
        hosted[sessionID] = entry
        let now = Date()
        for (approvalID, rpcID) in approvalsOpen {
            entry.client.respond(id: rpcID, result: ["outcome": ["outcome": "cancelled"]])
            _ = await approvalContext.take(id: approvalID)
            await approvals.resolve(id: approvalID, with: .pass)
            await store.endApproval(sessionID: sessionID, approvalID: approvalID, at: now, source: .acp)
        }
        for (questionID, rpcID) in questionsOpen {
            entry.client.respond(id: rpcID, result: ["outcome": ["outcome": "cancelled"]])
            await questions.cancelExact(sessionID: sessionID, questionID: questionID)
            await store.endQuestion(sessionID: sessionID, questionID: questionID, at: now, source: .acp)
        }
    }

    // MARK: - Shapes

    /// ACP's `kind` is the reliable signal; Cursor's `title` is prose. The
    /// canonical names are the ones `PermissionMatcher` and the allow store
    /// already understand.
    static func canonicalTool(kind: String?, title: String?) -> String {
        switch kind {
        case "execute": return "Bash"
        case "read": return "Read"
        case "edit": return "Edit"
        case "delete": return "Delete"
        case "move": return "Move"
        case "search": return "Grep"
        case "fetch": return "WebFetch"
        case "think": return "Thinking"
        default:
            guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return "tool" }
            return CursorToolVocabulary.canonicalTool(title)
        }
    }

    struct PermissionOptions { var allow: String; var reject: String }

    /// Which `optionId` means allow-once and which reject-once. The ids are
    /// the agent's to choose; the `kind` says what they mean. Missing kinds
    /// fall back to the ids Cursor documents.
    static func permissionOptions(_ raw: Any?) -> PermissionOptions {
        let options = (raw as? [[String: Any]]) ?? []
        func find(kind: String, fallback: String) -> String {
            if let match = options.first(where: { ($0["kind"] as? String) == kind }),
               let id = match["optionId"] as? String { return id }
            if let match = options.first(where: { (($0["optionId"] as? String) ?? "") == fallback }),
               let id = match["optionId"] as? String { return id }
            return fallback
        }
        return PermissionOptions(allow: find(kind: "allow_once", fallback: "allow-once"),
                                 reject: find(kind: "reject_once", fallback: "reject-once"))
    }

    static func selected(_ optionID: String) -> [String: Any] {
        ["outcome": ["outcome": "selected", "optionId": optionID]]
    }

    /// The phone answers with option values (their labels); Cursor wants the
    /// option ids. Free text has no place in Cursor's schema, so a typed answer
    /// travels as the reason on a `skipped` outcome — the model still reads it.
    static func questionResponse(question: PendingQuestion, answers: QuestionAnswers) -> [String: Any] {
        var selected: [[String: Any]] = []
        var typed: [String] = []
        for item in question.items {
            let values = (answers[item.id] ?? []).filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            let ids = values.compactMap { value in
                item.options.first { $0.id == value || $0.value == value || $0.label == value }?.id
            }
            if ids.isEmpty { typed.append("\(item.text): \(values.joined(separator: ", "))") }
            else { selected.append(["questionId": item.id, "selectedOptionIds": ids]) }
        }
        if selected.isEmpty, !typed.isEmpty {
            return ["outcome": ["outcome": "skipped", "reason": "The user answered from vibebuddy: " + typed.joined(separator: "; ")]]
        }
        return ["outcome": ["outcome": "answered", "answers": selected]]
    }

}
