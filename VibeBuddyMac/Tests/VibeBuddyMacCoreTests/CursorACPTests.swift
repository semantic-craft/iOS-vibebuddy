import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// A scripted `agent acp` on a pair of pipes. It answers the handshake the way
/// Cursor's CLI does (cursor.com/docs/cli/acp) and leaves `session/prompt`
/// open until the test ends the turn, so the test can push notifications and
/// server requests in between exactly as the real process would.
private final class FakeACPAgent: @unchecked Sendable {
    private let toAgent = Pipe()      // client writes, agent reads
    private let toClient = Pipe()     // agent writes, client reads
    private let lock = NSLock()
    private var buffer = Data()
    private var requests: [(id: Int, method: String, params: [String: Any])] = []
    private var responses: [Int: [String: Any]] = [:]
    private var nextID = 100
    let sessionID: String
    var protocolVersion = 1

    init(sessionID: String = "acp-1") {
        self.sessionID = sessionID
        toAgent.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self.consume(data)
        }
    }

    func client() -> CursorACPClient {
        CursorACPClient(reading: toClient.fileHandleForReading, writing: toAgent.fileHandleForWriting)
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let method = obj["method"] as? String {
                let params = obj["params"] as? [String: Any] ?? [:]
                guard let id = (obj["id"] as? NSNumber)?.intValue else {
                    lock.lock(); requests.append((id: -1, method: method, params: params)); lock.unlock()
                    continue
                }
                lock.lock(); requests.append((id: id, method: method, params: params)); lock.unlock()
                // The handshake answers itself; prompts wait for the test.
                switch method {
                case "initialize": respond(id, ["protocolVersion": protocolVersion, "agentCapabilities": ["loadSession": true]])
                case "authenticate": respond(id, [:])
                case "session/new": respond(id, ["sessionId": sessionID])
                case "session/load":
                    update(["sessionUpdate": "agent_message_chunk", "content": ["text": "OLD REPLAY"]])
                    update(["sessionUpdate": "tool_call", "toolCallId": "replay-0", "kind": "read", "title": "old read"])
                    respond(id, [:])
                default: break
                }
            } else if let id = (obj["id"] as? NSNumber)?.intValue {
                lock.lock(); responses[id] = obj; lock.unlock()
            }
        }
    }

    private func write(_ json: [String: Any]) {
        var data = try! JSONSerialization.data(withJSONObject: json)
        data.append(0x0A)
        try? toClient.fileHandleForWriting.write(contentsOf: data)
    }

    func respond(_ id: Int, _ result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func burstAndEnd(_ chunks: [String]) {
        guard let prompt = request(named: "session/prompt", after: promptsEnded) else { return }
        promptsEnded += 1
        var messages: [[String: Any]] = chunks.map { text in
            ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": sessionID,
             "update": ["sessionUpdate": "agent_message_chunk", "content": ["text": text]]]]
        }
        messages.append(["jsonrpc": "2.0", "id": prompt.id, "result": ["stopReason": "end_turn"]])
        var data = Data()
        for message in messages {
            data.append(try! JSONSerialization.data(withJSONObject: message))
            data.append(0x0A)
        }
        try? toClient.fileHandleForWriting.write(contentsOf: data)
    }

    func update(_ update: [String: Any]) {
        write(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": sessionID, "update": update]])
    }

    /// A server-initiated request; returns its id so the test can await the answer.
    @discardableResult
    func ask(_ method: String, _ params: [String: Any], id requestedID: Int? = nil) -> Int {
        lock.lock(); let id = requestedID ?? nextID; nextID += 1; lock.unlock()
        var full = params
        full["sessionId"] = sessionID
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": full])
        return id
    }

    func endTurn(_ stopReason: String) {
        guard let prompt = request(named: "session/prompt", after: promptsEnded) else { return }
        promptsEnded += 1
        respond(prompt.id, ["stopReason": stopReason])
    }
    private var promptsEnded = 0

    func request(named method: String, after skip: Int = 0) -> (id: Int, method: String, params: [String: Any])? {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.method == method }.dropFirst(skip).first
    }

    func requests(named method: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.method == method }.map(\.params)
    }

    func response(to id: Int) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return responses[id]
    }

    func close() {
        try? toClient.fileHandleForWriting.close()
    }
}

/// What the monitor asked to spawn, and how often it asked for the model
/// list — the two seams a dispatch's options and the cache show through.
private final class LaunchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CursorACPLaunch] = []
    private var listed = 0
    var launches: [CursorACPLaunch] { lock.lock(); defer { lock.unlock() }; return stored }
    var modelListings: Int { lock.lock(); defer { lock.unlock() }; return listed }
    func record(_ launch: CursorACPLaunch) { lock.lock(); stored.append(launch); lock.unlock() }
    func recordListing() { lock.lock(); listed += 1; lock.unlock() }
}

/// Poll until `condition` holds. Bounded so a wrong implementation fails
/// instead of hanging; the bound is liveness, never the assertion.
private func eventually(_ what: String, _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<600 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("never happened: \(what)")
}

