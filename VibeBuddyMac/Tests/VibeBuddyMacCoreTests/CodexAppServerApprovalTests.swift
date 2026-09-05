import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Server-initiated requests from the daemon become phone cards, and the
/// phone's decision goes back as the request's own response.
@Suite("Codex app-server approvals and questions")
struct CodexAppServerApprovalTests {
    private struct Harness {
        let connection: FakeConnection
        let store = SessionStore()
        let registry = ApprovalRegistry()
        let questions = QuestionRegistry()
        let sessionAllow = SessionAllowList()
        let allowStore: VibeBuddyAllowStore
        let context = ApprovalContextStore()
        let monitor: CodexAppServerMonitor
        let socket: URL
        let run: Task<Void, Never>

        init(rules: [String] = []) async {
            socket = FileManager.default.temporaryDirectory.appendingPathComponent("vb-sock-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: socket.path, contents: Data())
            connection = FakeConnection(results: fakeDaemonResults())
            allowStore = VibeBuddyAllowStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("vb-allow-\(UUID().uuidString).json"))
            for rule in rules { _ = await allowStore.add(rule) }
            monitor = CodexAppServerMonitor(
                enabled: true, socketPath: socket.path,
                approvalRegistry: registry, allowStore: allowStore, sessionAllow: sessionAllow,
                approvalContext: context, questionRegistry: questions,
                approvalID: { "card-1" }, requestTimeout: .seconds(10),
                makeClient: { [connection] _ in connection })
            let store = self.store
            let monitor = self.monitor
            run = Task { await monitor.run(store: store) }
        }

        func stop() { run.cancel(); connection.close(); try? FileManager.default.removeItem(at: socket) }

        func session(_ id: String) async -> AgentSession? {
            await store.snapshot(now: Date()).sessions.first { $0.id == id }
        }

        /// Bring a thread up as active so requests have a row to land on.
        func startThread(_ id: String) async {
            connection.push(["method": "thread/status/changed", "params": ["threadId": id, "status": ["type": "active", "activeFlags": []]]])
            _ = await waitFor { await session(id)?.status == .working }
        }

        func pushCommandApproval(thread: String, requestID: Int, command: String, itemID: String = "item-1") {
            connection.push(["method": "item/started", "params": ["threadId": thread, "turnId": "t", "startedAtMs": 1,
                                                                   "item": ["type": "commandExecution", "id": itemID, "command": command, "cwd": "/x/p", "status": "inProgress"]]])
            connection.push(["id": requestID, "method": "item/commandExecution/requestApproval",
                             "params": ["threadId": thread, "turnId": "t", "itemId": itemID, "kind": "command",
                                        "startedAtMs": 1, "environmentId": NSNull(), "command": command, "cwd": "/x/p",
                                        "reason": "needs network"]])
        }
    }

    @Test("a command approval becomes a card; approve answers accept and clears it")
    func approveCommand() async throws {
        let h = await Harness()
        defer { h.stop() }
        await h.startThread("thr-1")
        h.pushCommandApproval(thread: "thr-1", requestID: 7, command: "npm test")
        #expect(await waitFor { await h.session("thr-1")?.pendingApproval != nil })
        let card = try #require(await h.session("thr-1")?.pendingApproval)
        #expect(card.id == "card-1")
        #expect(card.tool == "Bash")
        #expect(card.command == "npm test")
        #expect(await h.session("thr-1")?.status == .needsResponse)
        await h.registry.resolve(id: "card-1", with: .allow)
        #expect(await waitFor { h.connection.decisions == ["accept"] })
        #expect(h.connection.lastResponse?.id == .number(7))
        #expect(await waitFor { await h.session("thr-1")?.pendingApproval == nil })
        #expect(await h.session("thr-1")?.status == .working)
    }

    @Test("deny answers decline; allow-for-session answers acceptForSession and skips the next card")
    func denyAndSession() async throws {
        let h = await Harness()
        defer { h.stop() }
        await h.startThread("thr-2")
        h.pushCommandApproval(thread: "thr-2", requestID: 1, command: "rm -rf build")
        #expect(await waitFor { await h.session("thr-2")?.pendingApproval != nil })
        await h.registry.resolve(id: "card-1", with: .deny)
        #expect(await waitFor { h.connection.decisions == ["decline"] })

        h.pushCommandApproval(thread: "thr-2", requestID: 2, command: "git push", itemID: "item-2")
        #expect(await waitFor { await h.session("thr-2")?.pendingApproval != nil })
        await h.sessionAllow.add("thr-2")      // what /decision allowSession does
        await h.registry.resolve(id: "card-1", with: .allow)
        #expect(await waitFor { h.connection.decisions == ["decline", "acceptForSession"] })

        // The rest of the session is answered without a card at all.
        h.pushCommandApproval(thread: "thr-2", requestID: 3, command: "cargo build", itemID: "item-3")
        #expect(await waitFor { h.connection.decisions.count == 3 })
        #expect(h.connection.decisions.last == "acceptForSession")
        #expect(await h.session("thr-2")?.pendingApproval == nil)
    }

