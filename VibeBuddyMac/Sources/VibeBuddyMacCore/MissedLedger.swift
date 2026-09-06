import Foundation
import VibeBuddyKit

/// One unanswered `needsResponse` that sat for five minutes with no
/// acknowledgement on any surface. Muted sessions count. The ledger is the
/// 1.2 ship gate (vision Q4 / Q13).
public struct MissedEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionID: String
    public let agent: AgentKind
    public let waitKind: WaitKind
    public let statusSince: Date
    public var pendingID: String?
    public let missedAt: Date
}

/// This week's miss count, plus the per-agent split. `count` is 0 when
/// nothing was missed — never omitted.
public struct MissedCounts: Codable, Sendable, Equatable {
    public let weekStart: String
    public let count: Int
    public let byAgent: [String: Int]

    public static let empty = MissedCounts(weekStart: "", count: 0, byAgent: [:])

    public var agentRows: [(agent: AgentKind, count: Int)] {
        byAgent.compactMap { raw, n in AgentKind(rawValue: raw).map { ($0, n) } }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.agent.displayName < $1.agent.displayName
            }
    }
}

public enum MissedLedgerLocation {
    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/vibebuddy/missed-ledger.json")
    }
}

/// Bounded local ledger of missed waits. Lives beside `LifecycleJournal`
/// (owner-only 0600, eight-week retention). A week starts Monday 06:00 local.
struct MissedLedger {
    static let waitTimeout: TimeInterval = 5 * 60
    static let retention: TimeInterval = 8 * 7 * 24 * 60 * 60

    struct WaitKey: Hashable, Codable {
        var sessionID: String
        var statusSince: Date
        var waitKind: WaitKind?
        var pendingID: String?
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let entries: [MissedEntry]
        let resolved: [WaitKey]
    }

    private struct Pending: Sendable {
        var agent: AgentKind
        var waitKind: WaitKind
    }

    private let url: URL?
    private(set) var entries: [MissedEntry]
    private var resolved: Set<WaitKey>
    private var pending: [WaitKey: Pending] = [:]

