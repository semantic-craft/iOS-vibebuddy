import Testing
import Foundation
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Approval routes")
struct ApprovalRoutesTests {
    private func server(allow: [String] = [], deny: [String] = []) -> VibeBuddyServer {
        VibeBuddyServer(store: SessionStore(), token: "t0k",
                        approvalRegistry: ApprovalRegistry(),
                        rules: { PermissionRules(allow: allow, deny: deny) },
                        approvalTimeout: .milliseconds(200),
                        approvalID: { "s" })
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
        let srv = server()   // empty allow → .ask
        try await srv.buildApplication().test(.router) { client in
            async let approval = client.execute(uri: "/approval", method: .post,
                                                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: body)) { res -> String in
                #expect(res.status == .ok)
                return String(buffer: res.body)
            }
            try await Task.sleep(for: .milliseconds(80))
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
        try await server().buildApplication().test(.router) { client in
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
}
