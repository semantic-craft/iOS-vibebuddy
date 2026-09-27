import Foundation
import VibeBuddyKit

/// The project name read-aloud opens with: the main checkout's folder, said
/// the way a person would say it. Agent worktrees (Claude, Cursor, Codex) live
/// in folders like `claude-code-vibebuddy-display-d51a8d`; their `.git` file
/// points back at the main repository, whose folder is the real project.
enum SpokenProjectName {
    /// Nil when there is no usable name (no path and a placeholder project).
    static func resolve(checkoutPath: String?, fallback: String) -> String? {
        let path = checkoutPath ?? (fallback.hasPrefix("/") ? fallback : nil)
        let spoken: String
        if let path, let main = mainCheckoutFolder(path) {
            spoken = speakable(main, trimTag: false)
        } else if let path {
            spoken = speakable(URL(fileURLWithPath: path).lastPathComponent, trimTag: true)
        } else {
            spoken = speakable(fallback, trimTag: true)
        }
        return spoken.contains(where: { $0.isLetter || $0.isNumber }) ? spoken : nil
    }

    /// Walks up from `path` to the nearest `.git`, stopping below the home
    /// folder so a dotfiles repository in `~` never names unrelated work. A
    /// worktree's `.git` file names its git dir, whose `commondir` leads to
    /// the repository's own git dir; a submodule has no `commondir` and keeps
    /// its own folder.
    static func mainCheckoutFolder(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        let start = dir.path
        while dir.path != "/" {
            if dir.path == home, start != home { return nil }
            let git = dir.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else { return dir.lastPathComponent }
                guard let text = try? String(contentsOf: git, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:")
                else { return dir.lastPathComponent }
                let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = URL(fileURLWithPath: raw, relativeTo: dir).standardizedFileURL
                guard let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty
                else { return dir.lastPathComponent }
                let commonDir = URL(fileURLWithPath: common, relativeTo: gitDir).standardizedFileURL
                let name = commonDir.lastPathComponent
                if name == ".git" { return commonDir.deletingLastPathComponent().lastPathComponent }
                return name.hasSuffix(".git") ? String(name.dropLast(4)) : name // bare repository
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// `iOS-vibebuddy` → `iOS vibebuddy`. A trailing hash-like tag (`d51a8d`)
    /// is dropped only from a worktree-style folder name; a main checkout's
    /// name keeps words like `app-2024`.
    static func speakable(_ folder: String, trimTag: Bool) -> String {
        var words = folder.split(whereSeparator: { "-_".contains($0) || $0.isWhitespace }).map(String.init)
        while trimTag, words.count > 1, let last = words.last, isTag(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static func isTag(_ word: String) -> Bool {
        let lower = word.lowercased()
        return lower.count >= 6 && lower.allSatisfy(\.isHexDigit) && lower.contains(where: \.isNumber)
    }

    /// Whether speech already names the project, ignoring case and separators
    /// (`iOS VibeBuddy`, `ios-vibebuddy`).
    static func isMentioned(_ name: String, in text: String) -> Bool {
        func folded(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let key = folded(name)
        return !key.isEmpty && folded(text).contains(key)
    }

    /// Prepended only when the generated speech never names the project.
    static func lead(_ name: String, language: VoiceLanguage) -> String {
        language == .chinese ? "\(name) 项目：" : "An update from the \(name) project. "
    }
}
