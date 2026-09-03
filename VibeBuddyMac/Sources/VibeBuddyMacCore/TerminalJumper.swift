import AppKit
import Foundation
import VibeBuddyKit

/// One try at raising the session's exact surface. Its commands run in order and
/// the attempt counts as a hit only if every one of them exits 0 — WezTerm needs
/// both `activate-pane` and `activate-tab`, and a half-done focus is not a focus.
struct JumpAttempt: Equatable, Sendable {
    var commands: [[String]]
    init(_ commands: [[String]]) { self.commands = commands }
    init(_ argv: [String]) { self.commands = [argv] }
}

/// One multiplexer command, plus whether its success means the pane actually
/// came into view. `switch-client` and `select-window` move the viewport;
/// `select-pane` and the unzoom only rearrange what is already on screen, so
/// their success alone is not a focus.
struct TmuxStep: Equatable, Sendable {
    var argv: [String]
    var focuses: Bool
}

/// Everything a jump will do, decided without running anything. Split by the
/// three levels of precision a `TerminalRef` can carry.
struct JumpPlan: Equatable, Sendable {
    /// Multiplexer pane selection. Every command runs; they are independent.
    var tmux: [TmuxStep] = []
    /// Surface targeting, most specific first. Execution stops at the first hit.
    var surface: [JumpAttempt] = []
    /// Bundle ids of the emulator the `surface` attempts address. At least one
    /// of them must already be running before any attempt may be made:
    /// `tell application id "…"` *launches* the app when it isn't, and a jump
    /// that opens a brand-new terminal is not the action the user asked for.
    /// Empty means "nothing below app level was planned".
    var requiredRunningBundleIDs: [String] = []
    /// The app to bring forward afterwards. `nil` when the host is unknown.
    var activateBundleID: String?

    var isEmpty: Bool { tmux.isEmpty && surface.isEmpty && activateBundleID == nil }
}

/// Plans and runs the jump from a session's `TerminalRef` to the terminal the
/// user left it in.
///
/// `plan(for:)` is pure — it decides which commands *would* run, which is where
/// every safety rule lives (ids are validated against a strict allowlist before
/// they can reach AppleScript, and an app is only scripted when the ref says the
/// session actually lives in it, so a jump can never launch a terminal the user
/// isn't using). `jump(_:)` executes that plan off the main actor with a per-step
/// timeout and reports what it actually achieved.
public enum TerminalJumper {

    // MARK: - Planning

    /// Terminal emulators we can address below app level. Derived from
    /// `TERM_PROGRAM`, or from the host bundle id when the host exports none.
    /// Scripting is gated on this twice over: the ref has to say the session
    /// lives in this family, *and* the family has to be running when the plan
    /// executes — `tell application id "com.apple.Terminal"` launches
    /// Terminal.app otherwise.
    enum Family: Equatable {
        case appleTerminal, iterm, ghostty, wezterm, kitty, other

        /// The `TERM_PROGRAM` this family is named by, which is also the key
        /// into `ForegroundTerminal`'s one bundle-id table — the same table
        /// that decides which sessions count as foregrounded.
        var termProgram: String? {
            switch self {
            case .appleTerminal: return "apple_terminal"
            case .iterm: return "iTerm.app"
            case .ghostty: return "ghostty"
            case .wezterm: return "wezterm"
            case .kitty: return "kitty"
            case .other: return nil
            }
        }

        /// Every bundle id this family can run under.
        var bundleIDs: [String] {
            termProgram.map { ForegroundTerminal.bundleIDs(forTermProgram: $0) } ?? []
        }
    }

    static func family(for ref: TerminalRef) -> Family {
        switch ref.termProgram?.lowercased() {
        case "apple_terminal": return .appleTerminal
        case "iterm.app": return .iterm
        case "ghostty": return .ghostty
        case "wezterm": return .wezterm
        case "kitty": return .kitty
        case .some: return .other
        case nil: break
        }
        switch ref.hostBundleId {
        case "com.apple.Terminal": return .appleTerminal
        case "com.googlecode.iterm2": return .iterm
        case "com.mitchellh.ghostty": return .ghostty
        case "com.github.wez.wezterm": return .wezterm
        case "net.kovidgoyal.kitty": return .kitty
        default: return .other
        }
    }

