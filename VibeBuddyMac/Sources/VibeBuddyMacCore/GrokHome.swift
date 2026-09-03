import Foundation

/// Where Grok Build keeps its data. Grok resolves it from `$GROK_HOME` and only
/// falls back to `~/.grok`, so every read of grok's files goes through here —
/// otherwise an isolated profile (a test rig, a second install) would be
/// observed at the wrong path while its hooks were installed at the right one
/// (`hooks/install-grok-hooks.py` honours the same variable).
public enum GrokHome {
    public static var url: URL {
        if let value = ProcessInfo.processInfo.environment["GROK_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }
}