@Suite("Cursor ACP host")
struct CursorACPTests {
    private struct Rig {
        let store = SessionStore()
        let approvals = ApprovalRegistry()
        let approvalContext = ApprovalContextStore()
        let questions = QuestionRegistry()
        let allowStore: VibeBuddyAllowStore
        let sessionAllow = SessionAllowList()
        let followups = CursorFollowupQueue()
        let agent: FakeACPAgent
        let log = LaunchLog()
        let monitor: CursorACPMonitor

        init(agent: FakeACPAgent = FakeACPAgent(), signedIn: Bool = true, deny: [String] = [],
             models: [String] = ["gpt-5", "sonnet-4.5"], recoveryDirectory: URL? = nil) {
            self.agent = agent
            let log = self.log
            allowStore = VibeBuddyAllowStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("vbacp-\(UUID().uuidString).json"))
            monitor = CursorACPMonitor(store: store, approvals: approvals, approvalContext: approvalContext,
                                       questions: questions, allowStore: allowStore, sessionAllow: sessionAllow,
                                       followups: followups,
                                       rules: { _ in PermissionRules(allow: [], deny: deny) },
                                       makeID: { UUID().uuidString },
                                       executable: URL(fileURLWithPath: "/usr/bin/true"),
                                       signInProbe: { signedIn },
                                       modelsProbe: { log.recordListing(); return models },
                                       spawn: { launch in log.record(launch); return agent.client() }, recoveryDirectory: recoveryDirectory)
        }

