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
                results.observe(prompt, session: reducer.sessions[id], sourceID: "replay", now: started)
                // Stop delivery is reconstructed at the recorded final-message
                // timestamp; no claim that a live Stop was captured.
                let stop = HookEvent(kind: .stop, sessionID: id, timestamp: date, completionText: text, completionSucceeded: true)
                reducer.apply(stop)
                results.observe(stop, session: reducer.sessions[id], sourceID: "replay", now: date)
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
                    reducer.apply(event)
                    results.observe(event, session: reducer.sessions[event.sessionID], sourceID: "replay", now: event.timestamp)
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

    private func recentFiles(_ directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .prefix(24).map { $0 }
    }
}
