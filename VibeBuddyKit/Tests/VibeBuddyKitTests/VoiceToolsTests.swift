import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("VoiceTools — realtime function-calling catalog & decoding")
struct VoiceToolsTests {

    @Test("Qwen and Doubao wire configurations include fresh status and hangup")
    func conversationToolsOnBothWires() throws {
        let expected: Set<String> = ["get_session_status", "end_voice_call", "approve_session", "deny_session", "answer_session",
                                     "mark_read_session", "instruct_session"]
        let qwen = QwenRealtimeSession.sessionConfig(instructions: "test", voice: "Cherry", tools: VoiceTools.conversation)
        let qwenTools = try #require(qwen["tools"] as? [[String: Any]])
        #expect(Set(qwenTools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }) == expected)
        let doubao = DoubaoRealtimeSession.sessionConfig(model: "1.2.6.1", instructions: "test", voice: "zh_female_vv_jupiter_bigtts", tools: VoiceTools.conversation)
        let doubaoTools = try #require(doubao["tools"] as? [[String: Any]])
        #expect(Set(doubaoTools.compactMap { $0["name"] as? String }) == expected)
        #expect(doubaoTools.count == expected.count)
    }

    @Test("mark-read and instruct decode strictly, like the others")
    func markReadAndInstructDecode() {
        #expect(VoiceTools.action(name: "mark_read_session", arguments: #"{"project":"payments-api"}"#) == .markRead(project: "payments-api"))
        #expect(VoiceTools.action(name: "mark_read_session", arguments: #"{"project":"  "}"#) == .none)
        #expect(VoiceTools.action(name: "instruct_session", arguments: #"{"project":"release-check","text":"skip codesign and rebuild"}"#)
                == .instruct(project: "release-check", text: "skip codesign and rebuild"))
        #expect(VoiceTools.action(name: "instruct_session", arguments: #"{"project":"release-check"}"#) == .none)
    }

    @Test("approve/deny require a project; answer requires project and text")
    func requiredParams() {
        func tool(_ n: String) -> VoiceTool { VoiceTools.all.first { $0.name == n }! }
        #expect(tool("approve_session").required == ["project"])
        #expect(tool("deny_session").required == ["project"])
        #expect(Set(tool("answer_session").required) == ["project", "text"])
    }

    // MARK: Decoding — (name, arguments JSON) → VoiceAction

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
}
