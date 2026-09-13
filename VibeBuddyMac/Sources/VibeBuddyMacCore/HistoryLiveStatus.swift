import Foundation
import VibeBuddyKit

/// Optional live observation. Never sends a session action or changes local state.
public enum HistoryLiveStatus {
    public static var definition: [String: Any] {
        ["name": "vibebuddy_live_status", "description": "Read live sessions grouped by checkout; an optional collaboration hint, not a lock.",
         "inputSchema": ["type": "object", "properties": ["project": ["type": "string"], "exclude_session": ["type": "string"]], "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
    }

    public static func call(arguments: [String: Any], environment: [String: String] = ProcessInfo.processInfo.environment,
                            fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> String {
        let options = try Options(arguments: arguments, callerID: environment["CODEX_THREAD_ID"])
        guard environment["VIBEBUDDY_PORT"] == nil || environment["VIBEBUDDY_PORT"].flatMap(Int.init) != nil else { return "live status unknown (invalid daemon port)" }
        let port = environment["VIBEBUDDY_PORT"].flatMap(Int.init) ?? 9876
        guard (1...65535).contains(port) else { return "live status unknown (invalid daemon port)" }
        let token = environment["VIBEBUDDY_TOKEN"] ?? TokenStore.defaultStore().load()
        guard let token, !token.isEmpty, !token.contains(where: { $0.isNewline }) else {
            return unknown(port: port)
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/snapshot")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do {
            let (data, response): (Data, URLResponse)
            if let fetch { (data, response) = try await fetch(request) }
            else { (data, response) = try await session.data(for: request) }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  data.count <= 8 * 1024 * 1024 else { return unknown(port: port) }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            return render(snapshot, project: options.project, excludeSession: options.excludeSession)
                .replacingOccurrences(of: token, with: "[redacted]")
        } catch { return unknown(port: port) }
    }

    public static func render(_ snapshot: Snapshot, project: String?, excludeSession: String?) -> String {
        let current = SessionCurrency.current(snapshot.sessions, now: snapshot.serverTime).filter { $0.historyOnly != true }
        let grouped = Dictionary(grouping: current.filter { $0.id != excludeSession }, by: checkout)
        var paths = Set(current.map(checkout)).sorted()
        if let project {
            let matching = project.hasPrefix("/") ? paths.filter { $0 == normalizedPath(project) } : paths.filter { URL(fileURLWithPath: $0).lastPathComponent == project }
            guard matching.count == 1 else {
                return (["Live status: project not found or ambiguous. Known checkouts:"] + paths.map { "- " + line($0) } + ["Collaboration hint only; this observation does not reserve a checkout."]).joined(separator: "\n")
            }
            paths = matching
        }
        paths = paths.filter { !(grouped[$0] ?? []).isEmpty }
        var lines = ["Live status (collaboration hint only)", "Observed: " + ISO8601DateFormatter().string(from: snapshot.serverTime)]
        if excludeSession == nil { lines.append("Caller session unknown; pass --exclude-session with your own session id to exclude it.") }
        if paths.isEmpty { lines.append("No other live sessions found.") }
        for path in paths {
            lines.append("\n## " + line(path))
            let rows = grouped[path, default: []].sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            if rows.contains(where: { $0.status == .working }) {
                lines.append(path.hasPrefix("/") ? "Another agent is working in this checkout." : "An agent is working; checkout directory unknown.")
            }
            for row in rows {
                lines.append("- " + line(row.id) + " | agent: " + row.agent.rawValue + " | " + row.status.rawValue
                    + " | waitKind: " + (row.waitKind?.rawValue ?? "none")
                    + " | controlChannel: " + (ControlChannel.infer(for: row)?.rawValue ?? "unknown")
                    + " | last activity: " + ISO8601DateFormatter().string(from: row.updatedAt))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func checkout(_ session: AgentSession) -> String {
        if let cwd = session.checkoutPath, cwd.hasPrefix("/") { return normalizedPath(cwd) }
        if let cwd = session.terminalRef?.cwd, cwd.hasPrefix("/") { return normalizedPath(cwd) }
        return session.project.hasPrefix("/") ? normalizedPath(session.project) : "unknown checkout (" + session.project + ")"
    }
    private static func normalizedPath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    private static func line(_ text: String) -> String { text.components(separatedBy: .controlCharacters).joined(separator: " ") }
    private static func unknown(port: Int) -> String { "live status unknown (daemon not reachable at 127.0.0.1:\(port))" }

    private struct Options {
        let project: String?
        let excludeSession: String?
        init(arguments: [String: Any], callerID: String?) throws {
            for (key, value) in arguments {
                guard ["project", "exclude_session"].contains(key), value is String else {
                    // Do not echo arbitrary input: it might contain a credential.
                    throw HistoryToolError.invalidArguments("Live status accepts only string project and exclude_session arguments.")
                }
            }
            project = arguments["project"] as? String
            let explicit = arguments["exclude_session"] as? String
            excludeSession = (explicit ?? callerID).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
