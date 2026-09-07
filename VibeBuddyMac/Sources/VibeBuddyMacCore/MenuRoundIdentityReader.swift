import Foundation
import VibeBuddyKit

/// Menu-only evidence for idle sessions without a lifecycle completion identity.
/// The actor performs file I/O away from the main actor and retains identifiers only.
public actor MenuRoundIdentityReader {
    private struct Stamp: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64
    }
    private struct Entry {
        let stamp: Stamp
        let identity: String
    }
    private var cache: [String: Entry] = [:]

    public init() {}

    /// Discover only requested active-session rollouts, including old idle files.
    /// `root` is the sessions directory; this never searches sibling archives.
    /// Filename matches are hints only: `identities` verifies the source content.
    public func codexPaths(sessionIDs: Set<String>, root: URL) -> [String: String] {
        guard !sessionIDs.isEmpty,
              case .found(let candidates, let incomplete) = CodexRolloutDiscovery.candidates(
                in: root, now: Date(), window: nil
              ), !incomplete else { return [:] }
        var result: [String: String] = [:]
        for id in sessionIDs where !id.isEmpty {
            let matches = candidates.filter { $0.url.lastPathComponent.hasSuffix("-\(id).jsonl") }
            if matches.count == 1 { result[id] = matches[0].url.path }
        }
        return result
    }

    public func identities(sessions: [AgentSession], paths: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for session in sessions where session.completionID == nil && session.presentationState == .idle {
            guard session.agent == .claudeCode || session.agent == .codex,
                  let path = paths[session.id], let before = stamp(path) else { continue }
            let key = "\(session.agent.rawValue):\(session.id):\(path)"
            if let entry = cache[key], entry.stamp == before {
                result[session.id] = entry.identity
                continue
            }
            cache.removeValue(forKey: key)
            guard let identity = read(path: path, session: session), stamp(path) == before else { continue }
            cache[key] = Entry(stamp: before, identity: identity)
            result[session.id] = identity
        }
        return result
    }

    private func stamp(_ path: String) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Stamp(size: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }

    private func read(path: String, session: AgentSession) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        var buffer = Data()
        var verifiedSession = false
        var round: String?
        var sawActivity = false
        do {
            while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    guard let root = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                    else { return nil }
                    if session.agent == .codex {
                        guard let type = root["type"] as? String,
                              let payload = root["payload"] as? [String: Any] else { return nil }
                        if type == "session_meta" {
                            guard payload["id"] as? String == session.id else { return nil }
                            verifiedSession = true
                        } else if type == "event_msg", payload["type"] as? String == "task_started" {
                            guard verifiedSession, let id = nonempty(payload["turn_id"]) else { return nil }
                            round = id
                            sawActivity = true
                        } else if type == "turn_context" {
                            // Metadata can corroborate a start, never invent one.
                            guard let id = nonempty(payload["turn_id"]), id == round else { return nil }
                        } else if type == "response_item" || type == "event_msg" {
                            sawActivity = true
                        }
                    } else {
                        if let id = root["sessionId"] as? String {
                            guard id == session.id else { return nil }
                            verifiedSession = true
                        }
                        guard root["isSidechain"] as? Bool != true,
                              root["isMeta"] as? Bool != true,
                              root["isCompactSummary"] as? Bool != true else { continue }
                        if root["type"] as? String == "assistant" { sawActivity = true }
                        guard root["type"] as? String == "user" else { continue }
                        sawActivity = true
                        guard root["sessionId"] as? String == session.id,
                              let message = root["message"] as? [String: Any],
                              message["role"] as? String == "user" else { return nil }
                        let content = message["content"]
                        let prompt: Bool
                        if let text = content as? String {
                            prompt = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        } else if let blocks = content as? [[String: Any]] {
                            prompt = blocks.contains { block in
                                let type = block["type"] as? String
                                return type == "text" || type == "image"
                            } && !blocks.contains { $0["type"] as? String == "tool_result" }
                        } else { return nil }
                        if prompt {
                            guard let id = nonempty(root["uuid"]) else { return nil }
                            round = id
                            sawActivity = true
                        }
                    }
                }
            }
        } catch { return nil }
        // A partial last record may be a new prompt: never reuse the previous identity.
        guard buffer.isEmpty, verifiedSession else { return nil }
        let source = session.agent == .codex ? "codex" : "claude"
        if let round { return "\(source):\(session.id):round:\(round)" }
        return sawActivity ? nil : "\(source):\(session.id):initial"
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}
