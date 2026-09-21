import Foundation
import VibeBuddyKit

/// Hosts Grok Build sessions over ACP and turns them into sessions the phone
/// and the Watch can fully act on (ADR-0030).
///
/// A Grok session in the terminal is reached through its hooks, which can
/// observe every event and *deny* a tool call but cannot approve one: Grok
/// documents a hook `allow` as "not blocked", and its own permission prompt has
/// no external answer channel. A `grok agent --no-leader stdio` process
/// vibebuddy spawns itself is the Grok analogue of the Cursor CLI over ACP
/// (ADR-0016, amendment 1): `session/request_permission`,
/// `_x.ai/ask_user_question`, `session/prompt` and `session/cancel` all travel
/// on one pipe, so the row carries `ControlChannel.acp`.
///
/// What the 2026-09-21 probes against grok 1.0.40 fixed:
///
/// - The ACP `sessionId` is the session directory name and the `sessionId` the
///   hooks report, so hooks and the session-directory enrichment describe the
///   same row; while the host carries it they only corroborate
///   (`SessionStore.acpOutranks`) and the `/approval` gate stays silent.
/// - Extension methods arrive with a leading underscore (`_x.ai/…`); the bare
///   spelling is "unknown ACP extension method". There is no interject
///   extension, so a supplement for a running turn waits in the follow-up
///   queue and goes out as the next prompt, exactly as it does for Cursor.
/// - A permission the phone denies ends the turn with `stopReason:
///   "cancelled"` (Grok files it under `StopCancelled/permission_rejected`).
///   That is an ending the user chose, not a failure, and not a stop either.
/// - The session's permission frequency is the user's own `[ui]
///   permission_mode`: `--permission-mode` and `_meta.yoloMode` on
///   `session/new` do not override an `always-approve` config. vibebuddy does
///   not change it; under always-approve no card ever appears, as in the TUI.
public struct GrokACPLaunch: Sendable, Equatable {
    public var cwd: String
    public var model: String?

    public init(cwd: String, model: String? = nil) {
        self.cwd = cwd
        self.model = model
    }

    /// `grok agent [-m MODEL] --no-leader stdio`. `--no-leader` keeps the
    /// process private even when the user has `[cli] use_leader` on: a
    /// leader-shared backend would answer to more than this host.
    public var arguments: [String] {
        var args = ["agent"]
        if let model, !model.isEmpty { args += ["-m", model] }
        return args + ["--no-leader", "stdio"]
    }

    /// Plain model ids only; anything else is refused before it becomes argv.
    struct InvalidModel: Error { let message: String }

    static func validModel(_ raw: String?) -> Result<String?, InvalidModel> {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .success(nil) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:"))
        guard raw.unicodeScalars.allSatisfy(allowed.contains), !raw.hasPrefix("-") else {
            return .failure(InvalidModel(message: "model must be a plain model id"))
        }
        return .success(raw)
    }
}

