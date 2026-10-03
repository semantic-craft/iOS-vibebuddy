import Foundation
import VibeBuddyKit

/// Discovers conversations started in the user's own CLI. Never launches or
/// controls agy; native SQLite endings disambiguate DONE transcript steps.
public actor AntigravityCLIMonitor {
    private let root: URL
    private var fingerprints: [String: String] = [:]
    private var initialized = false
    private var historicalEndings: [String: String] = [:]
    private var phases: [String: String] = [:]
    private var userIndices: [String: Int] = [:]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        root = home.appendingPathComponent(".gemini/antigravity-cli")
    }
    public static func forCurrentRun(environment: [String: String] = ProcessInfo.processInfo.environment) -> AntigravityCLIMonitor {
        if let root = environment["VIBEBUDDY_E2E_ROOT"] {
            return AntigravityCLIMonitor(home: URL(fileURLWithPath: root).appendingPathComponent("agents/antigravity"))
        }
        return AntigravityCLIMonitor()
    }
    public func run(store: SessionStore) async {
        while !Task.isCancelled {
            await poll(store: store, now: Date())
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
    public func poll(store: SessionStore, now: Date) async {
        let directory = root.appendingPathComponent("conversations")
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "db" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        let historical = !initialized
        initialized = true
        var found = Set<String>()
        for database in files.prefix(200) {
            if Task.isCancelled { return }
            let id = database.deletingPathExtension().lastPathComponent
            guard (try? HistorySessionReference("antigravity:" + id)) != nil else { continue }
            found.insert(id)
            let logs = root.appendingPathComponent("brain/\(id)/.system_generated/logs")
            let full = logs.appendingPathComponent("transcript_full.jsonl")
            let short = logs.appendingPathComponent("transcript.jsonl")
            let file = FileManager.default.fileExists(atPath: full.path) ? full : short
            let fingerprint = [database, URL(fileURLWithPath: database.path + "-wal"), file]
                .map { SessionTranscriptReader.sourceRevision($0) ?? "missing" }.joined(separator: "|")
            if fingerprints[id] == fingerprint {
                await store.markAntigravityObservation(sessionID: id, health: .healthy, at: now)
                continue
            }
            guard let native = AntigravityNative.state(database: database, sessionID: id),
                  let rows = AntigravityNative.rows(file), !rows.isEmpty else {
                await store.markAntigravityObservation(sessionID: id, health: .sourceUnreadable, at: now)
                continue
            }
            fingerprints[id] = fingerprint
            let prompt = rows.last { $0["type"] as? String == "USER_INPUT" }
            let userIndex = prompt?["step_index"] as? Int ?? 0
            let latestPlanner = rows.last { $0["type"] as? String == "PLANNER_RESPONSE" }
            let calls = latestPlanner?["tool_calls"] as? [[String: Any]] ?? []
            let callIndex = native.lastIndex - (latestPlanner?["step_index"] as? Int ?? -1) - 1
            let pendingCall = calls.indices.contains(callIndex) ? calls[callIndex] : calls.count == 1 ? calls[0] : nil
            let isQuestion = pendingCall?["name"] as? String == "ask_question"
            let question = isQuestion ? (pendingCall.flatMap(AntigravityNative.question)
                ?? "Antigravity has a question; details unavailable. Return to the CLI.") : nil
            let knownPermission = native.lastType == 132 && pendingCall?["name"] as? String == "run_command"
            let summary = AntigravityNative.summary(database: root.appendingPathComponent("conversation_summaries.db"), sessionID: id)
            let terminal = native.terminalIndex == native.lastIndex && !native.waiting
            let succeeded = terminal && native.reason == 4 && native.lastStatus == 3 && summary?.fullyIdle != false
            // The summary can catch up after the foreground DB has settled;
            // keep checking until its background work is explicitly idle.
            if terminal && native.reason == 4 && summary?.fullyIdle == false { fingerprints[id] = nil }
            let cancelled = terminal && native.reason == 2
            let failed = terminal && [1, 3, 6, 11].contains(native.reason ?? 0)
            let ended = succeeded || cancelled || failed
            let phase = ended ? "ended:\(native.executionID ?? String(native.lastIndex))" : native.waiting ? "waiting:\(native.lastIndex)" : "working:\(userIndex)"
            let title = prompt?["content"] as? String
            await store.registerAntigravitySession(sessionID: id, source: "CLI", cwd: summary?.cwd,
                title: summary?.title ?? title.map { String(Self.userText($0).prefix(120)) }, at: now)
            if native.waiting && !isQuestion && !knownPermission {
                fingerprints[id] = nil
                await store.markAntigravityObservation(sessionID: id, health: .unknownVersion, at: now)
                continue
            }
            await store.markAntigravityObservation(sessionID: id, health: .healthy, at: now)
            let missedNewTurn = userIndices[id].map { $0 != userIndex } == true
            userIndices[id] = userIndex
            if missedNewTurn && ended {
                await store.reconcileAntigravityHistory(sessionID: id, userStopped: cancelled, failed: failed,
                    at: now, replacesCompletedTurn: true)
                phases[id] = phase; historicalEndings[id] = phase
                continue
            }
            if (historical || phases[id] == nil) && ended {
                phases[id] = phase; historicalEndings[id] = phase
                await store.reconcileAntigravityHistory(sessionID: id, userStopped: cancelled, failed: failed, at: now)
                continue
            }
            if historicalEndings[id] == phase { continue }
            historicalEndings[id] = nil
            // A row already ended before discovery stays quiet. Changes to that
            // same ending may still fill a result we saw finish while observing.
            if phases[id] == phase && historical { continue }
            if phases[id] != phase || ended {
                let turnID = "antigravity-cli-\(userIndex)"
                if ended {
                    let text = latestPlanner?["content"] as? String
                    let complete = file == full && latestPlanner?["step_index"] as? Int == native.lastIndex
                        && (latestPlanner?["truncated_fields"] as? [String] ?? []).isEmpty
                    await store.ingest(HookEvent(kind: .stop, sessionID: id, agent: .antigravity,
                        message: cancelled ? "Turn cancelled" : failed ? (native.error ?? "Antigravity execution failed") : text.map { String($0.prefix(220)) },
                        transcriptPath: file.path, observationSource: .transcript, timestamp: now,
                        turnID: turnID, userStopped: cancelled, completionText: succeeded && complete ? text : nil,
                        completionSucceeded: succeeded, sourceCompletionID: turnID + "-\(native.lastIndex)"))
                } else {
                    let wasKnown = phases[id] != nil
                    if !wasKnown || phases[id]?.hasPrefix("ended:") == true || phases[id]?.hasPrefix("working:") == true && phases[id] != phase && !native.waiting {
                        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: id, agent: .antigravity,
                            message: title.map(Self.userText), transcriptPath: file.path,
                            observationSource: .transcript, timestamp: now, turnID: turnID))
                    }
                    if native.waiting {
                        let command = (pendingCall?["args"] as? [String: Any])?["CommandLine"] as? String
                        await store.ingest(HookEvent(kind: .notification, sessionID: id, agent: .antigravity,
                            message: question ?? command.map { "Permission requested: " + $0 } ?? "Antigravity is waiting for permission; return to the CLI.",
                            waitKind: question == nil ? .permission : .question,
                            transcriptPath: file.path, observationSource: .transcript, timestamp: now))
                    } else {
                        await store.ingest(HookEvent(kind: .preToolUse, sessionID: id, agent: .antigravity,
                            toolName: calls.first?["name"] as? String,
                            transcriptPath: file.path, observationSource: .transcript, timestamp: now))
                    }
                }
                phases[id] = phase
            }
        }
        for id in Set(fingerprints.keys).subtracting(found) {
            await store.markAntigravityObservation(sessionID: id, health: .sourceUnreadable, at: now)
        }
    }
    static func userText(_ text: String) -> String {
        guard let start = text.range(of: "<USER_REQUEST>"), let end = text.range(of: "</USER_REQUEST>") else { return text }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
