import XCTest
@testable import VibeBuddyKit

/// The two rules a CloudKit cue depends on that no device test can see
/// directly: the handlers find the wait through the rebuilt userInfo, and a
/// phone that switched a category off never gets a banner or a sound from a
/// record the whole account receives.
final class CloudKitCueTests: XCTestCase {
    func testUserInfoRebuildsTheShippingKeysByKind() {
        let fields: [String: Any] = ["sid": "s1", "rid": "r1", "nid": "s1-needs_approval"]
        XCTAssertEqual(CloudKitCue.userInfo(kind: .approval, fields: fields),
                       ["sessionId": "s1", "approvalId": "r1"])
        XCTAssertEqual(CloudKitCue.userInfo(kind: .question, fields: fields),
                       ["sessionId": "s1", "questionId": "r1"])
        XCTAssertEqual(CloudKitCue.userInfo(kind: .other, fields: fields), ["sessionId": "s1"])
        XCTAssertEqual(CloudKitCue.Kind(subscriptionID: CloudKitCue.Kind.question.subscriptionID), .question)
    }

    func testPhoneSwitchesQuietARecordTheAccountShares() {
        var prefs = CloudKitCue.PhonePrefs()
        let loud = CloudKitCue.presentation(for: .needsApproval, macWantsSound: true, macTimeSensitive: true, prefs: prefs)
        XCTAssertEqual(loud, .init(playsSound: true, timeSensitive: true, passive: false))

        prefs.categories.set(NotificationSound.needsApproval, enabled: false)
        let off = CloudKitCue.presentation(for: .needsApproval, macWantsSound: true, macTimeSensitive: true, prefs: prefs)
        XCTAssertEqual(off, .init(playsSound: false, timeSensitive: false, passive: true))

        prefs = CloudKitCue.PhonePrefs(playSound: false)
        let muted = CloudKitCue.presentation(for: .needsApproval, macWantsSound: true, macTimeSensitive: true, prefs: prefs)
        XCTAssertFalse(muted.playsSound)
        XCTAssertFalse(muted.passive)
    }
}
