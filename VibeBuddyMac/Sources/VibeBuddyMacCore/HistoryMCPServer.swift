import Foundation
import CoreFoundation

/// A single stdio connection. Only read-only tools are advertised; application
/// execution is delegated unchanged to the same executor the CLI uses.
@MainActor
public final class HistoryMCPServer {
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private let executor: HistoryToolExecutor
    private var initialized = false

    public init(executor: HistoryToolExecutor) { self.executor = executor }

    /// One newline-delimited frame in; one JSON frame out (without its delimiter).
    /// Notifications never produce a response, including unknown notifications.
    public func response(to data: Data) async throws -> Data? {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { return try encodeError(id: NSNull(), code: -32700, message: "Parse error") }
        guard let request = object as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return try encodeError(id: NSNull(), code: -32600, message: "Invalid request")
        }
        guard let id = request["id"] else { return nil }
        guard Self.validID(id) else { return try encodeError(id: NSNull(), code: -32600, message: "Invalid request id") }
        do {
            guard request["params"] == nil || request["params"] is [String: Any] else {
                throw HistoryToolError.invalidArguments("params must be an object")
            }
            let params = request["params"] as? [String: Any] ?? [:]
            let result: [String: Any]
            switch method {
            case "initialize":
                guard !initialized, let version = params["protocolVersion"] as? String,
                      params["capabilities"] is [String: Any],
                      let client = params["clientInfo"] as? [String: Any],
                      client["name"] is String, client["version"] is String else {
                    throw HistoryToolError.invalidArguments("initialize requires protocolVersion, capabilities and clientInfo; initialize once per connection")
                }
                initialized = true
                result = ["protocolVersion": Self.protocolVersions.contains(version) ? version : Self.protocolVersions[0],
                          "capabilities": ["tools": ["listChanged": false]],
                          "serverInfo": ["name": "vibebuddy", "version": "1.0.0"]]
            case "ping": result = [:]
            case "tools/list":
                guard initialized else { throw HistoryToolError.invalidArguments("Initialize the connection first") }
                guard params["cursor"] == nil else { throw HistoryToolError.invalidArguments("This tool list is not paginated") }
                result = ["tools": HistoryTools.definitions()]
            case "tools/call":
                guard initialized else { throw HistoryToolError.invalidArguments("Initialize the connection first") }
                guard let name = params["name"] as? String,
                      params["arguments"] == nil || params["arguments"] is [String: Any] else {
                    throw HistoryToolError.invalidArguments("tools/call requires a name and an arguments object")
                }
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                do {
                    let text = try await executor.execute(name, arguments: arguments)
                    result = Self.toolResult(text, isError: false)
                } catch HistoryToolError.invalidArguments(let message) {
                    throw HistoryToolError.invalidArguments(message)
                } catch {
                    result = Self.toolResult(error.localizedDescription, isError: true)
                }
            default: return try encodeError(id: id, code: -32601, message: "Method not found")
            }
            return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: [.sortedKeys])
        } catch HistoryToolError.invalidArguments(let message) {
            return try encodeError(id: id, code: -32602, message: message)
        }
    }

    private static func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }
    private static func validID(_ value: Any) -> Bool {
        if value is String { return true }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
    }
    private func encodeError(id: Any, code: Int, message: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]], options: [.sortedKeys])
    }
}