        func session() async -> AgentSession? {
            await store.snapshot(now: Date()).sessions.first { $0.id == agent.sessionID }
        }
    }

    private let request = DispatchRequest(agent: .cursor, cwd: "/x/p", prompt: "fix the tests", name: nil)

    @Test func restartLoadsSameIdentityWithoutReplayingHistoryOrDoubleHosting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Rig(recoveryDirectory: directory)
        #expect(await first.monitor.dispatch(request) == .started(sessionID: "acp-1"))
        await eventually("first prompt") { first.agent.request(named: "session/prompt") != nil }
        first.agent.endTurn("end_turn")
        await eventually("idle") { await first.session()?.status == .done }
        let other = Rig(recoveryDirectory: directory)
        await other.monitor.registerRecoverableSessions()
        #expect(await other.monitor.prompt(sessionID: "acp-1", text: "blocked") == false)
        #expect(other.log.launches.isEmpty)
        let failedRow = await other.session()
        #expect(failedRow?.cursorACPRecoveryFailure != nil)
        #expect(failedRow.map { SessionActionSupport.resolve(for: $0).isAvailable } == true)
        await first.monitor.shutdown()
        #expect(await other.monitor.prompt(sessionID: "acp-1", text: "explicit retry"))
        await other.monitor.shutdown()
        let second = Rig(recoveryDirectory: directory)
        await second.monitor.registerRecoverableSessions()
        let historical = await second.session()
        #expect(historical?.cursorACPRecoverable == true)
        #expect(historical?.historyOnly == true)
        #expect(historical?.controlChannel == ControlChannel.none)
        #expect(historical?.hasUnreadCompletion == false)
        #expect(await second.monitor.prompt(sessionID: "acp-1", text: "continue"))
        #expect(second.agent.request(named: "session/new") == nil)
        #expect(second.agent.request(named: "session/load")?.params["sessionId"] as? String == "acp-1")
        await eventually("second prompt") { second.agent.request(named: "session/prompt") != nil }
        second.agent.update(["sessionUpdate": "agent_message_chunk", "content": ["text": "NEW ANSWER"]])
        try? await Task.sleep(for: .milliseconds(20))
        second.agent.endTurn("end_turn")
        await eventually("second idle") { await second.session()?.status == .done }
        #expect(await second.session()?.summary?.contains("OLD REPLAY") != true)
        #expect(second.log.launches.first?.options.worktree == false)
        await second.monitor.shutdown()
    }

    @Test func oldRecoveryKeepsItsHistoricalTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let time = Date().addingTimeInterval(-7 * 86400)
        let record = CursorACPRecovery(sessionID: "acp-1", cwd: "/tmp", options: .init(),
            createdAt: time, origin: "vibebuddy-acp", unavailable: nil)
        try record.save(in: directory)
        let rig = Rig(recoveryDirectory: directory)
        await rig.monitor.registerRecoverableSessions()
        let row = await rig.session()
        #expect(row?.updatedAt == time)
        #expect(row?.historyOnly == true)
        #expect(row?.hasUnreadCompletion == false)
    }

    @Test func recoveryMetadataIsPrivateAndBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = CursorACPRecovery(sessionID: "old", cwd: "/tmp", options: .init(),
            createdAt: Date().addingTimeInterval(-31 * 86400), origin: "vibebuddy-acp", unavailable: nil)
        try old.save(in: directory)
        let current = CursorACPRecovery(sessionID: "current", cwd: "/tmp", options: .init(),
            createdAt: Date(), origin: "vibebuddy-acp", unavailable: nil)
        try current.save(in: directory)
        #expect(CursorACPRecovery.read(in: directory).map(\.sessionID) == ["current"])
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(current.filename + ".json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aDispatchBecomesAWorkingSessionOnTheACPChannel() async throws {
        let rig = Rig()
        let outcome = await rig.monitor.dispatch(request)
        #expect(outcome == .started(sessionID: "acp-1"))
        await eventually("the prompt reached the agent") { rig.agent.request(named: "session/prompt") != nil }
        let prompt = rig.agent.request(named: "session/prompt")?.params
        #expect(((prompt?["prompt"] as? [[String: Any]])?.first?["text"] as? String) == "fix the tests")
        await eventually("the session is working") { await rig.session()?.status == .working }
        let session = await rig.session()
        #expect(session?.agent == .cursor)
        #expect(session?.controlChannel == .acp)
        #expect(session?.observations?.contains { $0.source == .acp } == true)
        #expect(await rig.store.isACPHosted("acp-1"))
        // Steer / continue / stop all read as available on this row.
        #expect(SessionActionSupport.resolve(for: session!).isAvailable)
        #expect(SessionActionSupport.resolveStop(for: session!).isAvailable)
    }

    @Test func toolCallsAndTheEndingFlowThrough() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        rig.agent.update(["sessionUpdate": "tool_call", "toolCallId": "c1", "title": "Running tests", "kind": "execute", "status": "pending"])
        await eventually("active tool") { await rig.session()?.activeTool == "Bash" }
        rig.agent.update(["sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed"])
        rig.agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "All green."]])
        rig.agent.update(["sessionUpdate": "usage_update", "used": 53000, "size": 200000])
        await eventually("context") { await rig.session()?.contextTokens == 53000 }
        rig.agent.endTurn("end_turn")
        await eventually("done") { await rig.session()?.status == .done }
        let session = await rig.session()
        #expect(session?.contextWindow == 200000)
        #expect(session?.failed != true)
        #expect(session?.userStopped != true)
        #expect(session?.summary?.contains("All green") == true)
    }

    @Test func aPermissionRequestBecomesACardAndThePhonesAnswerGoesBack() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        rig.agent.update(["sessionUpdate": "tool_call", "toolCallId": "c1", "title": "rm -rf build", "kind": "execute",
                          "rawInput": ["command": "rm -rf build"]])
        let rpc = rig.agent.ask("session/request_permission", [
            "toolCall": ["toolCallId": "c1", "title": "rm -rf build", "kind": "execute", "rawInput": ["command": "rm -rf build"]],
            "options": [["optionId": "allow-once", "name": "Allow once", "kind": "allow_once"],
                        ["optionId": "allow-always", "name": "Always", "kind": "allow_always"],
                        ["optionId": "reject-once", "name": "Reject", "kind": "reject_once"]],
        ])
        await eventually("card") { await rig.session()?.pendingApproval != nil }
        let card = await rig.session()?.pendingApproval
        #expect(card?.tool == "Bash")
        #expect(card?.command == "rm -rf build")
        #expect(card?.answerable != false)
        #expect(await rig.session()?.status == .needsResponse)
        // The phone taps Allow: the same registry `/decision` resolves.
        #expect(await rig.approvals.claim(id: card!.id))
        await rig.approvals.resolve(id: card!.id, with: .allow)
        await eventually("answer") { rig.agent.response(to: rpc) != nil }
        let outcome = (rig.agent.response(to: rpc)?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "selected")
        #expect(outcome?["optionId"] as? String == "allow-once")
        await eventually("card gone") { await rig.session()?.pendingApproval == nil }
    }

    @Test func aDenyRuleAnswersWithoutACard() async throws {
        let rig = Rig(deny: ["Bash(rm -rf:*)"])
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let rpc = rig.agent.ask("session/request_permission", [
            "toolCall": ["toolCallId": "c9", "title": "rm -rf /", "kind": "execute", "rawInput": ["command": "rm -rf /"]],
            "options": [["optionId": "allow-once", "kind": "allow_once"], ["optionId": "reject-once", "kind": "reject_once"]],
        ])
        await eventually("answer") { rig.agent.response(to: rpc) != nil }
        let outcome = (rig.agent.response(to: rpc)?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["optionId"] as? String == "reject-once")
        #expect(await rig.session()?.pendingApproval == nil)
    }

    @Test func aQuestionIsAnsweredWithCursorsOwnOptionIDs() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let rpc = rig.agent.ask("cursor/ask_question", [
            "toolCallId": "q1", "title": "Need input",
            "questions": [["id": "mode", "prompt": "Which mode?",
                           "options": [["id": "agent", "label": "Agent"], ["id": "plan", "label": "Plan"]]],
                          ["id": "scope", "prompt": "Which files?", "allowMultiple": true,
                           "options": [["id": "a", "label": "a.swift"], ["id": "b", "label": "b.swift"]]]],
        ])
        await eventually("question") { await rig.session()?.pendingQuestion != nil }
        // The card is published an actor hop before the monitor starts waiting.
        await eventually("waiting") { await rig.questions.isWaiting(sessionID: "acp-1") }
        let question = await rig.session()!.pendingQuestion!
        #expect(question.items.count == 2)
        #expect(question.items[1].multiSelect)
        #expect(await rig.questions.resolveExact(sessionID: "acp-1", questionID: question.id,
                                                  answers: ["mode": ["Plan"], "scope": ["a.swift", "b.swift"]]))
        await eventually("answer") { rig.agent.response(to: rpc) != nil }
        let outcome = (rig.agent.response(to: rpc)?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "answered")
        let answers = outcome?["answers"] as? [[String: Any]]
        #expect(answers?.first { $0["questionId"] as? String == "mode" }?["selectedOptionIds"] as? [String] == ["plan"])
        #expect(answers?.first { $0["questionId"] as? String == "scope" }?["selectedOptionIds"] as? [String] == ["a", "b"])
        await eventually("question gone") { await rig.session()?.pendingQuestion == nil }
    }

    @Test func aPlanIsAcceptedFromTheCard() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let rpc = rig.agent.ask("cursor/create_plan", ["toolCallId": "p1", "name": "Refactor tabs",
                                                        "overview": "Tighten layout.", "plan": "1. …", "todos": []])
        await eventually("question") { await rig.session()?.pendingQuestion != nil }
        await eventually("waiting") { await rig.questions.isWaiting(sessionID: "acp-1") }
        let question = await rig.session()!.pendingQuestion!
        #expect(question.options.map(\.id) == ["accept", "reject"])
        #expect(await rig.questions.resolveExact(sessionID: "acp-1", questionID: question.id, answers: ["plan": ["Accept"]]))
        await eventually("answer") { rig.agent.response(to: rpc) != nil }
        let outcome = (rig.agent.response(to: rpc)?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "accepted")
    }

    @Test func fullPlanAndProviderTodosSurviveTheBlockingCardAndExactRejection() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let body = "# Full plan\n" + String(repeating: "Keep the complete implementation and verification section.\n", count: 80) + "PLAN_END_03\n"
        let rpc = rig.agent.ask("cursor/create_plan", ["toolCallId": "native-call\nprovider-part", "name": "Offline Grocery List",
            "overview": "Short overview must not replace the body", "plan": body,
            "todos": [["id": "schema", "content": "Specify the local schema", "status": "pending"]]], id: 0)
        await eventually("plan card") { await rig.session()?.pendingQuestion != nil }
        await eventually("waiting") { await rig.questions.isWaiting(sessionID: "acp-1") }
        let question = try #require(await rig.session()?.pendingQuestion)
        #expect(question.prompt.hasPrefix("Offline Grocery List\n\n"))
        #expect(question.prompt.contains(body))
        #expect(question.items.first?.text == question.prompt)
        #expect(question.prompt.contains("[pending] Specify the local schema"))
        #expect(!question.prompt.contains("Short overview"))
        let reason = "Do not accept: ACP_REJECT_03"
        #expect(await rig.questions.resolveExact(sessionID: "acp-1", questionID: question.id, answers: ["plan": [reason]]))
        await eventually("exact plan response") { rig.agent.response(to: rpc) != nil }
        let response = try #require(rig.agent.response(to: 0))
        let outcome = (response["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "rejected")
        #expect(outcome?["reason"] as? String == reason)
        await rig.monitor.shutdown()
    }

    @Test func partialReadUpdatesProduceOneIdentifiedSuccessfulLedgerRecord() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        // Same shape/order as evidence/01/acp-transcript.jsonl; the newline is
        // part of Cursor's real tool identity, not a transport delimiter.
        let call = "call-18379383-22b2-4594-a59e-87c85aff89f8-0\nfc_46003852-a212-951c-afbc-2379bd1c30bc_0"
        rig.agent.update(["sessionUpdate": "tool_call", "toolCallId": call, "title": "Read File", "kind": "read", "status": "pending", "rawInput": [:]])
        await eventually("read intent") { await rig.session()?.ledger?.contains { $0.id == call } == true }
        rig.agent.update(["sessionUpdate": "tool_call_update", "toolCallId": call, "title": "Read /tmp/sample.txt", "rawInput": ["path": "/tmp/sample.txt"], "locations": [["path": "/tmp/sample.txt"]]])
        await eventually("path arrived") { await rig.session()?.ledger?.first(where: { $0.id == call })?.files == ["/tmp/sample.txt"] }
        rig.agent.update(["sessionUpdate": "tool_call_update", "toolCallId": call, "status": "in_progress"])
        rig.agent.update(["sessionUpdate": "tool_call_update", "toolCallId": call, "status": "completed", "rawOutput": ["content": "ACP_BASELINE_7319\n"]])
        await eventually("read succeeded") { await rig.session()?.ledger?.first(where: { $0.id == call })?.result == .succeeded }
        let records = await rig.session()?.ledger?.filter { $0.source == "acp" } ?? []
        #expect(records.count == 1)
        #expect(records.first?.id == call)
        #expect(records.first?.tool == "Read")
        #expect(records.first?.files == ["/tmp/sample.txt"])
        #expect(records.first?.linesAdded == nil)
        await rig.monitor.shutdown()
    }

    @Test func notificationOnlyMethodsDoNotFabricateExecutionOutcomes() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        for method in ["cursor/update_todos", "cursor/task", "cursor/generate_image"] {
            let rpc = rig.agent.ask(method, ["toolCallId": "unverified", "description": "unknown"])
            await eventually("unsupported response") { rig.agent.response(to: rpc) != nil }
            #expect((rig.agent.response(to: rpc)?["error"] as? [String: Any])?["code"] as? Int == -32601)
            #expect(rig.agent.response(to: rpc)?["result"] == nil)
        }
        #expect(await rig.session()?.childAgents?.isEmpty != false)
        #expect(await rig.session()?.failed != true)
        await rig.monitor.shutdown()
    }

    @Test func aStopCancelsTheTurnAndIsMarkedAsTheUsers() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        // An open permission request must be answered `cancelled` on the way.
        let rpc = rig.agent.ask("session/request_permission", [
            "toolCall": ["toolCallId": "c1", "title": "npm test", "kind": "execute"],
            "options": [["optionId": "allow-once", "kind": "allow_once"], ["optionId": "reject-once", "kind": "reject_once"]],
        ])
        await eventually("card") { await rig.session()?.pendingApproval != nil }
        await rig.followups.queue(conversationID: "acp-1", text: "must not be sent after cancellation")
        let waiting = try #require(await rig.session())
        let dispatch = AnswerDispatch(store: rig.store, questions: rig.questions, inject: { _, _ in },
            interrupt: { id in await rig.monitor.cancel(sessionID: id) })
        let stale = await dispatch.deliver(SessionActionRequest(sessionID: "acp-1", intent: .stop,
            expectedStatusSince: waiting.statusSince.timeIntervalSince1970 - 1))
        #expect(stale != .accepted)
        let outcome = await dispatch.deliver(SessionActionRequest(sessionID: "acp-1", intent: .stop,
            expectedStatusSince: waiting.statusSince.timeIntervalSince1970))
        #expect(outcome == .accepted)
        await eventually("cancel notified") { rig.agent.request(named: "session/cancel") != nil }
        await eventually("permission cancelled") {
            ((rig.agent.response(to: rpc)?["result"] as? [String: Any])?["outcome"] as? [String: Any])?["outcome"] as? String == "cancelled"
        }
        rig.agent.endTurn("cancelled")
        await eventually("done") { await rig.session()?.status == .done }
        let session = await rig.session()
        #expect(session?.userStopped == true)
        #expect(session?.failed != true)
        #expect(session?.pendingApproval == nil)
        #expect(await rig.followups.peek(conversationID: "acp-1") == nil)
        #expect(rig.agent.request(named: "session/prompt", after: 1) == nil)
        // Nothing left to stop.
        #expect(await rig.monitor.cancel(sessionID: "acp-1") != .sent)
    }

    private actor ChunkSink {
        var text = ""
        func append(_ chunk: String) { text += chunk }
        func value() -> String { text }
    }

    @Test func pipeReplyAndEOFFollowSlowNotifications() async throws {
        let agent = FakeACPAgent()
        let client = agent.client()
        let sink = ChunkSink()
        client.onNotification = { _, params in
            let update = params?["update"] as? [String: Any]
            let chunk = (update?["content"] as? [String: Any])?["text"] as? String ?? ""
            // A suspended notification must still precede the prompt reply
            // and EOF that arrived in the same stdout burst.
            try? await Task.sleep(for: .milliseconds(1))
            await sink.append(chunk)
        }
        client.start()
        let prompt = Task {
            let reply = try await client.request("session/prompt", timeout: .seconds(3))
            return reply["stopReason"] as? String
        }
        await eventually("direct prompt") { agent.request(named: "session/prompt") != nil }
        let chunks = (0..<30).map { "\($0)," } + ["LAST_CHUNK"]
        agent.burstAndEnd(chunks)
        agent.close()
        let reply = try await prompt.value
        #expect(reply == "end_turn")
        #expect(await sink.value() == chunks.joined())
        await eventually("EOF") { client.isClosed }
    }

    @Test func pipeBurstPreservesChunkOrderBeforePromptCompletion() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let chunks = (0..<600).map { "\($0)," } + ["LAST_CHUNK"]
        rig.agent.burstAndEnd(chunks)
        await eventually("burst completion") { await rig.session()?.status == .done }
        let session = try #require(await rig.session())
        let completionID = try #require(session.completionID)
        let body = await rig.store.completionBody(sessionID: session.id, completionID: completionID)
        #expect(body.text == chunks.joined())
        await rig.monitor.shutdown()
    }

    @Test(arguments: [false, true])
    func lateWaitCleanupPreservesCompletedTurn(approval: Bool) async throws {
        let store = SessionStore()
        let start = Date()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "late-cleanup", agent: .cursor,
                                    observationSource: .acp, timestamp: start))
        if approval {
            await store.beginApproval(sessionID: "late-cleanup",
                PendingApproval(id: "wait", tool: "Read", commandPreview: "read marker"),
                at: start.addingTimeInterval(1), source: .acp)
        } else {
            await store.beginQuestion(sessionID: "late-cleanup",
                PendingQuestion(id: "wait", prompt: "Review plan"),
                at: start.addingTimeInterval(1), source: .acp)
        }
        // cancel has captured its wait, but turnEnded reaches the store first.
        await store.ingest(HookEvent(kind: .stop, sessionID: "late-cleanup", agent: .cursor,
                                    observationSource: .acp, timestamp: start.addingTimeInterval(3),
                                    completionText: "Finished result", completionSucceeded: true))
        let ended = try #require(await store.snapshot(now: Date()).sessions.first)
        #expect(ended.status == .done)
        #expect(ended.completionID != nil)
        if approval {
            await store.endApproval(sessionID: "late-cleanup", approvalID: "wait",
                                    at: start.addingTimeInterval(2), source: .acp)
        } else {
            await store.endQuestion(sessionID: "late-cleanup", questionID: "wait",
                                    at: start.addingTimeInterval(2), source: .acp)
        }
        let cleared = try #require(await store.snapshot(now: Date()).sessions.first)
        #expect(cleared.status == .done)
        #expect(cleared.completionID == ended.completionID)
        #expect(cleared.hasUnreadCompletion == ended.hasUnreadCompletion)
        #expect(cleared.statusSince == ended.statusSince)
        #expect(cleared.updatedAt == ended.updatedAt)
        #expect(cleared.userStopped == ended.userStopped)
        #expect(cleared.pendingQuestion == nil && cleared.pendingApproval == nil)
        // A stale cleanup must also leave the next turn's different wait alone.
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "late-cleanup", agent: .cursor,
                                    observationSource: .acp, timestamp: start.addingTimeInterval(4)))
        if approval {
            await store.beginApproval(sessionID: "late-cleanup",
                PendingApproval(id: "next", tool: "Read", commandPreview: "next read"),
                at: start.addingTimeInterval(5), source: .acp)
            await store.endApproval(sessionID: "late-cleanup", approvalID: "wait", at: Date(), source: .acp)
        } else {
            await store.beginQuestion(sessionID: "late-cleanup", PendingQuestion(id: "next", prompt: "Next plan"),
                                      at: start.addingTimeInterval(5), source: .acp)
            await store.endQuestion(sessionID: "late-cleanup", questionID: "wait", at: Date(), source: .acp)
        }
        let next = try #require(await store.snapshot(now: Date()).sessions.first)
        #expect(next.status == .needsResponse)
        #expect((approval ? next.pendingApproval?.id : next.pendingQuestion?.id) == "next")
        await store.ingest(HookEvent(kind: .stop, sessionID: "late-cleanup", agent: .cursor,
                                    observationSource: .acp, timestamp: start.addingTimeInterval(7)).markingUserStop())
        if approval {
            await store.endApproval(sessionID: "late-cleanup", approvalID: "next", at: Date(), source: .acp)
        } else {
            await store.endQuestion(sessionID: "late-cleanup", questionID: "next", at: Date(), source: .acp)
        }
        let stopped = try #require(await store.snapshot(now: Date()).sessions.first)
        #expect(stopped.status == .done && stopped.userStopped == true)
        #expect(stopped.completionID == nil && !stopped.hasUnreadCompletion)
    }

    @Test func endingAndCancelCannotResurrectATurn() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        _ = rig.agent.ask("cursor/create_plan", ["toolCallId": "plan", "plan": "Review this before continuing"])
        await eventually("plan wait") { await rig.session()?.pendingQuestion != nil }
        rig.agent.endTurn("end_turn")
        _ = await rig.monitor.cancel(sessionID: "acp-1")
        await eventually("ending settled") { await rig.session()?.status == .done }
        #expect(await rig.monitor.isRunning("acp-1") == false)
        #expect(await rig.monitor.prompt(sessionID: "acp-1", text: "next turn"))
        await eventually("next prompt") { rig.agent.request(named: "session/prompt", after: 1) != nil }
        #expect(await rig.monitor.isRunning("acp-1"))
        await rig.monitor.shutdown()
    }

    @Test func aSupplementQueuedDuringATurnGoesOutAsTheNextPrompt() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        #expect(await rig.followups.queue(conversationID: "acp-1", text: "also bump the version") != nil)
        rig.agent.endTurn("end_turn")
        await eventually("second prompt") { rig.agent.request(named: "session/prompt", after: 1) != nil }
        let second = rig.agent.request(named: "session/prompt", after: 1)?.params
        #expect(((second?["prompt"] as? [[String: Any]])?.first?["text"] as? String) == "also bump the version")
        #expect(await rig.followups.peek(conversationID: "acp-1") == nil)
        await eventually("working again") { await rig.session()?.status == .working }
        // A continue on a running turn is refused; once idle it is the next prompt.
        #expect(await rig.monitor.prompt(sessionID: "acp-1", text: "and lint") == false)
        rig.agent.endTurn("end_turn")
        await eventually("done") { await rig.session()?.status == .done }
        #expect(await rig.monitor.prompt(sessionID: "acp-1", text: "and lint"))
        await eventually("third prompt") { rig.agent.request(named: "session/prompt", after: 2) != nil }
    }

    @Test func hookEventsForAHostedConversationOnlyCorroborate() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("working") { await rig.session()?.status == .working }
        // Cursor's own hooks still fire for a CLI turn; a `stop` from them must
        // not end a turn the pipe says is running.
        let stop = HookEvent(kind: .stop, sessionID: "acp-1", agent: .cursor, cwd: "/x/p",
                             observationSource: .hook, timestamp: Date(), completionSucceeded: true)
        await rig.store.ingest(stop)
        let session = await rig.session()
        #expect(session?.status == .working)
        #expect(session?.observations?.contains { $0.source == .hook } == true)
        #expect(session?.controlChannel == .acp)
    }

    @Test func aPlainDispatchStartsTheCLIWithNoOptions() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        #expect(rig.log.launches == [CursorACPLaunch(cwd: "/x/p")])
        #expect(rig.log.launches.first?.leadingArguments == [])
    }

    @Test func modelModeAndWorktreeBecomeTheCLIsGlobalOptionsInFrontOfACP() async throws {
        let rig = Rig()
        var chosen = request
        chosen.model = "gpt-5"
        chosen.mode = "plan"
        chosen.worktree = true
        let outcome = await rig.monitor.dispatch(chosen)
        #expect(outcome == .started(sessionID: "acp-1"))
        #expect(rig.log.launches.count == 1)
        #expect(rig.log.launches.first?.cwd == "/x/p")
        #expect(rig.log.launches.first?.leadingArguments == ["--model", "gpt-5", "--mode", "plan", "-w"])
        // Agent mode is the CLI's default and needs no flag.
        await eventually("the row carries the chosen model") { await rig.session()?.model == "gpt-5" }
        var agentMode = request
        agentMode.mode = "agent"
        agentMode.model = "sonnet-4.5"
        let second = Rig(agent: FakeACPAgent(sessionID: "acp-2"))
        _ = await second.monitor.dispatch(agentMode)
        #expect(second.log.launches.first?.leadingArguments == ["--model", "sonnet-4.5"])
    }

    @Test func aModelOrModeThatIsNotAPlainTokenIsRefusedBeforeAnythingIsSpawned() async throws {
        let rig = Rig()
        var bad = request
        bad.model = "gpt-5; rm -rf ~"
        guard case .rejected(let why) = await rig.monitor.dispatch(bad) else { Issue.record("expected rejected"); return }
        #expect(why.contains("model"))
        var badMode = request
        badMode.mode = "yolo"
        guard case .rejected(let modeWhy) = await rig.monitor.dispatch(badMode) else { Issue.record("expected rejected"); return }
        #expect(modeWhy.contains("mode"))
        #expect(rig.log.launches.isEmpty)
        #expect(await rig.session() == nil)
    }

    @Test func theModelListIsProbedOncePerSignInVerdict() async throws {
        let rig = Rig()
        #expect(await rig.monitor.models() == ["gpt-5", "sonnet-4.5"])
        #expect(await rig.monitor.models() == ["gpt-5", "sonnet-4.5"])
        #expect(rig.log.modelListings == 1)
        await rig.monitor.invalidate()
        #expect(await rig.monitor.models() == ["gpt-5", "sonnet-4.5"])
        #expect(rig.log.modelListings == 2)
        // Signed out: no models, and no subprocess to ask for them.
        let signedOut = Rig(signedIn: false)
        #expect(await signedOut.monitor.models() == [])
        #expect(signedOut.log.modelListings == 0)
    }

    @Test func anUnexpectedProtocolVersionIsRefusedNotGuessed() async throws {
        let agent = FakeACPAgent()
        agent.protocolVersion = 2
        let rig = Rig(agent: agent)
        let outcome = await rig.monitor.dispatch(request)
        guard case .unavailable(let why) = outcome else { Issue.record("expected unavailable, got \(outcome)"); return }
        #expect(why.contains("version 2"))
        #expect(await rig.session() == nil)
        #expect(await rig.store.isACPHosted("acp-1") == false)
    }

    @Test func aSignedOutCLIIsNotOffered() async throws {
        let rig = Rig(signedIn: false)
        #expect(await rig.monitor.isSupported() == false)
        guard case .unavailable(let why) = await rig.monitor.dispatch(request) else { Issue.record("expected unavailable"); return }
        #expect(why.contains("login"))
    }

    @Test func theProcessGoingAwayEndsTheTurnAsAFailureAndReleasesTheRow() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("working") { await rig.session()?.status == .working }
        rig.agent.close()
        await eventually("done") { await rig.session()?.status == .done }
        let session = await rig.session()
        #expect(session?.failed == true)
        #expect(session?.userStopped != true)
        await eventually("released") { await rig.store.isACPHosted("acp-1") == false }
        #expect(await rig.session()?.controlChannel != .acp)
    }
}

