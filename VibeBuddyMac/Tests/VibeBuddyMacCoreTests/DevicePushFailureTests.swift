import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// The 2026-09-22 ledger: a phone whose token Apple had accepted on 09-12 and
/// has answered `400 BadDeviceToken` for ever since, so every push wrote one
/// `accepted` for the live phone and one `failed apnsHTTP400` for the stale
/// one, hundreds of times a day. A single 400 on a once-good token still says
/// nothing (it may be this Mac on the wrong environment); a day of them with
/// nothing accepted in between stands the phone down, once, with a reason.
struct DevicePushFailureTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-push-failure-\(UUID().uuidString)")
            .appendingPathComponent("device-registry.json")
    }

    private func sent(_ status: Int?, reason: String? = nil) -> APNsSendResult {
        APNsSendResult(outcome: status.map { (200..<300).contains($0) ? .accepted : .failed } ?? .failed,
                       status: status, failureReason: status.map { "apnsHTTP\($0)" }, reason: reason)
    }

    private func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }

    /// A proven token, refused for a day: counted per send, parked once the
    /// run spans 24 h, one `pruned` row, and the parking survives a restart.
    @Test func onceAcceptedTokenIsParkedAfterADayOfBadDeviceToken() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let spy = SpyDelivery()
        let tokens = DeviceTokens(url: url, recorder: spy)
        await tokens.register(DeviceRegistrationPayload(token: "stale", deviceID: "D61FF41B", name: "iPhone"), now: t0)
        await tokens.applySendResult(sent(200), token: "stale", now: t0)

        // Three refusals inside a day: counted, still pushed to.
        for hour in [1.0, 2.0, 23.0] {
            #expect(await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "stale", now: hours(hour)) == false)
        }
        let failing = try #require(await tokens.pairedPhones().first?.pushFailure)
        #expect(failing.count == 3)
        #expect(failing.firstAt == hours(1))
        #expect(failing.lastAt == hours(23))
        #expect(failing.parkedAt == nil)
        #expect(await tokens.all() == ["stale"])
        #expect(spy.records.isEmpty)

        // The refusal that crosses 24 h since the first parks the phone.
        #expect(await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "stale", now: hours(25.5)))
        let entry = try #require(await tokens.pairedPhones().first)
        #expect(entry.pushStanding == .parked(DevicePushFailure(
            reason: "BadDeviceToken", status: 400, firstAt: hours(1), lastAt: hours(25.5), count: 4,
            parkedAt: hours(25.5))))
        #expect(entry.device.token == "stale")          // kept for the list, not sent to
        #expect(await tokens.all().isEmpty)
        #expect(await tokens.devices().isEmpty)
        #expect(await tokens.summary() == DeviceRegistrySummary(count: 0, lastRegisteredAt: nil, parkedCount: 1))

        // One row, naming the phone and Apple's word — not a `failed` per push.
        #expect(spy.records.count == 1)
        let pruned = try #require(spy.records.first)
        #expect(pruned.channel == .apns)
        #expect(pruned.outcome == .pruned)
        #expect(pruned.apnsReason == "BadDeviceToken")
        #expect(pruned.failureReason == "BadDeviceToken")
        #expect(pruned.deviceID == "D61FF41B")
        #expect(pruned.timestamp == hours(25.5))

        let restarted = DeviceTokens(url: url, recorder: spy)
        #expect(await restarted.all().isEmpty)
        #expect(await restarted.pairedPhones().first?.isParked == true)
    }

    /// Nothing accepted in between is part of the rule: one accept ends the run.
    @Test func anAcceptInTheMiddleEndsTheRun() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tokens = DeviceTokens(url: url)
        await tokens.register(DeviceRegistrationPayload(token: "real", deviceID: "hermes"), now: t0)
        await tokens.applySendResult(sent(200), token: "real", now: t0)
        await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "real", now: hours(1))
        await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "real", now: hours(2))
        await tokens.applySendResult(sent(200), token: "real", now: hours(3))
        #expect(await tokens.pairedPhones().first?.pushFailure == nil)
        #expect(await tokens.pairedPhones().first?.lastAcceptedAt == hours(3))

        // A refusal a day later starts over; it is not the fourth of a run.
        #expect(await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "real", now: hours(30)) == false)
        #expect(await tokens.pairedPhones().first?.pushFailure?.count == 1)
        #expect(await tokens.all() == ["real"])
    }

    /// The count alone is not enough: a burst of refusals in one afternoon
    /// (the Mac pointed at the wrong environment) never parks a proven token.
    @Test func aBurstWithinADayDoesNotPark() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tokens = DeviceTokens(url: url)
        await tokens.register(DeviceRegistrationPayload(token: "real", deviceID: "hermes"), now: t0)
        await tokens.applySendResult(sent(200), token: "real", now: t0)
        for minute in stride(from: 1.0, through: 120.0, by: 1.0) {
            #expect(await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "real",
                                                 now: t0.addingTimeInterval(minute * 60)) == false)
        }
        #expect(await tokens.pairedPhones().first?.pushFailure?.count == 120)
        #expect(await tokens.all() == ["real"])
    }

    /// The phone reporting a token again revives it. The run is kept, so if
    /// Apple still refuses, the next send parks it again: one `pruned` row per
    /// reconnect, never a day of `failed` rows. A new token has no history.
    @Test func parkedPhoneRevivesWhenItReportsAToken() async throws {
        let spy = SpyDelivery()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tokens = DeviceTokens(url: url, recorder: spy)
        await tokens.register(DeviceRegistrationPayload(token: "stale", deviceID: "hermes", name: "Hermes"), now: t0)
        await tokens.applySendResult(sent(200), token: "stale", now: t0)
        for hour in [1.0, 2.0, 26.0] {
            await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "stale", now: hours(hour))
        }
        #expect(await tokens.all().isEmpty)
        #expect(spy.records.map(\.outcome) == [.pruned])

        // A report without a token (a reconnect before the APNs callback)
        // changes nothing about push.
        await tokens.register(DeviceRegistrationPayload(deviceID: "hermes", name: "Hermes"), now: hours(27))
        #expect(await tokens.all().isEmpty)
        #expect(await tokens.pairedPhones().first?.isParked == true)

        // The same token, reported again: pushed to once more.
        await tokens.register(DeviceRegistrationPayload(token: "stale", deviceID: "hermes"), now: hours(28))
        #expect(await tokens.all() == ["stale"])
        let revived = try #require(await tokens.pairedPhones().first)
        #expect(revived.pushFailure?.parkedAt == nil)
        #expect(revived.pushFailure?.count == 3)         // the run is remembered
        #expect(revived.lastAcceptedAt == t0)            // and so is its standing
        #expect(revived.device.name == "Hermes")
        #expect(revived.pushStanding == .failing(try #require(revived.pushFailure)))

        // Apple still refuses: parked on the spot, one more row.
        #expect(await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "stale", now: hours(29)))
        #expect(await tokens.all().isEmpty)
        #expect(spy.records.map(\.outcome) == [.pruned, .pruned])

        // Apple takes it after all (the Mac was fixed): the run is over.
        await tokens.register(DeviceRegistrationPayload(token: "stale", deviceID: "hermes"), now: hours(30))
        await tokens.applySendResult(sent(200), token: "stale", now: hours(31))
        #expect(await tokens.pairedPhones().first?.pushStanding == .registered)

        // A rotated token under the same identity starts from nothing.
        await tokens.register(DeviceRegistrationPayload(token: "fresh", deviceID: "hermes"), now: hours(32))
        let fresh = try #require(await tokens.pairedPhones().first)
        #expect(fresh.pushFailure == nil)
        #expect(fresh.lastAcceptedAt == nil)
        #expect(await tokens.all() == ["fresh"])
        #expect(await tokens.pairedPhones().count == 1)
    }

    /// 410 is Apple's definitive answer: parked at once, one row, and the
    /// phone keeps its identity, pairing and switches for the list.
    @Test func unregisteredParksAtOnceWithOneLedgerRow() async throws {
        let spy = SpyDelivery()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tokens = DeviceTokens(url: url, recorder: spy)
        await tokens.acceptNewRegistrations(now: t0)
        #expect(await tokens.registerFromPhone(DeviceRegistrationPayload(token: "gone", deviceID: "old-phone", name: "Old", playSound: false), now: t0))
        await tokens.applySendResult(sent(200), token: "gone", now: t0)

        #expect(await tokens.applySendResult(sent(410, reason: "Unregistered"), token: "gone", now: hours(1)))
        #expect(await tokens.all().isEmpty)
        let entry = try #require(await tokens.pairedPhones().first)
        #expect(entry.pairedAt == t0)
        #expect(entry.device.playSound == false)
        #expect(entry.pushStanding == .parked(DevicePushFailure(
            reason: "Unregistered", status: 410, firstAt: hours(1), lastAt: hours(1), count: 1, parkedAt: hours(1))))
        #expect(spy.records.count == 1)
        #expect(spy.records.first?.outcome == .pruned)
        #expect(spy.records.first?.apnsReason == "Unregistered")
        #expect(spy.records.first?.deviceID == "old-phone")
        #expect(await tokens.isConfirmed(deviceID: "old-phone"))
    }

    /// Sends that were already in flight when the phone was parked, and a
    /// different refusal for the same dead token, land on a parked phone.
    /// Neither is a new parking: no second `pruned` row, and a 400 after a 410
    /// does not quietly put the phone back on the push list.
    @Test func refusalsAfterParkingChangeNothing() async throws {
        let spy = SpyDelivery()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tokens = DeviceTokens(url: url, recorder: spy)
        await tokens.register(DeviceRegistrationPayload(token: "stale", deviceID: "hermes"), now: t0)
        await tokens.applySendResult(sent(200), token: "stale", now: t0)
        for hour in [1.0, 2.0, 26.0] {
            await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "stale", now: hours(hour))
        }
        let parked = try #require(await tokens.pairedPhones().first?.pushFailure)
        #expect(parked.isParked)

        // Stragglers from the same batch, then Apple's other word for it.
        #expect(await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "stale", now: hours(26.01)) == false)
        #expect(await tokens.applySendResult(sent(410, reason: "Unregistered"), token: "stale", now: hours(26.02)) == false)
        #expect(await tokens.pairedPhones().first?.pushFailure == parked)
        #expect(await tokens.all().isEmpty)
        #expect(spy.records.map(\.outcome) == [.pruned])

        // The other order: a 410 parks, and a later BadDeviceToken must not
        // start a fresh, un-parked run on a token that is still "ever accepted".
        let goneURL = tempURL()
        defer { try? FileManager.default.removeItem(at: goneURL.deletingLastPathComponent()) }
        let gone = DeviceTokens(url: goneURL, recorder: spy)
        await gone.register(DeviceRegistrationPayload(token: "dead", deviceID: "old"), now: t0)
        await gone.applySendResult(sent(200), token: "dead", now: t0)
        #expect(await gone.applySendResult(sent(410, reason: "Unregistered"), token: "dead", now: hours(1)))
        #expect(await gone.applySendResult(sent(400, reason: "BadDeviceToken"), token: "dead", now: hours(1.01)) == false)
        #expect(await gone.pairedPhones().first?.isParked == true)
        #expect(await gone.pairedPhones().first?.pushFailure?.reason == "Unregistered")
        #expect(await gone.all().isEmpty)
    }

    /// A token nobody identified is stood down under its token prefix, so the
    /// row still says which one.
    @Test func junkTokenIsPrunedUnderItsPrefix() async throws {
        let spy = SpyDelivery()
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tokens = DeviceTokens(url: url, recorder: spy)
        await tokens.register(DeviceRegistrationPayload(token: "deadbeefcafe"), now: t0)
        #expect(await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "deadbeefcafe", now: t0))
        #expect(spy.records.first?.deviceID == "deadbeef…")
        #expect(await tokens.summary().parkedCount == 1)
    }

    /// Housekeeping, not a send: a `pruned` row neither clears a standing
    /// failure nor latches one.
    @Test func prunedRowNeverMovesHealth() {
        var tracker = NotificationDeliveryHealthTracker(debounce: 60)
        let failed = NotificationDeliveryRecord(channel: .apns, outcome: .failed, sessionID: "s",
                                                sound: "agent_done", failureReason: "apnsHTTP400",
                                                timestamp: t0, apnsReason: "BadDeviceToken")
        let latched = tracker.apply(failed, now: t0)
        #expect(latched)
        let pruned = NotificationDeliveryRecord(channel: .apns, outcome: .pruned, sessionID: nil, sound: nil,
                                                failureReason: "BadDeviceToken", timestamp: hours(1),
                                                apnsReason: "BadDeviceToken", deviceID: "D61FF41B")
        let afterPruned = tracker.apply(pruned, now: hours(1))
        #expect(afterPruned == false)
        #expect(tracker.latchedFailure == failed)

        var fresh = NotificationDeliveryHealthTracker(debounce: 60)
        let freshLatched = fresh.apply(pruned, now: hours(1))
        #expect(freshLatched == false)
        #expect(fresh.latchedFailure == nil)
    }

    /// Rows and registry entries written before the new fields existed decode.
    @Test func olderFilesDecodeWithoutTheNewFields() throws {
        let row = #"{"channel":"apns","failureReason":"apnsHTTP400","id":"7AA7F06D-B172-444C-AAA6-3A6B1B14F97B","outcome":"failed","sessionID":"s","sound":"agent_done","timestamp":811710577.6}"#
        let record = try JSONDecoder().decode(NotificationDeliveryRecord.self, from: Data(row.utf8))
        #expect(record.apnsReason == nil)
        #expect(record.deviceID == nil)

        let entry = #"{"device":{"deviceID":"D61FF41B","token":"56e4"},"lastAcceptedAt":810891931.9,"registeredAt":811126132.1}"#
        let decoded = try JSONDecoder().decode(DeviceRegistryEntry.self, from: Data(entry.utf8))
        #expect(decoded.pushFailure == nil)
        #expect(decoded.pushStanding == .registered)
        #expect(decoded.isPushable)
    }
}
