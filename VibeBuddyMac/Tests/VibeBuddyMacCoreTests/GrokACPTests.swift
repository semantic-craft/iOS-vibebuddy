import Testing
import Foundation
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// A scripted `grok agent --no-leader stdio` on a pair of pipes. It answers the
/// handshake the way grok 1.0.40 does (probed 2026-09-21: `authMethods` with
/// `cached_token`, a `models` list on `session/new`) and leaves `session/prompt`
/// open until the test ends the turn.
private final class FakeGrokAgent: @unchecked Sendable {
    private let toAgent = Pipe()
    private let toClient = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var requests: [(id: Int, method: String, params: [String: Any])] = []
    private var responses: [Int: [String: Any]] = [:]
    private var nextID = 100
    private var promptsEnded = 0
    let sessionID: String
    var authMethods: [String] = ["cached_token", "grok.com"]
    /// What `session/load` answers with instead of success (grok 1.0.41 says
    /// `-32603 "Path not found."` for an id it has no directory for).
    var loadError: String?

    init(sessionID: String = "grok-acp-test-1") {
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
                switch method {
                case "initialize":
                    respond(id, ["protocolVersion": 1,
                                 "agentCapabilities": ["loadSession": true],
                                 "authMethods": authMethods.map { ["id": $0, "name": $0] },
                                 "_meta": ["agentVersion": "1.0.40"]])
                case "authenticate": respond(id, ["_meta": ["email": "x@y"]])
                case "session/load":
                    if let loadError {
                        write(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": loadError]])
                    } else {
                        // grok replays the history as updates before it answers.
                        update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "earlier"]])
                        respond(id, ["models": ["currentModelId": "grok-4.6",
                                                "availableModels": [["modelId": "grok-4.6", "name": "Grok 4.6",
                                                                     "_meta": ["totalContextTokens": 500000]]]]])
                    }
                case "session/new":
                    respond(id, ["sessionId": sessionID,
                                 "models": ["currentModelId": "grok-4.6",
                                            "availableModels": [["modelId": "grok-4.6", "name": "Grok 4.6",
                                                                 "_meta": ["totalContextTokens": 500000]]]]])
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

    func respond(_ id: Int, _ result: [String: Any]) { write(["jsonrpc": "2.0", "id": id, "result": result]) }

    func update(_ update: [String: Any]) {
        write(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": sessionID, "update": update]])
    }

    func notification(_ update: [String: Any]) {
        write(["jsonrpc": "2.0", "method": "_x.ai/session_notification", "params": ["sessionId": sessionID, "update": update]])
    }

    @discardableResult
    func ask(_ method: String, _ params: [String: Any]) -> Int {
        lock.lock(); let id = nextID; nextID += 1; lock.unlock()
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

    func close() { try? toClient.fileHandleForWriting.close() }
}

private final class LaunchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GrokACPLaunch] = []
    var launches: [GrokACPLaunch] { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ launch: GrokACPLaunch) { lock.lock(); stored.append(launch); lock.unlock() }
}

private func eventually(_ what: String, _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<600 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("never happened: \(what)")
}

/// grok 1.0.40's permission request, as probed on 2026-09-21.
private func permissionParams() -> [String: Any] { [
    "toolCall": ["toolCallId": "call-1", "kind": "execute", "title": "Execute `touch probe5.txt`",
                 "rawInput": ["variant": "Bash", "command": "touch probe5.txt", "description": "Create probe5.txt"],
                 "_meta": ["x.ai/tool": ["version": 1, "name": "run_terminal_command", "kind": "execute", "label": "Run Command"]]],
    "options": [["optionId": "always-allow", "name": "Yes, and don't ask again for bash commands", "kind": "allow_always"],
                ["optionId": "allow-once", "name": "Yes, proceed", "kind": "allow_once"],
                ["optionId": "reject-once", "name": "No, and tell Grok what to do differently", "kind": "reject_once"],
                ["optionId": "reject-always", "name": "No, and don't ask again for this command", "kind": "reject_always"]],
] }

private final class PermissionReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var enteredValue = false
    private var rulesReadValue = false
    var entered: Bool { lock.withLock { enteredValue } }
    var rulesRead: Bool { lock.withLock { rulesReadValue } }
    func markRulesRead() { lock.withLock { rulesReadValue = true } }
    func block() {
        lock.withLock { enteredValue = true }
        _ = releaseSignal.wait(timeout: .now() + 10)
    }
    func release() { releaseSignal.signal() }
}