@Suite("Cursor ACP shapes")
struct CursorACPShapeTests {
    @Test func toolKindsBecomeCanonicalNames() {
        #expect(CursorACPMonitor.canonicalTool(kind: "execute", title: "Running tests") == "Bash")
        #expect(CursorACPMonitor.canonicalTool(kind: "read", title: nil) == "Read")
        #expect(CursorACPMonitor.canonicalTool(kind: "edit", title: nil) == "Edit")
        #expect(CursorACPMonitor.canonicalTool(kind: "search", title: nil) == "Grep")
        #expect(CursorACPMonitor.canonicalTool(kind: nil, title: "Shell") == "Bash")
        #expect(CursorACPMonitor.canonicalTool(kind: nil, title: nil) == "tool")
    }

    @Test func permissionOptionsFollowTheKindNotTheID() {
        let options = CursorACPMonitor.permissionOptions([
            ["optionId": "yes", "kind": "allow_once"], ["optionId": "no", "kind": "reject_once"]])
        #expect(options.allow == "yes" && options.reject == "no")
        let documented = CursorACPMonitor.permissionOptions(nil)
        #expect(documented.allow == "allow-once" && documented.reject == "reject-once")
    }

    @Test func aTypedAnswerTravelsAsASkipReason() {
        let question = PendingQuestion(id: "q", prompt: "Which?", options: [QuestionOption(id: "a", label: "A")],
                                       questions: [QuestionItem(id: "q1", text: "Which?", options: [QuestionOption(id: "a", label: "A")])])
        let typed = CursorACPMonitor.questionResponse(question: question, answers: ["q1": ["something else"]])
        let outcome = typed["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "skipped")
        #expect((outcome?["reason"] as? String)?.contains("something else") == true)
        let picked = CursorACPMonitor.questionResponse(question: question, answers: ["q1": ["A"]])
        #expect(((picked["outcome"] as? [String: Any])?["outcome"] as? String) == "answered")
    }
}

@Suite("Cursor launch options")
struct CursorLaunchOptionTests {
    @Test func theListIsOneIDPerLineWhateverDecorationTheCLIPrints() {
        let fixture = """
        Available models:
        MODEL          DESCRIPTION
        * gpt-5        OpenAI GPT-5 (current)
        - sonnet-4.5   Anthropic
        | composer-1 | Cursor |
        claude-opus-4.1, the big one
        auto
        gpt-5

        Run `agent --model <model>` to pick one.
        """
        #expect(CursorCLI.parseModelList(fixture) == ["gpt-5", "sonnet-4.5", "composer-1", "claude-opus-4.1", "auto"])
        #expect(CursorCLI.parseModelList("Error: Authentication required. Run 'agent login'.") == [])
        #expect(CursorCLI.parseModelList("") == [])
    }

