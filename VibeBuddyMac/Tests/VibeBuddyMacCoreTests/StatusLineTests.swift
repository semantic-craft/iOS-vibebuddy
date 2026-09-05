import Foundation
import Testing
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// A status line document in the shape Claude Code 2.1.26x sends (docs:
/// "Customize your status line", full JSON schema).
private let statusLineJSON = #"""
{
  "cwd": "/x/project", "session_id": "s1", "session_name": "auth refactor",
  "prompt_id": "p1", "transcript_path": "/tmp/t.jsonl",
  "model": {"id": "claude-opus-5", "display_name": "Opus"},
  "workspace": {"current_dir": "/x/project", "project_dir": "/x/project", "added_dirs": [],
                "git_worktree": "feature-xyz", "repo": {"host": "github.com", "owner": "acme", "name": "project"}},
  "version": "2.1.261",
  "cost": {"total_cost_usd": 1.2345, "total_duration_ms": 45000, "total_api_duration_ms": 2300,
           "total_lines_added": 156, "total_lines_removed": 23},
  "context_window": {"total_input_tokens": 45000, "total_output_tokens": 5000, "context_window_size": 200000,
                     "used_percentage": 25.0, "remaining_percentage": 75.0},
  "effort": {"level": "high"},
  "rate_limits": {"five_hour": {"used_percentage": 23.5, "resets_at": 1788425600},
                  "seven_day": {"used_percentage": 41.2, "resets_at": 1788857600}},
  "pr": {"number": 1234, "url": "https://github.com/acme/project/pull/1234", "review_state": "pending"},
  "worktree": {"name": "my-feature", "path": "/x/.claude/worktrees/my-feature", "branch": "worktree-my-feature"}
}
"""#

@Suite("Claude status line")
struct StatusLineTests {
    let now = Date(timeIntervalSince1970: 1_788_600_000)

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    @Test("the document decodes into the session facts and both rate-limit windows")
    func decode() throws {
        let sample = try #require(StatusLineSample.decode(json(statusLineJSON)))
        #expect(sample.sessionID == "s1")
        #expect(sample.model == "Opus")
        #expect(sample.cwd == "/x/project")
        #expect(sample.sessionName == "auth refactor")
        #expect(sample.effort == "high")
        #expect(sample.costUSD == 1.2345)
        #expect(sample.contextTokens == 50_000)     // 25% of 200k, what Claude shows
        #expect(sample.contextWindow == 200_000)
        #expect(sample.prNumber == 1234)
        #expect(sample.prURL == "https://github.com/acme/project/pull/1234")
        #expect(sample.worktree == "my-feature")
        #expect(sample.fiveHour?.usedPercent == 24)
        #expect(sample.fiveHour?.windowDurationMinutes == 300)
        #expect(sample.sevenDay?.usedPercent == 41)
        #expect(sample.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_788_857_600))
        let usage = try #require(sample.usageSnapshot(fetchedAt: now))
        #expect(usage.provider == .claude)
        #expect(ProviderQuota(.available(usage, nextRefreshAt: nil), provider: .claude).weeklyRemainingPercent == 59)
    }

    @Test("without rate_limits there is no usage snapshot, and without a session id no sample")
    func decodeEdges() {
        var doc = json(statusLineJSON)
        doc["rate_limits"] = nil
        #expect(StatusLineSample.decode(doc)?.usageSnapshot(fetchedAt: now) == nil)
        doc["session_id"] = ""
        #expect(StatusLineSample.decode(doc) == nil)
    }

    @Test("a sample fills a known session and never creates or moves one")
    func storeApplies() async throws {
        let store = SessionStore()
        let sample = try #require(StatusLineSample.decode(json(statusLineJSON)))
        #expect(await store.applyStatusLine(sample, at: now) == false)
        #expect(await store.snapshot(now: now).sessions.isEmpty)

        let start = HookEvent(kind: .userPromptSubmit, sessionID: "s1", agent: .claudeCode,
                              cwd: "/x/project", timestamp: now)
        await store.ingest(start)
        #expect(await store.applyStatusLine(sample, at: now.addingTimeInterval(1)) == true)
        let session = try #require(await store.snapshot(now: now).sessions.first { $0.id == "s1" })
        #expect(session.status == .working)
        #expect(session.name == "auth refactor")
        #expect(session.displayTitle == "auth refactor")
        #expect(session.effort == "high")
        #expect(session.costUSD == 1.2345)
        #expect(session.estimatedCostUSD == 1.2345)
        #expect(session.contextTokens == 50_000)
        #expect(session.contextWindow == 200_000)
        #expect(session.prNumber == 1234)
        #expect(session.worktree == "my-feature")
        #expect(session.observations?.contains { $0.source == .statusline } == true)
    }

    @Test("/statusline is token-gated, updates the session and publishes the Claude allowance")
    func route() async throws {
        let store = SessionStore()
        let feed = AccountUsageLiveFeed()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s1", agent: .claudeCode,
                                     cwd: "/x/project", timestamp: now))
        let srv = VibeBuddyServer(store: store, token: "t0k", port: 9876, usageFeed: feed)
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/statusline", method: .post,
                                     body: ByteBuffer(string: statusLineJSON)) { res in
                #expect(res.status == .unauthorized)
            }
            try await client.execute(uri: "/statusline", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: "{\"nope\":1}")) { res in
                #expect(res.status == .badRequest)
            }
            try await client.execute(uri: "/statusline", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: statusLineJSON)) { res in
                #expect(res.status == .ok)
            }
        }
        let session = try #require(await store.snapshot(now: now).sessions.first { $0.id == "s1" })
        #expect(session.name == "auth refactor")
        let usage = try #require(await feed.latest(for: .claude))
        #expect(usage.secondary?.usedPercent == 41)
    }

    @Test("a quota auto-resume notification is metadata with a line, not a wait")
    func quotaNotification() async throws {
        let store = SessionStore()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s1", agent: .claudeCode,
                                     cwd: "/x/project", timestamp: now))
        let payload = #"{"hook_event_name":"Notification","session_id":"s1","cwd":"/x/project","notification_type":"quota_auto_resume_stale","message":"Usage limit reached","title":"Claude Code"}"#
        #expect(await store.ingest(Data(payload.utf8), agent: .claudeCode, receivedAt: now.addingTimeInterval(1)))
        let session = try #require(await store.snapshot(now: now).sessions.first { $0.id == "s1" })
        #expect(session.status == .working)
        #expect(session.summary == "Usage limit reached — waiting for it to reset")
        // A real permission prompt still waits.
        let prompt = #"{"hook_event_name":"Notification","session_id":"s1","cwd":"/x/project","notification_type":"permission_prompt","message":"Claude needs your permission"}"#
        await store.ingest(Data(prompt.utf8), agent: .claudeCode, receivedAt: now.addingTimeInterval(2))
        #expect(await store.snapshot(now: now).sessions.first { $0.id == "s1" }?.status == .needsResponse)
    }
}
