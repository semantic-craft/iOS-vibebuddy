import AppKit
import CoreGraphics
import Foundation
import VibeBuddyMacCore

/// The Mac-side inputs of `PresencePolicy` (which is pure and lives in core):
/// screen lock from the window server, idle time from the event system, and a
/// closure the daemon and the Codex monitor call with a session id.
enum Presence {
    /// `CGSessionCopyCurrentDictionary` reports the lock state of the current
    /// login session; a missing dictionary (no window server) reads as locked,
    /// which is the safer verdict: hold for the phone.
    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Seconds since the last keyboard or mouse event anywhere on the system.
    static func idleSeconds() -> TimeInterval {
        // kCGAnyInputEventType is ~0 on the C side.
        let any = CGEventType(rawValue: UInt32.max) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// A `@Sendable` evaluator over the shared menu-bar model. Resolved lazily
    /// so the closure can be built before the model finishes initializing.
    static func evaluator() -> @Sendable (String) async -> Bool {
        { sessionID in
            await MainActor.run {
                guard let model = MenuBarModel.shared else { return false }
                return PresencePolicy.decide(model.presenceInput(for: sessionID)) == .present
            }
        }
    }
}
