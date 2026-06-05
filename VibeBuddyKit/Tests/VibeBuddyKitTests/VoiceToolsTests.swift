import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("VoiceTools — realtime function-calling catalog & decoding")
struct VoiceToolsTests {

    // MARK: Catalog — the three tools the model is given

    @Test("the catalog exposes approve, deny, and answer tools")
    func catalog() {
        let names = Set(VoiceTools.all.map(\.name))
        #expect(names == ["approve_session", "deny_session", "answer_session"])
    }

    @Test("approve/deny require a project; answer requires project and text")
    func requiredParams() {
        func tool(_ n: String) -> VoiceTool { VoiceTools.all.first { $0.name == n }! }
        #expect(tool("approve_session").required == ["project"])
        #expect(tool("deny_session").required == ["project"])
        #expect(Set(tool("answer_session").required) == ["project", "text"])
    }

    // MARK: Decoding — (name, arguments JSON) → VoiceAction

    @Test("an approve tool call decodes to .approve")
    func decodeApprove() {
        let action = VoiceTools.action(name: "approve_session",
                                       arguments: #"{"project":"todo-app"}"#)
        #expect(action == .approve(project: "todo-app"))
    }

    @Test("a deny tool call decodes to .deny")
    func decodeDeny() {
        let action = VoiceTools.action(name: "deny_session",
                                       arguments: #"{"project":"docs-site"}"#)
        #expect(action == .deny(project: "docs-site"))
    }

    @Test("an answer tool call decodes project and text")
    func decodeAnswer() {
        let action = VoiceTools.action(name: "answer_session",
                                       arguments: #"{"project":"docs-review","text":"use the main branch"}"#)
        #expect(action == .answer(project: "docs-review", text: "use the main branch"))
    }

    @Test("surrounding whitespace in arguments is trimmed")
    func trimsWhitespace() {
        let action = VoiceTools.action(name: "approve_session",
                                       arguments: #"{"project":"  payments-api  "}"#)
        #expect(action == .approve(project: "payments-api"))
    }

    // MARK: Safety — never resolve a consequential action from garbage

    @Test("an unknown tool name decodes to .none")
    func unknownTool() {
        #expect(VoiceTools.action(name: "delete_everything",
                                  arguments: #"{"project":"x"}"#) == .none)
    }

    @Test("a missing or empty project never approves")
    func emptyProjectRejected() {
        #expect(VoiceTools.action(name: "approve_session", arguments: #"{}"#) == .none)
        #expect(VoiceTools.action(name: "approve_session", arguments: #"{"project":""}"#) == .none)
        #expect(VoiceTools.action(name: "approve_session", arguments: #"{"project":"   "}"#) == .none)
    }

    @Test("an answer with empty text is rejected")
    func emptyAnswerTextRejected() {
        #expect(VoiceTools.action(name: "answer_session",
                                  arguments: #"{"project":"api","text":""}"#) == .none)
        #expect(VoiceTools.action(name: "answer_session",
                                  arguments: #"{"project":"api"}"#) == .none)
    }

    @Test("malformed JSON arguments decode to .none")
    func malformedJSON() {
        #expect(VoiceTools.action(name: "approve_session", arguments: "not json") == .none)
        #expect(VoiceTools.action(name: "approve_session", arguments: "") == .none)
    }

    // MARK: Wire schema — what each provider serializes onto the wire

    @Test("the OpenAI/Qwen function schema uses lowercase JSON-schema types")
    func openAISchema() {
        let approve = VoiceTools.all.first { $0.name == "approve_session" }!
        let schema = approve.functionSchema()
        #expect(schema["type"] as? String == "function")
        #expect(schema["name"] as? String == "approve_session")
        let params = schema["parameters"] as? [String: Any]
        #expect(params?["type"] as? String == "object")
        #expect((params?["required"] as? [String]) == ["project"])
        let props = params?["properties"] as? [String: Any]
        let project = props?["project"] as? [String: Any]
        #expect(project?["type"] as? String == "string")
    }

    @Test("the Gemini declaration uses uppercase proto enum types and no wrapper type")
    func geminiSchema() {
        let answer = VoiceTools.all.first { $0.name == "answer_session" }!
        let decl = answer.geminiDeclaration()
        #expect(decl["name"] as? String == "answer_session")
        #expect(decl["type"] == nil)   // Gemini declarations are not wrapped in {type:"function"}
        let params = decl["parameters"] as? [String: Any]
        #expect(params?["type"] as? String == "OBJECT")   // Gemini Schema.type is the proto enum name
        let props = params?["properties"] as? [String: Any]
        let project = props?["project"] as? [String: Any]
        #expect(project?["type"] as? String == "STRING")
        #expect(props?["text"] != nil)
    }
}
