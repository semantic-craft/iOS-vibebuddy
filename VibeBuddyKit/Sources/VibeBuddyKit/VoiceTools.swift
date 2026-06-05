import Foundation

/// One function-calling tool offered to a realtime voice session, in a
/// provider-agnostic shape. Each provider serializes it onto its own wire format
/// (`functionSchema()` for the OpenAI-Realtime-style providers, including Qwen;
/// `geminiDeclaration()` for Gemini Live). `Sendable` so it can cross into the
/// provider actors.
public struct VoiceTool: Sendable {
    public let name: String
    public let description: String
    public let parameters: [Parameter]
    public let required: [String]

    public struct Parameter: Sendable {
        public let name: String
        public let type: String        // JSON-schema type, e.g. "string"
        public let description: String
    }

    /// The JSON-schema object describing this tool's parameters. OpenAI/Qwen use
    /// lowercase JSON-schema types (`object`/`string`); Gemini's `Schema.type` is
    /// the proto enum name (`OBJECT`/`STRING`), so it needs the uppercase variant.
    private func parametersSchema(uppercaseTypes: Bool) -> [String: Any] {
        func ty(_ s: String) -> String { uppercaseTypes ? s.uppercased() : s }
        var properties: [String: Any] = [:]
        for p in parameters {
            properties[p.name] = ["type": ty(p.type), "description": p.description]
        }
        return ["type": ty("object"), "properties": properties, "required": required]
    }

    /// OpenAI Realtime (GA) / Qwen-Omni flat function-tool object for
    /// `session.tools` — `{type:"function", name, description, parameters}`.
    public func functionSchema() -> [String: Any] {
        ["type": "function", "name": name, "description": description,
         "parameters": parametersSchema(uppercaseTypes: false)]
    }

    /// Gemini Live `functionDeclarations[]` entry — same fields, but **not**
    /// wrapped in `{type:"function"}`, and with uppercase proto-enum types.
    public func geminiDeclaration() -> [String: Any] {
        ["name": name, "description": description, "parameters": parametersSchema(uppercaseTypes: true)]
    }
}

/// The companion's action tools and the decoder that turns a model-emitted tool
/// call back into a `VoiceAction`. Pure & unit-tested: because approve/deny run
/// real commands on the Mac, decoding is deliberately strict — anything missing,
/// empty, or unrecognized resolves to `.none` and nothing executes.
public enum VoiceTools {
    public static let all: [VoiceTool] = [
        VoiceTool(
            name: "approve_session",
            description: "Approve the pending permission request for a coding session. "
                + "Only call this when the user clearly and explicitly asks to approve a specific session — "
                + "never from ambiguous or conversational mentions of approval.",
            parameters: [
                .init(name: "project", type: "string",
                      description: "The project name of the session to approve, taken from the session list."),
            ],
            required: ["project"]),
        VoiceTool(
            name: "deny_session",
            description: "Deny (reject) the pending permission request for a coding session. "
                + "Only call this when the user clearly and explicitly asks to deny a specific session.",
            parameters: [
                .init(name: "project", type: "string",
                      description: "The project name of the session to deny, taken from the session list."),
            ],
            required: ["project"]),
        VoiceTool(
            name: "answer_session",
            description: "Send a typed answer to a coding session that is waiting for the user's reply. "
                + "Only call this when the user clearly states what to answer.",
            parameters: [
                .init(name: "project", type: "string",
                      description: "The project name of the session to answer, taken from the session list."),
                .init(name: "text", type: "string",
                      description: "The exact answer to send to the session."),
            ],
            required: ["project", "text"]),
    ]

    /// Decode a tool call `(name, JSON arguments)` into a `VoiceAction`. Returns
    /// `.none` for any unknown tool, malformed JSON, or missing/blank field, so a
    /// consequential action is never synthesized from garbage.
    public static func action(name: String, arguments: String) -> VoiceAction {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .none
        }
        func nonEmpty(_ key: String) -> String? {
            guard let raw = obj[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        switch name {
        case "approve_session":
            guard let project = nonEmpty("project") else { return .none }
            return .approve(project: project)
        case "deny_session":
            guard let project = nonEmpty("project") else { return .none }
            return .deny(project: project)
        case "answer_session":
            guard let project = nonEmpty("project"), let text = nonEmpty("text") else { return .none }
            return .answer(project: project, text: text)
        default:
            return .none
        }
    }
}
