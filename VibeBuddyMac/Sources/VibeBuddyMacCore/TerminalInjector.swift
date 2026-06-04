import Foundation
import VibeBuddyKit

/// Types a phone-supplied answer into a captured terminal pane. We only inject
/// into tmux panes; raw TTY injection is intentionally avoided.
public enum TerminalInjector {
    public static func commands(for ref: TerminalRef, text: String) -> [[String]] {
        guard !text.isEmpty,
              let tmux = ref.tmux, let pane = ref.tmuxPane,
              !tmux.isEmpty, !pane.isEmpty,
              let socket = tmux.split(separator: ",").first.map(String.init), !socket.isEmpty
        else { return [] }
        let tmuxPath = TerminalCommand.tmuxPath()
        return [
            [tmuxPath, "-S", socket, "send-keys", "-t", pane, "-l", text],
            [tmuxPath, "-S", socket, "send-keys", "-t", pane, "Enter"],
        ]
    }

    public static func inject(_ text: String, into ref: TerminalRef) {
        for argv in commands(for: ref, text: text) where !argv.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            try? p.run()
            p.waitUntilExit()
        }
    }
}
