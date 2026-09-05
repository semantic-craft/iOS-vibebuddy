import Crypto
import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Notification delivery health")
struct NotificationDeliveryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("delivery vocabulary is attempted/scheduled/accepted/failed/filtered and never delivered")
    func vocabularyNeverDelivered() {
        #expect(Set(NotificationDeliveryOutcome.allCases.map(\.rawValue)) == [
            "attempted", "scheduled", "accepted", "failed", "filtered",
        ])
        #expect(!NotificationDeliveryOutcome.allCases.map(\.rawValue).contains("delivered"))
        #expect(NotificationDeliveryHealth.summary(for: .scheduled) == "Last attempt: scheduled")
        #expect(NotificationDeliveryHealth.summary(for: .accepted) == "Last attempt: accepted")
        #expect(NotificationDeliveryHealth.summary(for: .failed) == "Last attempt: failed")
        #expect(!NotificationDeliveryHealth.summary(for: .accepted).contains("delivered"))
        #expect(!NotificationDeliveryHealth.summary(for: .scheduled).contains("delivered"))
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

    private func sendViaStub(status: Int, recorder: SpyDelivery) async throws -> APNsSendResult {
        let key = P256.Signing.PrivateKey()
        let config = APNsConfig(teamID: "TEAM123456", keyID: "KEY7890AB",
                                bundleID: "com.vibebuddy.app", p8PEM: key.pemRepresentation,
                                useSandbox: true)
        let pusher = try APNsPusher(config: config, http: StubAPNsHTTP(status: status),
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
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: nil)!
        return (Data("{}".utf8), response)
    }
}
