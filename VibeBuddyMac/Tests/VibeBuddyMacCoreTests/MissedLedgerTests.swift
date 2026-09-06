import Foundation
import Testing
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Missed-response ledger")
struct MissedLedgerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a wait older than five minutes writes one missed entry")
    func recordsOncePerWait() {
        var ledger = MissedLedger()
        let session = waiting("s", agent: .claudeCode, wait: .permission, since: t0)
        ledger.observe([session], now: t0)
        ledger.observe([session], now: t0.addingTimeInterval(299))
        #expect(ledger.counts(weekContaining: t0, now: t0.addingTimeInterval(299)).count == 0)

        ledger.observe([session], now: t0.addingTimeInterval(300))
        ledger.observe([session], now: t0.addingTimeInterval(600))
        let counts = ledger.counts(weekContaining: t0.addingTimeInterval(300), now: t0.addingTimeInterval(600))
        #expect(counts.count == 1)
        #expect(counts.byAgent == ["claudeCode": 1])
        #expect(ledger.entries.map(\.waitKind) == [.permission])
    }

    @Test("acknowledge cancels the timer for that wait")
    func acknowledgementCancels() {
        var ledger = MissedLedger()
        let session = waiting("s", since: t0)
        ledger.observe([session], now: t0)
        ledger.acknowledge(sessionID: "s", now: t0.addingTimeInterval(60))
        ledger.observe([session], now: t0.addingTimeInterval(300))
        #expect(ledger.counts(weekContaining: t0.addingTimeInterval(300), now: t0.addingTimeInterval(300)).count == 0)
    }

    @Test("leaving needsResponse before five minutes is not a miss")
    func waitEndingCancels() {
        var ledger = MissedLedger()
        ledger.observe([waiting("s", since: t0)], now: t0)
        ledger.observe([], now: t0.addingTimeInterval(120))
        ledger.observe([], now: t0.addingTimeInterval(300))
        #expect(ledger.counts(weekContaining: t0.addingTimeInterval(300), now: t0.addingTimeInterval(300)).count == 0)
    }

    @Test("a muted session still counts")
    func mutedCounts() {
        var ledger = MissedLedger()
        var session = waiting("muted", agent: .codex, wait: .question, since: t0)
        session.attention = .muted
        session.attentionOverride = .muted
        ledger.observe([session], now: t0)
        ledger.observe([session], now: t0.addingTimeInterval(300))
        #expect(ledger.counts(weekContaining: t0.addingTimeInterval(300), now: t0.addingTimeInterval(300)).count == 1)
        #expect(ledger.entries.first?.agent == .codex)
    }

    @Test("zero for the week is 0, not blank")
    func zeroIsZero() {
        var ledger = MissedLedger()
        let counts = ledger.counts(weekContaining: t0, now: t0)
        #expect(counts.count == 0)
        #expect(counts.byAgent.isEmpty)
        #expect(!counts.weekStart.isEmpty)
    }

    @Test("week window starts Monday 06:00 local; older weeks stay queryable")
    func weekBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.firstWeekday = 2
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 6))!
        var ledger = MissedLedger()
        let lateSunday = monday.addingTimeInterval(-60)
        let session = waiting("s", since: lateSunday.addingTimeInterval(-300))
        ledger.observe([session], now: lateSunday.addingTimeInterval(-300))
        ledger.observe([session], now: lateSunday)
        #expect(ledger.counts(weekContaining: lateSunday, now: lateSunday, calendar: calendar).count == 1)
        #expect(ledger.counts(weekContaining: monday, now: monday, calendar: calendar).count == 0)
        #expect(ledger.counts(weekContaining: lateSunday, now: lateSunday, calendar: calendar).weekStart == "2026-08-31")
        #expect(ledger.counts(weekContaining: monday, now: monday, calendar: calendar).weekStart == "2026-09-07")
    }

    @Test("persists beside the journal at 0600 and keeps eight weeks")
    func persistsOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-missed-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("missed-ledger.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var ledger = MissedLedger(url: url, now: t0)
        let session = waiting("s", since: t0)
        ledger.observe([session], now: t0)
        ledger.observe([session], now: t0.addingTimeInterval(300))

        var reopened = MissedLedger(url: url, now: t0.addingTimeInterval(300))
        #expect(reopened.counts(weekContaining: t0.addingTimeInterval(300), now: t0.addingTimeInterval(300)).count == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("a late answer before the next poll still records the deadline once")
    func lateAnswerBetweenPolls() {
        var ledger = MissedLedger()
        ledger.observe([waiting("s", since: t0)], now: t0)
        ledger.observe([], now: t0.addingTimeInterval(301))
        ledger.observe([], now: t0.addingTimeInterval(330))
        #expect(ledger.entries.count == 1)
        #expect(ledger.entries.first?.missedAt == t0.addingTimeInterval(300))
    }

    @Test("a delayed poll assigns a miss to the week of its deadline")
    func delayedPollAcrossWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 6))!
        let since = monday.addingTimeInterval(-301)
        var ledger = MissedLedger()
        ledger.observe([waiting("s", since: since)], now: since)
        ledger.observe([], now: monday.addingTimeInterval(10))
        #expect(ledger.counts(weekContaining: monday.addingTimeInterval(-1), now: monday, calendar: calendar).count == 1)
        #expect(ledger.counts(weekContaining: monday, now: monday, calendar: calendar).count == 0)
    }

    @Test("calendar weeks do not overlap or gap across daylight saving changes")
    func daylightSavingWeeks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, minuteOffset) in [(3, 9, 30), (11, 2, -30)] {
            let monday = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 6))!
            let deadline = monday.addingTimeInterval(Double(minuteOffset * 60))
            let since = deadline.addingTimeInterval(-300)
            var ledger = MissedLedger()
            ledger.observe([waiting("s", since: since)], now: since)
            ledger.observe([], now: deadline)
            let previous = ledger.counts(weekContaining: monday.addingTimeInterval(-1), now: deadline, calendar: calendar)
            let current = ledger.counts(weekContaining: monday, now: deadline, calendar: calendar)
            #expect(previous.count == (minuteOffset < 0 ? 1 : 0))
            #expect(current.count == (minuteOffset > 0 ? 1 : 0))
        }
    }

    @Test("reads prune expired entries from memory and disk without a new miss")
    func idleRetentionPrunes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("miss-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("missed.json")
        var ledger = MissedLedger(url: url, now: t0)
        ledger.observe([waiting("s", since: t0)], now: t0)
        ledger.observe([], now: t0.addingTimeInterval(300))
        let future = t0.addingTimeInterval(MissedLedger.retention + 301)
        #expect(ledger.counts(weekContaining: t0, now: future).count == 0)
        #expect(ledger.entries.isEmpty)
        let reopened = MissedLedger(url: url, now: t0)
        #expect(reopened.entries.isEmpty)
    }

    private func waiting(
        _ id: String,
        agent: AgentKind = .claudeCode,
        wait: WaitKind = .permission,
        since: Date
    ) -> AgentSession {
        AgentSession(
            id: id, agent: agent, project: "demo",
            status: .needsResponse, waitKind: wait,
            statusSince: since, updatedAt: since
        )
    }
}

