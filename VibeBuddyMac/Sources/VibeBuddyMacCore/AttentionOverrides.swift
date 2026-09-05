import Foundation
import VibeBuddyKit

/// The attention levels the user set by hand, keyed by session id. Owned by
/// `SessionStore`, persisted beside the lifecycle journal so a daemon restart
/// keeps a muted session muted, and pruned whenever a session goes away —
/// a choice about a session lives exactly as long as the session.
public struct AttentionOverrides: Sendable, Equatable {
    public private(set) var levels: [String: SessionAttention]
    private let url: URL?

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("vibebuddy/attention.json")
    }

    /// `url: nil` keeps the overrides in memory only (tests, throwaway daemons).
    public init(url: URL?) {
        self.url = url
        self.levels = url.map(Self.read) ?? [:]
    }

    public subscript(sessionID: String) -> SessionAttention? { levels[sessionID] }

    /// Set, or with `nil` clear, the user's choice for one session.
    public mutating func set(_ level: SessionAttention?, for sessionID: String) {
        guard levels[sessionID] != level else { return }
        levels[sessionID] = level
        write()
    }

    /// Forget every session not in `live`.
    public mutating func prune(keeping live: Set<String>) {
        let stale = levels.keys.filter { !live.contains($0) }
        guard !stale.isEmpty else { return }
        for id in stale { levels[id] = nil }
        write()
    }

    private static func read(_ url: URL) -> [String: SessionAttention] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["sessions"] as? [String: String] else { return [:] }
        return raw.compactMapValues(SessionAttention.init(rawValue:))
    }

    private func write() {
        guard let url else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = levels.mapValues(\.rawValue)
        if let data = try? JSONSerialization.data(
            withJSONObject: ["sessions": raw], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// The level a session gets when the user has not chosen one: `followed`
/// while they were recently *driving* it — typed a prompt, jumped to it,
/// answered its approval or question — and `normal` otherwise. Never
/// `muted`: silence is only ever a choice.
public enum AutoAttention {
    /// How long one interaction keeps a session followed.
    public static let window: TimeInterval = 10 * 60

    public static func level(lastInteractionAt: Date?, now: Date) -> SessionAttention {
        guard let lastInteractionAt, now.timeIntervalSince(lastInteractionAt) < window else { return .normal }
        return .followed
    }
}
