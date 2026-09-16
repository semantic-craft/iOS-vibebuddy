import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("Exact Codex completion recovery")
struct CodexCompletionReaderTests {
    private func record(_ payload: [String: Any], type: String = "event_msg", seconds: Int = 1) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": type, "timestamp": "2026-09-15T12:00:0\(seconds)Z", "payload": payload])
        return String(decoding: data, as: UTF8.self)
    }

    @Test("Exact identity, partial writes, abort and permanent conflicts")
    func readerRejectsUnsafeEvidence() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let meta = try record(["id": "session"], type: "session_meta")
        let start = try record(["type": "task_started", "turn_id": "A"])
        let complete = try record(["type": "task_complete", "turn_id": "A", "last_agent_message": "Exact A"], seconds: 2)
        func write(_ lines: [String], newline: Bool = true) throws {
            try (lines.joined(separator: "\n") + (newline ? "\n" : "")).write(to: file, atomically: true, encoding: .utf8)
        }
        func read(_ session: String = "session", _ turn: String = "A") -> Result<CodexCompletionReader.CompletedTurn, CodexCompletionReader.Failure> {
            CodexCompletionReader.read(path: file.path, sessionID: session, turnID: turn)
        }
        try write([meta, start, complete])
        #expect(try read().get().text == "Exact A")
        #expect(throws: CodexCompletionReader.Failure.sessionMismatch) { try read("other").get() }
        #expect(throws: CodexCompletionReader.Failure.missingBoundary) { try read("session", "B").get() }
        let inherited = try record(["id": "parent"], type: "session_meta")
        try write([meta, inherited, start, complete])
        #expect(try read().get().text == "Exact A")
        #expect(throws: CodexCompletionReader.Failure.sessionMismatch) { try read("parent").get() }
        try write([meta, start, complete], newline: false)
        #expect(throws: CodexCompletionReader.Failure.notCompleted) { try read().get() }
        try write([meta, start, complete, complete])
        #expect(try read().get().text == "Exact A")
        let changed = try record(["type": "task_complete", "turn_id": "A", "last_agent_message": "Different"], seconds: 2)
        try write([meta, start, complete, changed, complete])
        #expect(throws: CodexCompletionReader.Failure.conflict) { try read().get() }
        let abort = try record(["type": "turn_aborted", "turn_id": "A"], seconds: 2)
        try write([meta, start, abort, complete])
        #expect(throws: CodexCompletionReader.Failure.aborted) { try read().get() }
        try write([meta, start, complete])
        #expect(throws: CodexCompletionReader.Failure.readLimitExceeded) {
            try CodexCompletionReader.read(path: file.path, sessionID: "session", turnID: "A", maxBytes: 16).get()
        }
    }

    @Test("Real 460/455 character records through first-discovery monitor",
          .enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_COMPLETION_FIXTURES"] != nil))
    func realMonitorFixtures() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VIBEBUDDY_COMPLETION_FIXTURES"]))
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("targets.json"))) as? [String: [String: String]])
        var lengths: [Int] = []
        for (sessionID, target) in manifest {
            let fixture = directory.appendingPathComponent(try #require(target["fixture"]))
            var lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map(String.init)
            // Restore only the actual source's discovery metadata, which the
            // prototype's privacy-minimized fixture intentionally omitted.
            let original = try String(contentsOfFile: #require(target["originPath"]), encoding: .utf8)
            lines[0] = try #require(original.split(separator: "\n").first).description
            // The extracted prototype uses spaced JSON; Codex writes compact
            // JSON and the production progress prefilter expects that encoding.
            lines = try lines.map { line in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
                return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("rollout-real.jsonl")
            try (lines.prefix(3).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            let monitor = CodexRolloutMonitor(root: root)
            let discovered = await monitor.poll(now: Date())
            let initial = try #require(discovered.first)
            #expect(initial.kind == .preToolUse)
            #expect(initial.turnID == target["turnID"])
            #expect(initial.turnStartedAt != nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((lines.dropFirst(3).joined(separator: "\n") + "\n").utf8))
            try handle.close()
            let ended = await monitor.poll(now: Date())
            let completion = try #require(ended.last { $0.completionSucceeded == true })
            let body = try CodexCompletionReader.read(path: file.path, sessionID: sessionID, turnID: #require(target["turnID"])).get()
            #expect(completion.completionText == body.text)
            var sequential = CodexRolloutParser()
            let control = lines.flatMap { sequential.parseEvents(Data($0.utf8), receivedAt: Date()) }.last { $0.completionSucceeded == true }
            #expect(control?.completionText == body.text)
            lengths.append(body.text.count)
            #expect(await CodexRolloutMonitor(root: root).poll(now: Date()).isEmpty)
            // A second real discovery window: final_answer is present but its
            // native successful task_complete has not reached disk yet.
            try (lines.dropLast().joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            let gapMonitor = CodexRolloutMonitor(root: root)
            #expect(await gapMonitor.poll(now: Date()).isEmpty)
            let gapHandle = try FileHandle(forWritingTo: file)
            try gapHandle.seekToEnd()
            try gapHandle.write(contentsOf: Data((try #require(lines.last) + "\n").utf8))
            try gapHandle.close()
            let gapCompletion = try #require(await gapMonitor.poll(now: Date()).last)
            #expect(gapCompletion.turnID == target["turnID"])
            #expect(gapCompletion.turnStartedAt != nil)
            #expect(gapCompletion.completionText == body.text)
        }
        #expect(lengths.sorted() == [455, 460])
    }

    @Test("Actual monitor bootstrap attaches the active boundary and excludes old endings")
    func monitorBootstrapBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-test.jsonl")
        let lines = try [record(["id": "session", "originator": "Codex Desktop"], type: "session_meta"),
                         record(["type": "task_started", "turn_id": "B"]),
                         record(["type": "function_call", "name": "exec"], type: "response_item", seconds: 2)]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let monitor = CodexRolloutMonitor(root: root)
        let events = await monitor.poll(now: Date())
        let tool = try #require(events.first)
        #expect(tool.kind == .preToolUse)
        #expect(tool.turnID == "B")
        #expect(tool.turnStartedAt != nil)
        #expect(URL(fileURLWithPath: try #require(tool.transcriptPath)).resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(!events.contains { $0.kind == .userPromptSubmit || $0.kind == .stop })
        var reducer = SessionReducer()
        events.forEach { reducer.apply($0) }
        reducer.apply(HookEvent(kind: .preToolUse, sessionID: "session", agent: .codex, timestamp: Date(), turnID: "A", turnStartedAt: Date(timeIntervalSince1970: 1)))
        reducer.apply(HookEvent(kind: .stop, sessionID: "session", agent: .codex, timestamp: Date(), turnID: "A", completionText: "Late A", completionSucceeded: true))
        #expect(reducer.sessions["session"]?.status == .working)
        let staleFinal = try record(["type": "message", "phase": "final_answer",
                                    "internal_chat_message_metadata_passthrough": ["turn_id": "A"]], type: "response_item", seconds: 3)
        let staleComplete = try record(["type": "task_complete", "turn_id": "A", "last_agent_message": "Late A"], seconds: 3)
        let staleHandle = try FileHandle(forWritingTo: file)
        try staleHandle.seekToEnd()
        try staleHandle.write(contentsOf: Data((staleFinal + "\n" + staleComplete + "\n").utf8))
        try staleHandle.close()
        #expect(await monitor.poll(now: Date()).isEmpty)
        let complete = try record(["type": "task_complete", "turn_id": "B", "last_agent_message": "Exact B"], seconds: 3)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((complete + "\n").utf8))
        try handle.close()
        let ended = await monitor.poll(now: Date())
        #expect(ended.last?.turnID == "B")
        #expect(ended.last?.completionText == "Exact B")
        ended.forEach { reducer.apply($0) }
        #expect(reducer.sessions["session"]?.status == .done)
        #expect(await CodexRolloutMonitor(root: root).poll(now: Date()).isEmpty)
        let replacement = try [record(["id": "session", "originator": "Codex Desktop"], type: "session_meta"),
                               record(["type": "task_started", "turn_id": "C"], seconds: 4),
                               record(["type": "function_call", "name": "exec"], type: "response_item", seconds: 5)]
        try (replacement.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let replacementEvents = await monitor.poll(now: Date())
        replacementEvents.forEach { reducer.apply($0) }
        #expect(reducer.sessions["session"]?.status == .working)
        reducer.apply(HookEvent(kind: .stop, sessionID: "session", agent: .codex, timestamp: Date(), turnID: "C", completionText: "Exact C", completionSucceeded: true))
        #expect(reducer.sessions["session"]?.status == .done)
    }
}
