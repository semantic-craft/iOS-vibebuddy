import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("TranscriptReader — JSONL tail parsing")
struct TranscriptReaderTests {

    private func assistant(text: String, model: String = "claude-opus-4-8",
                           inTok: Int = 1000, outTok: Int = 200) -> String {
        #"{"type":"assistant","message":{"role":"assistant","model":"\#(model)","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(inTok),"output_tokens":\#(outTok)}}}"#
    }

    private let userLine =
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"continue"}]}}"#

    private func parse(_ lines: [String]) -> TranscriptInfo {
        TranscriptReader.parse(tail: Data(lines.joined(separator: "\n").utf8))
    }

    @Test("extracts model, summed tokens, and summary from an assistant line")
    func basics() {
        let info = parse([assistant(text: "Wrote section 2.", inTok: 1000, outTok: 234)])
        #expect(info.model == "claude-opus-4-8")
        #expect(info.tokens == 1234)
        #expect(info.summary == "Wrote section 2.")
    }

    @Test("contextTokens = input + cache_read + cache_creation (the prompt actually sent)")
    func contextTokens() {
        let line = #"{"message":{"role":"assistant","model":"m","content":"hi","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":12000,"cache_creation_input_tokens":8000}}}"#
        let info = parse([line])
        #expect(info.tokens == 1200)            // turn cost unchanged
        #expect(info.contextTokens == 21000)    // 1000 + 12000 + 8000
    }

    @Test("contextTokens falls back to input+output when no cache fields present")
    func contextTokensNoCache() {
        let info = parse([assistant(text: "x", inTok: 1000, outTok: 200)])
        #expect(info.contextTokens == 1000)     // input only; no cache fields
    }

    @Test("uses the most recent assistant message for the summary")
    func mostRecent() {
        let info = parse([assistant(text: "old"), userLine, assistant(text: "newest")])
        #expect(info.summary == "newest")
    }

    @Test("ignores non-assistant lines")
    func ignoresUser() {
        let info = parse([userLine])
        #expect(info == TranscriptInfo())
    }

    @Test("handles content given as a plain string")
    func stringContent() {
        let line = #"{"message":{"role":"assistant","model":"m","content":"plain text reply","usage":{"input_tokens":5,"output_tokens":5}}}"#
        let info = parse([line])
        #expect(info.summary == "plain text reply")
        #expect(info.tokens == 10)
    }

    @Test("collapses whitespace and truncates to the limit")
    func collapseTruncate() {
        let multiline = #"{"message":{"role":"assistant","content":[{"type":"text","text":"a\n\n   b\t c"}]}}"#
        #expect(TranscriptReader.parse(tail: Data(multiline.utf8)).summary == "a b c")
        let long = #"{"message":{"role":"assistant","content":"abcdefghij"}}"#
        #expect(TranscriptReader.parse(tail: Data(long.utf8), summaryLimit: 5).summary == "abcde")
    }

    @Test("a broken leading line (tail cut mid-record) is skipped")
    func partialFirstLine() {
        let broken = "ken\":\"value\"}"
        let info = parse([broken, assistant(text: "ok")])
        #expect(info.summary == "ok")
    }

    @Test("empty input yields empty info")
    func empty() {
        #expect(parse([]) == TranscriptInfo())
    }

    @Test("extracts the latest AskUserQuestion prompt and options")
    func askUserQuestion() {
        let line = """
        {"message":{"role":"assistant","model":"m","content":[{"type":"tool_use","id":"toolu_q1","name":"AskUserQuestion","input":{"questions":[{"id":"branch","question":"Which branch should I use?","options":[{"id":"main","label":"main","description":"Use the current branch"},{"id":"new","label":"new branch","value":"create a new branch"}]}]}}],"usage":{"input_tokens":5,"output_tokens":1}}}
        """
        let info = parse([line])
        #expect(info.pendingQuestion?.id == "branch")
        #expect(info.pendingQuestion?.prompt == "Which branch should I use?")
        #expect(info.pendingQuestion?.options.map(\.label) == ["main", "new branch"])
        #expect(info.pendingQuestion?.options.map(\.value) == ["main", "create a new branch"])
    }

    @Test("AskUserQuestion accepts string options")
    func askUserQuestionStringOptions() {
        let line = """
        {"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q1","name":"ask_question","input":{"prompt":"Pick one","options":["main","new branch"]}}]}}
        """
        let info = parse([line])
        #expect(info.pendingQuestion?.id == "toolu_q1")
        #expect(info.pendingQuestion?.prompt == "Pick one")
        #expect(info.pendingQuestion?.options.map(\.value) == ["main", "new branch"])
    }

    @Test("AskUserQuestion without a prompt is ignored")
    func askUserQuestionWithoutPromptIgnored() {
        let line = """
        {"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_q1","name":"AskUserQuestion","input":{"options":["main"]}}]}}
        """
        let info = parse([line])
        #expect(info.pendingQuestion == nil)
    }

    @Test("read(path:) parses the tail of a file")
    func readFile() throws {
        let tmp = NSTemporaryDirectory() + "vb-transcript-\(UUID().uuidString).jsonl"
        let content = [userLine, assistant(text: "from file", inTok: 7, outTok: 3)]
            .joined(separator: "\n")
        try content.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let info = TranscriptReader.read(path: tmp)
        #expect(info?.summary == "from file")
        #expect(info?.tokens == 10)
        #expect(info?.model == "claude-opus-4-8")
    }

    @Test("read(path:) returns nil for a missing file")
    func readMissing() {
        #expect(TranscriptReader.read(path: "/no/such/file.jsonl") == nil)
    }
}
