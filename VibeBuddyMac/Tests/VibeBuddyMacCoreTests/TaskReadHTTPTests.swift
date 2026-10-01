import Foundation
import Testing
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Read-only phone task boundaries")
struct TaskReadHTTPTests {
    @Test(arguments: [TaskReadKind.history, .terminals])
    func repeatedNativeCursorFailsWithoutMintingAnotherPage(kind: TaskReadKind) async throws {
        let reader = TaskReadHTTP()
        let sessions = [AgentSession(id: "one", agent: .codex, project: "p", status: .working, statusSince: Date(), updatedAt: Date())]
        let uri = "/task-read?sourceID=mac&sessionID=one&kind=\(kind.rawValue)"
        let fetch: TaskReadHTTP.Fetch = { id, kind, _ in
            var result = TaskReadResponse(sourceID: "", sessionID: id, kind: kind)
            result.nextCursor = "stalled-native-cursor"
            return result
        }
        let first = await reader.read(uri: uri, sourceID: "mac", sessions: sessions, fetch: fetch)
        let page = try JSONDecoder().decode(TaskReadResponse.self, from: first.data)
        let cursor = try #require(page.nextCursor)
        let stalled = await reader.read(uri: uri + "&cursor=" + cursor, sourceID: "mac", sessions: sessions, fetch: fetch)
        #expect(stalled.status == 409)
        let failure = try JSONDecoder().decode(HistoryFailure.self, from: stalled.data)
        #expect(failure.reason == "cursor_did_not_advance")
        // Refresh starts a fresh page even if the upstream cursor has not changed.
        #expect(await reader.read(uri: uri, sourceID: "mac", sessions: sessions, fetch: fetch).status == 200)
    }

    @Test func cursorBindsSourceSessionAndKind() async throws {
        let reader = TaskReadHTTP()
        let sessions = ["one", "two"].map { AgentSession(id: $0, agent: .codex, project: "p", status: .working, statusSince: Date(), updatedAt: Date()) }
        let fetch: TaskReadHTTP.Fetch = { id, kind, cursor in
            var result = TaskReadResponse(sourceID: "", sessionID: id, kind: kind)
            result.messages = []
            result.nextCursor = cursor == nil ? "opaque-native:/+=cursor" : nil
            return result
        }
        let uri = "/task-read?sourceID=mac&sessionID=one&kind=history"
        let first = await reader.read(uri: uri, sourceID: "mac", sessions: sessions, fetch: fetch)
        #expect(first.status == 200)
        let page = try JSONDecoder().decode(TaskReadResponse.self, from: first.data)
        let cursor = try #require(page.nextCursor)
        #expect(cursor != "opaque-native:/+=cursor")
        #expect(page.sourceID == "mac" && page.sessionID == "one")
        let second = await reader.read(uri: uri + "&cursor=" + cursor, sourceID: "mac", sessions: sessions, fetch: { id, kind, native in
            #expect(native == "opaque-native:/+=cursor")
            return TaskReadResponse(sourceID: "", sessionID: id, kind: kind)
        })
        #expect(second.status == 200)
        for invalid in [uri.replacingOccurrences(of: "sessionID=one", with: "sessionID=two"),
                        uri.replacingOccurrences(of: "kind=history", with: "kind=terminals"),
                        uri.replacingOccurrences(of: "kind=history", with: "kind=goal")] {
            let result = await reader.read(uri: invalid + "&cursor=" + cursor, sourceID: "mac", sessions: sessions, fetch: fetch)
            #expect(result.status == 409)
        }
        #expect(await reader.read(uri: uri, sourceID: "other-mac", sessions: sessions, fetch: fetch).status == 409)
        #expect(await reader.read(uri: uri, sourceID: "mac", sessions: [], fetch: fetch).status == 404)
        #expect(await reader.read(uri: uri + "&kind=history", sourceID: "mac", sessions: sessions, fetch: fetch).status == 400)
    }

    @Test func authenticatedRoutesDoNotMutateStore() async throws {
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "test")
        let before = await store.snapshot(now: Date()).sessions
        try await server.buildApplication().test(.router) { client in
            for path in ["/task-read-capabilities", "/task-read?sourceID=mac&sessionID=unknown&kind=goal"] {
                try await client.execute(uri: path, method: .get) { #expect($0.status == .unauthorized) }
            }
            try await client.execute(uri: "/task-read-capabilities", method: .get, headers: [.authorization: "Bearer test"]) { result in
                #expect(result.status == .ok)
                let capability = try JSONDecoder().decode(TaskReadCapabilities.self, from: Data(buffer: result.body))
                #expect(capability.supported == TaskReadKind.allCases)
            }
        }
        #expect(await store.snapshot(now: Date()).sessions == before)
    }
}
