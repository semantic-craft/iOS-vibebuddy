import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Menu idle round identities")
struct MenuRoundIdentityReaderTests {
    private func session(_ agent: AgentKind) -> AgentSession {
        AgentSession(id: "session", agent: agent, project: "demo", status: .done, statusSince: Date(), updatedAt: Date())
    }
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    private func claude(_ uuid: String) -> String {
        "{\"type\":\"user\",\"sessionId\":\"session\",\"uuid\":\"\(uuid)\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"hello\"}}\n"
    }
    private let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"session\"}}\n"
    private func start(_ id: String) -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"\(id)\"}}\n"
    }

    @Test func stableAcrossRestartAndChangesOnlyForNewPrompt() async throws {
        let url = try file(claude("one"))
        defer { try? FileManager.default.removeItem(at: url) }
        let sessions = [session(.claudeCode)], paths = ["session": url.path]
        let reader = MenuRoundIdentityReader()
        let first = await reader.identities(sessions: sessions, paths: paths)
        #expect(first["session"] == "claude:session:round:one")
        let restarted = await MenuRoundIdentityReader().identities(sessions: sessions, paths: paths)
        #expect(first == restarted)
        try append("{\"type\":\"user\",\"sessionId\":\"session\",\"uuid\":\"tool\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"ok\"}]}}\n", to: url)
        #expect(await reader.identities(sessions: sessions, paths: paths) == first)
        try append(claude("two"), to: url)
        #expect(await reader.identities(sessions: sessions, paths: paths)["session"] == "claude:session:round:two")
    }

    @Test func codexRequiresRealStartAndStableSession() async throws {
        let url = try file(meta)
        defer { try? FileManager.default.removeItem(at: url) }
        let sessions = [session(.codex)], paths = ["session": url.path]
        let initial = await MenuRoundIdentityReader().identities(sessions: sessions, paths: paths)
        #expect(initial["session"] == "codex:session:initial")
        try append(start("one"), to: url)
        let first = await MenuRoundIdentityReader().identities(sessions: sessions, paths: paths)
        #expect(first["session"] == "codex:session:round:one")
        #expect(await MenuRoundIdentityReader().identities(sessions: sessions, paths: paths) == first)
        try append(start("two"), to: url)
        #expect(await MenuRoundIdentityReader().identities(sessions: sessions, paths: paths)["session"] == "codex:session:round:two")
        try append("{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"unobserved\"}}\n", to: url)
        #expect(await MenuRoundIdentityReader().identities(sessions: sessions, paths: paths).isEmpty)
    }

    @Test func missingSourcePartialTailAndMismatchFailOpen() async throws {
        let url = try file(claude("one"))
        defer { try? FileManager.default.removeItem(at: url) }
        let sessions = [session(.claudeCode)], paths = ["session": url.path]
        let reader = MenuRoundIdentityReader()
        #expect(await reader.identities(sessions: sessions, paths: [:]).isEmpty)
        #expect(await reader.identities(sessions: sessions, paths: paths)["session"] != nil)
        try append("{\"type\":\"user\"", to: url)
        #expect(await reader.identities(sessions: sessions, paths: paths).isEmpty)
        try Data(claude("two").replacingOccurrences(of: "sessionId\":\"session", with: "sessionId\":\"other").utf8).write(to: url)
        #expect(await reader.identities(sessions: sessions, paths: paths).isEmpty)
    }
    @Test func discoveryIncludesOldFilesAndRejectsAmbiguousPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions/2020/01/01")
        let archive = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let old = sessions.appendingPathComponent("rollout-old-session.jsonl")
        try Data(meta.utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try Data().write(to: sessions.appendingPathComponent("rollout-other-other-id.jsonl"))
        try Data().write(to: archive.appendingPathComponent("rollout-archived-session.jsonl"))
        let reader = MenuRoundIdentityReader()
        let sessionsRoot = root.appendingPathComponent("sessions")
        let discovered = await reader.codexPaths(sessionIDs: ["session"], root: sessionsRoot)
        #expect(Set(discovered.keys) == ["session"])
        let discoveredPath = try #require(discovered["session"])
        let actualAttributes = try FileManager.default.attributesOfItem(atPath: discoveredPath)
        let expectedAttributes = try FileManager.default.attributesOfItem(atPath: old.path)
        #expect(actualAttributes[.systemFileNumber] as? NSNumber == expectedAttributes[.systemFileNumber] as? NSNumber)
        try Data().write(to: sessions.appendingPathComponent("rollout-duplicate-session.jsonl"))
        #expect(await reader.codexPaths(sessionIDs: ["session"], root: sessionsRoot).isEmpty)
        #expect(await reader.codexPaths(sessionIDs: ["absent"], root: sessionsRoot).isEmpty)
    }

}
