import Testing
import Foundation
import Darwin
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// A PreToolUse approval payload for a Bash command in session "s".
private func bash(_ cmd: String) -> String {
    #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"\#(cmd)"}}"#
}

/// A Codex CLI PermissionRequest payload: Claude-shaped keys, fired only when
/// Codex would prompt. `tool_input.command` carries the shell command (Bash)
/// or the whole patch (apply_patch).
private func codexRequest(_ command: String, tool: String = "Bash",
                          mode: String = "default") -> String {
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
    return #"{"hook_event_name":"PermissionRequest","session_id":"cs","cwd":"/x/p","model":"gpt","#
        + #""permission_mode":"\#(mode)","turn_id":"t1","transcript_path":null,"#
        + #""tool_name":"\#(tool)","tool_input":{"command":"\#(escaped)"}}"#
}

private let codexAllow = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
private let codexDeny = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from vibebuddy"}}}"#

/// A Grok Build PreToolUse envelope: camelCase keys, snake_case event value.
private func grokBash(_ cmd: String, tool: String = "run_terminal_command",
                      mode: String = "bypassPermissions") -> String {
    #"{"hookEventName":"pre_tool_use","sessionId":"gs","cwd":"/x/p","workspaceRoot":"/x/p","#
        + #""permissionMode":"\#(mode)","toolUseId":"call-1","toolName":"\#(tool)","#
        + #""toolInput":{"command":"\#(cmd)","description":"d"}}"#
}

@Suite("Approval routes")
struct ApprovalRoutesTests {
    private func server(allow: [String] = [], deny: [String] = [],
                        store: SessionStore = SessionStore(),
                        approvalTimeout: Duration = .seconds(5),
                        port: Int = 9876, host: String = "0.0.0.0") -> VibeBuddyServer {
        // A throwaway temp-file allow store keeps each test hermetic (ADR 0010).
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbapproval-\(UUID().uuidString).json")
        return VibeBuddyServer(store: store, token: "t0k", host: host, port: port,
                        approvalRegistry: ApprovalRegistry(),
                        rules: { _ in PermissionRules(allow: allow, deny: deny) },
                        allowStore: VibeBuddyAllowStore(url: storeURL),
                        approvalTimeout: approvalTimeout,
                        approvalID: { "s" })
    }

