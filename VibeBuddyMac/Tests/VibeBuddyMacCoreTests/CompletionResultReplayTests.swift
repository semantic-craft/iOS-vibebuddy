import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Opt-in, read-only local source replay. No source path, identity or text is
/// printed/persisted. This verifies recorded evidence, not live hook delivery.
@Suite("Completion result local replay")
struct CompletionResultReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_COMPLETION_REPLAY"] == "1"))
    func recordedSources() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var claudeVerified = false
        for file in recentFiles(home.appendingPathComponent(".claude/projects")) {
            guard let data = try? Data(contentsOf: file), data.count < 16_777_216 else { continue }
            var prefix = Data()
            var started: Date?
            for line in data.split(separator: 10) {
                prefix.append(contentsOf: line); prefix.append(10)
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let stamp = row["timestamp"] as? String, let date = formatter.date(from: stamp),
                      let id = row["sessionId"] as? String, row["isSidechain"] as? Bool != true else { continue }
                if row["type"] as? String == "user" { started = date }
                guard let started, row["type"] as? String == "assistant",
                      let message = row["message"] as? [String: Any],
                      message["stop_reason"] as? String == "end_turn",
                      let text = ClaudeCompletionReader.parse(prefix, sessionID: id,
                          startedAt: started, completedAt: date, expectedText: nil), text.count <= 12_000 else { continue }
                var reducer = SessionReducer()
                var results = CompletionResults()
                let prompt = HookEvent(kind: .userPromptSubmit, sessionID: id, timestamp: started)
                reducer.apply(prompt)
                results.observe(prompt, session: reducer.sessions[id], sourceID: "replay", now: started, createdCompletion: true)
                // Stop delivery is reconstructed at the recorded final-message
                // timestamp; no claim that a live Stop was captured.
                let stop = HookEvent(kind: .stop, sessionID: id, timestamp: date, completionText: text, completionSucceeded: true)
                reducer.apply(stop)
                results.observe(stop, session: reducer.sessions[id], sourceID: "replay", now: date, createdCompletion: true)
                guard let candidate = results.candidates[id] else { continue }
                if case .ready(let frozen) = CompletionResults.freeze(text, candidate: candidate,
                    sourceID: "replay", sessionID: id, now: date) {
                    let matches = frozen.finalText == text
                    #expect(matches)
                    claudeVerified = true
                    break
                }
            }
            if claudeVerified { break }
        }
        #expect(claudeVerified, "No eligible recorded Claude ending found")

        var codexVerified = false
        for file in recentFiles(home.appendingPathComponent(".codex/sessions")) {
            guard let data = try? Data(contentsOf: file), data.count < 16_777_216 else { continue }
            var parser = CodexRolloutParser()
            var reducer = SessionReducer()
            var results = CompletionResults()
            for line in data.split(separator: 10) {
                for event in parser.parseEvents(Data(line), receivedAt: Date()) {
                    let previous = reducer.sessions[event.sessionID]?.completionID
                    reducer.apply(event)
                    results.observe(event, session: reducer.sessions[event.sessionID], sourceID: "replay", now: event.timestamp,
                        createdCompletion: reducer.sessions[event.sessionID]?.completionID != previous)
                    if case .ready(let value) = results.candidates[event.sessionID]?.outcome {
                        let matches = value.turnID == event.turnID && value.finalText == event.completionText
                        #expect(matches)
                        codexVerified = true
                    }
                }
                if codexVerified { break }
            }
            if codexVerified { break }
        }
        #expect(codexVerified, "No eligible recorded Codex ending found")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_COMPLETION_REPLAY"] == "1"))
    func recordedSettledEndings() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: copy) }
        var claudeVerified = false
        for file in recentFiles(home.appendingPathComponent(".claude/projects")) {
            guard let data = try? Data(contentsOf: file), data.count < 16_777_216 else { continue }
            var prefix = Data()
            var text: String?
            for line in data.split(separator: 10) {
                prefix.append(contentsOf: line); prefix.append(10)
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      row["isSidechain"] as? Bool != true else { continue }
                if row["type"] as? String == "assistant",
                   let message = row["message"] as? [String: Any], message["stop_reason"] as? String == "end_turn" {
                    text = (message["content"] as? [[String: Any]] ?? [])
                        .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                guard row["subtype"] as? String == "stop_hook_summary", let text, !text.isEmpty,
                      let id = row["sessionId"] as? String else { continue }
                try prefix.write(to: copy)
                if ClaudeCompletionReader.hooksSettled(path: copy.path, sessionID: id,
                    completedAt: .distantPast, expectedText: text) { claudeVerified = true; break }
            }
            if claudeVerified { break }
        }
        #expect(claudeVerified, "No eligible recorded Claude settled ending found")
        var cursorVerified = false
        for file in recentFiles(home.appendingPathComponent(".cursor/projects")) {
            guard let data = try? Data(contentsOf: file), data.count < 16_777_216 else { continue }
            var suffix = Data()
            for line in data.split(separator: 10) {
                let events = CursorTranscripts.parse(line: String(decoding: line, as: UTF8.self), fullContent: true)
                if events.contains(where: { if case .prompt = $0 { return true }; return false }) { suffix = Data() }
                suffix.append(contentsOf: line); suffix.append(10)
                guard events.contains(where: { if case .turnEnded("success", _) = $0 { return true }; return false }) else { continue }
                try suffix.write(to: copy)
                if CursorCompletionReader.read(path: copy.path, offset: 0) != nil { cursorVerified = true; break }
            }
            if cursorVerified { break }
        }
        #expect(cursorVerified, "No eligible recorded Cursor settled ending found")
    }

    private func recentFiles(_ directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .prefix(24).map { $0 }
    }
}
