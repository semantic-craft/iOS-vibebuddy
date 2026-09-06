import Foundation
import UIKit
import UserNotifications
import VibeBuddyKit

/// Whether a push has already told the user what this phone is about to post.
///
/// A push and a local notification for one cue carry the same identifier, but
/// iOS keeps them as two banners (ADR-0012). The Mac stands its push down when
/// this phone reports posting the cue first; this is the other order. While
/// the app was suspended the Mac pushed; now the stream has caught up and the
/// `SoundPolicy` earns the same waiting cue. If the push for that wait is still
/// in Notification Center — or is the very banner whose tap just brought the
/// app forward — the user has been told, and posting again would be a second
/// banner and a second sound.
///
/// Only a push delivered *for this wait* counts: one from an earlier wait of
/// the same session (a stale banner the wait's end never got to withdraw)
/// must not silence a fresh cue. The wait's start comes from the Mac's clock;
/// a small tolerance absorbs the two clocks disagreeing. Skew beyond it errs
/// toward posting — a duplicate, never a missing alert.
actor PushCoverage {
    static let shared = PushCoverage()

    /// How far a push's delivery may precede the wait's recorded start and
    /// still count as announcing it.
    static let clockTolerance: TimeInterval = 5

    /// Delivery dates of pushes whose tap opened the app, by identifier. A tap
    /// removes the banner from Notification Center before the stream can ask
    /// about it, so the tap itself is remembered until the wait is withdrawn.
    private var tapped: [String: Date] = [:]
    private var lastActivation = Date.distantPast

    private init() {}

    func noteTapped(identifier: String, deliveredAt: Date) {
        tapped[identifier] = deliveredAt
    }

    /// The app just came forward. A tap's `didReceive` and the stream's first
    /// snapshot race here; `covers` gives the tap a moment to land.
    func noteActivated(at now: Date = Date()) {
        lastActivation = now
    }

    /// The wait is over (or the app never posted it): nothing left to cover.
    func forget(_ identifiers: [String]) {
        for identifier in identifiers { tapped[identifier] = nil }
    }

    /// True when a push with `identifier`, delivered for the wait that began at
    /// `since`, is in Notification Center or was just tapped.
    func covers(_ identifier: String, since: Date) async -> Bool {
        if await check(identifier, since: since) { return true }
        // Right after activation the tap that opened the app may not have been
        // reported yet; look once more after a beat.
        guard Date().timeIntervalSince(lastActivation) < 1.5 else { return false }
        try? await Task.sleep(for: .milliseconds(500))
        return await check(identifier, since: since)
    }

    private func check(_ identifier: String, since: Date) async -> Bool {
        let earliest = since.addingTimeInterval(-Self.clockTolerance)
        if let tap = tapped[identifier], tap >= earliest { return true }
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return delivered.contains {
            $0.request.identifier == identifier
                && $0.request.trigger is UNPushNotificationTrigger
                && $0.date >= earliest
        }
    }
}
