import Foundation
import VibeBuddyKit

/// Builds and runs the commands to focus a session's terminal. `commands(for:)`
/// is pure (testable); `jump(_:)` executes them best-effort via `Process`.
public enum TerminalJumper {
    public static func commands(for ref: TerminalRef) -> [[String]] {
        var cmds: [[String]] = []
        if let tmux = ref.tmux, let pane = ref.tmuxPane,
           !tmux.isEmpty, !pane.isEmpty,
           let socket = tmux.split(separator: ",").first.map(String.init), !socket.isEmpty {
            let tmuxPath = TerminalCommand.tmuxPath()
            cmds.append([tmuxPath, "-S", socket, "switch-client", "-t", pane])
            cmds.append([tmuxPath, "-S", socket, "select-window", "-t", pane])
            cmds.append([tmuxPath, "-S", socket, "select-pane", "-t", pane])
        }
        if let app = appName(forTermProgram: ref.termProgram) {
            cmds.append(["/usr/bin/open", "-a", app])
        }
        return cmds
    }

    static func appName(forTermProgram tp: String) -> String? {
        switch tp.lowercased() {
        case "ghostty": return "Ghostty"
        case "iterm.app": return "iTerm"
        case "apple_terminal": return "Terminal"
        case "wezterm": return "WezTerm"
        case "vscode": return "Visual Studio Code"
        default: return nil
        }
    }

    public static func jump(_ ref: TerminalRef) {
        for argv in commands(for: ref) where !argv.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            try? p.run(); p.waitUntilExit()
        }
    }
}