    @Test("an exact always-allow rule in the vibebuddy store answers accept without a card")
    func alwaysAllowRule() async throws {
        let h = await Harness(rules: ["Bash(npm test)"])
        defer { h.stop() }
        await h.startThread("thr-3")
        h.pushCommandApproval(thread: "thr-3", requestID: 9, command: "npm test")
        #expect(await waitFor { h.connection.decisions == ["accept"] })
        #expect(await h.session("thr-3")?.pendingApproval == nil)
    }

    @Test("a request resolved elsewhere withdraws the card silently and sends nothing")
    func resolvedElsewhere() async throws {
        let h = await Harness()
        defer { h.stop() }
        await h.startThread("thr-4")
        h.pushCommandApproval(thread: "thr-4", requestID: 5, command: "make")
        #expect(await waitFor { await h.session("thr-4")?.pendingApproval != nil })
        h.connection.push(["method": "serverRequest/resolved", "params": ["threadId": "thr-4", "requestId": 5]])
        #expect(await waitFor { await h.session("thr-4")?.pendingApproval == nil })
        #expect(await h.session("thr-4")?.status == .working)
        // A late phone tap has nothing to answer.
        await h.registry.resolve(id: "card-1", with: .allow)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.connection.decisions.isEmpty)
    }

    @Test("a file change approval carries the paths and diff of the item that asked")
    func fileChange() async throws {
        let h = await Harness()
        defer { h.stop() }
        await h.startThread("thr-5")
        h.connection.push(["method": "item/started", "params": ["threadId": "thr-5", "turnId": "t", "startedAtMs": 1,
                                                                  "item": ["type": "fileChange", "id": "fc-1", "status": "inProgress",
                                                                           "changes": [["path": "/x/p/src/a.swift", "kind": "update", "diff": "-old\n+new"]]]]])
        h.connection.push(["id": "req-a", "method": "item/fileChange/requestApproval",
                           "params": ["threadId": "thr-5", "turnId": "t", "itemId": "fc-1", "startedAtMs": 1, "reason": NSNull()]])
        #expect(await waitFor { await h.session("thr-5")?.pendingApproval != nil })
        let card = try #require(await h.session("thr-5")?.pendingApproval)
        #expect(card.tool == "Edit")
        #expect(card.filePath == "/x/p/src/a.swift")
        #expect(card.newText == "-old\n+new")
        #expect(card.commandPreview == "Edit a.swift")
        await h.registry.resolve(id: "card-1", with: .allow)
        #expect(await waitFor { h.connection.decisions == ["accept"] })
        #expect(h.connection.lastResponse?.id == .string("req-a"))
    }

    @Test("request_user_input becomes a multi-question card and the answers go back per question id")
    func userInput() async throws {
        let h = await Harness()
        defer { h.stop() }
        await h.startThread("thr-6")
        h.connection.push(["id": 11, "method": "item/tool/requestUserInput",
                           "params": ["threadId": "thr-6", "turnId": "t", "itemId": "ui-1", "isBlocking": true,
                                      "questions": [
                                        ["id": "db", "header": "Database", "question": "Which database?", "isOther": true, "isSecret": false,
                                         "options": [["label": "Postgres", "description": "relational"], ["label": "SQLite", "description": "embedded"]]],
                                        ["id": "name", "header": "Name", "question": "Project name?", "isOther": true, "isSecret": false, "options": NSNull()],
                                      ]]])
        #expect(await waitFor { await h.session("thr-6")?.pendingQuestion != nil })
        let question = try #require(await h.session("thr-6")?.pendingQuestion)
        #expect(question.items.map(\.id) == ["db", "name"])
        #expect(question.items[0].options.map(\.label) == ["Postgres", "SQLite"])
        #expect(question.items[1].allowsOther)
        #expect(question.prompt == "Which database?")
        #expect(await h.session("thr-6")?.waitKind == .question)

        // What /answer does: structured answers to the waiting agent.
        let dispatch = AnswerDispatch(store: h.store, questions: h.questions, inject: { _, _ in })
        #expect(await dispatch.deliver(sessionID: "thr-6", text: nil, answers: ["db": ["Postgres"], "name": ["acme"]]))
        #expect(await waitFor { h.connection.lastResponse != nil })
        let result = try #require(h.connection.lastResponse)
        #expect(result.id == .number(11))
        let answers = result.result["answers"] as? [String: [String: [String]]]
        #expect(answers?["db"]?["answers"] == ["Postgres"])
        #expect(answers?["name"]?["answers"] == ["acme"])
        #expect(await waitFor { await h.session("thr-6")?.pendingQuestion == nil })
    }
}
