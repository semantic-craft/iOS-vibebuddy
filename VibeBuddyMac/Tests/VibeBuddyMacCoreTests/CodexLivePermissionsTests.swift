import Foundation
import Testing
import HummingbirdTesting
import NIOCore
import HTTPTypes
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Explicit opt-in: real configured Codex account and daemon; no command execution.
@Suite("Live Codex permission relay", .enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_CODEX_LIVE_ACCEPTANCE"] == "1"))
struct CodexLivePermissionsTests {
    @Test("real daemon permission request reaches the HTTP decision route and resolves")
    func relay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vb-codex-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let client = CodexAppServerClient()
        try client.connect()
        defer { client.close() }
        _ = try await client.request("initialize", params: ["clientInfo": ["name": "vibebuddy-live-acceptance", "version": "1"], "capabilities": ["experimentalApi": true]])
        client.notify("initialized")
        let created = try await client.request("thread/start", params: ["cwd": root.path, "approvalPolicy": "on-request", "sandbox": "workspace-write",
            "config": ["features.request_permissions_tool": true]])
        let thread = try #require(created["thread"] as? [String: Any])
        let id = try #require(thread["id"] as? String)
        func cleanup() async throws {
            // Archive stops/unloads this test-owned thread. Keep cwd for diagnosis
            // if the daemon cannot confirm cleanup; never remove an active cwd.
            _ = try await client.request("thread/archive", params: ["threadId": id])
            try FileManager.default.removeItem(at: root)
        }
        do {
        // A newly-created thread has no resumable rollout until its first turn.
        _ = try await client.request("turn/start", params: ["threadId": id, "input": [["type": "text", "text": "Reply READY only. Do not use tools."]]])
        var ready = false
        for _ in 0..<300 {
            let current = try await client.request("thread/read", params: ["threadId": id, "includeTurns": false])
            let state = ((current["thread"] as? [String: Any])?["status"] as? [String: Any])?["type"] as? String
            if state == "idle" { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(ready, "Initial no-tool turn did not finish")
        let store = SessionStore(journalURL: root.appendingPathComponent("journal.json"))
        let registry = ApprovalRegistry()
        let contexts = ApprovalContextStore()
        let allowStore = VibeBuddyAllowStore(url: root.appendingPathComponent("allow.json"))
        let sessionAllow = SessionAllowList()
        let monitor = CodexAppServerMonitor(acceptanceThreadID: id, approvalRegistry: registry, allowStore: allowStore,
                                           sessionAllow: sessionAllow, approvalContext: contexts)
        let run = Task { await monitor.run(store: store) }
        defer { run.cancel() }
        for _ in 0..<100 where await monitor.diagnostics().subscribedThreads == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        let diagnostic = await monitor.diagnostics()
        try #require(diagnostic.subscribedThreads == 1, "Subscription failed: \(diagnostic.lastError ?? "unknown")")
        print("LIVE_PERMISSION_STARTED thread=\(id)")
        _ = try await client.request("turn/start", params: ["threadId": id, "input": [["type": "text", "text": "This is a permission relay acceptance test. Call the built-in request_permissions tool once requesting network enabled with reason VIBEBUDDY_LIVE_PERMISSIONS. Do not execute any shell commands, edit files, or make network requests. After the permission tool returns, reply DONE. If the tool is unavailable, report UNAVAILABLE and stop."]]])
        var pending: PendingApproval?
        for _ in 0..<900 {
            pending = await store.snapshot(now: Date()).sessions.first { $0.id == id }?.pendingApproval
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let card = try #require(pending, "No real permission card arrived; live acceptance did not pass")
        try #require(card.tool == "Permissions")
        try #require(!card.canPersistDecision)
        print("LIVE_PERMISSION_CARD thread=\(id) tool=\(card.tool) persistent=\(card.canPersistDecision)")
        let server = VibeBuddyServer(store: store, token: "acceptance-only", approvalRegistry: registry,
                                     allowStore: allowStore, sessionAllow: sessionAllow, approvalContext: contexts)
        try await server.buildApplication().test(.router) { http in
            for choice in ["allowSession", "allow"] {
                try await http.execute(uri: "/decision", method: .post,
                    headers: [.authorization: "Bearer acceptance-only"],
                    body: ByteBuffer(string: "{\"approvalId\":\"\(card.id)\",\"decision\":\"\(choice)\"}")) { response in
                    #expect(response.status == (choice == "allow" ? .ok : .conflict))
                }
            }
        }
        for _ in 0..<300 {
            if await monitor.activeTurnID(threadID: id) == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await store.snapshot(now: Date()).sessions.first { $0.id == id }?.pendingApproval == nil)
        #expect(await sessionAllow.contains(id) == false)
        #expect(await allowStore.all().isEmpty)
        try #require(await monitor.activeTurnID(threadID: id) == nil)
        print("LIVE_PERMISSION_RESOLVED thread=\(id)")
        } catch {
            do { try await cleanup() }
            catch { Issue.record("Test-thread cleanup failed; temporary cwd retained: \(root.path)") }
            throw error
        }
        try await cleanup()
    }
}
