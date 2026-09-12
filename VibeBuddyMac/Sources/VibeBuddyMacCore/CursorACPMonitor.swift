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
public actor CursorACPMonitor {

    /// How long a card may wait before the agent is told the request was
    /// cancelled. ACP blocks the turn until it hears back, so this is the
    /// upper bound on a turn nobody is answering, not a UI timeout.
    public static let decisionTimeout: Duration = .seconds(6 * 3600)

    private struct Hosted {
        let client: CursorACPClient
        let cwd: String
        var running = false
        var stopRequestedAt: Date?
        var text = ""
        var tools: [String: String] = [:]
        var openApprovals: [String: JSONRPCID] = [:]
        var openQuestions: [String: JSONRPCID] = [:]
        var children: [String] = []
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
    private let spawn: @Sendable (String) throws -> CursorACPClient
    private let executable: URL?
    private let signInProbe: @Sendable () async -> Bool
    private var signedIn: Bool?
    private var hosted: [String: Hosted] = [:]

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
                spawn: (@Sendable (String) throws -> CursorACPClient)? = nil) {
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
        self.spawn = spawn ?? { cwd in
            guard let resolved else { throw CursorACPClient.ClientError.closed }
            return try CursorACPClient.spawn(executable: resolved, cwd: cwd)
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

    public func invalidate() { signedIn = nil }

    /// Whether this monitor is carrying the conversation right now.
    public func hosts(_ sessionID: String) -> Bool { hosted[sessionID] != nil }

    public func hostedSessionIDs() -> Set<String> { Set(hosted.keys) }

    /// Whether a turn is running on a hosted conversation.
    public func isRunning(_ sessionID: String) -> Bool { hosted[sessionID]?.running == true }

    // MARK: - Dispatch

    /// Start a conversation in `cwd` and give it its first prompt. Returns once
    /// the prompt has been accepted; the turn itself reports through the store.
    public func dispatch(_ request: DispatchRequest) async -> DispatchOutcome {
        guard request.agent == .cursor else { return .unsupported("This host only starts Cursor sessions") }
        guard executable != nil else {
            return .unavailable("The Cursor CLI (cursor-agent) is not installed on this Mac")
        }
        guard await isSupported() else {
            return .unavailable("The Cursor CLI is not signed in — run `cursor-agent login` on this Mac")
        }
        let client: CursorACPClient
        do { client = try spawn(request.cwd) } catch {
            return .unavailable("Couldn't start cursor-agent: \(error)")
        }
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
            hosted[sessionID] = Hosted(client: client, cwd: request.cwd)
            await store.setACPHosted(sessionID: sessionID, true)
            let now = Date()
            await store.ingest(HookEvent(kind: .sessionStart, sessionID: sessionID, agent: .cursor,
                                         cwd: request.cwd, sessionName: request.name,
                                         observationSource: .acp, timestamp: now))
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
        guard let entry = hosted[sessionID], !entry.running, !entry.client.isClosed else { return false }
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
        // The protocol requires every open permission request to be answered
        // `cancelled` once the turn is; the cards come down with them.
        await withdrawOpenRequests(sessionID: sessionID)
        return .sent
    }

    /// End every hosted process. Called when the daemon shuts down.
    public func shutdown() async {
        for (sessionID, entry) in hosted {
            entry.client.close()
            await store.setACPHosted(sessionID: sessionID, false)
        }
        hosted = [:]
    }

    // MARK: - Turns

    private func startTurn(sessionID: String, text: String) {
        guard var entry = hosted[sessionID] else { return }
        entry.running = true
        entry.text = ""
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
            await self.turnEnded(sessionID: sessionID, stopReason: stopReason, failure: failure)
        }
    }

    private func turnEnded(sessionID: String, stopReason: String, failure: String?) async {
        guard var entry = hosted[sessionID] else { return }
        entry.running = false
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
        for child in entry.children {
            await store.ingest(HookEvent(kind: .childLifecycle, sessionID: sessionID, agent: .cursor,
                                         observationSource: .acp, timestamp: now, childID: child,
                                         childKind: .subagent, childAction: .stopped))
        }
        entry.children = []
        hosted[sessionID] = entry
        // A failed ending carries `toolError` as well as its wording, so the
        // stuck cue does not hang on the failure heuristic recognising a phrase.
        let ending = HookEvent(kind: .stop, sessionID: sessionID, agent: .cursor, cwd: entry.cwd,
                               message: message, observationSource: .acp,
                               toolError: !cancelled && !succeeded, timestamp: now,
                               completionText: succeeded && !entry.text.isEmpty ? entry.text : nil,
                               completionSucceeded: cancelled ? false : succeeded)
        await store.ingest(cancelled ? ending.markingUserStop() : ending)
        if entry.client.isClosed {
            hosted[sessionID] = nil
            await store.setACPHosted(sessionID: sessionID, false)
            await store.recordSourceSignal(agent: .cursor, source: .acp, health: .temporarilySilent, at: now)
            return
        }
        // A supplement the phone queued while the turn ran goes out now, as
        // the next prompt — the same moment the hooks' `stop` would have
        // handed it to Cursor.
        if !cancelled, let next = await followups.take(conversationID: sessionID, now: now) {
            startTurn(sessionID: sessionID, text: next)
        }
    }

    // MARK: - Incoming

    /// JSON-RPC params are `[String: Any]`, which Swift cannot prove Sendable;
    /// they are parsed fresh from one line and handed to exactly one task, so
    /// the hop onto the actor is the only place they cross an isolation line.
    private struct Payload: @unchecked Sendable { let value: [String: Any]? }

    private func wire(_ client: CursorACPClient) {
        client.onNotification = { [weak self] method, params in
            guard let self else { return }
            let payload = Payload(value: params)
            Task { await self.handleNotification(method: method, params: payload.value) }
        }
        client.onRequest = { [weak self] id, method, params in
            guard let self else { return }
            let payload = Payload(value: params)
            Task { await self.handleRequest(id: id, method: method, params: payload.value, client: client) }
        }
        client.onClose = { [weak self] in
            guard let self else { return }
            Task { await self.clientClosed(client) }
        }
    }

    private func clientClosed(_ client: CursorACPClient) async {
        for (sessionID, entry) in hosted where entry.client === client {
            if entry.running { continue }   // `turnEnded` will see `isClosed` and finish up.
            hosted[sessionID] = nil
            await store.setACPHosted(sessionID: sessionID, false)
        }
    }

    private func handleNotification(method: String, params: [String: Any]?) async {
        guard method == "session/update",
              let sessionID = params?["sessionId"] as? String,
              var entry = hosted[sessionID],
              let update = params?["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else { return }
        let now = Date()
        switch kind {
        case "agent_message_chunk":
            if let text = (update["content"] as? [String: Any])?["text"] as? String {
                entry.text = String((entry.text + text).suffix(4000))
                hosted[sessionID] = entry
            }
        case "tool_call":
            let callID = (update["toolCallId"] as? String) ?? UUID().uuidString
            let name = Self.canonicalTool(kind: update["kind"] as? String, title: update["title"] as? String)
            entry.tools[callID] = name
            hosted[sessionID] = entry
            await store.ingest(HookEvent(kind: .preToolUse, sessionID: sessionID, agent: .cursor,
                                         cwd: entry.cwd, toolName: name,
                                         message: update["title"] as? String,
                                         observationSource: .acp, timestamp: now))
        case "tool_call_update":
            let callID = (update["toolCallId"] as? String) ?? ""
            let status = update["status"] as? String
            guard status == "completed" || status == "failed" else { return }
            let name = entry.tools.removeValue(forKey: callID) ?? "tool"
            hosted[sessionID] = entry
            await store.ingest(HookEvent(kind: .postToolUse, sessionID: sessionID, agent: .cursor,
                                         cwd: entry.cwd, toolName: name,
                                         observationSource: .acp, toolError: status == "failed",
                                         timestamp: now))
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
        guard let sessionID, hosted[sessionID] != nil else {
            client.respondError(id: id, code: -32602, message: "unknown session")
            return
        }
        switch method {
        case "session/request_permission":
            await permission(id: id, sessionID: sessionID, params: params ?? [:], client: client)
        case "cursor/ask_question":
            await askQuestion(id: id, sessionID: sessionID, params: params ?? [:], client: client)
        case "cursor/create_plan":
            await createPlan(id: id, sessionID: sessionID, params: params ?? [:], client: client)
        case "cursor/update_todos":
            let todos = params?["todos"] ?? []
            client.respond(id: id, result: ["outcome": ["outcome": "accepted", "todos": todos]])
        case "cursor/task":
            // The subagent runs on Cursor's side; vibebuddy only shows the row.
            let callID = (params?["toolCallId"] as? String) ?? UUID().uuidString
            let childID = "subagent:\(callID)"
            if var entry = hosted[sessionID] { entry.children.append(childID); hosted[sessionID] = entry }
            let type = Self.subagentType(params?["subagentType"])
            await store.ingest(HookEvent(kind: .childLifecycle, sessionID: sessionID, agent: .cursor,
                                         message: params?["description"] as? String,
                                         observationSource: .acp, timestamp: Date(),
                                         childID: childID, childKind: .subagent,
                                         childName: type, childType: type, childAction: .started))
            client.respond(id: id, result: ["outcome": ["outcome": "completed"]])
        case "cursor/generate_image":
            client.respond(id: id, result: ["outcome": ["outcome": "rejected", "reason": "vibebuddy does not generate images"]])
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
        let tool = entry.tools[callID]
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
        let overview = (params["overview"] as? String) ?? (params["plan"] as? String) ?? ""
        let options = [QuestionOption(id: "accept", label: "Accept"), QuestionOption(id: "reject", label: "Reject")]
        let item = QuestionItem(id: "plan", header: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Plan",
                                text: overview.isEmpty ? "Approve this plan?" : String(overview.prefix(600)),
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
        let chosen = (answers["plan"] ?? answers.values.first ?? []).joined(separator: " ").lowercased()
        let accepted = chosen.contains("accept")
        client.respond(id: id, result: ["outcome": accepted
            ? ["outcome": "accepted"]
            : ["outcome": "rejected", "reason": chosen.isEmpty ? "rejected from vibebuddy" : chosen]])
    }

    private func withdrawOpenRequests(sessionID: String) async {
        guard var entry = hosted[sessionID] else { return }
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

    static func subagentType(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        if let custom = (raw as? [String: Any])?["custom"] as? String { return custom }
        return nil
    }
}