public actor GrokACPMonitor {
    /// ACP blocks the turn until it hears back; this bounds a turn nobody answers.
    public static let decisionTimeout: Duration = CursorACPMonitor.decisionTimeout

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
        var requests: [UUID: Task<Void, Never>] = [:]
        var contextWindow: Int?
        var model: String?
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
    private let spawn: @Sendable (GrokACPLaunch) throws -> CursorACPClient
    private let executable: URL?
    private let signInProbe: @Sendable () -> Bool
    private var hosted: [String: Hosted] = [:]
    private var preparing: [String: CursorACPClient] = [:]
    private var stopping = false

    public init(store: SessionStore,
                approvals: ApprovalRegistry,
                approvalContext: ApprovalContextStore,
                questions: QuestionRegistry,
                allowStore: VibeBuddyAllowStore,
                sessionAllow: SessionAllowList,
                followups: CursorFollowupQueue = CursorFollowupQueue(),
                rules: @escaping @Sendable (AgentKind) -> PermissionRules = { PermissionRules.load(for: $0) },
                makeID: @escaping @Sendable () -> String = { UUID().uuidString },
                executable: URL? = GrokUsageProvider.resolveGrokExecutable(),
                signInProbe: (@Sendable () -> Bool)? = nil,
                spawn: (@Sendable (GrokACPLaunch) throws -> CursorACPClient)? = nil) {
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
        // `cached_token` is the auth method the agent advertises when
        // `~/.grok/auth.json` holds a login; without the file `authenticate`
        // would open a browser flow this host cannot drive.
        self.signInProbe = signInProbe ?? {
            FileManager.default.fileExists(atPath: GrokHome.url.appendingPathComponent("auth.json").path)
        }
        let resolved = executable
        self.spawn = spawn ?? { launch in
            guard let resolved else { throw CursorACPClient.ClientError.closed }
            return try CursorACPClient.spawn(executable: resolved, arguments: launch.arguments, cwd: launch.cwd)
        }
    }

    // MARK: - Availability

    /// Installed and signed in. Both are file checks, so this is cheap enough
    /// to answer on every snapshot.
    public func isSupported() -> Bool {
        executable != nil && signInProbe()
    }

    public func hosts(_ sessionID: String) -> Bool { hosted[sessionID] != nil }
    public func owns(_ sessionID: String) -> Bool { hosted[sessionID] != nil }
    public func isRunning(_ sessionID: String) -> Bool { hosted[sessionID]?.running == true }

    // MARK: - Dispatch

    public func dispatch(_ request: DispatchRequest) async -> DispatchOutcome {
        guard !stopping else { return .unavailable("The Grok host is shutting down") }
        guard request.agent == .grok else { return .unsupported("This host only starts Grok Build sessions") }
        guard executable != nil else { return .unavailable("Grok Build (grok) is not installed on this Mac") }
        guard signInProbe() else { return .unavailable("Grok Build is not signed in — run `grok` on this Mac and sign in") }
        let model: String?
        switch GrokACPLaunch.validModel(request.model) {
        case .success(let value): model = value
        case .failure(let why): return .rejected(why.message)
        }
        let client: CursorACPClient
        do { client = try spawn(GrokACPLaunch(cwd: request.cwd, model: model)) } catch {
            return .unavailable("Couldn't start grok: \(error)")
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
                await store.recordSourceSignal(agent: .grok, source: .acp, health: .unknownVersion, at: Date())
                return .unavailable("grok speaks ACP version \(version.map(String.init) ?? "?"), not 1")
            }
            let methods = (hello["authMethods"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            guard methods.contains("cached_token") else {
                client.close()
                return .unavailable("Grok Build is not signed in — run `grok` on this Mac and sign in")
            }
            do { _ = try await client.request("authenticate", params: ["methodId": "cached_token"]) } catch {
                client.close()
                return .unavailable("Grok Build's saved login was refused — run `grok` on this Mac and sign in again")
            }
            let created = try await client.request("session/new", params: ["cwd": request.cwd, "mcpServers": []])
            guard let sessionID = created["sessionId"] as? String, !sessionID.isEmpty else {
                client.close()
                return .unavailable("session/new returned no session id")
            }
            guard !stopping else { client.close(); return .unavailable("The Grok host is shutting down") }
            let models = Self.models(created["models"] ?? (hello["_meta"] as? [String: Any])?["modelState"])
            var entry = Hosted(client: client, cwd: request.cwd)
            entry.model = model ?? models.current
            entry.contextWindow = entry.model.flatMap { models.windows[$0] }
            hosted[sessionID] = entry
            client.enableUpdates()
            await store.setACPHosted(sessionID: sessionID, true)
            let now = Date()
            await store.ingest(HookEvent(kind: .sessionStart, sessionID: sessionID, agent: .grok,
                                         cwd: request.cwd, sessionName: request.name,
                                         model: entry.model, observationSource: .acp, timestamp: now))
            await store.recordSourceSignal(agent: .grok, source: .acp, health: .healthy, at: now)
            startTurn(sessionID: sessionID, text: request.prompt)
            return .started(sessionID: sessionID)
        } catch {
            client.close()
            await store.recordSourceSignal(agent: .grok, source: .acp, health: .sourceUnreadable, at: Date())
            return .unavailable("grok did not accept the session: \(error)")
        }
    }

    // MARK: - Actions

    /// Continue an idle hosted session. False when it is running (a supplement
    /// belongs in the follow-up queue) or not hosted here.
    public func prompt(sessionID: String, text: String) async -> Bool {
        guard let entry = hosted[sessionID], !entry.running, !entry.finishing, !entry.client.isClosed else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        startTurn(sessionID: sessionID, text: trimmed)
        return true
    }

    /// A supplement for a running turn: held until the prompt returns, then
    /// sent as the next one. False when nothing is running here.
    public func queueFollowup(sessionID: String, text: String) async -> Bool {
        guard let entry = hosted[sessionID], entry.running, !entry.client.isClosed else { return false }
        return await followups.queue(conversationID: sessionID, text: text) != nil
    }

    public func cancel(sessionID: String) async -> CodexAppServerMonitor.InterruptOutcome {
        guard var entry = hosted[sessionID] else {
            return .notSent(String(localized: "This Mac isn't running this Grok task."))
        }
        guard entry.running else {
            return .notSent(String(localized: "This task has already finished."))
        }
        guard !entry.client.isClosed else {
            return .notSent(String(localized: "The grok process behind this task has exited."))
        }
        entry.stopRequestedAt = Date()
        for task in entry.requests.values { task.cancel() }
        entry.requests = [:]
        hosted[sessionID] = entry
        entry.client.notify("session/cancel", params: ["sessionId": sessionID])
        await followups.cancel(conversationID: sessionID)
        guard hosted[sessionID]?.client === entry.client, hosted[sessionID]?.turnID == entry.turnID else { return .sent }
        await withdrawOpenRequests(sessionID: sessionID, expectedClient: entry.client, expectedTurnID: entry.turnID)
        return .sent
    }

    public func shutdown() async {
        stopping = true
        for client in preparing.values { client.close() }
        preparing = [:]
        for (sessionID, entry) in hosted {
            for task in entry.requests.values { task.cancel() }
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
        entry.text = ""
        entry.tools = [:]
        entry.stopRequestedAt = nil
        hosted[sessionID] = entry
        let client = entry.client
        Task { [weak self] in
            guard let self else { return }
            let now = Date()
            await self.store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: sessionID, agent: .grok,
                                              cwd: entry.cwd, message: String(text.prefix(220)),
                                              observationSource: .acp, timestamp: now, turnID: entry.turnID.uuidString))
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
                failure = "grok exited before the turn ended"
            }
            await self.turnEnded(sessionID: sessionID, client: client, stopReason: stopReason, failure: failure)
        }
    }

    private func turnEnded(sessionID: String, client: CursorACPClient, stopReason: String, failure: String?) async {
        guard var entry = hosted[sessionID], entry.client === client else { return }
        entry.running = false
        entry.finishing = true
        for task in entry.requests.values { task.cancel() }
        entry.requests = [:]
        hosted[sessionID] = entry
        await withdrawOpenRequests(sessionID: sessionID, expectedClient: client, expectedTurnID: entry.turnID)
        entry.openApprovals = [:]
        entry.openQuestions = [:]
        let now = Date()
        let asked = entry.stopRequestedAt != nil
        // Grok answers a denied permission and a user interrupt with the same
        // `cancelled`; only the one this host sent is the user's stop.
        let cancelled = stopReason == "cancelled"
        let succeeded = failure == nil && stopReason == "end_turn"
        let message: String?
        switch (failure, stopReason) {
        case (let text?, _): message = "Turn failed: \(text)"
        case (nil, "cancelled"): message = asked ? "Turn stopped" : "Turn ended after a denied request"
        case (nil, "end_turn"): message = entry.text.isEmpty ? nil : String(entry.text.suffix(220))
        case (nil, "refusal"): message = "Grok refused to continue"
        case (nil, "max_tokens"): message = "Turn hit the token limit"
        case (nil, "max_turn_requests"): message = "Turn hit the request limit"
        default: message = "Turn ended: \(stopReason)"
        }
        guard hosted[sessionID]?.client === client, hosted[sessionID]?.turnID == entry.turnID else { return }
        entry.finishing = false
        hosted[sessionID] = entry
        let ending = HookEvent(kind: .stop, sessionID: sessionID, agent: .grok, cwd: entry.cwd,
                               message: message, observationSource: .acp,
                               toolError: !cancelled && !succeeded, timestamp: now, turnID: entry.turnID.uuidString,
                               completionText: succeeded && !entry.text.isEmpty ? entry.text : nil,
                               // A denied request ends the turn without a verdict on the
                               // work: neither a success to summarise nor a failure to cue.
                               completionSucceeded: asked ? false : (cancelled ? nil : succeeded))
        await store.ingest(asked ? ending.markingUserStop() : ending)
        guard hosted[sessionID]?.client === client, hosted[sessionID]?.turnID == entry.turnID else { return }
        if asked || entry.client.isClosed { await followups.cancel(conversationID: sessionID) }
        if entry.client.isClosed {
            guard hosted[sessionID]?.client === client, hosted[sessionID]?.turnID == entry.turnID else { return }
            hosted[sessionID] = nil
            await store.setACPHosted(sessionID: sessionID, false)
            await store.recordSourceSignal(agent: .grok, source: .acp, health: .temporarilySilent, at: now)
            return
        }
        if !asked, let next = await followups.take(conversationID: sessionID, now: now) {
            guard hosted[sessionID]?.client === client, hosted[sessionID]?.turnID == entry.turnID else { return }
            await store.noteCursorFollowupHandoff(sessionID: sessionID, loopCount: nil, source: .acp, at: now)
            guard hosted[sessionID]?.client === client, hosted[sessionID]?.turnID == entry.turnID else { return }
            startTurn(sessionID: sessionID, text: next)
        }
    }

    // MARK: - Incoming

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
            Task { await self.receiveRequest(id: id, method: method, params: payload.value, client: client) }
        }
        client.onClose = { [weak self, weak client] in
            guard let self, let client else { return }
            Task { await self.clientClosed(client) }
        }
    }

    private func clientClosed(_ client: CursorACPClient) async {
        for (sessionID, entry) in hosted where entry.client === client {
            for task in entry.requests.values { task.cancel() }
            await followups.cancel(conversationID: sessionID)
            guard hosted[sessionID]?.client === entry.client else { continue }
            await withdrawOpenRequests(sessionID: sessionID, expectedClient: entry.client, expectedTurnID: entry.turnID)
            guard hosted[sessionID]?.client === client else { continue }
            if hosted[sessionID]?.running == true || hosted[sessionID]?.finishing == true { continue }
            hosted[sessionID] = nil
            await store.setACPHosted(sessionID: sessionID, false)
        }
    }

    private func handleNotification(method: String, params: [String: Any]?, client: CursorACPClient) async {
        guard let sessionID = params?["sessionId"] as? String,
              var entry = hosted[sessionID], entry.client === client,
              let update = params?["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else { return }
        let now = Date()
        switch (method, kind) {
        case ("session/update", "agent_message_chunk"):
            if let text = (update["content"] as? [String: Any])?["text"] as? String {
                entry.text = String((entry.text + text).suffix(4000))
                hosted[sessionID] = entry
            }
        case ("session/update", "tool_call"), ("session/update", "tool_call_update"):
            guard let callID = update["toolCallId"] as? String, !callID.isEmpty else { return }
            // The question tool is a wait, reported through its own request;
            // as a tool row it would only say "Ask User" over the card.
            if Self.toolMeta(update)?["kind"] as? String == "ask_user" { return }
            let old = entry.tools[callID]
            let name = Self.canonicalTool(update) ?? old?.tool ?? "tool"
            let input = GrokToolVocabulary.canonicalInput(update["rawInput"] as? [String: Any] ?? [:])
            let locations = (update["locations"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            let paths = locations + [input["file_path"] as? String].compactMap { $0 }
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
                sessionID: sessionID, agent: .grok, cwd: entry.cwd, toolName: name,
                message: update["title"] as? String, observationSource: .acp,
                toolError: result == .failed, timestamp: now)
            event.toolCall = record
            await store.ingest(event)
        case ("session/update", "session_info_update"):
            guard let title = (update["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return }
            await store.ingest(HookEvent(kind: .sessionMetadataChanged, sessionID: sessionID, agent: .grok,
                                         cwd: entry.cwd, sessionName: title, observationSource: .acp, timestamp: now))
        case ("_x.ai/session_notification", "turn_completed"):
            // `usage.totalTokens` is the prompt the last model call carried, so
            // it is the live context figure; the window comes from the model list.
            guard let total = ((update["usage"] as? [String: Any])?["totalTokens"] as? NSNumber)?.intValue else { return }
            var info = TranscriptInfo()
            info.contextTokens = total
            info.contextWindow = entry.contextWindow
            await store.ingest(HookEvent(kind: .sessionMetadataChanged, sessionID: sessionID, agent: .grok,
                                         cwd: entry.cwd, observationSource: .acp, timestamp: now, enrichment: info))
        default:
            // thought chunks, plan, hook_execution, pending_interaction and
            // the rest: understood, and none of them moves the three states.
            return
        }
    }

    private func receiveRequest(id: JSONRPCID, method: String, params: [String: Any]?, client: CursorACPClient) {
        let sessionID = (params?["sessionId"] as? String)
            ?? hosted.first(where: { $0.value.client === client })?.key
        guard let sessionID, var entry = hosted[sessionID], entry.client === client else {
            client.respondError(id: id, code: -32602, message: "unknown session")
            return
        }
        let requestID = UUID()
        let turnID = entry.turnID
        let payload = Payload(value: params)
        entry.requests[requestID] = Task {
            await self.handleRequest(id: id, method: method, params: payload.value,
                                     client: client, sessionID: sessionID, turnID: turnID)
            self.hosted[sessionID]?.requests[requestID] = nil
        }
        hosted[sessionID] = entry
    }

    private func handleRequest(id: JSONRPCID, method: String, params: [String: Any]?,
                               client: CursorACPClient, sessionID: String, turnID: UUID) async {
        guard !Task.isCancelled, !stopping, !client.isClosed,
              let current = hosted[sessionID], current.client === client,
              current.turnID == turnID, current.running, !current.finishing, current.stopRequestedAt == nil else {
            client.respond(id: id, result: Self.cancelledOutcome(for: method))
            return
        }
        switch method {
        case "session/request_permission":
            await permission(id: id, sessionID: sessionID, params: params ?? [:], client: client)
        case "_x.ai/ask_user_question", "x.ai/ask_user_question":
            await askQuestion(id: id, sessionID: sessionID, params: params ?? [:], client: client)
        default:
            // `fs/*` and `terminal/*` were declared unsupported at initialize;
            // any other extension is one this client does not speak.
            client.respondError(id: id, code: -32601, message: "method not supported by vibebuddy: \(method)")
        }
    }

    // MARK: - Permission

    private func permission(id: JSONRPCID, sessionID: String, params: [String: Any], client: CursorACPClient) async {
        guard let entry = hosted[sessionID] else { return }
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let callID = toolCall["toolCallId"] as? String ?? ""
        let title = toolCall["title"] as? String
        let tool = Self.canonicalTool(toolCall) ?? entry.tools[callID]?.tool ?? "tool"
        var input = GrokToolVocabulary.canonicalInput(toolCall["rawInput"] as? [String: Any] ?? [:])
        if tool == "Bash", input["command"] == nil, let title { input["command"] = title }
        let options = CursorACPMonitor.permissionOptions(params["options"])

        // Native deny always wins (ADR-0010): Grok's own `[permission]` deny
        // list and Claude's ride in the same rule set. An exact vibebuddy
        // always-allow or a session-wide allow answers without a card.
        let r = rules(.grok)
        if PermissionMatcher.decide(tool: tool, input: input, allow: [], deny: r.deny) == .deny {
            client.respond(id: id, result: CursorACPMonitor.selected(options.reject))
            return
        }
        let storeRules = await allowStore.all()
        let sessionAllowed = await sessionAllow.contains(sessionID)
        guard !Task.isCancelled else {
            client.respond(id: id, result: Self.cancelledOutcome(for: "session/request_permission"))
            return
        }
        if sessionAllowed || storeRules.contains(where: { AllowRule.matchesExactly($0, tool: tool, input: input) }) {
            client.respond(id: id, result: CursorACPMonitor.selected(options.allow))
            return
        }

        let approvalID = makeID()
        let details = ApprovalDetails.from(tool: tool, input: input)
        await approvalContext.set(id: approvalID, sessionID: sessionID,
                                  rule: AllowRule.forApproval(tool: tool, input: input))
        await approvals.prepare(id: approvalID)
        guard !Task.isCancelled else {
            _ = await approvalContext.take(id: approvalID)
            _ = await approvals.resolve(id: approvalID, with: .pass)
            _ = await approvals.wait(id: approvalID, timeout: .zero)
            client.respond(id: id, result: Self.cancelledOutcome(for: "session/request_permission"))
            return
        }
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
        case .allow: client.respond(id: id, result: CursorACPMonitor.selected(options.allow))
        case .deny: client.respond(id: id, result: CursorACPMonitor.selected(options.reject))
        case .pass: client.respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
        }
    }

    // MARK: - Questions

    private func askQuestion(id: JSONRPCID, sessionID: String, params: [String: Any], client: CursorACPClient) async {
        // Grok's question is Claude's `AskUserQuestion` input — `question`,
        // `options[].label/description`, `multiSelect` — which the Cursor
        // adapter already reads.
        guard let question = CursorAskQuestionInput.pendingQuestion(from: params, id: makeID()) else {
            client.respond(id: id, result: Self.questionCancelled)
            return
        }
        guard !Task.isCancelled else {
            client.respond(id: id, result: Self.questionCancelled)
            return
        }
        if var live = hosted[sessionID] { live.openQuestions[question.id] = id; hosted[sessionID] = live }
        await store.beginQuestion(sessionID: sessionID, question, at: Date(), source: .acp)
        let answers = await questions.wait(sessionID: sessionID, questionID: question.id, timeout: Self.decisionTimeout)
        guard var live = hosted[sessionID], live.openQuestions.removeValue(forKey: question.id) != nil else { return }
        hosted[sessionID] = live
        await store.endQuestion(sessionID: sessionID, questionID: question.id, at: Date(), source: .acp)
        guard let answers else {
            client.respond(id: id, result: Self.questionCancelled)
            return
        }
        client.respond(id: id, result: Self.questionResponse(question: question, answers: answers))
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
            entry.client.respond(id: rpcID, result: Self.questionCancelled)
            await questions.cancelExact(sessionID: sessionID, questionID: questionID)
            await store.endQuestion(sessionID: sessionID, questionID: questionID, at: now, source: .acp)
        }
    }

    // MARK: - Shapes

    /// Grok names the tool in `_meta["x.ai/tool"].name` (`run_terminal_command`,
    /// `write`, …) on `tool_call`, `tool_call_update` and the permission's
    /// `toolCall`; that is the same vocabulary the hooks carry, so the hook
    /// path's table translates it. ACP's `kind` is the fallback.
    static func canonicalTool(_ object: [String: Any]) -> String? {
        if let name = toolMeta(object)?["name"] as? String, !name.isEmpty {
            return GrokToolVocabulary.canonicalTool(name)
        }
        guard let kind = object["kind"] as? String ?? toolMeta(object)?["kind"] as? String else { return nil }
        return CursorACPMonitor.canonicalTool(kind: kind, title: nil)
    }

    static func toolMeta(_ object: [String: Any]) -> [String: Any]? {
        (object["_meta"] as? [String: Any])?["x.ai/tool"] as? [String: Any]
    }

    /// The model list on `session/new` (or `initialize._meta.modelState`):
    /// the current id and each model's context window.
    static func models(_ raw: Any?) -> (current: String?, windows: [String: Int]) {
        guard let state = raw as? [String: Any] else { return (nil, [:]) }
        var windows: [String: Int] = [:]
        for model in state["availableModels"] as? [[String: Any]] ?? [] {
            guard let id = model["modelId"] as? String,
                  let window = ((model["_meta"] as? [String: Any])?["totalContextTokens"] as? NSNumber)?.intValue
            else { continue }
            windows[id] = window
        }
        return (state["currentModelId"] as? String, windows)
    }

    static func cancelledOutcome(for method: String) -> [String: Any] {
        method.hasSuffix("ask_user_question") ? questionCancelled : ["outcome": ["outcome": "cancelled"]]
    }

    /// `AskUserQuestionExtResponse` is an internally tagged enum on `outcome`
    /// (grok 1.0.40 rejects a nested `outcome` object with "expected variant
    /// identifier" and a bare `answers` with "missing field `outcome`").
    static var questionCancelled: [String: Any] { ["outcome": "cancelled"] }

    /// The phone answers with option values (labels); Grok wants the labels
    /// keyed by question text, as Claude's `AskUserQuestion.answers` does.
    /// Free text travels as the answer itself: Grok's options are suggestions,
    /// not a closed set.
    static func questionResponse(question: PendingQuestion, answers: QuestionAnswers) -> [String: Any] {
        var byQuestion: [String: String] = [:]
        for item in question.items {
            let values = (answers[item.id] ?? []).filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            let labels = values.map { value in
                item.options.first { $0.id == value || $0.value == value || $0.label == value }?.label ?? value
            }
            byQuestion[item.text] = labels.joined(separator: ", ")
        }
        guard !byQuestion.isEmpty else { return questionCancelled }
        return ["outcome": "accepted", "answers": byQuestion, "partial_answers": false]
    }
}
