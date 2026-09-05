import Foundation
import Testing
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Claude background sessions")
struct ClaudeBackgroundSessionsTests {
    private func jobsDir(_ jobs: [(id: String, state: String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vb-jobs-\(UUID().uuidString)")
        for job in jobs {
            let dir = root.appendingPathComponent(job.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try job.state.write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("jobs with a state file are listed by short id; malformed entries and pins are skipped")
    func load() throws {
        let root = try jobsDir([
            ("747978a2", #"{"state":"blocked","needs":"choose the next step","name":"brooks sweep","sessionId":"747978a2-9efa-4859-8365-9f209d4fe9fe","template":"claude"}"#),
            ("deadbeef", "not json"),
            ("pins.json", "{}"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ClaudeBackgroundSessions.load(jobsDirectory: root)
        #expect(jobs.count == 1)
        #expect(jobs[0].id == "747978a2")
        #expect(jobs[0].name == "brooks sweep")
        #expect(jobs[0].state == "blocked")
        #expect(jobs[0].needs == "choose the next step")
        #expect(ClaudeBackgroundSessions.find(sessionID: "747978a2-9efa-4859-8365-9f209d4fe9fe", jobsDirectory: root)?.id == "747978a2")
        #expect(ClaudeBackgroundSessions.find(sessionID: "nope", jobsDirectory: root) == nil)
        #expect(ClaudeBackgroundSessions.load(jobsDirectory: root.appendingPathComponent("missing")).isEmpty)
    }

    @Test("a job lends its name and needs line to an unnamed Claude row, never to other agents")
    func enrich() async {
        let store = SessionStore()
        let now = Date()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "bg", agent: .claudeCode, cwd: "/x/a", timestamp: now))
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "cx", agent: .codex, cwd: "/x/a", timestamp: now))
        await store.applyBackgroundSessions([
            ClaudeBackgroundSession(id: "1", sessionID: "bg", name: "brooks sweep", state: "blocked", needs: "choose the next step"),
            ClaudeBackgroundSession(id: "2", sessionID: "cx", name: "not mine"),
            ClaudeBackgroundSession(id: "3", sessionID: "absent", name: "never created"),
        ])
        let sessions = await store.snapshot(now: now).sessions
        #expect(sessions.first { $0.id == "bg" }?.name == "brooks sweep")
        #expect(sessions.first { $0.id == "bg" }?.summary == "choose the next step")
        #expect(sessions.first { $0.id == "cx" }?.name == nil)
        #expect(sessions.count == 2)
    }

    @Test("only short hex job ids may reach the shell")
    func jobIDs() {
        #expect(ClaudeBackgroundSessions.isJobID("747978a2"))
        #expect(!ClaudeBackgroundSessions.isJobID("747978a2; rm -rf /"))
        #expect(!ClaudeBackgroundSessions.isJobID(""))
        #expect(!ClaudeBackgroundSessions.isJobID("DEADBEEF"))
    }
}

@Suite("Attach jump route")
struct AttachJumpRouteTests {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock(); var attached: [(String, String?)] = []
        func record(_ id: String, _ term: String?) { lock.withLock { attached.append((id, term)) } }
        var calls: [(String, String?)] { lock.withLock { attached } }
    }

    @Test("a background Claude session jumps by attaching in the preferred terminal")
    func attach() async throws {
        let store = SessionStore()
        let now = Date()
        // A terminal-backed session elsewhere sets the preferred program.
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "term", agent: .claudeCode, cwd: "/x/a", timestamp: now))
        await store.setTerminalRef(sessionID: "term", TerminalRef(termProgram: "iTerm.app", tty: "ttys001"))
        // The background one arrives through hooks too, but has no window.
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "bg-session", agent: .claudeCode, cwd: "/x/b", timestamp: now.addingTimeInterval(1)))
        let recorder = Recorder()
        let srv = VibeBuddyServer(store: store, token: "t0k", port: 9876,
                                  backgroundSessions: { [ClaudeBackgroundSession(id: "abc12345", sessionID: "bg-session", name: "audit")] },
                                  onAttach: { id, term in recorder.record(id, term); return .attached })
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/jump", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"sessionId":"bg-session"}"#)) { res in
                #expect(String(buffer: res.body).contains(#""outcome":"attached""#))
            }
            try await client.execute(uri: "/jump", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"sessionId":"unknown"}"#)) { res in
                #expect(String(buffer: res.body).contains(#""outcome":"noTerminal""#))
            }
        }
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.0 == "abc12345")
        #expect(recorder.calls.first?.1 == "iTerm.app")
    }
}