private extension VibeBuddyAllowStore {
    func holdPermissionReads(_ gate: PermissionReadGate) { gate.block() }
}

@Suite("Grok ACP host")
struct GrokACPTests {
    private struct Rig {
        let store: SessionStore
        let approvals = ApprovalRegistry()
        let approvalContext = ApprovalContextStore()
        let questions = QuestionRegistry()
        let allowStore: VibeBuddyAllowStore
        let sessionAllow = SessionAllowList()
        let agent: FakeGrokAgent
        let log = LaunchLog()
        let monitor: GrokACPMonitor

        init(agent: FakeGrokAgent = FakeGrokAgent(), signedIn: Bool = true, deny: [String] = [],
             onRulesRead: @escaping @Sendable () -> Void = {}, journalURL: URL? = nil,
             recoveryDirectory: URL? = nil,
             openInTerminal: (@Sendable (String, String, String?) async -> Bool)? = nil) {
            self.agent = agent
            store = SessionStore(sourceID: "grok-test-source", journalURL: journalURL)
            let log = self.log
            allowStore = VibeBuddyAllowStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("vbgrok-\(UUID().uuidString).json"))
            monitor = GrokACPMonitor(store: store, approvals: approvals, approvalContext: approvalContext,
                                     questions: questions, allowStore: allowStore, sessionAllow: sessionAllow,
                                     rules: { _ in onRulesRead(); return PermissionRules(allow: [], deny: deny) },
                                     makeID: { UUID().uuidString },
                                     executable: URL(fileURLWithPath: "/usr/bin/true"),
                                     signInProbe: { signedIn },
                                     spawn: { launch in log.record(launch); return agent.client() },
                                     recoveryDirectory: recoveryDirectory, openInTerminal: openInTerminal)
        }

