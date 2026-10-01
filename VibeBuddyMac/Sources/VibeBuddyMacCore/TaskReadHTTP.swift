import Foundation
import VibeBuddyKit

/// Per-server ephemeral cursor bindings. No thread control or completion mutation.
public actor TaskReadHTTP {
    public typealias Fetch = @Sendable (String, TaskReadKind, String?) async -> TaskReadResponse
    private struct Cursor { let source: String; let session: String; let kind: TaskReadKind; let native: String; let issued: Date }
    private var cursors: [String: Cursor] = [:]
    public init() {}
    public func read(uri: String, sourceID: String?, sessions: [AgentSession], fetch: Fetch) async -> HistoryHTTPReader.Result {
        func failure(_ status: Int, _ reason: String) -> HistoryHTTPReader.Result {
            .init(status: status, data: (try? JSONEncoder().encode(HistoryFailure(reason))) ?? Data())
        }
        guard uri.utf8.count < 4096, let parts = URLComponents(string: uri), let items = parts.queryItems,
              items.allSatisfy({ $0.value != nil }), Set(items.map(\.name)).count == items.count,
              Set(items.map(\.name)).isSubset(of: ["sourceID", "sessionID", "kind", "cursor"]) else { return failure(400, "invalid_request") }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard let requested = values["sourceID"], let id = values["sessionID"], !id.isEmpty,
              let kind = values["kind"].flatMap(TaskReadKind.init(rawValue:)) else { return failure(400, "invalid_request") }
        guard let sourceID, requested == sourceID else { return failure(409, "source_changed") }
        guard sessions.contains(where: { $0.id == id && $0.agent == .codex }) else { return failure(404, "session_not_found") }
        cursors = cursors.filter { Date().timeIntervalSince($0.value.issued) < 300 }
        var native: String?
        if let token = values["cursor"] {
            guard kind != .goal, let cursor = cursors[token], cursor.source == sourceID,
                  cursor.session == id, cursor.kind == kind else { return failure(409, "cursor_expired") }
            native = cursor.native
        }
        var result = await fetch(id, kind, native)
        result.sourceID = sourceID; result.sessionID = id; result.kind = kind
        if let next = result.nextCursor {
            let token = UUID().uuidString
            if cursors.count >= 256, let oldest = cursors.min(by: { $0.value.issued < $1.value.issued })?.key { cursors.removeValue(forKey: oldest) }
            cursors[token] = Cursor(source: sourceID, session: id, kind: kind, native: next, issued: Date())
            result.nextCursor = token
        }
        guard let data = try? JSONEncoder().encode(result), data.count <= 1_048_576 else { return failure(422, "message_exceeds_budget") }
        return .init(status: 200, data: data)
    }
}

extension CodexAppServerMonitor {
    public func phoneTaskRead(sessionID: String, kind: TaskReadKind, cursor: String?) async -> TaskReadResponse {
        var response = TaskReadResponse(sourceID: "", sessionID: sessionID, kind: kind)
        switch kind {
        case .goal:
            switch await taskGoal(threadID: sessionID) {
            case .success(let goal): response.goal = goal
            case .failure(let error): response.failure = String(describing: error)
            }
        case .terminals:
            switch await backgroundTerminals(threadID: sessionID, cursor: cursor) {
            case .success(let page): response.terminals = page.data; response.nextCursor = page.nextCursor
            case .failure(let error): response.failure = String(describing: error)
            }
        case .history:
            switch await historyPage(threadID: sessionID, cursor: cursor) {
            case .success(let page):
                do {
                    response.messages = try JSONDecoder().decode([HistoryMessage].self, from: JSONEncoder().encode(page.messages.filter { $0.kind != .thinking && $0.kind != .meta }))
                    response.nextCursor = page.nextCursor
                } catch { response.failure = "malformed" }
            case .failure(let error): response.failure = String(describing: error)
            }
        }
        return response
    }
}
