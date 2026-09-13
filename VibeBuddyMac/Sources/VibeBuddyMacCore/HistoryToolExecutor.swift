import Foundation
import CoreFoundation

/// Both CLI and MCP route through this entry; new tools add business routing here,
/// never in the protocol adapter. The caller supplies a read-only repository.
public struct HistoryToolExecutor: Sendable {
    public let repository: SessionHistoryRepository
    public init(repository: SessionHistoryRepository) { self.repository = repository }

    public static func requiresIndex(_ name: String) -> Bool {
        ["vibebuddy_list_sessions", "vibebuddy_list_projects"].contains(name)
    }

    public func execute(_ name: String, arguments: [String: Any], isolation: isolated (any Actor)? = #isolation) async throws -> String {
        try HistoryTools.validateArguments(name, arguments: arguments)
        if name == "vibebuddy_get_session" {
            try await repository.reloadReadOnlyMetadata()
            return try await HistoryTools.getSession(arguments: arguments, repository: repository)
        }
        if Self.requiresIndex(name) {
            try await repository.reloadReadOnlyMetadata()
            guard await repository.hasUsableIndex() else { throw HistoryToolError.noIndex }
            let snapshot = await repository.snapshot()
            do { return try HistoryTools.call(name, arguments: arguments, snapshot: snapshot) }
            catch HistoryToolError.invalidArguments(let message) {
                // Shape already passed the schema. Date syntax and other domain
                // failures are tool results that the model can act on.
                throw HistoryToolError.invalidValue(message)
            }
        }
        throw HistoryToolError.executionFailed("Tool execution is unavailable: \(name)")
    }
}

extension HistoryTools {
    /// CLI flags reach the tool layer unchanged. Only this shared layer interprets
    /// their scalar representation; JSON `call` and MCP skip this normalization.
    public static func normalizeCLIArguments(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        let schema = try inputSchema(name)
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        var result = arguments
        for (key, value) in arguments where properties[key]?["type"] as? String == "integer" {
            if let text = value as? String, let integer = Int(text) { result[key] = integer }
        }
        return result
    }

    /// Validate the schema subset used by our definitions. Unknown schema types
    /// fail closed so adding a tool cannot silently weaken input validation.
    public static func validateArguments(_ name: String, arguments: [String: Any]) throws {
        let schema = try inputSchema(name)
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        for key in schema["required"] as? [String] ?? [] where arguments[key] == nil {
            throw HistoryToolError.invalidArguments("Missing argument: \(key)")
        }
        for (key, value) in arguments {
            guard let property = properties[key] else { throw HistoryToolError.invalidArguments("Unknown argument: \(key)") }
            guard matches(value, schema: property) else { throw HistoryToolError.invalidArguments("Invalid argument: \(key)") }
        }
    }

    private static func inputSchema(_ name: String) throws -> [String: Any] {
        guard let definition = definitions().first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any] else {
            throw HistoryToolError.invalidArguments("Unknown tool: \(name)")
        }
        return schema
    }

    private static func matches(_ value: Any, schema: [String: Any]) -> Bool {
        switch schema["type"] as? String {
        case "string":
            guard let text = value as? String else { return false }
            return (schema["enum"] as? [String]).map { $0.contains(text) } ?? true
        case "boolean":
            return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue else { return false }
            if let minimum = schema["minimum"] as? NSNumber, number.doubleValue < minimum.doubleValue { return false }
            if let maximum = schema["maximum"] as? NSNumber, number.doubleValue > maximum.doubleValue { return false }
            return true
        case "array":
            guard let items = value as? [Any], let itemSchema = schema["items"] as? [String: Any] else { return false }
            return items.allSatisfy { matches($0, schema: itemSchema) }
        default: return false
        }
    }
}
