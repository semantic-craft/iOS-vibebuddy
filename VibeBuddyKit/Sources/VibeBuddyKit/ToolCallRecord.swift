import Foundation

/// Bounded observed tool evidence, never a task completion or an approval.
public struct ToolCallRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Result: String, Codable, Sendable { case unconfirmed, succeeded, failed }
    public var id: String
    public var tool: String
    public var command: String?
    public var files: [String]
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var result: Result
    public var exitCode: Int?
    public var observedAt: Date
    public var source: String
    public var coverage: String
    public init(id: String, tool: String, command: String? = nil, files: [String] = [],
                linesAdded: Int? = nil, linesRemoved: Int? = nil, result: Result = .unconfirmed,
                exitCode: Int? = nil, observedAt: Date, source: String,
                coverage: String = "Observed calls only; incomplete coverage") {
        self.id = id; self.tool = String(tool.prefix(120)); self.command = command.map { String($0.prefix(2000)) }
        self.files = Array(Set(files.map { String($0.prefix(1000)) })).sorted().prefix(50).map { $0 }
        self.linesAdded = linesAdded; self.linesRemoved = linesRemoved
        self.result = result; self.exitCode = exitCode; self.observedAt = observedAt
        self.source = source; self.coverage = coverage
    }
}

extension AgentSession {
    public var ledgerSummary: String? {
        guard ledger?.isEmpty == false else { return nil }
        guard linesAdded != nil, linesRemoved != nil else {
            return String(localized: "\(changedFiles?.count ?? 0) files · \(commandsRun ?? 0) commands · edit volume unavailable · retained calls", bundle: .module)
        }
        return String(localized: "\(changedFiles?.count ?? 0) files · \(commandsRun ?? 0) commands · cumulative edits +\(linesAdded ?? 0) −\(linesRemoved ?? 0) · retained calls", bundle: .module)
    }
}
