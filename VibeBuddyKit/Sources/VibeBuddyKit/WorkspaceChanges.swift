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