@Suite("Missed-response store and routes")
struct MissedRouteTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("store records a miss and GET /missed returns the week count")
    func getMissed() async throws {
        let store = SessionStore()
        await store.ingest(notification(session: "s", at: t0), receivedAt: t0)
        await store.evaluateMissed(now: t0.addingTimeInterval(299))
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(299)).count == 0)
        await store.evaluateMissed(now: t0.addingTimeInterval(300))
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(300)).count == 1)

        let server = VibeBuddyServer(store: store, token: "t0k")
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/missed", method: .get) { res in
                #expect(res.status == .unauthorized)
            }
            let day = ISO8601DateFormatter().string(from: t0).prefix(10)
            try await client.execute(uri: "/missed?week=\(day)", method: .get,
                                     headers: [.authorization: "Bearer t0k"]) { res in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(MissedCounts.self, from: Data(buffer: res.body))
                #expect(body.count == 1)
                #expect(body.byAgent["claudeCode"] == 1)
            }
        }
    }

    @Test("GET /missed with an empty week still reports zero")
    func getMissedZero() async throws {
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k")
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/missed?week=2020-01-06", method: .get,
                                     headers: [.authorization: "Bearer t0k"]) { res in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(MissedCounts.self, from: Data(buffer: res.body))
                #expect(body.count == 0)
                #expect(body.byAgent.isEmpty)
            }
            try await client.execute(uri: "/missed?week=not-a-date", method: .get,
                                     headers: [.authorization: "Bearer t0k"]) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("/acknowledge-wait cancels the exact missed timer")
    func acknowledgeCancels() async throws {
        let read = WaitReadRequest(sourceID: "mac", sessionID: "s", statusSince: t0, waitKind: .permission)
        let body = String(data: try JSONEncoder().encode(read), encoding: .utf8)!
        try await expectCancel(uri: "/acknowledge-wait", body: body)
    }

    @Test("/jump cancels the missed timer")
    func jumpCancels() async throws {
        try await expectCancel(uri: "/jump", body: #"{"sessionId":"s"}"#) { store in
            await store.setTerminalRef(sessionID: "s", TerminalRef(termProgram: "ghostty", tty: "ttys001"))
        }
    }

    @Test("/answer cancels the missed timer")
    func answerCancels() async throws {
        try await expectCancel(uri: "/answer", body: #"{"sessionId":"s","answer":"yes"}"#) { store in
            await store.setTerminalRef(sessionID: "s", TerminalRef(termProgram: "ghostty", tty: "ttys001"))
        }
    }

    @Test("/decision cancels the missed timer")
    func decisionCancels() async throws {
        let context = ApprovalContextStore()
        await context.set(id: "ap", sessionID: "s", rule: nil)
        try await expectCancel(uri: "/decision", body: #"{"approvalId":"ap","decision":"allow"}"#,
                               server: { store in
            VibeBuddyServer(store: store, token: "t0k", approvalContext: context,
                            onJump: { _ in .focused }, onAnswer: { _, _ in })
        })
    }

    @Test("a muted waiting session still records a miss")
    func mutedStoreCounts() async {
        let store = SessionStore()
        await store.ingest(notification(session: "s", at: t0), receivedAt: t0)
        await store.setAttention(sessionID: "s", .muted)
        await store.evaluateMissed(now: t0.addingTimeInterval(300))
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(300)).count == 1)
    }

    @Test("reconciliation uses the answer time even when the sweep is late", arguments: [60.0, 301.0])
    func reconciliationPreservesMiss(answerOffset: TimeInterval) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("miss-sweep-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: url.path)
        let store = SessionStore()
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification", "session_id": "s", "cwd": "/x/demo",
            "message": "needs your permission", "transcript_path": url.path])
        await store.ingest(payload, receivedAt: t0)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(answerOffset)], ofItemAtPath: url.path)
        await store.sweep(now: t0.addingTimeInterval(310))
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(310)).count == (answerOffset >= 300 ? 1 : 0))
    }

    @Test("a late sweep processes multiple early answers in event order")
    func earlyAnswersInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("miss-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore()
        for offset in [0.0, 100.0] {
            let url = directory.appendingPathComponent("\(offset).jsonl")
            try Data().write(to: url)
            let since = t0.addingTimeInterval(offset)
            try FileManager.default.setAttributes([.modificationDate: since], ofItemAtPath: url.path)
            let payload = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "Notification", "session_id": "s-\(offset)", "cwd": "/x/demo",
                "message": "needs your permission", "transcript_path": url.path])
            await store.ingest(payload, receivedAt: since)
            try FileManager.default.setAttributes([.modificationDate: since.addingTimeInterval(299)], ofItemAtPath: url.path)
        }
        await store.sweep(now: t0.addingTimeInterval(410))
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(410)).count == 0)
    }

    @Test("in-process wait resolution before timeout cannot become a later miss")
    func earlyResolutionCancels() async {
        for question in [false, true] {
            let store = SessionStore()
            await store.ingest(notification(session: "s", at: t0), receivedAt: t0)
            if question {
                await store.beginQuestion(sessionID: "s", PendingQuestion(id: "q", prompt: "Continue?"), at: t0)
                await store.endQuestion(sessionID: "s", at: t0.addingTimeInterval(60))
            } else {
                await store.beginApproval(sessionID: "s", PendingApproval(id: "p", tool: "Bash", commandPreview: "pwd"), at: t0)
                await store.endApproval(sessionID: "s", at: t0.addingTimeInterval(60))
            }
            #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(330)).count == 0)
        }
    }

    @Test("a replacement pending request has its own deadline and rejects the old read")
    func replacementWaitIdentity() async {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(notification(session: "s", at: t0), receivedAt: t0)
        await store.beginQuestion(sessionID: "s", PendingQuestion(id: "a", prompt: "A?"), at: t0)
        let readA = WaitReadRequest(sourceID: "mac", sessionID: "s", statusSince: t0,
                                   waitKind: .question, pendingID: "a")
        #expect(await store.acknowledgeWait(readA, now: t0.addingTimeInterval(60)))
        await store.beginQuestion(sessionID: "s", PendingQuestion(id: "b", prompt: "B?"), at: t0.addingTimeInterval(120))
        #expect(!((await store.acknowledgeWait(readA, now: t0.addingTimeInterval(130)))))
        #expect(await store.snapshot(now: t0.addingTimeInterval(130)).sessions.first?.pendingQuestion?.id == "b")
        // Re-observing B with richer content must not restart its timer.
        await store.beginQuestion(sessionID: "s", PendingQuestion(id: "b", prompt: "B detail"), at: t0.addingTimeInterval(180))
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(419)).count == 0)
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(420)).count == 1)
    }

    @Test("pending identity rejects stale reads even when source timestamps collide")
    func collidingWaitTimestamps() async {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(notification(session: "s", at: t0), receivedAt: t0)
        await store.beginQuestion(sessionID: "s", PendingQuestion(id: "a", prompt: "A?"), at: t0)
        let old = WaitReadRequest(sourceID: "mac", sessionID: "s", statusSince: t0,
                                  waitKind: .question, pendingID: "a")
        await store.beginQuestion(sessionID: "s", PendingQuestion(id: "b", prompt: "B?"), at: t0)
        #expect(!((await store.acknowledgeWait(old, now: t0.addingTimeInterval(60)))))
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(300)).count == 1)
    }

    @Test("late metadata for an existing wait retains its notification boundary")
    func lateWaitMetadata() async {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(notification(session: "s", at: t0), receivedAt: t0)
        await store.beginApproval(sessionID: "s", PendingApproval(id: "a", tool: "Bash", commandPreview: "pwd"),
                                  at: t0.addingTimeInterval(60))
        await store.beginApproval(sessionID: "s", PendingApproval(id: "a", tool: "Bash", commandPreview: "pwd detail"),
                                  at: t0.addingTimeInterval(120))
        #expect(await store.snapshot(now: t0.addingTimeInterval(120)).sessions.first?.statusSince == t0)
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(300)).count == 1)
    }

    @Test("late metadata preserves a prior view or miss instead of starting another ledger key")
    func lateMetadataKeepsReadOrMiss() async {
        for viewed in [false, true] {
            let store = SessionStore(sourceID: "mac")
            await store.ingest(notification(session: "s", at: t0), receivedAt: t0)
            if viewed {
                let read = WaitReadRequest(sourceID: "mac", sessionID: "s", statusSince: t0, waitKind: .permission)
                #expect(await store.acknowledgeWait(read, now: t0.addingTimeInterval(60)))
            }
            await store.evaluateMissed(now: t0.addingTimeInterval(300))
            await store.beginApproval(sessionID: "s", PendingApproval(id: "a", tool: "Bash", commandPreview: "pwd"),
                                      at: t0.addingTimeInterval(310))
            #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(400)).count == (viewed ? 0 : 1))
        }
    }

    @Test("viewing an exact wait respects its deadline without answering it", arguments: [60.0, 301.0])
    func waitReadRoute(elapsed: TimeInterval) async throws {
        let now = Date()
        let since = now.addingTimeInterval(-elapsed)
        let store = SessionStore(sourceID: "mac")
        await store.ingest(notification(session: "s", at: since), receivedAt: since)
        let server = VibeBuddyServer(store: store, token: "t0k")
        try await server.buildApplication().test(.router) { client in
            for read in [
                WaitReadRequest(sourceID: "other", sessionID: "s", statusSince: since, waitKind: .permission),
                WaitReadRequest(sourceID: "mac", sessionID: "s", statusSince: since.addingTimeInterval(-1), waitKind: .permission)
            ] {
                try await client.execute(uri: "/acknowledge-wait", method: .post,
                    headers: [.authorization: "Bearer t0k"],
                    body: ByteBuffer(data: try JSONEncoder().encode(read))) { response in
                    #expect(response.status == .conflict)
                }
            }
            let read = WaitReadRequest(sourceID: "mac", sessionID: "s", statusSince: since, waitKind: .permission)
            try await client.execute(uri: "/acknowledge-wait", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(data: try JSONEncoder().encode(read))) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(await store.snapshot(now: now).sessions.first?.status == .needsResponse)
        #expect(await store.missedCounts(week: now, now: now.addingTimeInterval(400)).count == (elapsed >= 300 ? 1 : 0))
    }

    private func expectCancel(
        uri: String,
        body: String,
        setup: ((SessionStore) async -> Void)? = nil,
        server: ((SessionStore) -> VibeBuddyServer)? = nil
    ) async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(notification(session: "s", at: t0), receivedAt: t0)
        if let setup { await setup(store) }
        let srv = server?(store) ?? VibeBuddyServer(store: store, token: "t0k",
                                                    onJump: { _ in .focused }, onAnswer: { _, _ in })
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: uri, method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: body)) { res in
                #expect(res.status == .ok)
            }
        }
        await store.evaluateMissed(now: t0.addingTimeInterval(300))
        #expect(await store.missedCounts(week: t0, now: t0.addingTimeInterval(300)).count == 0)
    }

    private func notification(session: String, at _: Date) -> Data {
        Data(#"{"hook_event_name":"Notification","session_id":"\#(session)","cwd":"/x/demo","message":"needs your permission"}"#.utf8)
    }
}
