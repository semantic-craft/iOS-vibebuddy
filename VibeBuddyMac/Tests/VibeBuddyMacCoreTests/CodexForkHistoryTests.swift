import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Codex fork transcript ownership")
struct CodexForkHistoryTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        func reader() -> SessionTranscriptReader {
            SessionTranscriptReader(claudeHome: root, codexHome: root, cursorHome: root)
        }
        func write(_ id: String, fork: Bool = false) throws -> URL {
            let file = root.appendingPathComponent("sessions/\(id).jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = [#"{"type":"session_meta","payload":{"id":"OWNER","cwd":"/owner","originator":"Codex Desktop","source":"vscode"}}"#.replacingOccurrences(of: "OWNER", with: id)]
            if fork {
                lines.append(#"{"type":"session_meta","payload":{"id":"parent","cwd":"/ancestor","source":{"subagent":"spawn"}}}"#)
                lines.append(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"inheritedneedle"}]}}"#)
            }
            lines.append(#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OWNERneedle"}]}}"#.replacingOccurrences(of: "OWNER", with: id))
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            return file
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func firstEnvelopeOwnsIdentityAndProvenance() throws {
        let f = Fixture(); defer { f.remove() }
        let file = try f.write("child", fork: true)
        let session = try SessionHistoryParser.read(url: file, agent: .codex, updatedAt: Date())
        #expect(session.id == "codex:child")
        #expect(session.projectPath == "/owner" && session.source == "desktop")
        #expect(session.messages.contains { $0.text == "inheritedneedle" })
        #expect(session.warnings.contains { $0.contains("parent") })
    }

    @Test func readerKeepsParentAndChildApartAndRefusesDuplicateOwners() async throws {
        let f = Fixture(); defer { f.remove() }
        let parent = try f.write("parent")
        _ = try f.write("child", fork: true)
        let reader = f.reader()
        for id in ["parent", "child"] {
            #expect(try await reader.readTranscript(key: "codex:" + id).session.nativeSessionID == id)
        }
        // Genuine duplicate owner sources stay ambiguous; the reader never picks one.
        try Data(contentsOf: parent).write(to: parent.deletingLastPathComponent().appendingPathComponent("rollout-x-parent.jsonl"))
        do {
            _ = try await f.reader().readTranscript(key: "codex:parent")
            Issue.record("Duplicate owner was silently selected")
        } catch { #expect(String(describing: error).contains("Ambiguous session key")) }
    }

    @Test func phoneAndMacReadParentAndChildSeparately() async throws {
        let f = Fixture(); defer { f.remove() }
        _ = try f.write("parent"); _ = try f.write("child", fork: true)
        let http = HistoryHTTPReader(reader: f.reader())
        for id in ["parent", "child"] {
            let key = "codex:" + id
            let mac = try await f.reader().readTranscript(key: key)
            let response = await http.read(uri: "/history?sourceID=mac&key=" + key, sourceID: "mac")
            #expect(response.status == 200)
            let page = try JSONDecoder().decode(HistoryPage.self, from: response.data)
            #expect(page.key == key)
            #expect(page.messages.map(\.text) == mac.session.messages.map(\.text))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_FORK_FIXTURES"] != nil))
    func realCopiesUseTheTranscriptReader() async throws {
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VIBEBUDDY_FORK_FIXTURES"]))
        let f = Fixture(); defer { f.remove() }
        let sessions = f.root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var owners: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" {
            let data = try Data(contentsOf: file)
            let first = try #require(data.split(separator: 10).first)
            let root = try #require(JSONSerialization.jsonObject(with: Data(first)) as? [String: Any])
            let payload = try #require(root["payload"] as? [String: Any])
            let owner = try #require(payload["id"] as? String)
            owners.append(owner)
            let copy = sessions.appendingPathComponent(file.lastPathComponent)
            try data.write(to: copy)
            var parser = CodexRolloutParser()
            var lastCompletion: (turn: String, text: String)?
            var emittedOwners = Set<String>()
            for line in data.split(separator: 10) {
                for event in parser.parseEvents(Data(line), receivedAt: Date()) {
                    emittedOwners.insert(event.sessionID)
                }
                if let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   row["type"] as? String == "event_msg", let event = row["payload"] as? [String: Any],
                   event["type"] as? String == "task_complete", let turn = event["turn_id"] as? String,
                   let text = event["last_agent_message"] as? String { lastCompletion = (turn, text) }
            }
            #expect(parser.sessionID == owner)
            let subagent = payload["thread_source"] as? String == "subagent"
            #expect(subagent ? emittedOwners.isEmpty : emittedOwners == [owner])
            let completion = try #require(lastCompletion)
            let result = CodexCompletionReader.read(path: copy.path, sessionID: owner, turnID: completion.turn)
            if data.split(separator: 10).contains(where: { $0.count > 2 * 1024 * 1024 }) {
                // Preserve the completion reader's existing per-record safety limit.
                // This is an explicit completion gap, not a history identity failure.
                #expect(throws: CodexCompletionReader.Failure.readLimitExceeded) { try result.get() }
                print("Real completion NOT covered owner=\(owner): source contains a record above the existing 2 MiB limit")
            } else {
                let recovered = try result.get()
                #expect(recovered.text == completion.text)
                print("Real fork completion owner=\(owner) turn=\(completion.turn) chars=\(recovered.text.count) subagent=\(subagent)")
            }
        }
        #expect(owners.count == 2)
        let reader = f.reader()
        for id in owners {
            // This is SessionReaderModel's exact readTranscript(key:) entry point.
            let transcript = try await reader.readTranscript(key: "codex:" + id)
            #expect(transcript.session.nativeSessionID == id)
            #expect(!transcript.session.messages.isEmpty)
            print("Real fork copy owner=\(id) records=\(transcript.session.messages.count)")
        }
    }

}
