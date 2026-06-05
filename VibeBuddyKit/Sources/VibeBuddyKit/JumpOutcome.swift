import Foundation

/// What a "jump to terminal" request resolved to, reported by the Mac `/jump`
/// route and read by the phone so it can give honest feedback instead of failing
/// silently. (A transport failure is represented client-side as the absence of an
/// outcome, i.e. `nil`.)
public enum JumpOutcome: String, Codable, Sendable {
    case focused        // a terminal ref existed and a focus command was run
    case unsupported    // a ref existed but no runnable focus command (unknown terminal type)
    case noTerminal     // the session has no terminal ref to focus

    /// Decide the outcome from whether a terminal ref exists and whether a
    /// runnable focus command was produced for it. Pure so it can be unit-tested
    /// away from the route and the `Process`-running jumper.
    public static func decide(hasRef: Bool, hasRunnableCommand: Bool) -> JumpOutcome {
        guard hasRef else { return .noTerminal }
        return hasRunnableCommand ? .focused : .unsupported
    }
}
