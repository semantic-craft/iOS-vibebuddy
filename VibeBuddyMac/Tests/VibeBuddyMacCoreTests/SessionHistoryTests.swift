import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class SessionHistoryTests: XCTestCase {
    func testInjectedContextIsRetainedButDoesNotBecomeTitle() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = ["<recommended_plugins>setup</recommended_plugins>", "# AGENTS.md instructions for /tmp", "真实任务标题"]
        let data = try lines.map { text in
            try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
        }.reduce(into: Data()) { $0.append($1); $0.append(10) }
        try data.write(to: file)
        let record = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        XCTAssertEqual(record.title, "真实任务标题")
        XCTAssertEqual(record.messageCount, 3)
    }

    func testCodexMirrorDoesNotConsumeEarlierEventOnlyTurn() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"continue"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"first answer"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"continue"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"continue"}]}}"#
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        let session = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        XCTAssertEqual(session.messages.map(\.text), ["continue", "first answer", "continue"])
    }

    func testCodexMessageIdentitySurvivesSourcePrepend() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let existing = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"original target"}]}}"#
        let prepended = existing.replacingOccurrences(of: "original target", with: "unrelated new message")
        try Data(existing.utf8).write(to: file)
        let before = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        try Data((prepended + "\n" + existing).utf8).write(to: file)
        let after = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        XCTAssertEqual(after.messages.first(where: { $0.id == before.messages[0].id })?.text, "original target")
        XCTAssertNotEqual(after.messages[0].id, before.messages[0].id)
    }

    func testCanonicalCodexMessagesDoNotDuplicateEventMirrorsAndToolsExport() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"request"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"request"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"echo hello"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"```sample```"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"event-only answer"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"request"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","channel":"analysis","content":[{"type":"output_text","text":"private reasoning"}]}}"#
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        let session = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        XCTAssertEqual(session.messages.count, 6)
        XCTAssertEqual(session.messages.last(where: { $0.kind != .thinking })?.text, "request")
        XCTAssertTrue(session.messages.contains { $0.text == "event-only answer" })
        XCTAssertEqual(session.messages[1].toolName, "shell")
        XCTAssertTrue(session.messages.contains { $0.kind == .thinking && $0.text == "private reasoning" })
        XCTAssertFalse(SessionHistoryExport.markdown(session: session).contains("private reasoning"))
        XCTAssertTrue(SessionHistoryExport.markdown(session: session).contains("````text"))
    }
}
