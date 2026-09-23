import Foundation
import Testing
@testable import VibeBuddyMacCore

/// AI-05: background sessions come from `claude agents --json --all`, run only
/// when something may have changed.
@Suite("claude agents --json source")
struct ClaudeAgentsSourceTests {
    /// Shape recorded from Claude Code 2.1.280 on 2026-09-23 (paths trimmed).
    static let sample = Data(#"""
    [
      {"id": "747978a2", "cwd": "/p/responsay", "kind": "background", "startedAt": 1781444893757,
       "sessionId": "747978a2-9efa-4859-8365-9f209d4fe9fe", "name": "brooks sweep", "state": "blocked"},
      {"id": "d6c8c5b9", "cwd": "/p/vb", "kind": "background", "startedAt": 1788875789061,
       "sessionId": "d6c8c5b9-a315-4587-99be-cd75c04032e4", "state": "done"},
      {"id": "abc12345", "kind": "background", "sessionId": "abc12345-0000-0000-0000-000000000000",
       "state": "blocked", "waitingFor": "permission prompt"},
      {"pid": 60827, "cwd": "/p/vb", "kind": "interactive", "startedAt": 1790133835212,
       "sessionId": "8abab909-ba56-43c9-96a9-5b8180b24e0f", "name": "cleanup", "status": "busy"},
      {"id": "../evil", "kind": "background", "sessionId": "x"}
    ]
    """#.utf8)

    @Test("background entries only; fields decoded as they appear; unsafe ids dropped")
    func parses() throws {
        let sessions = try #require(ClaudeBackgroundSessions.parseAgentsJSON(Self.sample))
        #expect(sessions.map(\.id) == ["747978a2", "abc12345", "d6c8c5b9"])
        #expect(sessions[0].name == "brooks sweep")
        #expect(sessions[0].state == "blocked")
        #expect(sessions[0].needs == nil)
        #expect(sessions[1].needs == "permission prompt")
        #expect(sessions[2].name == nil)
        #expect(ClaudeBackgroundSessions.parseAgentsJSON(Data("not json".utf8)) == nil)
    }

    @Test("a missing waitingFor is filled from that job's own needs line")
    func needsFromJobFile() throws {
        let sessions = try #require(ClaudeBackgroundSessions.parseAgentsJSON(Self.sample,
            jobNeeds: { $0 == "747978a2" ? "choose which of 3 next steps" : nil }))
        #expect(sessions.first { $0.id == "747978a2" }?.needs == "choose which of 3 next steps")
        #expect(sessions.first { $0.id == "abc12345" }?.needs == "permission prompt")   // CLI wins
    }

    @Test("runs only when the jobs fingerprint changes or the cache is older than maxAge")
    func caches() async {
        let clock = Clock(), print = Box("a")
        let source = ClaudeAgentsSource(run: { Self.sample }, fingerprint: { print.value },
                                        fallback: { [] }, needs: { _ in nil }, maxAge: 60, now: { clock.now })
        #expect(await source.currentFresh().count == 3)
        _ = await source.currentFresh(); _ = await source.currentFresh()
        #expect(source.runCount == 1)
        print.value = "b"
        _ = await source.currentFresh()
        #expect(source.runCount == 2)
        clock.now = clock.now.addingTimeInterval(61)
        _ = await source.currentFresh()
        #expect(source.runCount == 3)
        await source.refreshNow()
        #expect(source.runCount == 4)
    }

    @Test("current() never blocks: a stale cache returns at once and refreshes behind it")
    func currentDoesNotBlock() async {
        let gate = DispatchSemaphore(value: 0)
        let source = ClaudeAgentsSource(run: { gate.wait(); return Self.sample },
                                        fingerprint: { "x" }, fallback: { [] }, needs: { _ in nil })
        #expect(source.current().isEmpty)       // returned while the run is held
        gate.signal()
        #expect(await source.currentFresh().count == 3)
        #expect(source.runCount == 1)
    }

    @Test("concurrent callers share one run")
    func singleFlight() async {
        let source = ClaudeAgentsSource(run: { Thread.sleep(forTimeInterval: 0.2); return Self.sample },
                                        fingerprint: { "x" }, fallback: { [] }, needs: { _ in nil })
        async let a = source.currentFresh()
        async let b = source.currentFresh()
        async let c = source.refreshNow()
        let results = await [a, b, c]
        #expect(results.allSatisfy { $0.count == 3 })
        #expect(source.runCount == 1)
    }

    @Test("a missing or failing CLI falls back to the jobs files")
    func fallsBack() async {
        let fallback = ClaudeBackgroundSession(id: "deadbeef", sessionID: "s", name: "from jobs")
        let source = ClaudeAgentsSource(run: { nil }, fingerprint: { "x" }, fallback: { [fallback] }, needs: { _ in nil })
        #expect(await source.currentFresh() == [fallback])
    }

    @Test("find answers from the cache once its time limit passes, and finds a new session in time",
          .timeLimit(.minutes(1)))
    func findTimeLimit() async {
        let print = Box("a"), gate = DispatchSemaphore(value: 0)
        let source = ClaudeAgentsSource(run: {
            // The first run answers; later ones hang like a wedged CLI.
            if print.value != "a" { _ = gate.wait(timeout: .now() + 10) }
            return Self.sample
        }, fingerprint: { print.value }, fallback: { [] }, needs: { _ in nil })
        let id = "747978a2-9efa-4859-8365-9f209d4fe9fe"
        #expect(await ClaudeBackgroundSessions.find(sessionID: id, in: source)?.id == "747978a2")
        print.value = "b"   // stale: the next lookup has to wait for a refresh
        let start = Date()
        #expect(await ClaudeBackgroundSessions.find(sessionID: id, in: source, timeLimit: .milliseconds(200))?.id == "747978a2")
        #expect(await ClaudeBackgroundSessions.find(sessionID: "nope", in: source, timeLimit: .milliseconds(200)) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
        print.value = "a"   // release the held run; the refresh the late lookup starts answers at once
        gate.signal()
    }

    @Test("the jobs directory follows CLAUDE_CONFIG_DIR, like the hook installer")
    func jobsDirectoryHonoursConfigDir() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(ClaudeBackgroundSessions.jobsDirectory(environment: [:], home: home).path == "/Users/someone/.claude/jobs")
        #expect(ClaudeBackgroundSessions.jobsDirectory(environment: ["CLAUDE_CONFIG_DIR": "/cfg/work"], home: home).path
                == "/cfg/work/jobs")
        #expect(ClaudeBackgroundSessions.jobsDirectory(environment: ["CLAUDE_CONFIG_DIR": "~/.claude-work"], home: home).path
                == "/Users/someone/.claude-work/jobs")
    }

    /// A fake `claude` at `<home>/.local/bin/claude`, which `ClaudeExecutable.resolve` tries first.
    private static func fakeCLI(_ body: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("vb-agents-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return home
    }

    @Test("runCLI returns the CLI's stdout on a clean exit, nil on a failing one")
    func runCLIExitStatus() throws {
        let ok = try Self.fakeCLI(#"echo '[]'"#)
        defer { try? FileManager.default.removeItem(at: ok) }
        #expect(ClaudeAgentsSource.runCLI(environment: ["PATH": "/usr/bin:/bin"], home: ok, timeout: 10) == Data("[]\n".utf8))
        let failing = try Self.fakeCLI(#"echo '[]'; exit 3"#)
        defer { try? FileManager.default.removeItem(at: failing) }
        #expect(ClaudeAgentsSource.runCLI(environment: ["PATH": "/usr/bin:/bin"], home: failing, timeout: 10) == nil)
    }

    @Test("runCLI stops a CLI that ignores TERM: nil, and the child is gone when it returns",
          .timeLimit(.minutes(1)))
    func runCLIKillsAStuckChild() throws {
        let home = try Self.fakeCLI(#"trap '' TERM; echo $$ > "$HOME/pid"; exec sleep 60"#)
        defer { try? FileManager.default.removeItem(at: home) }
        // The timeout leaves the shell time to reach `trap` even on a loaded host;
        // a TERM before it would kill the shell and never write the pid file.
        #expect(ClaudeAgentsSource.runCLI(environment: ["PATH": "/usr/bin:/bin"], home: home, timeout: 2) == nil)
        let pid = try #require(Int32(try String(contentsOf: home.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("runCLI whose CLI exited while a grandchild holds stdout returns without a TERM grace",
          .timeLimit(.minutes(1)))
    func runCLIGrandchildHoldsStdout() throws {
        let home = try Self.fakeCLI(#"(sleep 3 &); echo '[]'; exit 0"#)
        defer { try? FileManager.default.removeItem(at: home) }
        let start = Date()
        #expect(ClaudeAgentsSource.runCLI(environment: ["PATH": "/usr/bin:/bin"], home: home, timeout: 1) == nil)
        // The one-second TERM grace would put this at two seconds or more.
        #expect(Date().timeIntervalSince(start) < 1.9)
    }

    @Test("runCLI closes stdout's read end before it returns: no reader outlives it",
          .timeLimit(.minutes(1)))
    func runCLIClosesStdoutOnReturn() throws {
        // The grandchild writes only once runCLI has returned (the `go` file). A
        // reader still blocked in read() would take the line; a closed read end
        // fails the write (EPIPE). The wait is bounded so no grandchild lingers.
        let home = try Self.fakeCLI(#"( (trap '' PIPE; i=0; while [ ! -e "$HOME/go" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done; echo late || touch "$HOME/closed") & ); echo '[]'; exit 0"#)
        defer { try? FileManager.default.removeItem(at: home) }
        // As in runCLIKillsAStuckChild, the timeout leaves the shell time to fork.
        #expect(ClaudeAgentsSource.runCLI(environment: ["PATH": "/usr/bin:/bin"], home: home, timeout: 2) == nil)
        FileManager.default.createFile(atPath: home.appendingPathComponent("go").path, contents: nil)
        let closed = home.appendingPathComponent("closed")
        let limit = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: closed.path), Date() < limit {
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(FileManager.default.fileExists(atPath: closed.path))
    }

    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
    private final class Box: @unchecked Sendable { var value: String; init(_ v: String) { value = v } }
}
