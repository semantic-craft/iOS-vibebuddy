import Foundation

public struct HistorySearchHit: Sendable {
    public var session: SessionHistorySession
    public var seq: Int
    public var excerpt: String
    public var reference: String { "vibebuddy://session/\(HistoryTools.key(session))#\(seq)" }
}

public struct HistorySearchPage: Sendable {
    public var hits: [HistorySearchHit]
    public var notIndexed: [SessionHistorySession]
    public var unavailable: [SessionHistorySession]
}

extension HistoryTools {
    public static func search(arguments: [String: Any], repository: SessionHistoryRepository, now: Date = Date()) async throws -> String {
        let scope = try selection("vibebuddy_search", arguments: arguments, snapshot: await repository.snapshot(), now: now)
        guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HistoryToolError.invalidArguments("query must contain non-whitespace text.")
        }
        if let notice = scope.notice { return notice + "\n\n" + scope.freshness }
        let page = try await repository.search(query, sessionIDs: Set(scope.sessions.map(\.id)), limit: scope.limit)
        var lines = ["# Search results", "", "Coverage: indexed readable dialogue and tool text; Meta and Thinking omitted. Use show REF --tools to expand tool details."]
        if page.hits.isEmpty { lines += ["", "No matches found."] }
        for hit in page.hits {
            lines += ["", "## \(oneLine(hit.session.title))", "Key: \(key(hit.session)) | Project: \(oneLine(hit.session.projectPath))",
                      "Source revision: \(hit.session.sourceRevision ?? "unknown")", "", "> " + oneLine(hit.excerpt), "ref: \(hit.reference)"]
        }
        if !page.notIndexed.isEmpty {
            lines += ["", "Not indexed yet (missing rows or source revision changed); run vibebuddy-mcp index --rebuild:"]
            lines += page.notIndexed.sorted { key($0) < key($1) }.map { "- \(key($0)): not indexed yet — \(oneLine($0.sourcePath))" }
        }
        if !page.unavailable.isEmpty {
            lines += ["", "References unavailable: cached transcript or unique source identity could not be verified. Use show KEY or rebuild the index."]
            lines += page.unavailable.sorted { key($0) < key($1) }.map { "- " + key($0) }
        }
        lines += ["", scope.freshness]
        return lines.joined(separator: "\n")
    }

    // The FTS layer returns literal source excerpts, never highlighted HTML or
    // marker-delimited text. Flatten line breaks without stripping source code.
    private static func oneLine(_ value: String) -> String {
        value.components(separatedBy: .controlCharacters).joined(separator: " ")
    }
}
