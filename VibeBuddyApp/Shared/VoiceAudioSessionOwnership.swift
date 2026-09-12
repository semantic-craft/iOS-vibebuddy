import Foundation

/// AVAudioSession is process-wide. Cleanup belongs to the latest call, including
/// an unfinished deactivation inherited from the preceding call.
@MainActor
final class VoiceAudioSessionOwnership {
    static let shared = VoiceAudioSessionOwnership()

    private var owner: UUID?
    private(set) var needsDeactivation = false

    func claim() -> UUID {
        let token = UUID()
        owner = token
        // Do not clear a preceding call's failed cleanup obligation.
        return token
    }

    /// Claim cleanup before setActive(true), which may throw after partially
    /// changing the shared session. An old call cannot acquire this obligation.
    func markActivationAttempt(owner token: UUID) {
        guard owner == token else { return }
        needsDeactivation = true
    }

    /// Returns false for stale/already released owners without touching audio.
    /// A throwing operation retains both ownership and the cleanup obligation.
    @discardableResult
    func release(owner token: UUID, operation: () throws -> Void) throws -> Bool {
        guard owner == token else { return false }
        if needsDeactivation { try operation() }
        guard owner == token else { return false }
        needsDeactivation = false
        owner = nil
        return true
    }
}
