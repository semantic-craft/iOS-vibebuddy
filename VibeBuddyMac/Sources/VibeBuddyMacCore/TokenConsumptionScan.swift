import Foundation
import VibeBuddyKit

/// One assistant/API call's tokens. Internal to local log aggregation; never
/// enters the session reducer.
struct TokenUsageEntry: Equatable, Sendable {
    var agent: AgentKind
    var model: String
    var project: String
    var sessionID: String
    var timestamp: Date
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int
    var reasoningOutputTokens: Int

    var usageScore: Int { inputTokens + outputTokens + cachedInputTokens + reasoningOutputTokens }

    var estimatedUSD: Double {
        Pricing.estimatedUSD(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            model: model)
    }
}

/// Walks the same Claude Code / Codex homes session history already uses and
/// folds token usage into today / last-7-day summaries. Read-only.
public enum TokenConsumptionScan {
    public static let recency: TimeInterval = 14 * 24 * 60 * 60
    public static let refreshInterval: TimeInterval = 5 * 60

    public static func defaultClaudeHomes(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var homes = [home.appendingPathComponent(".claude")]
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            let extra = URL(fileURLWithPath: configured)
            if extra.standardizedFileURL != homes[0].standardizedFileURL {
                homes.append(extra)
            }
        }
        return homes
    }

    public static func defaultCodexHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        return home.appendingPathComponent(".codex")
    }

    public static func snapshot(
        claudeHomes: [URL],
        codexHome: URL,
        now: Date,
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) -> TokenConsumptionSnapshot {
        var warnings: [String] = []
        let since = now.addingTimeInterval(-recency)
        var entries: [TokenUsageEntry] = []
        for home in claudeHomes {
            entries += ClaudeTokenConsumptionParser.parse(
                home: home, since: since, fileManager: fileManager, warnings: &warnings)
        }
        entries += CodexTokenConsumptionParser.parse(
            home: codexHome, since: since, fileManager: fileManager, warnings: &warnings)
        return TokenConsumptionAggregator.snapshot(
            entries: entries, now: now, calendar: calendar, warnings: warnings)
    }
}

enum TokenConsumptionAggregator {
    static let topN = 8

    static func snapshot(
        entries: [TokenUsageEntry],
        now: Date,
        calendar: Calendar,
        warnings: [String]
    ) -> TokenConsumptionSnapshot {
        let todayStart = calendar.startOfDay(for: now)
        // Inclusive of today plus the previous six calendar days.
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart)
            ?? now.addingTimeInterval(-7 * 24 * 60 * 60)
        let windows = [
            window(.today, entries: entries, start: todayStart, end: now),
            window(.last7Days, entries: entries, start: weekStart, end: now),
        ]
        return TokenConsumptionSnapshot(
            observedAt: now,
            windows: windows,
            warnings: warnings.isEmpty ? nil : Array(warnings.prefix(8)))
    }

    private static func window(
        _ kind: TokenConsumptionWindowKind,
        entries: [TokenUsageEntry],
        start: Date,
        end: Date
    ) -> TokenConsumptionWindow {
        let slice = entries.filter { $0.timestamp >= start && $0.timestamp <= end }
        return TokenConsumptionWindow(
            kind: kind,
            counts: totals(slice),
            byAgent: rows(slice, key: { $0.agent.rawValue }, label: { $0.agent.displayName }, limit: nil),
            byModel: rows(slice, key: { $0.model }, label: { $0.model }, limit: topN),
            byProject: rows(slice, key: { $0.project }, label: { $0.project }, limit: topN))
    }

    private static func totals(_ entries: [TokenUsageEntry]) -> TokenCountBreakdown {
        var counts = TokenCountBreakdown()
        var sessions = Set<String>()
        for entry in entries {
            counts.inputTokens += entry.inputTokens
            counts.outputTokens += entry.outputTokens
            counts.cachedInputTokens += entry.cachedInputTokens
            counts.reasoningOutputTokens += entry.reasoningOutputTokens
            counts.estimatedUSD += entry.estimatedUSD
            sessions.insert(entry.sessionID)
        }
        counts.sessionCount = sessions.count
        return counts
    }

    private static func rows(
        _ entries: [TokenUsageEntry],
        key: (TokenUsageEntry) -> String,
        label: (TokenUsageEntry) -> String,
        limit: Int?
    ) -> [TokenConsumptionRow] {
        var grouped: [String: [TokenUsageEntry]] = [:]
        var labels: [String: String] = [:]
        for entry in entries {
            let k = key(entry)
            grouped[k, default: []].append(entry)
            labels[k] = label(entry)
        }
        var result = grouped.keys.map { k in
            TokenConsumptionRow(key: k, label: labels[k] ?? k, counts: totals(grouped[k] ?? []))
        }
        result.sort {
            if $0.counts.billedTokens != $1.counts.billedTokens {
                return $0.counts.billedTokens > $1.counts.billedTokens
            }
            return $0.key < $1.key
        }
        if let limit { return Array(result.prefix(limit)) }
        return result
    }
}