        func session() async -> AgentSession? {
            await store.snapshot(now: Date()).sessions.first { $0.id == agent.sessionID }
        }
    }

    private let request = DispatchRequest(agent: .grok, cwd: "/x/p", prompt: "fix the tests", name: nil)

    @Test func launchArgumentsAreAgentStdioWithoutLeader() {
        #expect(GrokACPLaunch(cwd: "/x").arguments == ["agent", "--no-leader", "stdio"])
        #expect(GrokACPLaunch(cwd: "/x", model: "grok-4.6").arguments == ["agent", "-m", "grok-4.6", "--no-leader", "stdio"])
        #expect(GrokACPLaunch.validModel("--yolo").isFailure)
        #expect(GrokACPLaunch.validModel("grok 4").isFailure)
    }

    // MARK: - Recovery (AI-02)

    private func recoveryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vbgrok-acp-\(UUID().uuidString)")
    }

    @Test func aHostedSessionReloadsAfterTheHostRestarts() async throws {
        let directory = recoveryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Rig(recoveryDirectory: directory)
        _ = await first.monitor.dispatch(request)
        await eventually("prompt") { first.agent.request(named: "session/prompt") != nil }
        first.agent.endTurn("end_turn")
        await eventually("done") { await first.session()?.status == .done }
        let records = GrokACPRecovery.read(in: directory)
        #expect(records.map(\.sessionID) == [first.agent.sessionID])
        #expect(records.first?.cwd == "/x/p")
        #expect(records.first?.model == "grok-4.6")
        let file = directory.appendingPathComponent(try #require(records.first).filename + ".json")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        await first.monitor.shutdown()

        // A new host: the row is back as a reloadable one, not a live channel.
        let second = Rig(agent: FakeGrokAgent(sessionID: first.agent.sessionID), recoveryDirectory: directory)
        await second.monitor.registerRecoverableSessions()
        let row = try #require(await second.session())
        #expect(row.agent == .grok)
        #expect(row.cursorACPRecoverable == true)
        #expect(row.controlChannel == ControlChannel.none)
        let support = SessionActionSupport.resolve(for: row)
        #expect(support.intent == .continue && support.isAvailable)
        #expect(support.note?.contains("Grok Build") == true)
        #expect(second.log.launches.isEmpty, "registering starts no process")

        #expect(await second.monitor.prompt(sessionID: row.id, text: "go on"))
        let load = try #require(second.agent.request(named: "session/load"))
        #expect(load.params["sessionId"] as? String == row.id)
        #expect(load.params["cwd"] as? String == "/x/p")
        #expect(second.log.launches == [GrokACPLaunch(cwd: "/x/p", model: "grok-4.6")])
        await eventually("prompt after load") { second.agent.request(named: "session/prompt") != nil }
        #expect(second.agent.request(named: "session/prompt")?.params["prompt"] as? [[String: String]]
            == [["type": "text", "text": "go on"]])
        #expect(await second.store.isACPHosted(row.id))
        await eventually("working") { await second.session()?.status == .working }
        #expect(await second.session()?.controlChannel == .acp)
        await second.monitor.shutdown()
    }

    @Test func aFailedReloadSaysWhyAndReopensInATerminal() async throws {
        let directory = recoveryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "01a0ffff-0000-7000-8000-000000000000"
        try GrokACPRecovery(sessionID: id, cwd: "/x/gone", model: nil, createdAt: Date()).save(in: directory)
        let agent = FakeGrokAgent(sessionID: id)
        agent.loadError = "Path not found."
        let opened = LaunchLog()
        let rig = Rig(agent: agent, recoveryDirectory: directory, openInTerminal: { session, cwd, _ in
            opened.record(GrokACPLaunch(cwd: cwd, model: session)); return true
        })
        await rig.monitor.registerRecoverableSessions()
        #expect(await rig.monitor.prompt(sessionID: id, text: "go on") == false)
        let row = try #require(await rig.session())
        #expect(row.cursorACPRecoveryFailure?.contains("Path not found.") == true)
        #expect(row.cursorACPRecoveryFailure?.contains("grok --resume") == true)
        #expect(SessionActionSupport.resolve(for: row).isAvailable, "a retry stays possible")
        #expect(await rig.store.isACPHosted(id) == false)

        #expect(await rig.monitor.resumeInTerminal(sessionID: id, preferring: nil) == .attached)
        #expect(opened.launches == [GrokACPLaunch(cwd: "/x/gone", model: id)])
        #expect(GrokACPRecovery.read(in: directory).isEmpty)
        #expect(await rig.session() == nil, "the terminal owns it now")
        #expect(await rig.monitor.owns(id) == false)
    }

    @Test func theTerminalCommandIsQuotedAndTheIDChecked() {
        let grok = URL(fileURLWithPath: "/Users/me/.grok/bin/grok")
        #expect(GrokCLI.resumeCommand(sessionID: "01a0d2ed-aa8e-7090-b6fc-bdd78d5beab3", cwd: "/tmp/a b'c", executable: grok)
            == "cd '/tmp/a b'\\''c' && '/Users/me/.grok/bin/grok' --resume=01a0d2ed-aa8e-7090-b6fc-bdd78d5beab3")
        for bad in ["", "-rf", "a;b", "a b", "$(x)"] {
            #expect(GrokCLI.resumeCommand(sessionID: bad, cwd: nil, executable: grok) == nil, "\(bad)")
        }
    }

    @Test func aDispatchBecomesAWorkingSessionOnTheACPChannel() async throws {
        let rig = Rig()
        let outcome = await rig.monitor.dispatch(request)
        #expect(outcome == .started(sessionID: rig.agent.sessionID))
        #expect(rig.log.launches == [GrokACPLaunch(cwd: "/x/p", model: nil)])
        #expect(rig.agent.request(named: "authenticate")?.params["methodId"] as? String == "cached_token")
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        await eventually("working") { await rig.session()?.status == .working }
        let session = await rig.session()
        #expect(session?.agent == .grok)
        #expect(session?.model == "grok-4.6")
        #expect(session?.controlChannel == .acp)
        #expect(await rig.store.isACPHosted(rig.agent.sessionID))
        #expect(SessionActionSupport.resolve(for: session!).isAvailable)
        #expect(SessionActionSupport.resolveStop(for: session!).isAvailable)
        #expect(await rig.monitor.hosts(rig.agent.sessionID))
    }

    @Test func hostedResultsSurviveCorroboratingHooksAcrossTurns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rig = Rig(journalURL: directory.appendingPathComponent("lifecycle.json"))
        var completions: [String] = []
        _ = await rig.monitor.dispatch(request)
        for index in 0..<2 {
            await eventually("prompt") { rig.agent.request(named: "session/prompt", after: index) != nil }
            let nativeTurn = "native-prompt-\(index)"
            await rig.store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: rig.agent.sessionID,
                agent: .grok, observationSource: .hook, timestamp: Date(), turnID: nativeTurn))
            let text = "Result for turn \(index)."
            rig.agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]])
            await rig.store.ingest(HookEvent(kind: .stop, sessionID: rig.agent.sessionID, agent: .grok,
                observationSource: .hook, timestamp: Date(), turnID: nativeTurn, completionText: text, completionSucceeded: true))
            rig.agent.endTurn("end_turn")
            await eventually("done") { await rig.session()?.status == .done }
            let session = try #require(await rig.session())
            let completion = try #require(session.completionID)
            let body = await rig.store.completionBody(sessionID: session.id, completionID: completion)
            #expect(body.text == text)
            completions.append(completion)
            if index == 0 {
                #expect(await rig.monitor.prompt(sessionID: session.id, text: "next"))
            }
        }
        let ledger = RecapLedger(url: directory.appendingPathComponent("recap-ledger.json"))
        for (index, completion) in completions.enumerated() {
            let key = RecapEntry.completedID(sourceID: "grok-test-source", sessionID: rig.agent.sessionID, completionID: completion)
            #expect(ledger.results[key]?.text == "Result for turn \(index).")
        }
        await rig.monitor.shutdown()
    }

    @Test func firstWebSocketSnapshotAdvertisesGrokWithoutHTTPWarmup() async throws {
        let rig = Rig()
        let server = VibeBuddyServer(store: rig.store, token: "cold-stream", host: "127.0.0.1", port: 0,
                                     backgroundSessions: { [] }, grokACP: rig.monitor)
        try await server.buildApplication().test(.live) { client in
            let port = try #require(client.port)
            var request = URLRequest(url: URL(string: "ws://localhost:\(port)/ws")!)
            request.setValue("Bearer cold-stream", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.resume()
            defer { socket.cancel(with: .normalClosure, reason: nil) }
            guard case let .string(message) = try await socket.receive(),
                  case let .snapshot(snapshot) = try JSONDecoder().decode(ServerEvent.self, from: Data(message.utf8)) else {
                Issue.record("Expected the first live snapshot")
                return
            }
            #expect(snapshot.dispatchAgents?.contains(.grok) == true)
        }
    }

    @Test func phoneWireContractContinuesHostedGrokAndRejectsStaleRound() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("first prompt") { rig.agent.request(named: "session/prompt") != nil }
        rig.agent.endTurn("end_turn")
        await eventually("done") { await rig.session()?.status == .done }
        let session = try #require(await rig.session())
        let server = VibeBuddyServer(store: rig.store, token: "t0k", grokACP: rig.monitor)
        try await server.buildApplication().test(.router) { client in
            // Match DecisionClient.phoneAnswer, including its empty question identity.
            for stale in [true, false] {
                let body: [String: Any] = ["sessionId": session.id, "expectedQuestionId": "",
                    "intent": "continue", "requestId": UUID().uuidString,
                    "expectedStatusSince": session.statusSince.timeIntervalSince1970 + (stale ? 5 : 0),
                    "answer": "PHONE_CONTINUED"]
                try await client.execute(uri: "/answer", method: .post,
                    headers: [.authorization: "Bearer t0k"],
                    body: ByteBuffer(data: try JSONSerialization.data(withJSONObject: body))) { response in
                    #expect(response.status == (stale ? .conflict : .ok))
                }
                if stale { #expect(rig.agent.requests(named: "session/prompt").count == 1) }
            }
        }
        await eventually("phone continuation") { rig.agent.requests(named: "session/prompt").count == 2 }
        let prompt = rig.agent.request(named: "session/prompt", after: 1)?.params["prompt"] as? [[String: Any]]
        #expect(prompt?.first?["text"] as? String == "PHONE_CONTINUED")
        await rig.monitor.shutdown()
    }

    @Test func signedOutOrMissingCLIIsReportedNotSpawned() async {
        let signedOut = Rig(signedIn: false)
        #expect(await signedOut.monitor.isSupported() == false)
        guard case .unavailable(let why) = await signedOut.monitor.dispatch(request) else { Issue.record("dispatched"); return }
        #expect(why.contains("signed in"))
        #expect(signedOut.log.launches.isEmpty)

        let noToken = FakeGrokAgent()
        noToken.authMethods = ["grok.com"]
        let rig = Rig(agent: noToken)
        guard case .unavailable = await rig.monitor.dispatch(request) else { Issue.record("dispatched without a cached token"); return }
        #expect(noToken.request(named: "authenticate") == nil)
    }

    @Test func aPermissionRequestBecomesACardAndTheDecisionSelectsTheOption() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let id = rig.agent.ask("session/request_permission", permissionParams())
        await eventually("card") { await rig.session()?.pendingApproval != nil }
        let approval = await rig.session()!.pendingApproval!
        #expect(approval.tool == "Bash")
        #expect(approval.command == "touch probe5.txt")
        #expect(approval.isAnswerable)
        #expect(await rig.session()?.status == .needsResponse)
        await rig.approvals.resolve(id: approval.id, with: .allow)
        await eventually("answered") { rig.agent.response(to: id) != nil }
        let outcome = (rig.agent.response(to: id)?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "selected")
        #expect(outcome?["optionId"] as? String == "allow-once")
        await eventually("card gone") { await rig.session()?.pendingApproval == nil }
    }

    @Test func aDeniedPermissionEndsTheTurnAsAChosenEndingNotAFailure() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let id = rig.agent.ask("session/request_permission", permissionParams())
        await eventually("card") { await rig.session()?.pendingApproval != nil }
        await rig.approvals.resolve(id: await rig.session()!.pendingApproval!.id, with: .deny)
        await eventually("answered") { rig.agent.response(to: id) != nil }
        let outcome = (rig.agent.response(to: id)?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["optionId"] as? String == "reject-once")
        // grok answers a rejected permission with `cancelled` (StopCancelled/permission_rejected).
        rig.agent.endTurn("cancelled")
        await eventually("done") { await rig.session()?.status == .done }
        let session = await rig.session()
        #expect(session?.failed != true)
        #expect(session?.userStopped != true)
    }

    @Test func nativeDenyRuleAnswersWithoutACard() async throws {
        let rig = Rig(deny: ["Bash(touch:*)"])
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let id = rig.agent.ask("session/request_permission", permissionParams())
        await eventually("answered") { rig.agent.response(to: id) != nil }
        let outcome = (rig.agent.response(to: id)?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["optionId"] as? String == "reject-once")
        #expect(await rig.session()?.pendingApproval == nil)
    }

    @Test func aQuestionBecomesACardAndTheAnswerIsKeyedByQuestionText() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let id = rig.agent.ask("_x.ai/ask_user_question", [
            "toolCallId": "call-q", "mode": "default",
            "questions": [["question": "Which color?", "multiSelect": NSNull(),
                           "options": [["label": "Red", "description": "Red"], ["label": "Blue", "description": "Blue"]]]],
        ])
        await eventually("question") { await rig.session()?.pendingQuestion != nil }
        // The card is published an actor hop before the monitor starts waiting.
        await eventually("waiting") { await rig.questions.isWaiting(sessionID: rig.agent.sessionID) }
        let question = await rig.session()!.pendingQuestion!
        #expect(question.items.first?.text == "Which color?")
        #expect(question.items.first?.options.map(\.label) == ["Red", "Blue"])
        #expect(question.isAnswerable)
        #expect(await rig.questions.resolveExact(sessionID: rig.agent.sessionID, questionID: question.id,
                                                 answers: [question.items[0].id: ["Red"]]))
        await eventually("answered") { rig.agent.response(to: id) != nil }
        let result = rig.agent.response(to: id)?["result"] as? [String: Any]
        #expect(result?["outcome"] as? String == "accepted")
        #expect((result?["answers"] as? [String: String]) == ["Which color?": "Red"])
        await eventually("card gone") { await rig.session()?.pendingQuestion == nil }
    }

    @Test func aSupplementWaitsForTheTurnAndGoesOutAsTheNextPrompt() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        #expect(await rig.monitor.queueFollowup(sessionID: rig.agent.sessionID, text: "also run lint"))
        #expect(await rig.monitor.prompt(sessionID: rig.agent.sessionID, text: "nope") == false)
        rig.agent.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Done."]])
        rig.agent.endTurn("end_turn")
        await eventually("second prompt") { rig.agent.request(named: "session/prompt", after: 1) != nil }
        let second = rig.agent.request(named: "session/prompt", after: 1)?.params
        #expect(((second?["prompt"] as? [[String: Any]])?.first?["text"] as? String) == "also run lint")
        await eventually("working again") { await rig.session()?.status == .working }
        rig.agent.endTurn("end_turn")
        await eventually("done") { await rig.session()?.status == .done }
        #expect(await rig.monitor.prompt(sessionID: rig.agent.sessionID, text: "continue"))
        await eventually("third prompt") { rig.agent.request(named: "session/prompt", after: 2) != nil }
    }

    @Test func toolCallsUseGrokVocabularyAndUsageFillsContext() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        rig.agent.update(["sessionUpdate": "tool_call", "toolCallId": "c1", "title": "write",
                          "rawInput": ["file_path": "/x/p/a.txt", "content": "hello"],
                          "_meta": ["x.ai/tool": ["name": "write", "kind": "write"]]])
        await eventually("active tool") { await rig.session()?.activeTool == "Write" }
        rig.agent.update(["sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed"])
        rig.agent.update(["sessionUpdate": "session_info_update", "title": "Write hello file"])
        await eventually("title") { await rig.session()?.name == "Write hello file" }
        rig.agent.notification(["sessionUpdate": "turn_completed", "prompt_id": "p1", "stop_reason": "end_turn",
                                "usage": ["inputTokens": 58475, "outputTokens": 167, "totalTokens": 58642]])
        await eventually("context") { await rig.session()?.contextTokens == 58642 }
        #expect(await rig.session()?.contextWindow == 500000)
        rig.agent.endTurn("end_turn")
        await eventually("done") { await rig.session()?.status == .done }
    }

    @Test func aCancelIsTheUsersStopAndWithdrawsOpenCards() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let id = rig.agent.ask("session/request_permission", permissionParams())
        await eventually("card") { await rig.session()?.pendingApproval != nil }
        let session = await rig.session()!
        #expect(await rig.monitor.cancel(sessionID: session.id) == .sent)
        await eventually("cancel sent") { rig.agent.request(named: "session/cancel") != nil }
        await eventually("card withdrawn") { rig.agent.response(to: id) != nil }
        let outcome = (rig.agent.response(to: id)?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        #expect(outcome?["outcome"] as? String == "cancelled")
        rig.agent.endTurn("cancelled")
        await eventually("done") { await rig.session()?.status == .done }
        #expect(await rig.session()?.userStopped == true)
        #expect(await rig.session()?.failed != true)
    }

    @Test func cancellingWhilePermissionRulesLoadCannotReopenTheFinishedTurn() async throws {
        let gate = PermissionReadGate()
        let rig = Rig(onRulesRead: { gate.markRulesRead() })
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        let blockedRead = Task { await rig.allowStore.holdPermissionReads(gate) }
        await eventually("blocked permission actor") { gate.entered }
        let rpc = rig.agent.ask("session/request_permission", permissionParams())
        await eventually("permission handler reached rules") { gate.rulesRead }
        _ = await rig.monitor.cancel(sessionID: rig.agent.sessionID)
        rig.agent.endTurn("cancelled")
        await eventually("cancelled turn ended") { await rig.session()?.status == .done }
        gate.release()
        await blockedRead.value
        await eventually("cancelled permission reply") { rig.agent.response(to: rpc) != nil }
        let session = try #require(await rig.session())
        #expect(session.status == .done)
        #expect(session.pendingApproval == nil)
        let result = rig.agent.response(to: rpc)?["result"] as? [String: Any]
        #expect((result?["outcome"] as? [String: Any])?["outcome"] as? String == "cancelled")
        await rig.monitor.shutdown()
    }

    @Test func theProcessExitingEndsTheTurnAndReleasesTheHost() async throws {
        let rig = Rig()
        _ = await rig.monitor.dispatch(request)
        await eventually("prompt") { rig.agent.request(named: "session/prompt") != nil }
        rig.agent.close()
        await eventually("done") { await rig.session()?.status == .done }
        #expect(await rig.session()?.failed == true)
        await eventually("released") { await rig.store.isACPHosted(rig.agent.sessionID) == false }
        #expect(await rig.monitor.hosts(rig.agent.sessionID) == false)
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
}
