import Testing
import Foundation
@testable import VibeBuddyKit

/// Who a cue is sent to, and — when nobody — the reason recorded in its place.
/// The reason is the point: a push that is never attempted used to leave nothing
/// behind, so "the phone did not want it", "no phone was listening" and "no cue
/// was earned" all looked the same in the delivery log, which is to say invisible.
@Suite("PushFanout")
struct PushFanoutTests {

    private func alert(_ sound: NotificationSound = .agentDone,
                       delivery: DeliveryLevel = .bannerSound) -> SoundAlert {
        SoundAlert(session: AgentSession(id: "a", agent: .claudeCode, project: "p", status: .done,
                                         statusSince: Date(), updatedAt: Date()),
                   sound: sound, delivery: delivery)
    }

    private func device(_ token: String? = "tok",
                        quiet: Bool? = nil,
                        categories: NotificationCategoryPrefs? = nil) -> DeviceRegistrationPayload {
        DeviceRegistrationPayload(token: token, quietMode: quiet, categories: categories)
    }

    @Test("a registered device that wants the cue is a recipient, at the Mac's level")
    func sends() {
        let plan = PushFanout.plan(alert(), devices: [device()], apnsConfigured: true)
        #expect(plan.recipients.map(\.level) == [.bannerSound])
        #expect(plan.skip == nil)
    }

    @Test("no APNs key: nothing is sent and the log says why")
    func noKey() {
        let plan = PushFanout.plan(alert(), devices: [device()], apnsConfigured: false)
        #expect(plan.recipients.isEmpty)
        #expect(plan.skip == .apnsNotConfigured)
    }

    @Test("a list-only cue stays on the Mac by design — and says so")
    func notLoudEnough() {
        let plan = PushFanout.plan(alert(delivery: .list), devices: [device()], apnsConfigured: true)
        #expect(plan.recipients.isEmpty)
        #expect(plan.skip == .notLoudEnough)
    }

    @Test("an empty registry is a reason, not silence — this is a Mac that restarted")
    func noDevice() {
        #expect(PushFanout.plan(alert(), devices: [], apnsConfigured: true).skip == .noRegisteredDevice)
    }

    @Test("a device that registered without a push token is not a device to send to")
    func tokenlessDevice() {
        let plan = PushFanout.plan(alert(), devices: [device(nil), device("")], apnsConfigured: true)
        #expect(plan.skip == .noRegisteredDevice)
    }

    @Test("a switched-off category drops the cue and says so")
    func categoryOff() {
        let off = NotificationCategoryPrefs(enabled: [.needsApproval])
        let plan = PushFanout.plan(alert(), devices: [device(categories: off)], apnsConfigured: true)
        #expect(plan.recipients.isEmpty)
        #expect(plan.skip == .categoryOff)
    }

    @Test("a phone in Quiet mode drops a completion — the muted column is a drop")
    func quietDropsCompletion() {
        let plan = PushFanout.plan(alert(), devices: [device(quiet: true)], apnsConfigured: true)
        #expect(plan.recipients.isEmpty)
        #expect(plan.skip == .deviceQuietMode)
    }

    @Test("a phone in Quiet mode still takes an approval, one level quieter")
    func quietKeepsApproval() {
        let plan = PushFanout.plan(alert(.needsApproval), devices: [device(quiet: true)],
                                   apnsConfigured: true)
        #expect(plan.recipients.map(\.level) == [.banner])   // muted column: banner, no sound
        #expect(plan.skip == nil)
    }

    @Test("a device is never louder than the Mac decided")
    func neverLouderThanTheMac() {
        let plan = PushFanout.plan(alert(.needsApproval, delivery: .banner),
                                   devices: [device()], apnsConfigured: true)
        #expect(plan.recipients.map(\.level) == [.banner])
    }

    @Test("a phone that never uploaded switches keeps the default set")
    func defaultCategories() {
        #expect(PushFanout.plan(alert(), devices: [device(categories: nil)],
                                apnsConfigured: true).recipients.count == 1)
    }

    @Test("one phone wanting it is enough — no reason is recorded when anyone was sent to")
    func partialFanout() {
        let plan = PushFanout.plan(
            alert(),
            devices: [device("quiet-one", quiet: true), device("listening")],
            apnsConfigured: true)
        #expect(plan.recipients.map(\.device.token) == ["listening"])
        #expect(plan.skip == nil)
    }
}
