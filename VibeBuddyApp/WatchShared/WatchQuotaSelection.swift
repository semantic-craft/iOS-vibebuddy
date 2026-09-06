import Foundation
import VibeBuddyKit

/// A destination, never a transported quota reading or task acknowledgement.
enum WatchQuotaSelection: String, CaseIterable, Identifiable {
    case codex, claude, both
    var id: String { rawValue }
    var providers: [AccountUsageProvider] {
        switch self {
        case .codex: [.codex]
        case .claude: [.claude]
        case .both: [.codex, .claude]
        }
    }
    var url: URL { URL(string: "vibebuddy://quota/\(rawValue)")! }
    init?(url: URL) {
        guard url.scheme == "vibebuddy", url.host == "quota",
              url.query == nil, url.fragment == nil else { return nil }
        self.init(rawValue: String(url.path.dropFirst()))
    }
}
