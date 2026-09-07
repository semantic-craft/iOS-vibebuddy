import Foundation
import VibeBuddyKit

/// A destination, never a transported quota reading or task acknowledgement.
///
/// Raw values are deep-link path segments (`vibebuddy://quota/<raw>`). Keep
/// legacy `codex` / `claude` / `both` so saved complication URLs keep working;
/// unknown future paths fall back to `.both` instead of failing open.
enum WatchQuotaSelection: String, CaseIterable, Identifiable {
    case codex, claude, grok, cursor, both, all
    var id: String { rawValue }
    var providers: [AccountUsageProvider] {
        switch self {
        case .codex: [.codex]
        case .claude: [.claude]
        case .grok: [.grok]
        case .cursor: [.cursor]
        case .both: [.codex, .claude]
        case .all: AccountUsageProvider.allCases
        }
    }
    var url: URL { URL(string: "vibebuddy://quota/\(rawValue)")! }
    init?(url: URL) {
        guard url.scheme == "vibebuddy", url.host == "quota",
              url.query == nil, url.fragment == nil else { return nil }
        let path = String(url.path.dropFirst())
        guard !path.isEmpty else { return nil }
        if let known = Self(rawValue: path) {
            self = known
        } else {
            // Tolerate unknown future path segments so an older Watch build
            // still opens quota detail instead of ignoring the deep link.
            self = .both
        }
    }
}
