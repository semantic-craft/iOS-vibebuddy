import Foundation

/// Why a bounded recent-output read could not show dialogue.
public enum RecentOutputUnavailability: String, Codable, Sendable, Equatable {
    /// The session is not in the current snapshot.
    case unknownSession
    /// The session exists but no transcript, rollout, or app-server items are known.
    case noSource
    /// A source path exists but could not be read.
    case unreadable
    /// The agent has no verified dialogue format for this source.
    case unsupported
}

/// One user or assistant line in a bounded recent-output slice.
public struct RecentOutputEntry: Codable, Equatable, Sendable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

/// Authenticated, bounded, read-only recent dialogue for a Session.
///
/// This is not a transcript dump and not a completion acknowledgement. Empty
/// entries with `unavailable == nil` mean the source was readable but held no
/// dialogue yet. `truncated` means older lines or per-line text were cut.
public struct RecentOutput: Codable, Equatable, Sendable {
    public let sessionId: String
    public let source: ObservationSource?
    public let updatedAt: Date?
    public let truncated: Bool
    public let unavailable: RecentOutputUnavailability?
    public let entries: [RecentOutputEntry]

    public init(
        sessionId: String,
        source: ObservationSource? = nil,
        updatedAt: Date? = nil,
        truncated: Bool = false,
        unavailable: RecentOutputUnavailability? = nil,
        entries: [RecentOutputEntry] = []
    ) {
        self.sessionId = sessionId
        self.source = source
        self.updatedAt = updatedAt
        self.truncated = truncated
        self.unavailable = unavailable
        self.entries = unavailable == nil ? entries : []
    }

    public static func unavailable(
        sessionId: String,
        reason: RecentOutputUnavailability,
        source: ObservationSource? = nil,
        updatedAt: Date? = nil
    ) -> RecentOutput {
        RecentOutput(sessionId: sessionId, source: source, updatedAt: updatedAt,
                     unavailable: reason)
    }

    public var sourceLabel: String { source?.displayName ?? "Unknown" }

    /// Empty when the slice is ready and untruncated. Used as the status line
    /// under the entries — never as a substitute for a pending question.
    public var statusLine: String {
        if let unavailable {
            switch unavailable {
            case .unknownSession: return "This session is no longer on the Mac."
            case .noSource: return "No recent output source for this session."
            case .unreadable: return "The recent output source cannot be read."
            case .unsupported: return "This agent’s output format is not supported yet."
            }
        }
        if entries.isEmpty { return "No recent output yet." }
        if truncated { return "Bounded excerpt — not the full history." }
        return ""
    }
}