    /// Wait until the held approval is visible as a pending card. The server
    /// registers the decision context before broadcasting the card, so from this
    /// point a `/decision` always finds what it needs — a fixed sleep does not,
    /// and the whole-suite run is parallel enough to lose that race.
    private func waitForPendingApproval(_ store: SessionStore, session: String) async throws {
        for _ in 0..<1000 {
            let sessions = await store.snapshot(now: Date()).sessions
            if sessions.first(where: { $0.id == session })?.pendingApproval != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("no approval ever became pending for session \(session)")
    }

    @Test("allow-listed command returns an allow decision immediately")
    func allowImmediate() async throws {
        let body = #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls -la"}}"#
        try await server(allow: ["Bash(ls:*)"]).buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post,
                                     headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: body)) { res in
                #expect(res.status == .ok)
                let text = String(buffer: res.body)
                #expect(text.contains("\"permissionDecision\":\"allow\""))
            }
        }
    }

    @Test("an un-listed command holds, then a /decision approve releases it")
    func askThenApprove() async throws {
        let body = #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        let store = SessionStore()
        let srv = server(store: store)   // empty allow → .ask
        try await srv.buildApplication().test(.router) { client in
            async let approval = client.execute(uri: "/approval", method: .post,
                                                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: body)) { res -> String in
                #expect(res.status == .ok)
                return String(buffer: res.body)
            }
            try await waitForPendingApproval(store, session: "s")
            let decision = #"{"approvalId":"s","decision":"allow"}"#
            try await client.execute(uri: "/decision", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: decision)) { res in
                #expect(res.status == .ok)
            }
            let text = try await approval
            #expect(text.contains("\"permissionDecision\":\"allow\""))
        }
    }

    @Test("no decision times out to an empty body (hook prints nothing)")
    func timesOutEmpty() async throws {
        let body = #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        try await server(approvalTimeout: .milliseconds(200)).buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post,
                                     headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: body)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).isEmpty)   // 200ms timeout → empty
            }
        }
    }

    @Test("/decision without a token is 401")
    func decisionUnauthorized() async throws {
        try await server().buildApplication().test(.router) { client in
            try await client.execute(uri: "/decision", method: .post,
                                     body: ByteBuffer(string: #"{"approvalId":"x","decision":"allow"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: always-allow / allow-this-session (ADR 0010)

    @Test("alwaysAllow persists a rule so the next identical call auto-allows")
    func alwaysAllowPersists() async throws {
        let store = SessionStore()
        let srv = server(store: store)   // empty native allow → first call holds
        try await srv.buildApplication().test(.router) { client in
            async let first = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: bash("git status"))) { res -> String in
                String(buffer: res.body)
            }
            try await waitForPendingApproval(store, session: "s")
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"alwaysAllow"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await first.contains("\"permissionDecision\":\"allow\""))

            // Second identical call is now auto-allowed — no holding, no /decision.
            try await client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: bash("git status"))) { res in
                #expect(String(buffer: res.body).contains("\"permissionDecision\":\"allow\""))
            }
        }
    }

    @Test("allowSession auto-allows a different command in the same session")
    func allowSessionAllowsSiblings() async throws {
        let store = SessionStore()
        let srv = server(store: store)
        try await srv.buildApplication().test(.router) { client in
            async let first = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: bash("git status"))) { res -> String in
                String(buffer: res.body)
            }
            try await waitForPendingApproval(store, session: "s")
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"allowSession"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await first.contains("\"permissionDecision\":\"allow\""))

            // A *different* command in the same session is now auto-allowed.
            try await client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: bash("npm test"))) { res in
                #expect(String(buffer: res.body).contains("\"permissionDecision\":\"allow\""))
            }
        }
    }

    // MARK: - Grok Build (?agent=grok)
    //
    // Same machinery, different envelope (camelCase) and different decision
    // contract on the wire (`{"decision":…}` instead of hookSpecificOutput).

    private func approve(_ client: some TestClientProtocol, body: String,
                         agent: String? = nil) async throws -> String {
        let uri = agent.map { "/approval?agent=\($0)" } ?? "/approval"
        return try await client.execute(uri: uri, method: .post,
            headers: [.authorization: "Bearer t0k"],
            body: ByteBuffer(string: body)) { res -> String in
            #expect(res.status == .ok)
            return String(buffer: res.body)
        }
    }

    @Test("an allow-listed grok call answers in grok's decision contract")
    func grokAllowImmediate() async throws {
        try await server(allow: ["Bash(ls:*)"]).buildApplication().test(.router) { client in
            let text = try await approve(client, body: grokBash("ls -la"), agent: "grok")
            #expect(text == #"{"decision":"allow"}"#)
        }
    }

    @Test("the blocking grok hook is also the PreToolUse signal — the session goes working")
    func grokIngestsTheEvent() async throws {
        let store = SessionStore()
        try await server(allow: ["Bash(ls:*)"], store: store).buildApplication().test(.router) { client in
            _ = try await approve(client, body: grokBash("ls -la"), agent: "grok")
            let snapshot = await store.snapshot(now: Date())
            let session = try #require(snapshot.sessions.first { $0.id == "gs" })
            #expect(session.agent == .grok)
            #expect(session.status == .working)
        }
    }

    @Test("a grok call holds, and a phone deny answers deny + reason")
    func grokAskThenDeny() async throws {
        let store = SessionStore()
        let srv = server(store: store)   // empty allow → .ask
        try await srv.buildApplication().test(.router) { client in
            async let held = approve(client, body: grokBash("rm -rf build", mode: "default"),
                                     agent: "grok")
            try await waitForPendingApproval(store, session: "gs")
            // The pending card carries the mode, so the UI can say an allow here
            // is not final (grok still prompts locally outside bypassPermissions).
            let pending = await store.snapshot(now: Date()).sessions.first { $0.id == "gs" }?.pendingApproval
            #expect(pending?.tool == "Bash")
            #expect(pending?.command == "rm -rf build")
            #expect(pending?.permissionMode == "default")
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"deny"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await held == #"{"decision":"deny","reason":"vibebuddy"}"#)
        }
    }

    @Test("no decision on a grok call times out to an empty body (fail-open)")
    func grokTimesOutEmpty() async throws {
        try await server(approvalTimeout: .milliseconds(200)).buildApplication().test(.router) { client in
            let text = try await approve(client, body: grokBash("rm -rf build"), agent: "grok")
            #expect(text.isEmpty)
        }
    }

    @Test("a native deny rule short-circuits a grok call without holding")
    func grokNativeDeny() async throws {
        try await server(deny: ["Bash(rm:*)"]).buildApplication().test(.router) { client in
            let text = try await approve(client, body: grokBash("rm -rf build"), agent: "grok")
            #expect(text == #"{"decision":"deny","reason":"vibebuddy"}"#)
        }
    }

    @Test("a Read deny rule matches grok's read_file/target_file spelling")
    func grokNativeDenyOnPath() async throws {
        let body = #"{"hookEventName":"pre_tool_use","sessionId":"gs","toolName":"read_file","#
            + #""toolInput":{"target_file":"/Users/me/secrets/id_rsa"}}"#
        try await server(deny: ["Read(/Users/me/secrets/**)"]).buildApplication().test(.router) { client in
            let text = try await approve(client, body: body, agent: "grok")
            #expect(text == #"{"decision":"deny","reason":"vibebuddy"}"#)
        }
    }

    @Test("alwaysAllow from a grok approval matches the next grok call, alias included")
    func grokAlwaysAllowPersists() async throws {
        let store = SessionStore()
        try await server(store: store).buildApplication().test(.router) { client in
            async let first = approve(client, body: grokBash("git status"), agent: "grok")
            try await waitForPendingApproval(store, session: "gs")
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"alwaysAllow"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await first == #"{"decision":"allow"}"#)

            // Same command again — and under grok's older tool spelling, which
            // canonicalizes to the same `Bash(git status)` rule.
            let again = try await approve(client, body: grokBash("git status", tool: "run_terminal_cmd"),
                                          agent: "grok")
            #expect(again == #"{"decision":"allow"}"#)
        }
    }

    // MARK: - Codex CLI (?agent=codex)
    //
    // Claude-shaped envelope on PermissionRequest (Codex fires it only when it
    // would prompt), answered in Codex's own contract: hookSpecificOutput with
    // `decision.behavior` allow/deny. An `allow` is final on Codex's side.

    @Test("an allow-listed codex request answers allow in the PermissionRequest contract")
    func codexAllowImmediate() async throws {
        try await server(allow: ["Bash(ls:*)"]).buildApplication().test(.router) { client in
            let text = try await approve(client, body: codexRequest("ls -la"), agent: "codex")
            #expect(text == codexAllow)
        }
    }

    @Test("the blocking codex hook is also its PermissionRequest signal — the session waits with a card")
    func codexIngestsTheEvent() async throws {
        let store = SessionStore()
        let srv = server(store: store)   // empty allow → .ask
        try await srv.buildApplication().test(.router) { client in
            async let held = approve(client, body: codexRequest("rm -rf build"), agent: "codex")
            try await waitForPendingApproval(store, session: "cs")
            let session = try #require(await store.snapshot(now: Date()).sessions.first { $0.id == "cs" })
            #expect(session.agent == .codex)
            #expect(session.status == .needsResponse)
            #expect(session.pendingApproval?.tool == "Bash")
            #expect(session.pendingApproval?.command == "rm -rf build")
            // Codex's allow is final, so no hedging mode rides on the card.
            #expect(session.pendingApproval?.permissionMode == nil)
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"deny"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await held == codexDeny)
            let after = try #require(await store.snapshot(now: Date()).sessions.first { $0.id == "cs" })
            #expect(after.pendingApproval == nil)
        }
    }

    @Test("no decision on a codex request times out to an empty body — Codex then prompts itself")
    func codexTimesOutEmpty() async throws {
        try await server(approvalTimeout: .milliseconds(200)).buildApplication().test(.router) { client in
            let text = try await approve(client, body: codexRequest("rm -rf build"), agent: "codex")
            #expect(text.isEmpty)
        }
    }

    @Test("a native deny rule short-circuits a codex request without holding")
    func codexNativeDeny() async throws {
        try await server(deny: ["Bash(rm:*)"]).buildApplication().test(.router) { client in
            let text = try await approve(client, body: codexRequest("rm -rf build"), agent: "codex")
            #expect(text == codexDeny)
        }
    }

    @Test("apply_patch on one file is an Edit the user's path rules can allow")
    func codexApplyPatchSingleFile() async throws {
        let patch = "*** Begin Patch\n*** Update File: /x/p/src/app.swift\n@@\n-a\n+b\n*** End Patch"
        try await server(allow: ["Edit(/x/p/src/**)"]).buildApplication().test(.router) { client in
            let text = try await approve(client, body: codexRequest(patch, tool: "apply_patch"), agent: "codex")
            #expect(text == codexAllow)
        }
    }

    @Test("apply_patch across files holds as an Edit card and alwaysAllow persists no rule")
    func codexApplyPatchMultiFileHolds() async throws {
        let patch = "*** Begin Patch\n*** Update File: /x/p/a.swift\n@@\n-a\n+b\n*** Add File: /x/p/b.swift\n+c\n*** End Patch"
        let store = SessionStore()
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbapproval-\(UUID().uuidString).json")
        let allowStore = VibeBuddyAllowStore(url: storeURL)
        let srv = VibeBuddyServer(store: store, token: "t0k", host: "0.0.0.0", port: 9876,
                                  approvalRegistry: ApprovalRegistry(),
                                  rules: { _ in PermissionRules(allow: ["Edit(/x/p/src/**)"], deny: []) },
                                  allowStore: allowStore, approvalTimeout: .seconds(5),
                                  approvalID: { "s" })
        try await srv.buildApplication().test(.router) { client in
            async let held = approve(client, body: codexRequest(patch, tool: "apply_patch"), agent: "codex")
            try await waitForPendingApproval(store, session: "cs")
            let pending = await store.snapshot(now: Date()).sessions.first { $0.id == "cs" }?.pendingApproval
            #expect(pending?.tool == "Edit")
            #expect(pending?.filePath == nil)
            #expect(pending?.command == patch)
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"alwaysAllow"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await held == codexAllow)
            // A path-less Edit yields no rule: the next multi-file patch asks again.
            #expect(await allowStore.all().isEmpty)
        }
    }

    @Test("alwaysAllow from a codex approval matches the next identical codex command")
    func codexAlwaysAllowPersists() async throws {
        let store = SessionStore()
        try await server(store: store).buildApplication().test(.router) { client in
            async let first = approve(client, body: codexRequest("git status"), agent: "codex")
            try await waitForPendingApproval(store, session: "cs")
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"alwaysAllow"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await first == codexAllow)
            let again = try await approve(client, body: codexRequest("git status"), agent: "codex")
            #expect(again == codexAllow)
        }
    }

    // MARK: - end-to-end through hooks/approval-hook.sh

    @Test("hooks/approval-hook.sh grok posts, and prints the daemon's JSON verbatim")
    func hookScriptEndToEnd() async throws {
        let port = try freePort()
        let srv = server(allow: ["Bash(ls:*)"], port: port, host: "127.0.0.1")
        let serving = Task { try await srv.buildApplication().runService() }
        defer { serving.cancel() }
        try await waitUntilListening(port: port)

        let out = try await runApprovalHook(source: "grok", port: port, token: "t0k",
                                            stdin: grokBash("ls -la"))
        #expect(out == #"{"decision":"allow"}"#)

        // No argument keeps the Claude Code contract.
        let claude = try await runApprovalHook(source: nil, port: port, token: "t0k",
                                               stdin: bash("ls -la"))
        #expect(claude.contains("\"permissionDecision\":\"allow\""))

        // `codex` answers in the PermissionRequest contract, byte for byte.
        let codex = try await runApprovalHook(source: "codex", port: port, token: "t0k",
                                              stdin: codexRequest("ls -la"))
        #expect(codex == codexAllow)

        // A wrong token is a 401 → nothing on stdout → the agent fails open.
        let unauthorized = try await runApprovalHook(source: "grok", port: port, token: "wrong",
                                                     stdin: grokBash("ls -la"))
        #expect(unauthorized.isEmpty)
    }
}

