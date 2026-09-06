import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("RecentOutputReader — per-agent formats")
struct RecentOutputReaderTests {

    @Test("Claude transcript keeps user and assistant prose, drops thinking and tool results")
    func claudeFiltersNoise() {
        let lines = [
            claudeUser("fix the flaky test"),
            claudeAssistant(blocks: [
                #"{"type":"thinking","thinking":"I should look around"}"#,
                #"{"type":"text","text":"Looking at the suite."}"#,
            ]),
            claudeToolResult("ok"),
            claudeAssistant(blocks: [#"{"type":"text","text":"Patched the race."}"#]),
        ]
        let slice = RecentOutputReader.claude(tail: data(lines))
        #expect(slice.entries.map(\.role) == ["user", "assistant", "assistant"])
        #expect(slice.entries.map(\.text) == [
            "fix the flaky test", "Looking at the suite.", "Patched the race.",
        ])
        #expect(!slice.truncated)
    }

    @Test("Claude marks truncation when the window or a line is cut")
    func claudeTruncates() {
        let lines = [
            claudeAssistant(blocks: [#"{"type":"text","text":"line 1"}"#]),
            claudeAssistant(blocks: [#"{"type":"text","text":"line 2"}"#]),
            claudeAssistant(blocks: [#"{"type":"text","text":"line 3"}"#]),
            claudeAssistant(blocks: [#"{"type":"text","text":"line 4"}"#]),
        ]
        let limited = RecentOutputReader.claude(tail: data(lines), limit: 2)
        #expect(limited.entries.map(\.text) == ["line 3", "line 4"])
        #expect(limited.truncated)

        let long = claudeAssistant(blocks: [#"{"type":"text","text":"abcdefghij"}"#])
        let cut = RecentOutputReader.claude(tail: data([long]), perEntryLimit: 5)
        #expect(cut.entries.map(\.text) == ["abcde"])
        #expect(cut.truncated)
    }

    @Test("Codex rollout keeps dialogue and tool names, drops reasoning and tool output")
    func codexRolloutFiltersNoise() {
        let lines = [
            #"{"timestamp":"2026-09-02T01:00:00Z","type":"session_meta","payload":{"id":"thread-1"}}"#,
            #"{"timestamp":"2026-09-02T01:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the flaky test"}]}}"#,
            #"{"timestamp":"2026-09-02T01:00:02Z","type":"response_item","payload":{"type":"reasoning","summary":[{"text":"secret chain"}]}}"#,
            #"{"timestamp":"2026-09-02T01:00:03Z","type":"response_item","payload":{"type":"function_call","name":"exec","call_id":"c1"}}"#,
            #"{"timestamp":"2026-09-02T01:00:04Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"full terminal dump"}}"#,
            #"{"timestamp":"2026-09-02T01:00:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Patched the race."}]}}"#,
        ]
        let slice = RecentOutputReader.codexRollout(tail: data(lines))
        #expect(slice.entries.map(\.role) == ["user", "assistant", "assistant"])
        #expect(slice.entries.map(\.text) == [
            "fix the flaky test", "⚙ exec", "Patched the race.",
        ])
        #expect(slice.updatedAt != nil)
        #expect(!slice.truncated)
    }

    @Test("Codex rollout does not duplicate task_complete text already captured")
    func codexRolloutDedupesCompletion() {
        let lines = [
            #"{"timestamp":"2026-09-02T01:00:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}"#,
            #"{"timestamp":"2026-09-02T01:00:06Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Done"}}"#,
        ]
        let slice = RecentOutputReader.codexRollout(tail: data(lines))
        #expect(slice.entries.map(\.text) == ["Done"])
    }

    @Test("Codex app-server items keep user/agent text and skip reasoning plus tool output")
    func codexAppServerFiltersNoise() {
        let items: [[String: Any]] = [
            ["type": "userMessage", "text": "fix the flaky test"],
            ["type": "reasoning", "text": "secret chain"],
            ["type": "commandExecution", "command": "git status", "aggregatedOutput": "full terminal dump"],
            ["type": "agentMessage", "text": "Patched the race."],
        ]
        let slice = RecentOutputReader.codexAppServer(items: items)
        #expect(slice.entries.map(\.role) == ["user", "assistant", "assistant"])
        #expect(slice.entries.map(\.text) == [
            "fix the flaky test", "⚙ Shell", "Patched the race.",
        ])
    }

    private func data(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    private func claudeUser(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func claudeAssistant(blocks: [String]) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[\#(blocks.joined(separator: ","))]}}"#
    }

    private func claudeToolResult(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"\#(text)"}]}}"#
    }
}
