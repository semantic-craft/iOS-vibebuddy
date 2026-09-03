import Foundation

/// What a "jump to terminal" request resolved to, reported by the Mac `/jump`
/// route and read by the phone so it can give honest feedback instead of failing
/// silently. (A transport failure is represented client-side as the absence of an
/// outcome, i.e. `nil`.)
///
/// The middle case matters: most hosts let us raise the *app* but not the exact
/// window — VS Code and Cursor expose no API for their integrated terminals, and
/// kitty without a remote-control socket cannot be addressed at all. Reporting
/// that as `focused` would promise a precision we didn't deliver.
public enum JumpOutcome: String, Codable, Sendable {
    case focused        // the session's own pane/tab/window was raised
    case activatedApp   // only its host application could be brought forward
    case unsupported    // a ref existed but nothing about it was actionable
    case noTerminal     // the session has no terminal ref to focus

    /// Decide the outcome from what the jump actually achieved. Pure so it can be
    /// unit-tested away from the route and the `Process`-running jumper.
    public static func decide(hasRef: Bool,
                              focusedExactTarget: Bool,
                              activatedApp: Bool) -> JumpOutcome {
        guard hasRef else { return .noTerminal }
        if focusedExactTarget { return .focused }
        return activatedApp ? .activatedApp : .unsupported
    }
}