// MARK: - helpers for the end-to-end hook run

/// The repo root, from this file's path: …/VibeBuddyMac/Tests/VibeBuddyMacCoreTests/<file>.
private func repoRoot(_ file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // VibeBuddyMacCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // VibeBuddyMac
        .deletingLastPathComponent()   // repo root
}

private enum HookTestError: Error { case noFreePort }

/// An ephemeral port the kernel just handed out — closed again before use, so
/// the server can claim it. Good enough for a single-process test.
private func freePort() throws -> Int {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HookTestError.noFreePort }
    defer { Darwin.close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = in_addr_t(0)   // INADDR_ANY
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw HookTestError.noFreePort }
    var out = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &out) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &len) }
    }
    guard named == 0 else { throw HookTestError.noFreePort }
    return Int(UInt16(bigEndian: out.sin_port))
}

private func waitUntilListening(port: Int) async throws {
    for _ in 0..<100 {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/snapshot")!)
        request.timeoutInterval = 1
        if let (_, response) = try? await URLSession.shared.data(for: request),
           response is HTTPURLResponse { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("server never came up on port \(port)")
}

/// Run the real hook script against the running daemon and return its stdout.
private func runApprovalHook(source: String?, port: Int, token: String,
                             stdin: String) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [repoRoot().appendingPathComponent("hooks/approval-hook.sh").path]
        + (source.map { [$0] } ?? [])
    var env = ProcessInfo.processInfo.environment
    env["VIBEBUDDY_PORT"] = String(port)
    env["VIBEBUDDY_TOKEN"] = token
    process.environment = env
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)   // always fail-open
    return String(decoding: data, as: UTF8.self)
}