enum TokenLogJSON {
    /// Per-file read budget. JSONL is append-only; a start-only cap would drop
    /// the newest usage, so we stream until this limit and then warn.
    static let byteLimit = 128 * 1024 * 1024

    static func int(_ value: Any?) -> Int {
        switch value {
        case let i as Int: return max(0, i)
        case let i as Int64: return max(0, Int(clamping: i))
        case let d as Double where d.isFinite: return max(0, Int(d.rounded()))
        case let n as NSNumber: return max(0, n.intValue)
        default: return 0
        }
    }

    /// Stream complete lines instead of slurp-from-start so a large transcript
    /// still contributes its recent `token_count` / assistant usage records.
    static func objects(url: URL) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var objects: [[String: Any]] = []
        var remainder = Data()
        var total = 0
        while true {
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            total += chunk.count
            remainder.append(chunk)
            while let newline = remainder.firstIndex(of: 10) {
                let line = Data(remainder[..<newline])
                remainder.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    objects.append(obj)
                }
            }
            if total > byteLimit { break }
        }
        if total <= byteLimit, !remainder.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: remainder) as? [String: Any] {
            objects.append(obj)
        }
        return objects
    }

    static func date(_ raw: Any?, iso: ISO8601DateFormatter, fractional: ISO8601DateFormatter) -> Date? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        return fractional.date(from: string) ?? iso.date(from: string)
    }

    static func projectName(_ cwd: String?, fallback: String) -> String {
        guard let cwd else { return fallback }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? fallback
    }
}

struct TokenLogFile {
    let url: URL
    let size: Int
    let mtime: Date
    let sessionID: String
    let fallbackProject: String
}

enum TokenLogDiscovery {
    static func jsonlFiles(
        in root: URL,
        since: Date,
        sessionID: (URL) -> String,
        fallbackProject: (URL) -> String,
        fileManager: FileManager,
        warnings: inout [String]
    ) -> [TokenLogFile] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var readable = true
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                readable = false
                return true
            }
        ) else {
            warnings.append("Unable to enumerate \(root.path)")
            return []
        }
        var files: [TokenLogFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate ?? .distantPast
            guard mtime >= since else { continue }
            files.append(TokenLogFile(
                url: url,
                size: values?.fileSize ?? 0,
                mtime: mtime,
                sessionID: sessionID(url),
                fallbackProject: fallbackProject(url)))
        }
        if !readable {
            warnings.append("Incomplete read of \(root.path)")
        }
        return files
    }

    static func bestCopy(_ files: [TokenLogFile]) -> [TokenLogFile] {
        var groups: [String: [TokenLogFile]] = [:]
        for file in files { groups[file.sessionID, default: []].append(file) }
        return groups.values.compactMap { group in
            group.max { a, b in
                if a.size != b.size { return a.size < b.size }
                if a.mtime != b.mtime { return a.mtime < b.mtime }
                return a.url.path > b.url.path
            }
        }
    }
}

enum ClaudeTokenConsumptionParser {
    static func parse(
        home: URL,
        since: Date,
        fileManager: FileManager,
        warnings: inout [String]
    ) -> [TokenUsageEntry] {
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        let files = TokenLogDiscovery.bestCopy(TokenLogDiscovery.jsonlFiles(
            in: projects,
            since: since,
            sessionID: { $0.deletingPathExtension().lastPathComponent },
            fallbackProject: { projectFromRelative($0, under: projects) },
            fileManager: fileManager,
            warnings: &warnings))
        return files.flatMap { file -> [TokenUsageEntry] in
            if file.size > TokenLogJSON.byteLimit {
                warnings.append("Skipped oversized Claude transcript \(file.url.lastPathComponent)")
                return []
            }
            return parseFile(file)
        }
    }