    @Test func onlyPlainTokensAndDocumentedBracketOverridesPass() {
        for ok in ["gpt-5", "sonnet-4-thinking", "claude-opus-4.1", "vendor/model:latest",
                   "claude-opus-4-8[context=1m,effort=high,fast=false]"] {
            #expect(CursorLaunchOptions.isModelToken(ok), "\(ok)")
        }
        for bad in ["", "gpt 5", "gpt-5; rm -rf ~", "$(id)", "gpt-5[", "gpt-5[context]", "gpt-5[a=b]x", "模型"] {
            #expect(!CursorLaunchOptions.isModelToken(bad), "\(bad)")
        }
    }

    @Test func aRequestBecomesArgumentsOrARejection() throws {
        var request = DispatchRequest(agent: .cursor, cwd: "/x/p", prompt: "go")
        #expect(try CursorLaunchOptions.from(request).get().arguments == [])
        request.mode = "Ask"
        request.worktree = true
        #expect(try CursorLaunchOptions.from(request).get().arguments == ["--mode", "ask", "-w"])
        request.mode = "agent"
        request.worktree = false
        request.model = " gpt-5 "
        #expect(try CursorLaunchOptions.from(request).get().arguments == ["--model", "gpt-5"])
        request.model = "gpt 5"
        #expect(CursorLaunchOptions.from(request) == .failure(.invalidModel("gpt 5")))
        request.model = nil
        request.mode = "edit"
        #expect(CursorLaunchOptions.from(request) == .failure(.invalidMode("edit")))
    }

    @Test func theTerminalFallbackPutsTheSameFlagsBeforeTheDoubleDash() {
        let options = CursorLaunchOptions(model: "gpt-5", mode: "plan", worktree: true)
        let parts = [CursorCLI.shellQuoted("/usr/local/bin/cursor-agent")] + options.arguments.map(CursorCLI.shellQuoted)
            + ["--", CursorCLI.shellQuoted("fix it")]
        #expect(CursorCLI.command(parts, cwd: "/x/p")
                == "cd '/x/p' && '/usr/local/bin/cursor-agent' '--model' 'gpt-5' '--mode' 'plan' '-w' -- 'fix it'")
    }
}
