import Foundation

public enum ChangesScope: String, Codable, CaseIterable, Sendable {
    case uncommitted, staged, branch
    public var title: String {
        switch self {
        case .uncommitted: String(localized: "Uncommitted", bundle: .module)
        case .staged: String(localized: "Staged", bundle: .module)
        case .branch: String(localized: "Branch", bundle: .module)
        }
    }
}
public struct WorkspaceChanges: Codable, Equatable, Sendable {
    public var scope: ChangesScope
    public var baseline: String
    public var attribution: String
    public var untrackedFiles: [String] = []
    public var files: [String]
    public var stat: String
    public var diff: String?
    public var truncated: Bool
    public var unavailableReason: String?
    public init(scope: ChangesScope, baseline: String, attribution: String, files: [String] = [], stat: String = "",
                diff: String? = nil, truncated: Bool = false, unavailableReason: String? = nil) {
        self.scope = scope; self.baseline = baseline; self.attribution = attribution; self.files = files
        self.stat = stat; self.diff = diff; self.truncated = truncated; self.unavailableReason = unavailableReason
    }
}

public extension WorkspaceChanges {
    /// Lines added across tracked files in this comparison, read from the
    /// stat's summary line ("3 files changed, 187 insertions(+), 4 deletions(-)").
    /// `nil` means the count is unknown — the workspace could not be read, or
    /// the summary is not in a form we recognise — so a failure is never shown
    /// as "no changes". `0` is only returned when Git reported a clean comparison.
    var addedLineCount: Int? { statCount(of: "insertion") }
    /// Lines deleted, on the same terms as `addedLineCount`.
    var deletedLineCount: Int? { statCount(of: "deletion") }

    private func statCount(of noun: String) -> Int? {
        guard unavailableReason == nil else { return nil }
        let trimmed = stat.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        guard let summary = trimmed.split(separator: "\n").last, summary.contains("changed") else { return nil }
        // "187 insertions(+)" / "1 insertion(+)"; absent when that side is zero.
        guard let match = summary.firstMatch(of: try! Regex("(\\d+) \(noun)s?\\(")) ,
              let value = Int(match.output[1].substring ?? "") else {
            return summary.contains(noun) ? nil : 0
        }
        return value
    }
}