    private static func projectFromRelative(_ url: URL, under projects: URL) -> String {
        let prefix = projects.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return "unknown" }
        let relative = String(path.dropFirst(prefix.count))
        let first = relative.split(separator: "/").first.map(String.init) ?? ""
        return first.split(separator: "-").last.map(String.init) ?? "unknown"
    }

    private static func parseFile(_ file: TokenLogFile) -> [TokenUsageEntry] {
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var keyed: [String: TokenUsageEntry] = [:]
        var anonymous: [TokenUsageEntry] = []
        var lastModel: String?
        var sessionProject = file.fallbackProject
        var foundCwd = false

        for obj in TokenLogJSON.objects(url: file.url) {
            if !foundCwd, let cwd = obj["cwd"] as? String, !cwd.trimmingCharacters(in: .whitespaces).isEmpty {
                sessionProject = TokenLogJSON.projectName(cwd, fallback: file.fallbackProject)
                foundCwd = true
            }
            guard (obj["type"] as? String) == "assistant" else { continue }
            let message = obj["message"] as? [String: Any]
            guard let usage = message?["usage"] as? [String: Any] else { continue }
            guard let timestamp = TokenLogJSON.date(obj["timestamp"], iso: iso, fractional: fractional) else { continue }

            let rawModel = (message?["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !rawModel.isEmpty, rawModel != "<synthetic>" { lastModel = rawModel }
            let model = (rawModel.isEmpty || rawModel == "<synthetic>") ? (lastModel ?? "claude-unknown") : rawModel
            let input = TokenLogJSON.int(usage["input_tokens"]) + cacheCreation(usage)
            let output = TokenLogJSON.int(usage["output_tokens"])
            let cached = TokenLogJSON.int(usage["cache_read_input_tokens"])
            if input + output + cached == 0 { continue }

            let entry = TokenUsageEntry(
                agent: .claudeCode, model: model, project: sessionProject,
                sessionID: file.sessionID, timestamp: timestamp,
                inputTokens: input, outputTokens: output,
                cachedInputTokens: cached, reasoningOutputTokens: 0)
            if let key = dedupeKey(obj, message: message) {
                if keyed[key]?.usageScore ?? -1 < entry.usageScore { keyed[key] = entry }
            } else {
                anonymous.append(entry)
            }
        }

        var result = anonymous + Array(keyed.values)
        for i in result.indices { result[i].project = sessionProject }
        return result
    }

    private static func cacheCreation(_ usage: [String: Any]) -> Int {
        let direct = TokenLogJSON.int(usage["cache_creation_input_tokens"])
        let breakdown = usage["cache_creation"] as? [String: Any] ?? [:]
        let split = TokenLogJSON.int(breakdown["ephemeral_5m_input_tokens"])
            + TokenLogJSON.int(breakdown["ephemeral_1h_input_tokens"])
        return max(direct, split)
    }

    private static func dedupeKey(_ obj: [String: Any], message: [String: Any]?) -> String? {
        let messageID = (message?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestID = (obj["requestId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !messageID.isEmpty || !requestID.isEmpty { return "call:\(messageID)\u{0}\(requestID)" }
        if let uuid = obj["uuid"] as? String, !uuid.isEmpty { return uuid }
        return nil
    }
}

enum CodexTokenConsumptionParser {
    static func parse(
        home: URL,
        since: Date,
        fileManager: FileManager,
        warnings: inout [String]
    ) -> [TokenUsageEntry] {
        let roots = [
            home.appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        var discovered: [TokenLogFile] = []
        for root in roots {
            discovered += TokenLogDiscovery.jsonlFiles(
                in: root, since: since,
                sessionID: { $0.deletingPathExtension().lastPathComponent },
                fallbackProject: { _ in "unknown" },
                fileManager: fileManager, warnings: &warnings)
        }
        var bySession: [String: (file: TokenLogFile, entries: [TokenUsageEntry])] = [:]
        for file in discovered {
            if file.size > TokenLogJSON.byteLimit {
                warnings.append("Skipped oversized Codex rollout \(file.url.lastPathComponent)")
                continue
            }
            let parsed = parseFile(file)
            let sessionID = parsed.sessionID ?? file.sessionID
            let candidate = TokenLogFile(
                url: file.url, size: file.size, mtime: file.mtime,
                sessionID: sessionID, fallbackProject: parsed.project)
            if let existing = bySession[sessionID] {
                let keepNew = candidate.size != existing.file.size
                    ? candidate.size > existing.file.size
                    : candidate.mtime >= existing.file.mtime
                if keepNew { bySession[sessionID] = (candidate, parsed.entries) }
            } else {
                bySession[sessionID] = (candidate, parsed.entries)
            }
        }
        return bySession.values.flatMap(\.entries)
    }

    private static func parseFile(_ file: TokenLogFile) -> (sessionID: String?, project: String, entries: [TokenUsageEntry]) {
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var sessionID: String?
        var project = file.fallbackProject
        var sessionMetaCount = 0
        var skippingReplay = false
        var model = "unknown"
        var prevTotal: [String: Int]?
        var prevCumulativeTotal: Int?
        var entries: [TokenUsageEntry] = []

        for obj in TokenLogJSON.objects(url: file.url) {
            let type = obj["type"] as? String
            if type == "session_meta", let payload = obj["payload"] as? [String: Any] {
                sessionMetaCount += 1
                if sessionMetaCount == 1 {
                    if let id = payload["id"] as? String, !id.isEmpty { sessionID = id }
                    project = projectName(from: payload, fallback: project)
                } else {
                    skippingReplay = true
                }
                continue
            }
            if type == "turn_context", let payload = obj["payload"] as? [String: Any],
               let name = payload["model"] as? String, !name.isEmpty {
                model = name
                continue
            }
            guard type == "event_msg", let payload = obj["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else { continue }
            if eventType == "thread_settings_applied",
               let settings = payload["thread_settings"] as? [String: Any],
               let name = settings["model"] as? String, !name.isEmpty {
                model = name
                continue
            }
            if eventType == "task_started" {
                skippingReplay = false
                continue
            }
            guard eventType == "token_count" else { continue }
            guard let info = payload["info"] as? [String: Any] else { continue }

            let currentTotal = info["total_token_usage"] as? [String: Any]
            let cumulative = TokenLogJSON.int(currentTotal?["total_tokens"])
            let isDuplicate = cumulative > 0 && cumulative == prevCumulativeTotal
            if cumulative > 0 { prevCumulativeTotal = cumulative }

            var usage = info["last_token_usage"] as? [String: Any]
            if usage == nil, let curr = currentTotal {
                if let prev = prevTotal {
                    let inputDelta = TokenLogJSON.int(curr["input_tokens"]) - prev["input_tokens", default: 0]
                    let outputDelta = TokenLogJSON.int(curr["output_tokens"]) - prev["output_tokens", default: 0]
                    let cachedDelta = TokenLogJSON.int(curr["cached_input_tokens"]) - prev["cached_input_tokens", default: 0]
                    let reasoningDelta = TokenLogJSON.int(curr["reasoning_output_tokens"]) - prev["reasoning_output_tokens", default: 0]
                    if inputDelta < 0 || outputDelta < 0 || cachedDelta < 0 || reasoningDelta < 0 {
                        usage = curr
                    } else {
                        usage = [
                            "input_tokens": inputDelta,
                            "output_tokens": outputDelta,
                            "cached_input_tokens": cachedDelta,
                            "reasoning_output_tokens": reasoningDelta,
                        ]
                    }
                } else {
                    usage = curr
                }
            }
            if let curr = currentTotal {
                prevTotal = [
                    "input_tokens": TokenLogJSON.int(curr["input_tokens"]),
                    "output_tokens": TokenLogJSON.int(curr["output_tokens"]),
                    "cached_input_tokens": TokenLogJSON.int(curr["cached_input_tokens"]),
                    "reasoning_output_tokens": TokenLogJSON.int(curr["reasoning_output_tokens"]),
                ]
            }
            if skippingReplay || isDuplicate { continue }
            guard let usage else { continue }
            guard let timestamp = TokenLogJSON.date(obj["timestamp"], iso: iso, fractional: fractional) else { continue }
            if let named = info["model"] as? String, !named.isEmpty { model = named }
            else if let named = payload["model"] as? String, !named.isEmpty { model = named }

            // OpenAI-style fields overlap; prefer `cached_input_tokens` the way
            // vibe-usage does (`||`), rather than summing both names.
            let cachedPrimary = TokenLogJSON.int(usage["cached_input_tokens"])
            let cached = cachedPrimary > 0 ? cachedPrimary : TokenLogJSON.int(usage["cache_read_input_tokens"])
            let reasoning = TokenLogJSON.int(usage["reasoning_output_tokens"])
            let input = max(0, TokenLogJSON.int(usage["input_tokens"]) - cached)
            let output = max(0, TokenLogJSON.int(usage["output_tokens"]) - reasoning)
            if input + output + cached + reasoning == 0 { continue }
            entries.append(TokenUsageEntry(
                agent: .codex, model: model, project: project,
                sessionID: sessionID ?? file.sessionID, timestamp: timestamp,
                inputTokens: input, outputTokens: output,
                cachedInputTokens: cached, reasoningOutputTokens: reasoning))
        }
        return (sessionID, project, entries)
    }

    private static func projectName(from meta: [String: Any], fallback: String) -> String {
        if let git = meta["git"] as? [String: Any], let url = git["repository_url"] as? String {
            let trimmed = url.hasSuffix(".git") ? String(url.dropLast(4)) : url
            let parts = trimmed.split(separator: "/").suffix(2).map(String.init)
            if parts.count == 2 { return parts.joined(separator: "/") }
        }
        return TokenLogJSON.projectName(meta["cwd"] as? String, fallback: fallback)
    }
}
