import Foundation
import VibeBuddyKit

/// One status line JSON from Claude Code, as forwarded by
/// `hooks/vibebuddy-statusline.sh`. Decoded at the boundary into the few
/// facts the session row and the quota view use; everything else is dropped.
///
/// A sample is bookkeeping: it fills fields on a session the hooks already
/// opened and never creates one or moves the three-state progress.
public struct StatusLineSample: Sendable, Equatable {
    public let sessionID: String
    public var model: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var sessionName: String?
    public var effort: String?
    public var costUSD: Double?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var prNumber: Int?
    public var prURL: String?
    public var worktree: String?
    /// The claude.ai rate-limit windows, when the CLI reports them.
    public var fiveHour: AccountUsageWindow?
    public var sevenDay: AccountUsageWindow?
    public var extraWindows: [AccountUsageWindow] = []

    public init(sessionID: String) { self.sessionID = sessionID }

    public static func decode(_ obj: [String: Any]) -> StatusLineSample? {
        guard let sessionID = obj["session_id"] as? String, !sessionID.isEmpty else { return nil }
        var sample = StatusLineSample(sessionID: sessionID)
        let model = obj["model"] as? [String: Any]
        sample.model = Self.nonEmpty(model?["display_name"] as? String) ?? Self.nonEmpty(model?["id"] as? String)
        let workspace = obj["workspace"] as? [String: Any]
        sample.cwd = Self.nonEmpty(workspace?["current_dir"] as? String) ?? Self.nonEmpty(obj["cwd"] as? String)
        sample.transcriptPath = Self.nonEmpty(obj["transcript_path"] as? String)
        sample.sessionName = Self.nonEmpty(obj["session_name"] as? String)
        sample.effort = Self.nonEmpty((obj["effort"] as? [String: Any])?["level"] as? String)
        if let cost = obj["cost"] as? [String: Any], let usd = Self.double(cost["total_cost_usd"]) {
            sample.costUSD = usd
        }
        if let context = obj["context_window"] as? [String: Any] {
            let size = Self.int(context["context_window_size"])
            sample.contextWindow = size
            if let percent = Self.double(context["used_percentage"]), let size {
                // What Claude itself shows: the pre-calculated occupancy.
                sample.contextTokens = Int((percent / 100 * Double(size)).rounded())
            } else if let input = Self.int(context["total_input_tokens"]) {
                sample.contextTokens = input + (Self.int(context["total_output_tokens"]) ?? 0)
            }
        }
        if let pr = obj["pr"] as? [String: Any] {
            sample.prNumber = Self.int(pr["number"])
            sample.prURL = Self.nonEmpty(pr["url"] as? String)
        }
        if let worktree = obj["worktree"] as? [String: Any] {
            sample.worktree = Self.nonEmpty(worktree["name"] as? String)
        } else if let name = Self.nonEmpty(workspace?["git_worktree"] as? String) {
            sample.worktree = name
        }
        if let limits = obj["rate_limits"] as? [String: Any] {
            sample.fiveHour = Self.window(limits["five_hour"], kind: .primary, minutes: 5 * 60)
            sample.sevenDay = Self.window(limits["seven_day"], kind: .secondary, minutes: 7 * 24 * 60)
            sample.extraWindows = Self.extraWindows(from: limits)
        }
        return sample
    }

    /// The subscription allowance this sample carries, in the collectors'
    /// shape, or nil when the CLI sent no `rate_limits`.
    public func usageSnapshot(fetchedAt: Date) -> AccountUsageSnapshot? {
        guard fiveHour != nil || sevenDay != nil || !extraWindows.isEmpty else { return nil }
        return AccountUsageSnapshot(
            provider: .claude, planType: nil,
            primary: fiveHour, secondary: sevenDay,
            lifetimeTokens: nil, latestDailyTokens: nil,
            fetchedAt: fetchedAt,
            extraWindows: extraWindows.isEmpty ? nil : extraWindows)
    }

    private static let reservedRateLimitKeys: Set<String> = ["five_hour", "seven_day"]

    private static func extraWindows(from limits: [String: Any]) -> [AccountUsageWindow] {
        var extras: [AccountUsageWindow] = []
        var seen: Set<String> = []
        for (rawKey, value) in limits.sorted(by: { $0.key < $1.key }) where !reservedRateLimitKeys.contains(rawKey) {
            let minutes: Int?
            let lowered = rawKey.lowercased()
            if lowered.contains("five_hour") || lowered.contains("five-hour") {
                minutes = 5 * 60
            } else if lowered.contains("seven_day") || lowered.contains("seven-day") {
                minutes = 7 * 24 * 60
            } else {
                minutes = nil
            }
            guard let window = Self.window(value, kind: .extra, minutes: minutes ?? 0) else { continue }
            let slug: String
            let key: String
            if lowered.hasPrefix("seven_day_") || lowered.hasPrefix("five_hour_")
                || lowered.hasPrefix("seven-day-") || lowered.hasPrefix("five-hour-") {
                let stripped = QuotaPresentation.extraWindowTitle(fromStatusLineKey: rawKey)
                    .replacingOccurrences(of: " only", with: "")
                slug = QuotaPresentation.slug(stripped)
                key = "claude-weekly-scoped-\(slug)"
            } else {
                slug = QuotaPresentation.slug(rawKey)
                key = "claude-status-\(slug)"
            }
            guard !slug.isEmpty, seen.insert(key).inserted else { continue }
            extras.append(.extra(
                key: key,
                label: QuotaPresentation.extraWindowTitle(fromStatusLineKey: rawKey),
                usedPercent: window.usedPercent,
                windowDurationMinutes: minutes,
                resetsAt: window.resetsAt
            ))
        }
        return extras
    }

    private static func window(_ value: Any?, kind: AccountUsageWindowKind, minutes: Int) -> AccountUsageWindow? {
        guard let object = value as? [String: Any],
              let used = double(object["used_percentage"]), used.isFinite, (0...100).contains(used) else { return nil }
        let resets = double(object["resets_at"]).flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return AccountUsageWindow(kind: kind, usedPercent: Int(used.rounded()),
                                  windowDurationMinutes: minutes, resetsAt: resets)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let d as Double: return d.isFinite ? Int(d) : nil
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        case let n as Int: return Double(n)
        default: return nil
        }
    }
}
