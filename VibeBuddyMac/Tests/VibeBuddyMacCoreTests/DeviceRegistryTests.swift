import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// The registry exists so a Mac restart does not silently stop every push to a
/// closed iPhone. These cover the parts that are pure: survive a restart, merge
/// partial reports, evict only on Apple's 410, and never break the app.
struct DeviceRegistryTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-device-registry-\(UUID().uuidString)")
            .appendingPathComponent("device-registry.json")
    }

    @Test func registrationSurvivesARestart() async throws {
        let url = tempURL()
        let first = DeviceTokens(url: url)
        await first.register(DeviceRegistrationPayload(
            token: "abc", name: "Hermes", model: "iPhone",
            systemVersion: "iOS 26.0", playSound: true, quietMode: false))

        // A new process reading the same file — what used to come up empty.
        let restarted = DeviceTokens(url: url)
        #expect(await restarted.all() == ["abc"])
        #expect(await restarted.devices().first?.name == "Hermes")
        #expect(await restarted.devices().first?.playSound == true)
        #expect(await restarted.summary().count == 1)
    }

    @Test func fileIsOwnerOnly() async throws {
        let url = tempURL()
        let tokens = DeviceTokens(url: url)
        await tokens.register(DeviceRegistrationPayload(token: "abc"))

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attrs[.posixPermissions] as? NSNumber == 0o600)
    }

    @Test func partialReportKeepsPreviouslyUploadedPrefs() async throws {
        let url = tempURL()
        let tokens = DeviceTokens(url: url)
        var categories = NotificationCategoryPrefs.default
        categories.set(.agentDone, enabled: false)
        await tokens.register(DeviceRegistrationPayload(
            token: "abc", name: "Hermes", playSound: false, categories: categories))

        // A reconnect before the APNs callback carries no switches; the ones the
        // phone uploaded last time must not be reset to the defaults.
        await tokens.register(DeviceRegistrationPayload(token: "abc", name: "Hermes Pro"))

        let device = try #require(await tokens.devices().first)
        #expect(device.name == "Hermes Pro")
        #expect(device.playSound == false)
        #expect(device.categories?.isEnabled(.agentDone) == false)
        #expect(await tokens.devices().count == 1)
    }

    @Test func tokenlessPayloadIsNotRegistered() async throws {
        let tokens = DeviceTokens(url: tempURL())
        await tokens.register(DeviceRegistrationPayload(name: "Hermes"))
        #expect(await tokens.all().isEmpty)
    }

    private func sent(_ status: Int?, reason: String? = nil) -> APNsSendResult {
        APNsSendResult(outcome: status.map { (200..<300).contains($0) ? .accepted : .failed } ?? .failed,
                       status: status, failureReason: status.map { "apnsHTTP\($0)" }, reason: reason)
    }

    @Test func unregisteredResponseEvictsTheToken() async throws {
        let url = tempURL()
        let tokens = DeviceTokens(url: url)
        await tokens.register(DeviceRegistrationPayload(token: "abc"))
        await tokens.applySendResult(sent(200), token: "abc")   // even a proven token

        #expect(await tokens.applySendResult(sent(410), token: "abc"))
        #expect(await tokens.all().isEmpty)
        #expect(await DeviceTokens(url: url).all().isEmpty)   // eviction persisted
    }

    /// A token Apple has never once accepted and now calls bad is junk — a typo,
    /// a test fixture, or another process posting a fake registration.
    @Test func badTokenThatWasNeverAcceptedIsEvicted() async throws {
        let url = tempURL()
        let tokens = DeviceTokens(url: url)
        await tokens.register(DeviceRegistrationPayload(token: "junk"))

        #expect(await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "junk"))
        #expect(await tokens.all().isEmpty)
        #expect(await DeviceTokens(url: url).all().isEmpty)
    }

    /// APNs answers 400 for request faults too — a bad topic, a bad collapse id,
    /// an empty payload. None of those say anything about the phone, so a token
    /// that has never been accepted still survives them.
    @Test func request400sNeverEvict() async throws {
        let url = tempURL()
        let tokens = DeviceTokens(url: url)
        await tokens.register(DeviceRegistrationPayload(token: "fresh"))
        for reason in ["BadTopic", "BadCollapseId", "PayloadEmpty", "TopicDisallowed"] {
            #expect(await tokens.applySendResult(sent(400, reason: reason), token: "fresh") == false, Comment(rawValue: reason))
        }
        #expect(await tokens.applySendResult(sent(400), token: "fresh") == false)   // no reason at all
        #expect(await tokens.all() == ["fresh"])
    }

    /// The phone keeps its bearer token and re-reports on every reconnect, so
    /// "forget" must outlast the next `POST /device` — until the user shows the
    /// pairing QR again, which is the explicit intent to pair.
    @Test func forgetBlocksReRegistrationUntilPairingIsShownAgain() async throws {
        let url = tempURL()
        let tokens = DeviceTokens(url: url)
        await tokens.register(DeviceRegistrationPayload(token: "abc", name: "Hermes"))
        await tokens.forgetAll()
        #expect(await tokens.all().isEmpty)

        await tokens.register(DeviceRegistrationPayload(token: "abc", name: "Hermes"))   // the reconnect
        #expect(await tokens.all().isEmpty)
        // The block survives a restart.
        let restarted = DeviceTokens(url: url)
        await restarted.register(DeviceRegistrationPayload(token: "abc"))
        #expect(await restarted.all().isEmpty)
        // A different phone is not affected.
        await restarted.register(DeviceRegistrationPayload(token: "xyz"))
        #expect(await restarted.all() == ["xyz"])
        // Showing the QR lifts the block.
        await restarted.acceptNewRegistrations()
        await restarted.register(DeviceRegistrationPayload(token: "abc"))
        #expect(Set(await restarted.all()) == ["abc", "xyz"])
    }

    /// The same 400 on a token Apple *has* accepted points at this Mac being on
    /// the wrong APNs environment, not at the phone. Dropping every device over
    /// that would recreate the silent failure the registry exists to prevent.
    @Test func badTokenThatWasAcceptedBeforeIsKept() async throws {
        let url = tempURL()
        let tokens = DeviceTokens(url: url)
        await tokens.register(DeviceRegistrationPayload(token: "real"))
        await tokens.applySendResult(sent(200), token: "real")

        #expect(await tokens.applySendResult(sent(400, reason: "BadDeviceToken"), token: "real") == false)
        #expect(await tokens.all() == ["real"])
        // …and the standing survives a restart, so the next 400 does not evict either.
        let restarted = DeviceTokens(url: url)
        #expect(await restarted.applySendResult(sent(400, reason: "BadDeviceToken"), token: "real") == false)
        #expect(await restarted.all() == ["real"])
    }

    @Test func transientFailuresNeverEvict() async throws {
        let tokens = DeviceTokens(url: tempURL())
        await tokens.register(DeviceRegistrationPayload(token: "abc"))

        // Offline says nothing; throttling and server errors are about Apple.
        for status: Int? in [403, 429, 500, 503, nil] {
            #expect(await tokens.applySendResult(sent(status), token: "abc") == false)
        }
        #expect(await tokens.all() == ["abc"])
    }

    @Test func reconnectingDoesNotResetAProvenToken() async throws {
        let tokens = DeviceTokens(url: tempURL())
        await tokens.register(DeviceRegistrationPayload(token: "real"))
        await tokens.applySendResult(sent(200), token: "real")

        // A phone that reconnects keeps whatever standing it had with Apple.
        await tokens.register(DeviceRegistrationPayload(token: "real", name: "Hermes"))
        #expect(await tokens.applySendResult(sent(400), token: "real") == false)
        #expect(await tokens.all() == ["real"])
    }

    @Test func forgettingThePhoneClearsTheFile() async throws {
        let url = tempURL()
        let tokens = DeviceTokens(url: url)
        await tokens.register(DeviceRegistrationPayload(token: "abc"))
        await tokens.removeAll()
        #expect(await DeviceTokens(url: url).all().isEmpty)
    }

    @Test func corruptFileStartsEmptyInsteadOfThrowing() async throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let tokens = DeviceTokens(url: url)
        #expect(await tokens.all().isEmpty)
        await tokens.register(DeviceRegistrationPayload(token: "abc"))
        #expect(await tokens.all() == ["abc"])
    }

    @Test func rotatedTokensAreBoundedByTheCap() async throws {
        var registry = DeviceRegistry(url: nil, capacity: 2)
        let start = Date()
        for (i, token) in ["a", "b", "c"].enumerated() {
            registry.upsert(DeviceRegistrationPayload(token: token),
                            now: start.addingTimeInterval(Double(i)))
        }
        #expect(registry.devices.compactMap(\.token) == ["b", "c"])
    }

    @Test func summaryReportsTheNewestRegistration() async throws {
        var registry = DeviceRegistry(url: nil)
        #expect(registry.summary == DeviceRegistrySummary(count: 0, lastRegisteredAt: nil))

        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        registry.upsert(DeviceRegistrationPayload(token: "a"), now: old)
        registry.upsert(DeviceRegistrationPayload(token: "b"), now: new)
        #expect(registry.summary == DeviceRegistrySummary(count: 2, lastRegisteredAt: new))
    }
}
