import Foundation

/// Whether the person is at the Mac right now, and so should answer an
/// agent's prompt where it appears rather than wait for the phone.
///
/// Pure: the Mac app gathers the inputs (frontmost app, screen lock, idle
/// time, the user's override) and the daemon applies the verdict to every
/// blocking path — a hook gate, a question relay, an app-server request.
/// Present means "let the agent's own prompt take the answer, show the phone a
/// read-only card"; away means "hold for the phone".
public struct PresencePolicy: Sendable, Equatable {
    public struct Input: Sendable, Equatable {
        /// The session's own surface (its terminal app, or Codex Desktop for a
        /// Desktop thread) is frontmost.
        public var sessionSurfaceFocused: Bool
        public var screenLocked: Bool
        /// Seconds since the last keyboard or mouse event, system-wide.
        public var idleSeconds: TimeInterval
        /// The Settings override: "Always ask the phone first".
        public var alwaysAskPhone: Bool

        public init(sessionSurfaceFocused: Bool, screenLocked: Bool, idleSeconds: TimeInterval,
                    alwaysAskPhone: Bool) {
            self.sessionSurfaceFocused = sessionSurfaceFocused
            self.screenLocked = screenLocked
            self.idleSeconds = idleSeconds
            self.alwaysAskPhone = alwaysAskPhone
        }
    }

    public enum Verdict: Sendable, Equatable { case present, away }

    /// No input for this long counts as having left, even with the terminal
    /// still in front.
    public static let idleThreshold: TimeInterval = 120

    public static func decide(_ input: Input) -> Verdict {
        if input.alwaysAskPhone { return .away }
        if input.screenLocked { return .away }
        if input.idleSeconds >= idleThreshold { return .away }
        return input.sessionSurfaceFocused ? .present : .away
    }
}