    static func plan(for ref: TerminalRef,
                            tmuxPath: String = TerminalCommand.tmuxPath(),
                            weztermPath: String? = TerminalCommand.weztermPath(),
                            kittenPath: String? = TerminalCommand.kittenPath()) -> JumpPlan {
        var plan = JumpPlan()

        if let socket = tmuxSocket(ref.tmux), let pane = paneID(ref.tmuxPane) {
            plan.tmux = [
                TmuxStep(argv: [tmuxPath, "-S", socket, "switch-client", "-t", pane], focuses: true),
                TmuxStep(argv: [tmuxPath, "-S", socket, "select-window", "-t", pane], focuses: true),
                // A zoomed window hides every other pane; unzoom only when it is
                // zoomed, evaluated by tmux itself so the plan stays pure.
                TmuxStep(argv: [tmuxPath, "-S", socket, "if-shell", "-F", "-t", pane,
                                "#{window_zoomed_flag}", "resize-pane -Z -t \(pane)"], focuses: false),
                // Picks the pane inside a window that is already on screen —
                // it succeeds just as happily when that window is buried, so
                // on its own it is not evidence of a jump.
                TmuxStep(argv: [tmuxPath, "-S", socket, "select-pane", "-t", pane], focuses: false),
            ]
        }

        let family = family(for: ref)
        switch family {
        case .appleTerminal:
            if let tty = ttyDevice(ref.tty) {
                plan.surface.append(JumpAttempt(osascript(appleTerminalScript(tty: tty))))
            }
        case .iterm:
            if let id = opaqueID(ref.itermSessionId) {
                plan.surface.append(JumpAttempt(osascript(itermScript(match: "unique ID", value: id))))
            }
            if let tty = ttyDevice(ref.tty) {
                plan.surface.append(JumpAttempt(osascript(itermScript(match: "tty", value: tty))))
            }
        case .ghostty:
            if let id = opaqueID(ref.ghosttyTerminalId) {
                plan.surface.append(JumpAttempt(osascript(ghosttyScript(match: "id", value: id))))
            }
            if let cwd = scriptSafePath(ref.cwd) {
                plan.surface.append(JumpAttempt(osascript(ghosttyScript(match: "working directory", value: cwd))))
            }
        case .wezterm:
            if let pane = digits(ref.weztermPane), let wezterm = weztermPath {
                plan.surface.append(JumpAttempt([
                    [wezterm, "cli", "activate-pane", "--pane-id", pane],
                    [wezterm, "cli", "activate-tab", "--pane-id", pane],
                ]))
            }
        case .kitty:
            if let window = digits(ref.kittyWindowId), let socket = kittySocket(ref.kittyListenOn),
               let kitten = kittenPath {
                plan.surface.append(JumpAttempt(
                    [kitten, "@", "--to", socket, "focus-window", "--match", "id:\(window)"]))
            }
        case .other:
            break
        }

        // Nothing below app level may be attempted against an app that isn't
        // already running (see `JumpPlan.requiredRunningBundleIDs`).
        if !plan.surface.isEmpty { plan.requiredRunningBundleIDs = family.bundleIDs }

        // The host bundle id comes from real process ancestry, so it wins over the
        // `TERM_PROGRAM` table — that table cannot tell Cursor from VS Code (both
        // report `vscode`), and the ancestry can.
        plan.activateBundleID = ref.hostBundleId
            ?? ref.termProgram.flatMap { ForegroundTerminal.bundleIDs(forTermProgram: $0).first }
        return plan
    }

    // MARK: - AppleScript

    private static func osascript(_ source: String) -> [String] {
        [TerminalCommand.osascriptPath, "-e", source]
    }

    /// Terminal.app tabs expose a read-only `tty`, which is the only per-tab
    /// handle it offers. Raising the window needs both `selected tab` and
    /// `index` — the first picks the tab, the second brings the window forward.
    ///
    /// Addressed by bundle id, not by name, throughout: `tell application "X"`
    /// resolves the name at compile time and pops the "Where is X?" chooser
    /// when it can't, while `tell application id "…"` is unambiguous.
    private static func appleTerminalScript(tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
        \trepeat with w in windows
        \t\trepeat with t in tabs of w
        \t\t\tif tty of t is "\(tty)" then
        \t\t\t\tset selected tab of w to t
        \t\t\t\tset index of w to 1
        \t\t\t\tactivate
        \t\t\t\treturn "ok"
        \t\t\tend if
        \t\tend repeat
        \tend repeat
        end tell
        error "vibebuddy: no matching Terminal tab"
        """
    }

    /// iTerm2 nests window → tab → session and every level has its own `select`.
    private static func itermScript(match property: String, value: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
        \trepeat with w in windows
        \t\trepeat with t in tabs of w
        \t\t\trepeat with s in sessions of t
        \t\t\t\tif \(property) of s is "\(value)" then
        \t\t\t\t\tselect w
        \t\t\t\t\tselect t
        \t\t\t\t\tselect s
        \t\t\t\t\tactivate
        \t\t\t\t\treturn "ok"
        \t\t\t\tend if
        \t\t\tend repeat
        \t\tend repeat
        \tend repeat
        end tell
        error "vibebuddy: no matching iTerm session"
        """
    }

    /// Ghostty exposes `focus` on a terminal and a `whose` filter over them.
    /// `activate` comes second so a miss (which raises an AppleScript error)
    /// doesn't pull Ghostty forward on its way to failing.
    private static func ghosttyScript(match property: String, value: String) -> String {
        """
        tell application id "com.mitchellh.ghostty"
        \tfocus (first terminal whose \(property) is "\(value)")
        \tactivate
        end tell
        """
    }

