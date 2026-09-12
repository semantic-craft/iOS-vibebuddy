import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// A pass counter the scripted transport can bump from a `@Sendable` closure.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

/// Scripted `api.cursor.com`. Records every request so a test can assert what
/// was — and was not — sent.
final class ScriptedCursorCloudTransport: CursorCloudTransport, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func cursorCloudData(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(request) }
        return try handler(request)
    }

    static func json(_ body: String, status: Int = 200, for request: URLRequest) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                          httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Cursor Cloud Agents API")
struct CursorCloudAgentTests {
    static let agentID = "bc-00000000-0000-0000-0000-000000000001"
    static let runID = "run-00000000-0000-0000-0000-000000000001"
    static let key = "key_supersecret_value"

    static func client(_ transport: ScriptedCursorCloudTransport,
                       apiKey: String? = key) -> CursorCloudAgentClient {
        CursorCloudAgentClient(baseURL: URL(string: "https://api.cursor.example")!,
                               apiKey: { apiKey }, transport: transport)
    }

    // MARK: - Wire

    @Test("list reads v1 agents, sends the key as a bearer token and skips archived")
    func listAgents() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            let body = """
            {"items":[{"id":"\(Self.agentID)","name":"Fix the parser","status":"ACTIVE",
            "env":{"type":"cloud"},"url":"https://cursor.com/agents/x",
            "updatedAt":"2026-09-12T10:00:00Z","latestRunId":"\(Self.runID)"}]}
            """
            return ScriptedCursorCloudTransport.json(body, for: request)
        }
        let agents = try await Self.client(transport).agents()
        #expect(agents.count == 1)
        #expect(agents[0].id == Self.agentID)
        #expect(agents[0].status == .active)
        #expect(agents[0].name == "Fix the parser")
        #expect(agents[0].environment == "cloud")
        #expect(agents[0].latestRunID == Self.runID)

        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/v1/agents")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
        let query = try #require(request.url?.query)
        #expect(query.contains("includeArchived=false"))
    }

    @Test("list follows nextCursor to the end")
    func listPaginates() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
            let body = cursor == nil
                ? #"{"items":[{"id":"bc-1","status":"IDLE"}],"nextCursor":"page2"}"#
                : #"{"items":[{"id":"bc-2","status":"ACTIVE"}]}"#
            return ScriptedCursorCloudTransport.json(body, for: request)
        }
        let agents = try await Self.client(transport).agents()
        #expect(agents.map(\.id) == ["bc-1", "bc-2"])
        #expect(transport.requests.count == 2)
    }

    @Test("an agent status this build does not know is dropped, not guessed at")
    func unknownStatusDropped() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            ScriptedCursorCloudTransport.json(
                #"{"items":[{"id":"bc-1","status":"HIBERNATING"},{"id":"bc-2","status":"IDLE"}]}"#,
                for: request)
        }
        let agents = try await Self.client(transport).agents()
        #expect(agents.map(\.id) == ["bc-2"])
    }

    @Test("a follow-up is POST /v1/agents/{id}/runs with the documented prompt body")
    func startRunShape() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            ScriptedCursorCloudTransport.json(
                #"{"run":{"id":"run-9","agentId":"bc-1","status":"CREATING"}}"#, for: request)
        }
        let run = try await Self.client(transport).startRun(agentID: "bc-1", text: "  keep going  ")
        #expect(run.status == .creating)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/agents/bc-1/runs")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let prompt = try #require(json["prompt"] as? [String: Any])
        #expect(prompt["text"] as? String == "keep going")
    }

    @Test("a terminal run carries its result and branch")
    func runDetail() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            let body = """
            {"id":"\(Self.runID)","agentId":"\(Self.agentID)","status":"FINISHED",
            "result":"Renamed the field and updated both call sites.",
            "git":{"branches":[{"repoUrl":"github.com/a/b","branch":"cursor/fix-1","prUrl":"https://github.com/a/b/pull/3"}]}}
            """
            return ScriptedCursorCloudTransport.json(body, for: request)
        }
        let run = try await Self.client(transport).run(agentID: Self.agentID, runID: Self.runID)
        #expect(run.status == .finished)
        #expect(run.result == "Renamed the field and updated both call sites.")
        #expect(run.branch == "cursor/fix-1")
        #expect(run.pullRequestURL == "https://github.com/a/b/pull/3")
    }

    // MARK: - Refusals

    @Test("409 agent_busy is its own error, and any other 409 is not mistaken for it")
    func busyIsDistinct() async throws {
        let busy = ScriptedCursorCloudTransport { request in
            ScriptedCursorCloudTransport.json(#"{"code":"agent_busy","message":"A run is active"}"#,
                                              status: 409, for: request)
        }
        await #expect(throws: CursorCloudError.busy) {
            try await Self.client(busy).startRun(agentID: "bc-1", text: "hi")
        }
        let other = ScriptedCursorCloudTransport { request in
            ScriptedCursorCloudTransport.json(#"{"code":"repo_locked"}"#, status: 409, for: request)
        }
        await #expect(throws: CursorCloudError.service(status: 409, code: "repo_locked")) {
            try await Self.client(other).startRun(agentID: "bc-1", text: "hi")
        }
    }

    @Test("no key means no request is ever sent")
    func missingKey() async throws {
        let transport = ScriptedCursorCloudTransport { _ in
            Issue.record("Must not call Cursor without a key")
            throw CursorCloudError.transport
        }
        await #expect(throws: CursorCloudError.missingKey) {
            try await Self.client(transport, apiKey: nil).agents()
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("a busy agent is told to wait, and every refusal keeps the key out of its text",
          arguments: [(409, #"{"code":"agent_busy"}"#), (401, "{}"), (404, "{}"), (429, "{}"), (500, "{}")])
    func refusalCopyNeverEchoesTheKey(status: Int, body: String) async throws {
        let transport = ScriptedCursorCloudTransport { request in
            ScriptedCursorCloudTransport.json(body, status: status, for: request)
        }
        let outcome = await Self.client(transport).continueAgent(id: "bc-1", text: "go")
        guard case let .failed(message) = outcome else {
            #expect(status == 500, "only an unclassified failure may answer `unknown`")
            return
        }
        #expect(!message.contains(Self.key))
        #expect(!message.isEmpty)
        if status == 409 { #expect(message.contains("finishes")) }
    }

    @Test("a started run reports accepted")
    func continueAccepted() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            ScriptedCursorCloudTransport.json(
                #"{"run":{"id":"run-9","agentId":"bc-1","status":"CREATING"}}"#, for: request)
        }
        let outcome = await Self.client(transport).continueAgent(id: "bc-1", text: "go")
        #expect(outcome == .accepted)
    }

    // MARK: - Monitor

    /// A scripted account: one list response per pass, plus agent detail and run
    /// detail for whatever is asked.
    static func monitorTransport(_ statuses: [[String: String]],
                                 runStatus: String = "FINISHED",
                                 result: String? = "Done.",
                                 repo: String? = "github.com/org/repo") -> ScriptedCursorCloudTransport {
        let passes = Counter()
        return ScriptedCursorCloudTransport { request in
            let path = request.url!.path
            if path.contains("/runs/") {
                let body = """
                {"id":"\(Self.runID)","agentId":"\(Self.agentID)","status":"\(runStatus)"
                \(result.map { ",\"result\":\"\($0)\"" } ?? "")}
                """
                return ScriptedCursorCloudTransport.json(body, for: request)
            }
            // Per-agent detail: /v1/agents/{id} with nothing after it.
            if path.hasPrefix("/v1/agents/") {
                let id = String(path.dropFirst("/v1/agents/".count))
                let repos = repo.map { #","repos":[{"url":"\#($0)"}]"# } ?? ""
                return ScriptedCursorCloudTransport.json(
                    #"{"id":"\#(id)","status":"IDLE"\#(repos)}"#, for: request)
            }
            let index = min(passes.next(), statuses.count - 1)
            let items = statuses[index].map { id, status in
                #"{"id":"\#(id)","status":"\#(status)","latestRunId":"\#(Self.runID)","updatedAt":"2026-09-12T10:00:00Z"}"#
            }.joined(separator: ",")
            return ScriptedCursorCloudTransport.json("{\"items\":[\(items)]}", for: request)
        }
    }

    static func monitor(_ transport: ScriptedCursorCloudTransport,
                        apiKey: String? = key) -> CursorCloudAgentMonitor {
        CursorCloudAgentMonitor(client: client(transport, apiKey: apiKey))
    }

    @Test("an agent nothing on this Mac has ever seen still gets a row")
    func rowsComeFromTheAPI() async throws {
        // The decisive case: this Mac's Cursor database holds no bc- rows at
        // all, so a design that waited for one would show nothing, ever.
        let transport = Self.monitorTransport([[Self.agentID: "ACTIVE"]])
        let (agents, events) = await Self.monitor(transport).pass(now: Date())
        #expect(agents?.map(\.id) == [Self.agentID])
        #expect(agents?.first?.repository == "github.com/org/repo")
        #expect(events.map(\.kind) == [.userPromptSubmit])
        // The repository stands in for a project: a cloud agent has no folder.
        #expect(events.first?.cwd == "github.com/org/repo")
        #expect(events.first?.observationSource == .cloud)
    }

    @Test("an agent already idle at launch replays nothing but is still reported")
    func idleAtLaunchIsSilentNotInvisible() async throws {
        let transport = Self.monitorTransport([[Self.agentID: "IDLE"]])
        let monitor = Self.monitor(transport)
        let (agents, events) = await monitor.pass(now: Date())
        #expect(events.isEmpty)
        // Silent, but present — it becomes a quiet history row.
        #expect(agents?.map(\.id) == [Self.agentID])
        let (_, again) = await monitor.pass(now: Date())
        #expect(again.isEmpty)
    }

    @Test("running then idle ends the turn with the run's own result")
    func activeToIdleCompletes() async throws {
        let transport = Self.monitorTransport([[Self.agentID: "ACTIVE"], [Self.agentID: "IDLE"]])
        let monitor = Self.monitor(transport)
        _ = await monitor.pass(now: Date())
        let (_, events) = await monitor.pass(now: Date())
        #expect(events.map(\.kind) == [.stop])
        #expect(events.first?.completionSucceeded == true)
        #expect(events.first?.completionText == "Done.")
    }

    @Test("a run that errored ends the turn without claiming success")
    func erroredRunIsNotSuccess() async throws {
        let transport = Self.monitorTransport([[Self.agentID: "ACTIVE"], [Self.agentID: "IDLE"]],
                                              runStatus: "ERROR", result: nil)
        let monitor = Self.monitor(transport)
        _ = await monitor.pass(now: Date())
        let (_, events) = await monitor.pass(now: Date())
        #expect(events.first?.kind == .stop)
        #expect(events.first?.completionSucceeded == false)
        #expect(events.first?.completionText == nil)
    }

    @Test("a cancelled run reads as an ending the person asked for")
    func cancelledRunIsAUserStop() async throws {
        let transport = Self.monitorTransport([[Self.agentID: "ACTIVE"], [Self.agentID: "IDLE"]],
                                              runStatus: "CANCELLED", result: nil)
        let monitor = Self.monitor(transport)
        _ = await monitor.pass(now: Date())
        let (_, events) = await monitor.pass(now: Date())
        #expect(events.first?.userStopped == true)
        #expect(events.first?.completionSucceeded == false)
    }

    @Test("the repository is fetched once and then reused")
    func repositoryIsCached() async throws {
        let transport = Self.monitorTransport([[Self.agentID: "ACTIVE"], [Self.agentID: "ACTIVE"]])
        let monitor = Self.monitor(transport)
        _ = await monitor.pass(now: Date())
        _ = await monitor.pass(now: Date())
        let details = transport.requests.filter {
            $0.url!.path.hasPrefix("/v1/agents/") && !$0.url!.path.contains("/runs")
        }
        #expect(details.count == 1)
    }

    @Test("without a key the monitor never reaches the network")
    func monitorNeedsAKey() async throws {
        let transport = ScriptedCursorCloudTransport { _ in
            Issue.record("Must not poll Cursor without a key")
            throw CursorCloudError.transport
        }
        let (agents, events) = await Self.monitor(transport, apiKey: nil).pass(now: Date())
        #expect(agents?.isEmpty == true)
        #expect(events.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    @Test("a failed poll applies nothing — an unreachable API is not an empty account")
    func failedPollAppliesNothing() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            ScriptedCursorCloudTransport.json("{}", status: 500, for: request)
        }
        let (agents, events) = await Self.monitor(transport).pass(now: Date())
        // nil, not [] — [] would wipe every row the last good pass established.
        #expect(agents == nil)
        #expect(events.isEmpty)
    }

    @Test("an agent that leaves the list ends, once")
    func vanishedAgentEnds() async throws {
        let transport = Self.monitorTransport([[Self.agentID: "ACTIVE"], [:]])
        let monitor = Self.monitor(transport)
        _ = await monitor.pass(now: Date())
        let (_, events) = await monitor.pass(now: Date())
        #expect(events.map(\.kind) == [.sessionEnd])
        let (_, again) = await monitor.pass(now: Date())
        #expect(again.isEmpty)
    }

    // MARK: - Jump

    @Test("only a Cursor page is ever handed to a browser",
          arguments: ["http://cursor.com/agents/x",
                      "https://evil.com/agents/x",
                      "https://cursor.com.evil.com/x",
                      "https://user:pw@cursor.com/x",
                      "javascript:alert(1)",
                      "not a url at all"])
    func jumpRejectsAnythingElse(_ page: String) async {
        #expect(CursorCloudJumper.validated(page) == nil)
        let outcome = await CursorCloudJumper.jump(page: page) { _ in
            Issue.record("Must not open \(page)")
            return true
        }
        #expect(outcome == .unsupported)
    }

    @Test("a Cursor agent page opens", arguments: ["https://cursor.com/agents/bc-1",
                                                  "https://www.cursor.com/agents/bc-1"])
    func jumpOpensTheAgentPage(_ page: String) async {
        let outcome = await CursorCloudJumper.jump(page: page) { url in
            #expect(url.absoluteString == page)
            return true
        }
        #expect(outcome == .focused)
    }

    // MARK: - Cancel

    @Test("cancelling a live run is sent")
    func cancelSent() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/agents/bc-1/runs/run-1/cancel")
            return ScriptedCursorCloudTransport.json(#"{"id":"run-1"}"#, for: request)
        }
        let outcome = await Self.client(transport).cancel(agentID: "bc-1", runID: "run-1")
        #expect(outcome == .sent)
    }

    @Test("a run that already finished is refused, not reported as failure")
    func cancelNotCancellable() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            ScriptedCursorCloudTransport.json(#"{"code":"run_not_cancellable"}"#,
                                              status: 409, for: request)
        }
        let outcome = await Self.client(transport).cancel(agentID: "bc-1", runID: "run-1")
        #expect(outcome == .notSent("This run has already finished."))
    }

    @Test("a cancel that never reached Cursor is unconfirmed, never retried")
    func cancelUnconfirmed() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            ScriptedCursorCloudTransport.json("{}", status: 500, for: request)
        }
        let outcome = await Self.client(transport).cancel(agentID: "bc-1", runID: "run-1")
        #expect(outcome == .unconfirmed)
        #expect(transport.requests.count == 1)
    }

    // MARK: - Conversation

    @Test("the runs list is the conversation v1 has no endpoint for")
    func recentOutputFromRuns() async throws {
        let transport = ScriptedCursorCloudTransport { request in
            #expect(request.url?.path == "/v1/agents/bc-1/runs")
            let body = """
            {"items":[
              {"id":"run-3","agentId":"bc-1","status":"RUNNING"},
              {"id":"run-2","agentId":"bc-1","status":"ERROR"},
              {"id":"run-1","agentId":"bc-1","status":"FINISHED","result":"Renamed the field."}
            ]}
            """
            return ScriptedCursorCloudTransport.json(body, for: request)
        }
        let output = await Self.client(transport).recentOutput(agentID: "bc-1")
        #expect(output.source == .cloud)
        #expect(output.unavailable == nil)
        // Oldest first, the way a conversation reads. The still-running run has
        // nothing to say yet and contributes no line.
        #expect(output.entries.map(\.text) == ["Renamed the field.", "This run ended with an error."])
    }

    @Test("no key is no source, and an unreachable API is an unreadable one")
    func recentOutputUnavailability() async throws {
        let none = ScriptedCursorCloudTransport { _ in
            Issue.record("Must not call Cursor without a key")
            throw CursorCloudError.transport
        }
        let missing = await Self.client(none, apiKey: nil).recentOutput(agentID: "bc-1")
        #expect(missing.unavailable == .noSource)

        let broken = ScriptedCursorCloudTransport { request in
            ScriptedCursorCloudTransport.json("{}", status: 500, for: request)
        }
        let unreadable = await Self.client(broken).recentOutput(agentID: "bc-1")
        #expect(unreadable.unavailable == .unreadable)
    }

    // MARK: - What the composer may send

    static func cloudSession(status: SessionStatus,
                             observations: [ObservationEvidence]?) -> AgentSession {
        let now = Date()
        var session = AgentSession(id: agentID, agent: .cursor, project: "/tmp/repo",
                                   status: status, statusSince: now, updatedAt: now)
        session.observations = observations
        return session
    }

    static let cloudEvidence = [ObservationEvidence(source: .cloud, lastObservedAt: Date(),
                                                    health: .healthy)]

    @Test("a running cloud agent refuses a supplement — Cursor allows one run at a time")
    func runningCloudAgentRefusesSteer() {
        let support = SessionActionSupport.resolve(
            for: Self.cloudSession(status: .working, observations: Self.cloudEvidence))
        #expect(support.intent == .steer)
        #expect(!support.isAvailable)
        #expect(support.unsupportedReason?.contains("busy") == true)
    }

    @Test("an idle cloud agent takes the next run, and says where it lands")
    func idleCloudAgentContinues() {
        let support = SessionActionSupport.resolve(
            for: Self.cloudSession(status: .done, observations: Self.cloudEvidence))
        #expect(support.intent == .continue)
        #expect(support.isAvailable)
        #expect(support.note?.contains("cloud agent") == true)
    }

    @Test("a cloud agent with no reachable API asks for the key, not for Cursor's hooks")
    func unreachableCloudAgentAsksForTheKey() {
        for status: SessionStatus in [.working, .done] {
            let support = SessionActionSupport.resolve(
                for: Self.cloudSession(status: status, observations: nil))
            #expect(!support.isAvailable)
            #expect(support.unsupportedReason?.contains("API key") == true)
            // The local-Cursor copy would send the person to the hook installer,
            // which does nothing for an agent that never runs on this Mac.
            #expect(support.unsupportedReason?.contains("hooks") != true)
        }
    }

    @Test("a hooked local Cursor chat is unaffected by any of this")
    func localCursorUnchanged() {
        let now = Date()
        var session = AgentSession(id: "11111111-2222-3333-4444-555555555555", agent: .cursor,
                                   project: "/tmp/repo", status: .working,
                                   statusSince: now, updatedAt: now)
        session.observations = [ObservationEvidence(source: .hook, lastObservedAt: Date(),
                                                    health: .healthy)]
        let support = SessionActionSupport.resolve(for: session)
        #expect(support.intent == .steer)
        #expect(support.isAvailable)
        #expect(support.note?.contains("queued") == true)
    }

    @Test("a live cloud run can be stopped — Cursor's API cancels it")
    func stopAvailableForLiveCloudRun() {
        let support = SessionActionSupport.resolveStop(
            for: Self.cloudSession(status: .working, observations: Self.cloudEvidence))
        #expect(support.isAvailable)
    }

    @Test("a finished or unreachable cloud agent says why stop is not on offer")
    func stopRefusedWhenThereIsNothingToCancel() {
        let done = SessionActionSupport.resolveStop(
            for: Self.cloudSession(status: .done, observations: Self.cloudEvidence))
        #expect(!done.isAvailable)
        #expect(done.unsupportedReason?.contains("already finished") == true)

        let noKey = SessionActionSupport.resolveStop(
            for: Self.cloudSession(status: .working, observations: nil))
        #expect(!noKey.isAvailable)
        #expect(noKey.unsupportedReason?.contains("API key") == true)
    }

    @Test("a local Cursor chat is still refused — it has no interrupt")
    func stopStillRefusedForLocalCursor() {
        let now = Date()
        let local = AgentSession(id: "11111111-2222-3333-4444-555555555555", agent: .cursor,
                                 project: "/tmp/repo", status: .working,
                                 statusSince: now, updatedAt: now)
        let support = SessionActionSupport.resolveStop(for: local)
        #expect(!support.isAvailable)
        #expect(support.unsupportedReason?.contains("Cursor on your Mac") == true)
    }

    @Test("only a bc- id is a cloud agent")
    func cloudIdentity() {
        #expect(SessionActionSupport.isCursorCloudAgent(
            Self.cloudSession(status: .done, observations: nil)))
        let now = Date()
        var local = AgentSession(id: "11111111-2222-3333-4444-555555555555", agent: .cursor,
                                 project: "/tmp/repo", status: .done,
                                 statusSince: now, updatedAt: now)
        #expect(!SessionActionSupport.isCursorCloudAgent(local))
        local = AgentSession(id: "bc-1", agent: .codex, project: "/tmp/repo",
                             status: .done, statusSince: now, updatedAt: now)
        #expect(!SessionActionSupport.isCursorCloudAgent(local))
    }
}
