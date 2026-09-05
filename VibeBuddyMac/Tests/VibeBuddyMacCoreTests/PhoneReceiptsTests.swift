import Testing
import Foundation
import Crypto
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// The phone reports the cues it posted itself; the Mac's push for the same
/// cue and wait stands down, and nothing else does (ADR-0012).
@Suite("PhoneReceipts — a push stands down only for a cue the phone reported")
struct PhoneReceiptsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let waitSince = Date(timeIntervalSince1970: 1_799_999_990)

    private func payload(_ identifier: String = "s1-needs_approval", token: String = "tok",
                         since: Date? = nil) -> NotifiedPayload {
        NotifiedPayload(token: token, posted: [.init(identifier: identifier, since: since ?? waitSince)])
    }

    @Test("a receipt already in hand answers at once, hold or not")
    func receiptBeforeDecision() async {
        let receipts = PhoneReceipts(grace: .seconds(2))
        await receipts.record(payload(), now: now)
        let clock = ContinuousClock()
        let started = clock.now
        let found = await receipts.receipt(for: "s1-needs_approval", since: waitSince,
                                           from: "tok", hold: true, now: now)
        #expect(found?.identifier == "s1-needs_approval")
        #expect(clock.now - started < .milliseconds(500))
    }

    @Test("with a stream open the push waits for a receipt that is still on its way")
    func receiptArrivesDuringHold() async {
        let receipts = PhoneReceipts(grace: .seconds(2))
        let now = self.now, waitSince = self.waitSince
        async let decision = receipts.receipt(for: "s1-needs_approval", since: waitSince,
                                              from: "tok", hold: true, now: now)
        try? await Task.sleep(for: .milliseconds(150))
        await receipts.record(payload(), now: now)
        #expect(await decision != nil)
    }

    @Test("no receipt: the push goes out after the grace, never later")
    func noReceiptPushesAfterGrace() async {
        let receipts = PhoneReceipts(grace: .milliseconds(300))
        let clock = ContinuousClock()
        let started = clock.now
        let found = await receipts.receipt(for: "s1-needs_approval", since: waitSince,
                                           from: "tok", hold: true, now: now)
        #expect(found == nil)
        let elapsed = clock.now - started
        #expect(elapsed >= .milliseconds(300))
        #expect(elapsed < .seconds(2))
    }

    @Test("with no stream open nobody can report: the push goes out at once")
    func noStreamNoWait() async {
        let receipts = PhoneReceipts(grace: .seconds(5))
        let clock = ContinuousClock()
        let started = clock.now
        let found = await receipts.receipt(for: "s1-needs_approval", since: waitSince,
                                           from: "tok", hold: false, now: now)
        #expect(found == nil)
        #expect(clock.now - started < .milliseconds(500))
    }

    @Test("a receipt for an earlier wait of the same session does not silence the next one")
    func differentWaitDoesNotMatch() async {
        let receipts = PhoneReceipts(grace: .milliseconds(100))
        await receipts.record(payload(since: waitSince), now: now)
        let nextWait = waitSince.addingTimeInterval(30)
        let found = await receipts.receipt(for: "s1-needs_approval", since: nextWait,
                                           from: "tok", hold: false, now: now)
        #expect(found == nil)
        // The two clocks may disagree by a little; the same wait still matches.
        let skewed = waitSince.addingTimeInterval(0.4)
        #expect(await receipts.receipt(for: "s1-needs_approval", since: skewed,
                                       from: "tok", hold: false, now: now) != nil)
    }

    @Test("another phone's receipt, another cue, or a cue with no wait never match")
    func otherPhoneOtherCue() async {
        let receipts = PhoneReceipts(grace: .milliseconds(100))
        await receipts.record(payload(token: "other"), now: now)
        await receipts.record(payload("s1-needs_answer"), now: now)
        #expect(await receipts.receipt(for: "s1-needs_approval", since: waitSince,
                                       from: "tok", hold: false, now: now) == nil)
        #expect(await receipts.receipt(for: "s1-needs_approval", since: nil,
                                       from: "other", hold: false, now: now) == nil)
    }

    @Test("a receipt older than the memory is forgotten")
    func expiredReceipt() async {
        let receipts = PhoneReceipts(grace: .milliseconds(100), memory: 60)
        await receipts.record(payload(), now: now)
        #expect(await receipts.receipt(for: "s1-needs_approval", since: waitSince,
                                       from: "tok", hold: false, now: now.addingTimeInterval(61)) == nil)
    }

    @Test("what the phone reported lands in the log on the phone channel and never moves health")
    func phoneReportsAreLogged() async {
        let spy = SpyDelivery()
        let receipts = PhoneReceipts(recorder: spy)
        await receipts.record(NotifiedPayload(
            token: "tok",
            posted: [.init(identifier: "s1-needs_approval", since: waitSince)],
            coveredByPush: [.init(identifier: "s2-needs_answer", since: waitSince)]), now: now)
        #expect(spy.records.map(\.channel) == [.phone, .phone])
        #expect(spy.records.map(\.outcome) == [.scheduled, .skipped])
        #expect(spy.records.map(\.failureReason) == [nil, "pushCovered"])
        #expect(spy.records.map(\.sound) == ["needs_approval", "needs_answer"])

        var tracker = NotificationDeliveryHealthTracker()
        let macFailure = NotificationDeliveryRecord(channel: .local, outcome: .failed, sessionID: "s",
                                                    sound: "needs_approval", failureReason: "permissionDenied",
                                                    timestamp: now)
        let macPrompted = tracker.apply(macFailure, now: now)
        let phonePrompted = tracker.apply(spy.records[0], now: now)
        #expect(macPrompted)
        #expect(!phonePrompted)
        #expect(tracker.latchedFailure?.failureReason == "permissionDenied")
    }

    @Test("the pusher sends nothing for a cue the phone reported, and records why")
    func pusherFiltersReportedCue() async throws {
        let spy = SpyDelivery()
        let receipts = PhoneReceipts(grace: .milliseconds(100), recorder: spy)
        let http = CountingAPNsHTTP()
        let pusher = try pusher(http: http, recorder: spy, receipts: receipts)
        await receipts.record(payload(token: "abc"), now: now)

        let filtered = await pusher.send(title: "t", body: "b", to: "abc", sound: "needs_approval.caf",
                                         now: now, sessionID: "s1", soundCategory: "needs_approval",
                                         waitSince: waitSince, holdForPhone: true)
        #expect(filtered.outcome == .skipped)
        #expect(filtered.failureReason == "phonePosted")
        #expect(await http.calls == 0)
        #expect(spy.records.last?.channel == .apns)
        #expect(spy.records.last?.outcome == .skipped)

        // The same cue for the next wait, unreported: sent as before.
        let sent = await pusher.send(title: "t", body: "b", to: "abc", sound: "needs_approval.caf",
                                     now: now, sessionID: "s1", soundCategory: "needs_approval",
                                     waitSince: waitSince.addingTimeInterval(120), holdForPhone: false)
        #expect(sent.outcome == .accepted)
        #expect(await http.calls == 1)
    }

    @Test("/notified takes a phone's receipt behind the bearer token")
    func notifiedRoute() async throws {
        let receipts = PhoneReceipts(grace: .milliseconds(100))
        let server = VibeBuddyServer(store: SessionStore(), token: "t0k", phoneReceipts: receipts)
        let body = try JSONEncoder().encode(payload())
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/notified", method: .post,
                                     body: ByteBuffer(bytes: body)) { res in
                #expect(res.status == .unauthorized)
            }
            try await client.execute(uri: "/notified", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(bytes: body)) { res in
                #expect(res.status == .ok)
            }
        }
        #expect(await receipts.receipt(for: "s1-needs_approval", since: waitSince,
                                       from: "tok", hold: false) != nil)
    }

    private func pusher(http: CountingAPNsHTTP, recorder: SpyDelivery,
                        receipts: PhoneReceipts) throws -> APNsPusher {
        let key = P256.Signing.PrivateKey()
        let config = APNsConfig(teamID: "TEAM123456", keyID: "KEY7890AB",
                                bundleID: "com.vibebuddy.app", p8PEM: key.pemRepresentation,
                                useSandbox: true)
        return try APNsPusher(config: config, http: http, recorder: recorder, receipts: receipts)
    }
}

/// Answers 200 and counts how often it was asked.
private actor CountingAPNsHTTP: APNsHTTPClient {
    private(set) var calls = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        return (Data(), response)
    }
}
