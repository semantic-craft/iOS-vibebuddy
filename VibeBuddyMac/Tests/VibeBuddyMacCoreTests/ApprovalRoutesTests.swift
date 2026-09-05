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

/// A Claude Code PermissionRequest payload: fired only when Claude would stop
/// and ask (a prompt in default mode, an uncertain classifier in auto mode).
private func claudeRequest(_ cmd: String, tool: String = "Bash") -> String {
    #"{"hook_event_name":"PermissionRequest","session_id":"ps","cwd":"/x/p","permission_mode":"default","#
        + #""tool_use_id":"toolu_1","tool_name":"\#(tool)","tool_input":{"command":"\#(cmd)"}}"#
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

/// A legacy Claude PreToolUse gate payload (the shape Grok's gate still uses),
/// carrying a permission mode. Only this event is ever short-circuited.
private func claude(tool: String, input: String = #"{"command":"rm -rf build"}"#,
                    mode: String?) -> String {
    let modeField = mode.map { #","permission_mode":"\#($0)""# } ?? ""
    return #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/x/p"\#(modeField),"tool_name":"\#(tool)","tool_input":\#(input)}"#
}
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

    // MARK: - Claude Code PermissionRequest (the agent already chose to ask)

    /// A Claude PermissionRequest carrying Claude's own always-allow proposal.
    private func claudeRequestWithSuggestion(_ cmd: String) -> String {
        #"{"hook_event_name":"PermissionRequest","session_id":"ps","cwd":"/x/p","permission_mode":"default","#
            + #""tool_name":"Bash","tool_input":{"command":"\#(cmd)"},"#
            + #""permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"\#(cmd)"}],"behavior":"allow","destination":"localSettings"},"#
            + #"{"type":"setMode","mode":"acceptEdits","destination":"session"}]}"#
    }

    @Test("a PermissionRequest holds even when our copy of the allow rules would match")
    func permissionRequestNeverReMatchesAllowRules() async throws {
        let store = SessionStore()
        // `Bash(ls:*)` auto-allows a PreToolUse gate; Claude has already run the
        // same rule and still asked, so the request must reach the phone.
        let srv = server(allow: ["Bash(ls:*)"], store: store)
        try await srv.buildApplication().test(.router) { client in
            async let held = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: claudeRequest("ls -la"))) { res -> String in
                String(buffer: res.body)
            }
            try await waitForPendingApproval(store, session: "ps")
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"allow"}"#)) { res in
                #expect(res.status == .ok)
            }
            let text = try await held
            #expect(text.contains(#""hookEventName":"PermissionRequest""#))
            #expect(text.contains(#""behavior":"allow""#))
            #expect(!text.contains("updatedPermissions"))
        }
    }

    @Test("a native deny rule still wins over a PermissionRequest")
    func permissionRequestNativeDeny() async throws {
        try await server(deny: ["Bash(rm:*)"]).buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: claudeRequest("rm -rf build"))) { res in
                #expect(String(buffer: res.body).contains(#""behavior":"deny""#))
            }
        }
    }

    @Test("alwaysAllow echoes Claude's own suggestion as updatedPermissions and writes nothing to the store")
    func alwaysAllowEchoesNativeSuggestion() async throws {
        let store = SessionStore()
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbapproval-\(UUID().uuidString).json")
        let allowStore = VibeBuddyAllowStore(url: storeURL)
        let srv = VibeBuddyServer(store: store, token: "t0k", port: 9876,
                                  approvalRegistry: ApprovalRegistry(),
                                  rules: { _ in PermissionRules(allow: [], deny: []) },
                                  allowStore: allowStore,
                                  approvalTimeout: .seconds(5), approvalID: { "s" })
        try await srv.buildApplication().test(.router) { client in
            async let held = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: claudeRequestWithSuggestion("npm run lint"))) { res -> String in
                String(buffer: res.body)
            }
            try await waitForPendingApproval(store, session: "ps")
            // The card shows Claude's rule text, not vibebuddy's derived one.
            let pending = await store.snapshot(now: Date()).sessions
                .first(where: { $0.id == "ps" })?.pendingApproval
            #expect(pending?.suggestedRule == "Bash(npm run lint)")
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"alwaysAllow"}"#)) { res in
                #expect(res.status == .ok)
            }
            let text = try await held
            #expect(text.contains(#""behavior":"allow""#))
            #expect(text.contains(#""updatedPermissions":[{"#))
            #expect(text.contains(#""ruleContent":"npm run lint""#))
            // Only the allow-rule entry rides back; the mode switch is dropped.
            #expect(!text.contains("setMode"))
            #expect(await allowStore.all().isEmpty)
        }
    }

    @Test("alwaysAllow without a suggestion still persists vibebuddy's own rule")
    func alwaysAllowFallsBackToStore() async throws {
        let store = SessionStore()
        let srv = server(store: store)
        try await srv.buildApplication().test(.router) { client in
            async let held = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: claudeRequest("git status"))) { res -> String in
                String(buffer: res.body)
            }
            try await waitForPendingApproval(store, session: "ps")
            let pending = await store.snapshot(now: Date()).sessions
                .first(where: { $0.id == "ps" })?.pendingApproval
            #expect(pending?.suggestedRule == nil)
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"alwaysAllow"}"#)) { res in
                #expect(res.status == .ok)
            }
            let text = try await held
            #expect(text.contains(#""behavior":"allow""#))
            #expect(!text.contains("updatedPermissions"))
            // The same request next time is auto-allowed from the vibebuddy store.
            try await client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: claudeRequest("git status"))) { res in
                #expect(String(buffer: res.body).contains(#""behavior":"allow""#))
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

    // MARK: permission-mode / read-only short circuit (notification-filtering/01)

    private func expectImmediateAllow(_ srv: VibeBuddyServer, store: SessionStore,
                                      body: String) async throws {
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: body)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("\"permissionDecision\":\"allow\""))
            }
        }
        let session = await store.snapshot(now: Date()).sessions.first { $0.id == "s" }
        #expect(session?.pendingApproval == nil)
        #expect(session?.status == .working)   // the hook is still the PreToolUse signal
    }

    @Test("a bypassPermissions Bash call allows at once, holds nothing, still goes working")
    func bypassModeShortCircuits() async throws {
        let store = SessionStore()
        try await expectImmediateAllow(server(store: store), store: store,
                                       body: claude(tool: "Bash", mode: "bypassPermissions"))
    }

    @Test("a default-mode Read allows at once without a card")
    func defaultModeReadShortCircuits() async throws {
        let store = SessionStore()
        try await expectImmediateAllow(server(store: store), store: store,
            body: claude(tool: "Read", input: #"{"file_path":"/x/p/a.swift"}"#, mode: "default"))
    }

    @Test("an acceptEdits Edit allows at once without a card")
    func acceptEditsEditShortCircuits() async throws {
        let store = SessionStore()
        try await expectImmediateAllow(server(store: store), store: store,
            body: claude(tool: "Edit", input: #"{"file_path":"/x/p/a.swift","old_string":"a","new_string":"b"}"#,
                         mode: "acceptEdits"))
    }

    @Test("a default-mode Edit still holds for the phone")
    func defaultModeEditHolds() async throws {
        let store = SessionStore()
        let srv = server(store: store, approvalTimeout: .milliseconds(300))
        try await srv.buildApplication().test(.router) { client in
            async let held = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: claude(tool: "Edit",
                    input: #"{"file_path":"/x/p/a.swift","old_string":"a","new_string":"b"}"#,
                    mode: "default"))) { res -> String in String(buffer: res.body) }
            try await waitForPendingApproval(store, session: "s")
            #expect(try await held.isEmpty)   // timed out → fail-open, empty body
        }
    }

    @Test("a PermissionRequest is never short-circuited — even a bypassPermissions Bash holds")
    func permissionRequestIsNeverShortCircuited() async throws {
        let store = SessionStore()
        let srv = server(store: store, approvalTimeout: .milliseconds(300))
        try await srv.buildApplication().test(.router) { client in
            async let held = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string:
                    #"{"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/x/p","permission_mode":"bypassPermissions","#
                    + #""tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#)) { res -> String in String(buffer: res.body) }
            try await waitForPendingApproval(store, session: "s")
            #expect(try await held.isEmpty)   // timed out → fail-open, empty body
        }
    }

    @Test("a default-mode MCP tool still holds — MCP is never read-only")
    func defaultModeMCPHolds() async throws {
        let store = SessionStore()
        let srv = server(store: store, approvalTimeout: .milliseconds(300))
        try await srv.buildApplication().test(.router) { client in
            async let held = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: claude(tool: "mcp__filesystem__read_file",
                    input: #"{"path":"/x/p/a.swift"}"#, mode: "default"))) { res -> String in
                String(buffer: res.body)
            }
            try await waitForPendingApproval(store, session: "s")
            #expect(try await held.isEmpty)
        }
    }

    @Test("a native deny rule beats bypassPermissions")
    func denyBeatsBypass() async throws {
        try await server(deny: ["Bash(rm:*)"]).buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: claude(tool: "Bash", mode: "bypassPermissions"))) { res in
                #expect(String(buffer: res.body).contains("\"permissionDecision\":\"deny\""))
            }
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
            // `default` mode: a bypass-mode call would short-circuit to allow instead of holding.
            let text = try await approve(client, body: grokBash("rm -rf build", mode: "default"), agent: "grok")
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
            async let first = approve(client, body: grokBash("git status", mode: "default"), agent: "grok")
            try await waitForPendingApproval(store, session: "gs")
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"alwaysAllow"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await first == #"{"decision":"allow"}"#)

            // Same command again — and under grok's older tool spelling, which
            // canonicalizes to the same `Bash(git status)` rule.
            let again = try await approve(client, body: grokBash("git status", tool: "run_terminal_cmd", mode: "default"),
                                          agent: "grok")
            #expect(again == #"{"decision":"allow"}"#)
        }
    }

    // MARK: - Claude Code PermissionRequest (the gate `--approval` installs)
    //
    // Same envelope as Claude's PreToolUse, but it only fires when Claude would
    // prompt, and it is answered with `decision.behavior` — the very contract
    // Codex adopted. A PreToolUse payload keeps the `permissionDecision` reply.

    // An allow-listed *Claude* PermissionRequest is deliberately not answered
    // from our copy of Claude's rules — Claude ran them and still asked — see
    // `permissionRequestNeverReMatchesAllowRules` above. Codex keeps the
    // matcher (`codexPermissionRequestAllowImmediate` below): its only rule
    // vocabulary is the one vibebuddy applies.

    @Test("a held claude PermissionRequest shows the card on the known session; a phone deny answers deny + message")
    func claudePermissionRequestHoldThenDeny() async throws {
        let store = SessionStore()
        let prompt = #"{"hook_event_name":"UserPromptSubmit","session_id":"ps","cwd":"/x/p","prompt":"go"}"#
        await store.ingest(Data(prompt.utf8), receivedAt: Date())
        let srv = server(store: store)   // empty allow → .ask
        try await srv.buildApplication().test(.router) { client in
            async let held = approve(client, body: claudeRequest("rm -rf build"))
            try await waitForPendingApproval(store, session: "ps")
            let session = try #require(await store.snapshot(now: Date()).sessions.first { $0.id == "ps" })
            #expect(session.agent == .claudeCode)
            #expect(session.status == .needsResponse)
            #expect(session.pendingApproval?.command == "rm -rf build")
            #expect(session.pendingApproval?.permissionMode == nil)
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"deny"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await held == codexDeny)
            let after = try #require(await store.snapshot(now: Date()).sessions.first { $0.id == "ps" })
            #expect(after.pendingApproval == nil)
            #expect(after.status == .working)
        }
    }

    @Test("alwaysAllow from a claude PermissionRequest also auto-allows the same call on a PreToolUse gate")
    func claudePermissionRequestAlwaysAllowSharesRules() async throws {
        let store = SessionStore()
        try await server(store: store).buildApplication().test(.router) { client in
            async let first = approve(client, body: claudeRequest("git status"))
            try await waitForPendingApproval(store, session: "ps")
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"alwaysAllow"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await first == codexAllow)
            // The persisted rule is event-agnostic: a legacy PreToolUse gate
            // reads it too, in its own contract.
            let legacy = try await approve(client, body: bash("git status"))
            #expect(legacy.contains("\"permissionDecision\":\"allow\""))
        }
    }

    // MARK: - Codex CLI (?agent=codex)
    //
    // Claude-shaped envelope on PermissionRequest (Codex fires it only when it
    // would prompt), answered in Codex's own contract: hookSpecificOutput with
    // `decision.behavior` allow/deny. An `allow` is final on Codex's side.

    @Test("an allow-listed codex request answers allow at once and raises no wait")
    func codexAllowImmediate() async throws {
        let store = SessionStore()
        try await server(allow: ["Bash(ls:*)"], store: store).buildApplication().test(.router) { client in
            let text = try await approve(client, body: codexRequest("ls -la"), agent: "codex")
            #expect(text == codexAllow)
            // A decided request is not a wait: nothing is marked needsResponse
            // (and so no "needs you" push fires) for an immediate outcome.
            #expect(await store.snapshot(now: Date()).sessions.first { $0.id == "cs" } == nil)
        }
    }

    /// A Codex session the status forwarders have already opened (working).
    private func seedCodexSession(_ store: SessionStore) async {
        let prompt = #"{"hook_event_name":"UserPromptSubmit","session_id":"cs","cwd":"/x/p","prompt":"go"}"#
        await store.ingest(Data(prompt.utf8), agent: .codex, receivedAt: Date())
    }

    @Test("a held codex request puts the card on the known session, and a phone deny returns it to working")
    func codexHoldOnKnownSession() async throws {
        let store = SessionStore()
        await seedCodexSession(store)
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
            #expect(after.status == .working)   // denied is not stuck waiting
        }
    }

    /// Counts needs-response announcements (the APNs push path) and remembers
    /// whether each carried the approval card.
    private actor WaitAnnouncements {
        var cards: [Bool] = []
        func record(_ session: AgentSession) { cards.append(session.pendingApproval != nil) }
    }

    @Test("a held request on an unknown session opens it from the payload and announces the wait once, with the card")
    func codexHoldOnUnknownSessionOpensIt() async throws {
        let store = SessionStore()
        let announced = WaitAnnouncements()
        await store.setNeedsResponseHandler { session in await announced.record(session) }
        let srv = server(store: store)
        try await srv.buildApplication().test(.router) { client in
            async let held = approve(client, body: codexRequest("rm -rf build"), agent: "codex")
            try await waitForPendingApproval(store, session: "cs")
            let session = try #require(await store.snapshot(now: Date()).sessions.first { $0.id == "cs" })
            #expect(session.status == .needsResponse)
            #expect(session.pendingApproval?.command == "rm -rf build")
            // One push, and it is the approval push — not a generic "needs you"
            // from opening the session followed by a second one for the card.
            try await Task.sleep(for: .milliseconds(50))
            #expect(await announced.cards == [true])
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"allow"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await held == codexAllow)
        }
    }

    @Test("no decision on a codex request times out to an empty body — Codex then prompts itself")
    func codexTimesOutEmpty() async throws {
        try await server(approvalTimeout: .milliseconds(200)).buildApplication().test(.router) { client in
            let text = try await approve(client, body: codexRequest("rm -rf build"), agent: "codex")
            #expect(text.isEmpty)
        }
    }

    @Test("a native deny rule short-circuits a codex request without holding or a wait")
    func codexNativeDeny() async throws {
        let store = SessionStore()
        await seedCodexSession(store)
        try await server(deny: ["Bash(rm:*)"], store: store).buildApplication().test(.router) { client in
            let text = try await approve(client, body: codexRequest("rm -rf build"), agent: "codex")
            #expect(text == codexDeny)
            let session = try #require(await store.snapshot(now: Date()).sessions.first { $0.id == "cs" })
            #expect(session.status == .working)      // still the working session it was
            #expect(session.pendingApproval == nil)
        }
    }

    @Test("a rename out of an allowed scope holds — the destination counts as touched")
    func codexRenameAcrossScopesHolds() async throws {
        let patch = "*** Begin Patch\n*** Update File: /x/p/allowed/a.swift\n*** Move to: /x/p/denied/b.swift\n@@\n-a\n+b\n*** End Patch"
        let store = SessionStore()
        let srv = server(allow: ["Edit(/x/p/allowed/**)"], store: store)
        try await srv.buildApplication().test(.router) { client in
            async let held = approve(client, body: codexRequest(patch, tool: "apply_patch"), agent: "codex")
            try await waitForPendingApproval(store, session: "cs")
            let pending = await store.snapshot(now: Date()).sessions.first { $0.id == "cs" }?.pendingApproval
            #expect(pending?.tool == "Edit")
            #expect(pending?.filePath == nil)
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"s","decision":"deny"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await held == codexDeny)
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
        let srv = server(allow: ["Bash(ls:*)"], deny: ["Bash(rm:*)"], port: port, host: "127.0.0.1")
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

        // So does Claude's PermissionRequest gate (no source argument). Its allow
        // rules are never re-run there, so the immediate answer is a native deny.
        let request = try await runApprovalHook(source: nil, port: port, token: "t0k",
                                                stdin: claudeRequest("rm -rf build"))
        #expect(request == codexDeny)

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
