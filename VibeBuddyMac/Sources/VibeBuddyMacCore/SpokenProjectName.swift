import Foundation
import VibeBuddyKit

/// The project name read-aloud opens with: the main checkout's folder, said
/// the way a person would say it. Agent worktrees (Claude, Cursor, Codex) live
/// in folders like `claude-code-vibebuddy-display-d51a8d`; their `.git` file
/// points back at the main repository, whose folder is the real project.
enum SpokenProjectName {
    static func resolve(checkoutPath: String?, fallback: String) -> String {
        let folder = checkoutPath.flatMap(mainCheckoutFolder) ?? fallback
        let spoken = speakable(folder)
        return spoken.isEmpty ? fallback : spoken
    }

    /// Walks up from `path` to the nearest `.git`. A worktree's `.git` is a
    /// file reading `gitdir: <main>/.git/worktrees/<name>`; anything else
    /// (a normal checkout, a submodule) keeps its own folder name.
    static func mainCheckoutFolder(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        while dir.path != "/" {
            let git = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue,
                   let text = try? String(contentsOf: git, encoding: .utf8),
                   let line = text.split(whereSeparator: \.isNewline).first,
                   line.hasPrefix("gitdir:"),
                   let marker = line.range(of: "/.git/worktrees/") {
                    let main = line[line.index(line.startIndex, offsetBy: 7)..<marker.lowerBound]
                        .trimmingCharacters(in: .whitespaces)
                    let name = URL(fileURLWithPath: main).lastPathComponent
                    if !name.isEmpty { return name }
                }
                return dir.lastPathComponent
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// `iOS-vibebuddy` → `iOS vibebuddy`; separators become spaces and a
    /// trailing hash- or number-like tag (`d51a8d`, `1884`) is dropped.
    static func speakable(_ folder: String) -> String {
        var words = folder.split(whereSeparator: { "-_.".contains($0) || $0.isWhitespace }).map(String.init)
        while words.count > 1, let last = words.last, isTag(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static func isTag(_ word: String) -> Bool {
        let lower = word.lowercased()
        if lower.allSatisfy(\.isNumber) { return true }
        return lower.count >= 6 && lower.allSatisfy(\.isHexDigit) && lower.contains(where: \.isNumber)
    }

    /// Prepended only when the generated speech never names the project.
    static func lead(_ name: String, language: VoiceLanguage) -> String {
        language == .chinese ? "\(name) 项目：" : "An update from the \(name) project. "
    }
}
