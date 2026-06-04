import Foundation

enum TerminalCommand {
    static let tmuxCandidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    static func tmuxPath(fileManager: FileManager = .default) -> String {
        tmuxCandidates.first { fileManager.isExecutableFile(atPath: $0) } ?? "/usr/bin/tmux"
    }
}