    init(url: URL? = nil, now: Date = Date()) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           envelope.schemaVersion == 1 {
            entries = Self.pruned(envelope.entries, now: now)
            resolved = Set(Self.prunedResolved(envelope.resolved, now: now))
        } else {
            entries = []
            resolved = []
        }
    }

    mutating func observe(_ sessions: [AgentSession], now: Date) {
        // Account for elapsed waits before a new snapshot removes them.
        flush(now: now)
        var live = Set<WaitKey>()
        for session in sessions where session.status == .needsResponse {
            let key = WaitKey(sessionID: session.id, statusSince: session.statusSince,
                              waitKind: session.waitKind ?? (session.pendingApproval != nil ? .permission : .question),
                              pendingID: session.pendingApproval?.id ?? session.pendingQuestion?.id)
            live.insert(key)
            adoptPendingIdentity(for: key)
            if resolved.contains(key) || recorded(key) { continue }
            pending[key] = Pending(agent: session.agent, waitKind: key.waitKind ?? .question)
        }
        pending = pending.filter { live.contains($0.key) }
        flush(now: now)
    }

    mutating func acknowledge(sessionID: String, now: Date) {
        flush(now: now)
        let keys = pending.keys.filter { $0.sessionID == sessionID }
        guard !keys.isEmpty else { return }
        for key in keys {
            pending[key] = nil
            resolved.insert(key)
        }
        resolved = Set(Self.prunedResolved(Array(resolved), now: now))
        persistBestEffort()
    }

    mutating func counts(weekContaining date: Date, now: Date, calendar: Calendar = .current) -> MissedCounts {
        prune(now: now)
        let start = Self.weekStart(containing: date, calendar: calendar)
        let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
        let inWeek = entries.filter { $0.missedAt >= start && $0.missedAt < end }
        var byAgent: [String: Int] = [:]
        for entry in inWeek { byAgent[entry.agent.rawValue, default: 0] += 1 }
        return MissedCounts(weekStart: Self.weekStartString(start, calendar: calendar),
                            count: inWeek.count, byAgent: byAgent)
    }

    static func parseWeek(_ raw: String?, now: Date, calendar: Calendar = .current) -> Date? {
        guard let raw, !raw.isEmpty else { return now }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: raw) else { return nil }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    static func weekStart(containing date: Date, calendar: Calendar) -> Date {
        var calendar = calendar
        calendar.firstWeekday = 2
        let shifted = date.addingTimeInterval(-6 * 60 * 60)
        let monday = calendar.dateInterval(of: .weekOfYear, for: shifted)?.start
            ?? calendar.startOfDay(for: shifted)
        return calendar.date(bySettingHour: 6, minute: 0, second: 0, of: monday)
            ?? monday.addingTimeInterval(6 * 60 * 60)
    }

    private mutating func flush(now: Date) {
        var wrote = false
        for (key, wait) in pending {
            guard now.timeIntervalSince(key.statusSince) >= Self.waitTimeout else { continue }
            guard !recorded(key) else {
                pending[key] = nil
                continue
            }
            entries.append(MissedEntry(
                id: UUID(),
                sessionID: key.sessionID,
                agent: wait.agent,
                waitKind: wait.waitKind,
                statusSince: key.statusSince,
                pendingID: key.pendingID,
                missedAt: key.statusSince.addingTimeInterval(Self.waitTimeout)
            ))
            pending[key] = nil
            wrote = true
        }
        let pruned = prune(now: now, persist: false)
        if wrote || pruned { persistBestEffort() }
    }

    @discardableResult
    private mutating func prune(now: Date, persist: Bool = true) -> Bool {
        let keptEntries = Self.pruned(entries, now: now)
        let keptResolved = Set(Self.prunedResolved(Array(resolved), now: now))
        let changed = keptEntries.count != entries.count || keptResolved != resolved
        entries = keptEntries
        resolved = keptResolved
        if changed && persist { persistBestEffort() }
        return changed
    }

    /// A hook can describe a wait before its richer pending request arrives.
    /// That metadata upgrade keeps the original acknowledgement/miss, while a
    /// replacement concrete ID is always a distinct key.
    private mutating func adoptPendingIdentity(for key: WaitKey) {
        guard key.pendingID != nil else { return }
        let generic = WaitKey(sessionID: key.sessionID, statusSince: key.statusSince,
                              waitKind: key.waitKind, pendingID: nil)
        var changed = false
        if resolved.remove(generic) != nil {
            resolved.insert(key)
            changed = true
        }
        for index in entries.indices where entries[index].sessionID == key.sessionID
            && entries[index].statusSince == key.statusSince
            && entries[index].waitKind == key.waitKind && entries[index].pendingID == nil {
            entries[index].pendingID = key.pendingID
            changed = true
        }
        if changed { persistBestEffort() }
    }

    private func recorded(_ key: WaitKey) -> Bool {
        entries.contains { $0.sessionID == key.sessionID && $0.statusSince == key.statusSince
            && $0.waitKind == key.waitKind && $0.pendingID == key.pendingID }
    }

    private static func pruned(_ entries: [MissedEntry], now: Date) -> [MissedEntry] {
        let cutoff = now.addingTimeInterval(-retention)
        return entries.filter { $0.missedAt >= cutoff }
    }

    private static func prunedResolved(_ keys: [WaitKey], now: Date) -> [WaitKey] {
        let cutoff = now.addingTimeInterval(-retention)
        return keys.filter { $0.statusSince >= cutoff }
    }

    private static func weekStartString(_ start: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: start)
    }

    private func persistBestEffort() {
        guard let url else { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(
                schemaVersion: 1, entries: entries, resolved: Array(resolved)))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Fail open: a miss count must never block hook processing.
        }
    }
}
