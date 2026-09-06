import Foundation

/// A local daemon installation's identity. Failure to persist yields no identity,
/// so a wrist cannot mistake an ephemeral value for a restart-safe authority.
public enum DaemonIdentity {
    public static func load(url: URL = AttentionOverrides.defaultURL()
        .deletingLastPathComponent().appendingPathComponent("source-id")) -> String? {
        if let value = try? String(contentsOf: url, encoding: .utf8),
           let id = UUID(uuidString: value) { return id.uuidString }
        let value = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url, options: .atomic)
            return value
        } catch { return nil }
    }
}
