import Foundation

/// Absolute paths to the CLI tools the jumper and injector shell out to. Hooks
/// run under the user's shell, but the daemon does not inherit a useful `PATH`,
/// so every command is resolved to a real file before it is planned.
enum TerminalCommand {
    static let tmuxCandidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    /// WezTerm's CLI. The app bundle ships its own copy, so a user who never
    /// installed the Homebrew formula is still reachable.
    static let weztermCandidates = [
        "/opt/homebrew/bin/wezterm",
        "/usr/local/bin/wezterm",
        "/Applications/WezTerm.app/Contents/MacOS/wezterm",
    ]

    /// kitty's remote-control client.
    static let kittenCandidates = [
        "/opt/homebrew/bin/kitten",
        "/usr/local/bin/kitten",
        "/Applications/kitty.app/Contents/MacOS/kitten",
    ]

    static let osascriptPath = "/usr/bin/osascript"

    static func tmuxPath(fileManager: FileManager = .default) -> String {
        first(of: tmuxCandidates, fileManager: fileManager) ?? "/usr/bin/tmux"
    }

    /// `nil` when WezTerm isn't installed — the jumper then skips its step
    /// instead of planning a command that cannot run.
    static func weztermPath(fileManager: FileManager = .default) -> String? {
        first(of: weztermCandidates, fileManager: fileManager)
    }

    /// `nil` when kitty isn't installed.
    static func kittenPath(fileManager: FileManager = .default) -> String? {
        first(of: kittenCandidates, fileManager: fileManager)
    }

    private static func first(of candidates: [String], fileManager: FileManager) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
