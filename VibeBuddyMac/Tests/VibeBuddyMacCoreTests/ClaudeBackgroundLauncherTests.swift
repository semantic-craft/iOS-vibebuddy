import Foundation
import Testing
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// A stand-in `claude` that behaves like 2.1.261: `--help` lists `--bg`,
/// `--bg` prints the backgrounded line, writes the job's state file and
/// records its arguments and working directory.
private func fakeClaude(jobs: URL, supportsBG: Bool = true) throws -> (exe: URL, log: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vb-claude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let exe = root.appendingPathComponent("claude"), log = root.appendingPathComponent("log")
    let script = """
    #!/bin/sh
    if [ "$1" = "--help" ]; then echo "\(supportsBG ? "  --bg, --background   Start the session in the background" : "  --bare   Minimal mode")"; exit 0; fi
    printf '%s\\n' "$PWD" > "\(log.path)"; for a in "$@"; do printf '%s\\n' "$a" >> "\(log.path)"; done
    mkdir -p "\(jobs.path)/de59db03"
    echo '{"state":"working","name":"listing","sessionId":"de59db03-b594-416f-abdd-de54e8a96095"}' > "\(jobs.path)/de59db03/state.json"
    echo "Starting background service…"
    echo "backgrounded · de59db03 · listing"
    echo "  claude attach de59db03    open in this terminal"
    """
    try script.write(to: exe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    return (exe, log)
}

@Suite("Claude background launcher")
struct ClaudeBackgroundLauncherTests {
    @Test("claude --bg --name -- prompt in the requested directory; the full session id comes back")
    func launch() async throws {
        let jobs = FileManager.default.temporaryDirectory.appendingPathComponent("vb-jobs-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("vb-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let fake = try fakeClaude(jobs: jobs)
        let launcher = ClaudeBackgroundLauncher(executable: fake.exe, jobsDirectory: jobs)
        #expect(await launcher.isSupported())
        let outcome = await launcher.dispatch(DispatchRequest(agent: .claudeCode, cwd: cwd.path, prompt: "-- list uncommitted changes", name: "listing"))
        #expect(outcome == .started(sessionID: "de59db03-b594-416f-abdd-de54e8a96095"))
        let lines = try String(contentsOf: fake.log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == cwd.standardizedFileURL.path)
        #expect(Array(lines.dropFirst()) == ["--bg", "--name", "listing", "--", "-- list uncommitted changes"])
        #expect(await launcher.dispatch(DispatchRequest(agent: .codex, cwd: cwd.path, prompt: "x")) == .unsupported("This launcher only starts Claude Code sessions"))
    }

    @Test("no CLI, or one without --bg, is unavailable and not offered")
    func unsupported() async throws {
        let jobs = FileManager.default.temporaryDirectory.appendingPathComponent("vb-jobs-\(UUID().uuidString)")
        let old = try fakeClaude(jobs: jobs, supportsBG: false)
        let launcher = ClaudeBackgroundLauncher(executable: old.exe, jobsDirectory: jobs)
        #expect(await !launcher.isSupported())
        if case .unavailable = await launcher.dispatch(DispatchRequest(agent: .claudeCode, cwd: "/tmp", prompt: "x")) {} else {
            Issue.record("expected unavailable")
        }
        let none = ClaudeBackgroundLauncher(executable: nil, jobsDirectory: jobs)
        #expect(await !none.isSupported())
    }

    @Test("the job id is read from the backgrounded line only")
    func parse() {
        #expect(ClaudeBackgroundLauncher.jobID(in: "Starting background service…\nbackgrounded · aa6c2d09 · vb probe\n  claude attach aa6c2d09") == "aa6c2d09")
        #expect(ClaudeBackgroundLauncher.jobID(in: "  claude attach aa6c2d09") == nil)
        #expect(ClaudeBackgroundLauncher.jobID(in: "backgrounded · ../x · nope") == nil)
    }

    @Test("/dispatch routes Claude to the launcher and the snapshot offers it")
    func route() async throws {
        let jobs = FileManager.default.temporaryDirectory.appendingPathComponent("vb-jobs-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("vb-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let fake = try fakeClaude(jobs: jobs)
        let store = SessionStore()
        await store.ingest(HookEvent(kind: .sessionStart, sessionID: "s0", agent: .claudeCode, cwd: cwd.path, timestamp: Date()))
        let srv = VibeBuddyServer(store: store, token: "t0k", port: 9876,
                                  claudeLauncher: ClaudeBackgroundLauncher(executable: fake.exe, jobsDirectory: jobs))
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/snapshot", method: .get, headers: [.authorization: "Bearer t0k"]) { res in
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(buffer: res.body))
                #expect(snapshot.dispatchAgents == [.claudeCode])
            }
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"claudeCode","cwd":"\#(cwd.path)","prompt":"list files"}"#)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("de59db03-b594-416f-abdd-de54e8a96095"))
            }
        }
    }
}