    // MARK: - Validation
    //
    // Every value below is interpolated into an AppleScript source string or an
    // argv, and all of it originates in a hook running on the user's machine.
    // Nothing reaches a script until it matches a closed allowlist, so a quote or
    // newline smuggled into e.g. `$ITERM_SESSION_ID` cannot end the string
    // literal and append statements.

    private static let idCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:_.-")
    private static let socketCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:/._-")

    /// `%3` — a tmux pane id.
    static func paneID(_ value: String?) -> String? {
        guard let value, value.hasPrefix("%"), value.count > 1,
              value.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return value
    }

    /// The socket path out of `$TMUX` (`socket,pid,session`). argv-only, so a
    /// path is enough; it never reaches a shell — but it must be an absolute
    /// path, which is the only shape tmux ever writes there, so a relative or
    /// option-looking value (`-S`, `--x`) can't be smuggled into the argv.
    static func tmuxSocket(_ tmux: String?) -> String? {
        guard let socket = tmux?.split(separator: ",").first.map(String.init),
              socket.hasPrefix("/") else { return nil }
        return socket
    }

    static func digits(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    /// An emulator-assigned identifier: iTerm2's `unique ID`, Ghostty's terminal id.
    static func opaqueID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.allSatisfy(idCharacters.contains) else { return nil }
        return value
    }

    /// `ttys003` (however it was captured) → `/dev/ttys003`, the form both
    /// Terminal.app and iTerm2 report.
    static func ttyDevice(_ value: String?) -> String? {
        guard var name = value, !name.isEmpty else { return nil }
        if name.hasPrefix("/dev/") { name = String(name.dropFirst(5)) }
        guard name.hasPrefix("ttys"), name.count > 4,
              name.dropFirst(4).allSatisfy(\.isNumber) else { return nil }
        return "/dev/" + name
    }

    static func kittySocket(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.allSatisfy(socketCharacters.contains) else { return nil }
        return value
    }

    /// A path is the one value we can't allowlist by character — directory names
    /// are arbitrary — so it is escaped instead, and rejected outright if it
    /// carries a control character that could break out of the string literal.
    static func scriptSafePath(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        return value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Execution

    /// How long any single command gets. AppleScript to a live app answers in
    /// milliseconds; the budget exists for the first-run Automation prompt, which
    /// blocks `osascript` until the user answers it.
    static let stepTimeout: TimeInterval = 3

    /// The plan runs on a plain dispatch queue, never on the cooperative pool:
    /// every step blocks on a `Process` for up to `stepTimeout`, and blocking a
    /// pool thread starves every other task on it. `withCheckedContinuation`
    /// bridges the two worlds, so the caller still just awaits.
    public static func jump(_ ref: TerminalRef) async -> JumpOutcome {
        let plan = plan(for: ref)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: execute(plan))
            }
        }
    }

    /// Whether an app with this bundle id is running right now. Injected so the
    /// gate can be tested without launching anything.
    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func execute(_ plan: JumpPlan,
                        isRunning: (String) -> Bool = TerminalJumper.isRunning,
                        activate: (String) -> Bool = TerminalJumper.activate) -> JumpOutcome {
        var focused = false
        // tmux commands are independent: a detached client makes `switch-client`
        // fail while `select-window` still lands, so any success counts — but
        // only from a step that actually moves the viewport.
        for step in plan.tmux {
            if run(step.argv), step.focuses { focused = true }
        }
        // Scripting a terminal launches it if it isn't running, so the whole
        // surface tier is skipped unless the emulator is already up. Losing the
        // exact target degrades the jump to `.activatedApp`, which is the right
        // answer: there is no window of ours to raise.
        if plan.requiredRunningBundleIDs.contains(where: isRunning) {
            // Surface attempts are alternatives, ordered most specific first.
            for attempt in plan.surface {
                if attempt.commands.allSatisfy(run) {
                    focused = true
                    break
                }
            }
        }
        let activated = plan.activateBundleID.map(activate) ?? false
        return JumpOutcome.decide(hasRef: true, focusedExactTarget: focused, activatedApp: activated)
    }

    /// Runs one command and reports whether it exited 0. Never throws, never
    /// blocks longer than `stepTimeout`, and produces no output of its own.
    ///
    /// A timed-out step is killed, not merely asked to stop: `osascript` waiting
    /// on the Automation consent dialog ignores `SIGTERM`, and an orphan of it
    /// would hold that dialog open for the rest of the session.
    private static func run(_ argv: [String]) -> Bool {
        guard let executable = argv.first,
              FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return false }
        if finished.wait(timeout: .now() + stepTimeout) == .timedOut {
            let pid = process.processIdentifier
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut, pid > 0 {
                kill(pid, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
            return false
        }
        return process.terminationStatus == 0
    }

    /// Brings an already-running app forward. Deliberately does *not* launch it:
    /// a jump is a return to work in progress, and starting a fresh terminal
    /// would be a different, unasked-for action. Injected into `execute` so a
    /// test's verdict doesn't depend on which apps happen to be open.
    static func activate(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.activate(options: [.activateAllWindows]) ?? false
    }
}
