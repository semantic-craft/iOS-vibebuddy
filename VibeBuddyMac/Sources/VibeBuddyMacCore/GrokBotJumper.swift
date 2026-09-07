import AppKit
import VibeBuddyKit

/// Only the official app is addressable; no protocol evidence supports jumping
/// to an exact bot. Explicit Jump may open it, but never reports `.focused`.
public enum GrokBotJumper {
    public static let bundleID = "com.anysphere.sand"

    @MainActor
    public static func jump() async -> JumpOutcome {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return .unsupported
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { app, error in
                continuation.resume(returning: app != nil && error == nil ? .activatedApp : .unsupported)
            }
        }
    }
}
