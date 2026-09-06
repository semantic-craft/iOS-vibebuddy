import Crypto
import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Notification delivery health")
struct NotificationDeliveryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("delivery vocabulary is attempted/scheduled/accepted/failed/skipped, never delivered")
    func vocabularyNeverDelivered() {
        #expect(Set(NotificationDeliveryOutcome.allCases.map(\.rawValue)) == [
            "attempted", "scheduled", "accepted", "failed", "skipped",
        ])
        #expect(!NotificationDeliveryOutcome.allCases.map(\.rawValue).contains("delivered"))
        #expect(NotificationDeliveryHealth.summary(for: .scheduled) == "Last attempt: scheduled")
        #expect(NotificationDeliveryHealth.summary(for: .accepted) == "Last attempt: accepted")
        #expect(NotificationDeliveryHealth.summary(for: .failed) == "Last attempt: failed")
        #expect(NotificationDeliveryHealth.summary(for: .skipped) == "Last attempt: skipped")
        #expect(!NotificationDeliveryHealth.summary(for: .accepted).contains("delivered"))
        #expect(!NotificationDeliveryHealth.summary(for: .scheduled).contains("delivered"))
    }

    @Test("a standing failure survives a restart even when skips came after it")
    func latchedFailureSurvivesReload() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-reload-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = NotificationDeliveryRecorder(url: url, now: now)
        await first.record(NotificationDeliveryRecord(
            channel: .apns, outcome: .failed, sessionID: "a", sound: "agent_done",
            failureReason: "apnsHTTP400", timestamp: now))
        // …then the ordinary traffic that follows a failure: cues nobody was sent
        // to. Seeding a fresh tracker from the last record alone would read one of
        // these and forget the failure entirely.
        for i in 1...3 {
            await first.record(NotificationDeliveryRecord(
                channel: .apns, outcome: .skipped, sessionID: "b\(i)", sound: "agent_done",
                failureReason: CueSkipReason.noRegisteredDevice.rawValue,
                timestamp: now.addingTimeInterval(Double(i))))
        }

        let reloaded = NotificationDeliveryRecorder(url: url, now: now.addingTimeInterval(10))
        let health = await reloaded.health()
        #expect(health.latchedFailure?.failureReason == "apnsHTTP400")
        #expect(health.lastAttempt?.outcome == .skipped)

        // An accepted send still clears it, before and after a reload.
        await reloaded.record(NotificationDeliveryRecord(
            channel: .apns, outcome: .accepted, sessionID: "c", sound: "agent_done",
            failureReason: nil, timestamp: now.addingTimeInterval(11)))
        let cleared = NotificationDeliveryRecorder(url: url, now: now.addingTimeInterval(12))
        #expect(await cleared.health().latchedFailure == nil)
    }

    @Test("a skipped push is not a failure — it never latches a health diagnostic")
    func skippedIsNotAFailure() {
        var tracker = NotificationDeliveryHealthTracker()
        let skip = NotificationDeliveryRecord(
            channel: .apns, outcome: .skipped, sessionID: "a", sound: "agent_done",
            failureReason: CueSkipReason.noRegisteredDevice.rawValue, timestamp: now)
        let surfaced = tracker.apply(skip, now: now)
        #expect(surfaced == false)
        #expect(tracker.latchedFailure == nil)
        #expect(tracker.lastAttempt?.failureReason == "noRegisteredDevice")

        // …and it does not clear a real failure that is still standing, either.
        var latched = NotificationDeliveryHealthTracker()
        let failure = NotificationDeliveryRecord(
            channel: .apns, outcome: .failed, sessionID: "a", sound: "agent_done",
            failureReason: "apnsHTTP400", timestamp: now)
        let firstFailure = latched.apply(failure, now: now)
        #expect(firstFailure)
        let afterSkip = latched.apply(skip, now: now.addingTimeInterval(1))
        #expect(afterSkip == false)
        #expect(latched.latchedFailure?.failureReason == "apnsHTTP400")
    }

    @Test("authorized local schedule is scheduled; permission off is failed")
    func scheduledVersusPermissionFailure() {
        let scheduled = LocalNotificationDelivery.classify(authorized: true, scheduleError: nil)
        #expect(scheduled.outcome == .scheduled)
        #expect(scheduled.failureReason == nil)

        let denied = LocalNotificationDelivery.classify(authorized: false, scheduleError: nil)
        #expect(denied.outcome == .failed)
        #expect(denied.failureReason == "permissionDenied")
        #expect(denied.outcome != .scheduled)
        #expect(denied.outcome.rawValue != "delivered")

        let scheduleFailed = LocalNotificationDelivery.classify(
            authorized: true, scheduleError: TestError.boom)
        #expect(scheduleFailed.outcome == .failed)
        #expect(scheduleFailed.failureReason == "scheduleFailed")
    }

    @Test("APNs 2xx is accepted; anything else is failed; never delivered")
    func apnsTwoXXIsAcceptedOtherwiseFailed() {
        let ok = APNsDelivery.classify(status: 200, error: nil)
        #expect(ok.outcome == .accepted)
        #expect(ok.failureReason == nil)
        #expect(APNsDelivery.classify(status: 201, error: nil).outcome == .accepted)
        #expect(APNsDelivery.classify(status: 299, error: nil).outcome == .accepted)

        let rejected = APNsDelivery.classify(status: 400, error: nil)
        #expect(rejected.outcome == .failed)
        #expect(rejected.failureReason == "apnsHTTP400")
        #expect(APNsDelivery.classify(status: 403, error: nil).failureReason == "apnsHTTP403")
        #expect(APNsDelivery.classify(status: 500, error: nil).outcome == .failed)

        let unreachable = APNsDelivery.classify(status: nil, error: TestError.boom)
        #expect(unreachable.outcome == .failed)
        #expect(unreachable.failureReason == "apnsUnreachable")

        #expect(ok.outcome.rawValue != "delivered")
        #expect(rejected.outcome.rawValue != "delivered")
    }

    @Test("APNs pusher records accepted on 2xx and failed otherwise")
    func pusherRecordsHonestHTTPOutcome() async throws {
        let spy = SpyDelivery()
        let accepted = try await sendViaStub(status: 200, recorder: spy)
        #expect(accepted.outcome == .accepted)
        #expect(spy.records.last?.outcome == .accepted)
        #expect(spy.records.last?.channel == .apns)
        #expect(spy.records.last?.sessionID == "sess-1")
        #expect(spy.records.last?.sound == "needs_approval")
        #expect(spy.records.last?.outcome.rawValue != "delivered")

        let failed = try await sendViaStub(status: 400, recorder: spy)
        #expect(failed.outcome == .failed)
        #expect(spy.records.last?.outcome == .failed)
        #expect(spy.records.last?.failureReason == "apnsHTTP400")
        #expect(spy.records.last?.outcome.rawValue != "delivered")
    }

    @Test("same failure reason is latched once; recovery clears health")
    func debounceAndRecoveryClear() {
        var tracker = NotificationDeliveryHealthTracker(debounce: 60)
        let fail = record(.failed, reason: "permissionDenied", at: now)
        let firstPrompt = tracker.apply(fail, now: now)
        #expect(firstPrompt)
        #expect(tracker.latchedFailure?.failureReason == "permissionDenied")
        let suppressed = tracker.apply(fail, now: now.addingTimeInterval(10))
        #expect(!suppressed)
        #expect(tracker.latchedFailure?.id == fail.id)

        let other = record(.failed, reason: "apnsHTTP400", at: now.addingTimeInterval(11))
        let otherPrompt = tracker.apply(other, now: now.addingTimeInterval(11))
        #expect(otherPrompt)
        #expect(tracker.latchedFailure?.failureReason == "apnsHTTP400")

        let recovered = record(.scheduled, at: now.addingTimeInterval(20))
        let recoveredPrompt = tracker.apply(recovered, now: now.addingTimeInterval(20))
        #expect(!recoveredPrompt)
        #expect(tracker.latchedFailure == nil)
        #expect(tracker.lastAttempt?.outcome == .scheduled)
    }

    @Test("delivery log is bounded to 250 entries and 7 days")
    func boundedLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-delivery-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("delivery.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var log = NotificationDeliveryLog(url: url, capacity: 2, retention: 60, now: now)
        log.append(record(.failed, reason: "permissionDenied", at: now.addingTimeInterval(-61)), now: now)
        log.append(record(.scheduled, at: now), now: now)
        log.append(record(.accepted, at: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
        log.append(record(.failed, reason: "apnsHTTP500", at: now.addingTimeInterval(2)),
                   now: now.addingTimeInterval(2))

        let reopened = NotificationDeliveryLog(url: url, capacity: 2, retention: 60,
                                               now: now.addingTimeInterval(2))
        #expect(reopened.recent(limit: 10).map(\.outcome) == [.failed, .accepted])
        #expect(!reopened.recent(limit: 10).contains(where: { $0.outcome.rawValue == "delivered" }))
    }

    @Test("the APNs error body's reason rides on the send result; a success has none")
    func sendResultCarriesApplesReason() async throws {
        let spy = SpyDelivery()
        let bad = try await sendViaStub(status: 400, body: #"{"reason":"BadDeviceToken"}"#, recorder: spy)
        #expect(bad.reason == "BadDeviceToken")
        #expect(APNsDelivery.tokenOutcome(status: bad.status, reason: bad.reason, everAccepted: false) == .neverValid)
        let topic = try await sendViaStub(status: 400, body: #"{"reason":"BadTopic"}"#, recorder: spy)
        #expect(APNsDelivery.tokenOutcome(status: topic.status, reason: topic.reason, everAccepted: false) == .keep)
        let ok = try await sendViaStub(status: 200, body: "", recorder: spy)
        #expect(ok.reason == nil)
    }

    @Test("send preserves action category separately from the delivery ledger cue")
    func sendPreservesActionMetadata() async throws {
        let key = P256.Signing.PrivateKey()
        let config = APNsConfig(teamID: "TEAM123456", keyID: "KEY7890AB",
                                bundleID: "com.vibebuddy.app", p8PEM: key.pemRepresentation,
                                useSandbox: true)
        let http = ActionPayloadHTTP()
        let recorder = SpyDelivery()
        let pusher = try APNsPusher(config: config, http: http, recorder: recorder)
        _ = await pusher.send(title: "t", body: "b", to: "fixture", sound: "",
                              sessionID: "s", soundCategory: "needs_approval",
                              category: "approval", timeSensitive: true, approvalId: "p")
        let request = try #require(await http.request)
        let data = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aps = try #require(payload["aps"] as? [String: Any])
        #expect(aps["category"] as? String == "approval")
        #expect(aps["interruption-level"] as? String == "time-sensitive")
        #expect(payload["approvalId"] as? String == "p")
        #expect(recorder.records.allSatisfy { $0.sound == "needs_approval" })
    }

    private func sendViaStub(status: Int, body: String = "{}", recorder: SpyDelivery) async throws -> APNsSendResult {
        let key = P256.Signing.PrivateKey()
        let config = APNsConfig(teamID: "TEAM123456", keyID: "KEY7890AB",
                                bundleID: "com.vibebuddy.app", p8PEM: key.pemRepresentation,
                                useSandbox: true)
        let pusher = try APNsPusher(config: config, http: StubAPNsHTTP(status: status, body: body),
                                    recorder: recorder)
        return await pusher.send(title: "t", body: "b", to: "abc", sound: "needs_approval.caf",
                                 now: now, sessionID: "sess-1", soundCategory: "needs_approval")
    }

    private func record(_ outcome: NotificationDeliveryOutcome, reason: String? = nil,
                        at timestamp: Date) -> NotificationDeliveryRecord {
        NotificationDeliveryRecord(
            channel: .local, outcome: outcome, sessionID: "sess",
            sound: "needs_approval", failureReason: reason, timestamp: timestamp)
    }
}

private enum TestError: Error { case boom }

final class SpyDelivery: NotificationDeliveryRecording, @unchecked Sendable {
    private(set) var records: [NotificationDeliveryRecord] = []
    func record(_ record: NotificationDeliveryRecord) async { records.append(record) }
}

private struct StubAPNsHTTP: APNsHTTPClient, Sendable {
    let status: Int
    var body: String = "{}"
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private actor ActionPayloadHTTP: APNsHTTPClient {
    private(set) var request: URLRequest?
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!)
    }
}
