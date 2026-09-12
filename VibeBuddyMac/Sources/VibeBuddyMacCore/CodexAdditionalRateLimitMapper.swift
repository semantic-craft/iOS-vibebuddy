import Foundation
import VibeBuddyKit

/// Maps Codex `additional_rate_limits` (Spark and other named windows) onto
/// extra `AccountUsageWindow`s. Reimplemented from CodexBar's mapper; not vendored.
enum CodexAdditionalRateLimitMapper {
    static let sparkWindowID = "codex-spark"
    static let sparkWeeklyWindowID = "codex-spark-weekly"
    static let sparkWindowTitle = "Codex Spark 5-hour"
    static let sparkWeeklyWindowTitle = "Codex Spark Weekly"

    static func windows(from entries: [AdditionalRateLimitDTO]?) -> [AccountUsageWindow]? {
        guard let entries, !entries.isEmpty else { return nil }
        var usedIDs = Set<String>()
        let mapped = entries.flatMap { windows(from: $0, usedIDs: &usedIDs) }
        return mapped.isEmpty ? nil : mapped
    }

    private static func windows(
        from entry: AdditionalRateLimitDTO,
        usedIDs: inout Set<String>
    ) -> [AccountUsageWindow] {
        if isSpark(entry) {
            return sparkWindows(from: entry, usedIDs: &usedIDs)
        }
        guard let snapshot = entry.primaryWindow ?? entry.secondaryWindow,
              let id = windowID(for: entry), usedIDs.insert(id).inserted,
              let window = snapshot.model(
                key: id,
                label: windowTitle(for: entry)
              ) else { return [] }
        return [window]
    }

    private static func sparkWindows(
        from entry: AdditionalRateLimitDTO,
        usedIDs: inout Set<String>
    ) -> [AccountUsageWindow] {
        let candidates: [(FlexibleRateWindow?, Bool)] = [
            (entry.primaryWindow, true),
            (entry.secondaryWindow, false),
        ]
        return candidates.compactMap { snapshot, fiveHourFallback in
            guard let snapshot else { return nil }
            let fiveHour = isFiveHour(snapshot, fallback: fiveHourFallback)
            let id = fiveHour ? sparkWindowID : sparkWeeklyWindowID
            guard usedIDs.insert(id).inserted else { return nil }
            return snapshot.model(
                key: id,
                label: fiveHour ? sparkWindowTitle : sparkWeeklyWindowTitle,
                defaultMinutes: fiveHour ? 5 * 60 : 7 * 24 * 60
            )
        }
    }

    private static func isFiveHour(_ snapshot: FlexibleRateWindow, fallback: Bool) -> Bool {
        guard let minutes = snapshot.windowMinutes, minutes > 0 else { return fallback }
        if minutes <= 6 * 60 { return true }
        if minutes >= 6 * 24 * 60 { return false }
        return fallback
    }

    private static func windowID(for entry: AdditionalRateLimitDTO) -> String? {
        guard let source = firstNonEmpty(entry.meteredFeature, entry.limitName) else { return nil }
        let slug = QuotaPresentation.slug(source)
        return slug.isEmpty ? nil : "codex-\(slug)"
    }

    private static func windowTitle(for entry: AdditionalRateLimitDTO) -> String {
        firstNonEmpty(entry.limitName, entry.meteredFeature) ?? "Codex extra limit"
    }

    private static func isSpark(_ entry: AdditionalRateLimitDTO) -> Bool {
        [entry.limitName, entry.meteredFeature]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("spark") }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

struct AdditionalRateLimitDTO: Decodable {
    var limitName: String?
    var meteredFeature: String?
    var primaryWindow: FlexibleRateWindow?
    var secondaryWindow: FlexibleRateWindow?

    private enum CodingKeys: String, CodingKey {
        case limitName, limit_name
        case meteredFeature, metered_feature
        case primary, secondary
        case rateLimit, rate_limit
        case usedPercent, used_percent
        case windowDurationMins, window_duration_mins
        case resetsAt, resets_at, resetAt, reset_at
        case limitWindowSeconds, limit_window_seconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        limitName = (try? values.decode(String.self, forKey: .limitName))
            ?? (try? values.decode(String.self, forKey: .limit_name))
        meteredFeature = (try? values.decode(String.self, forKey: .meteredFeature))
            ?? (try? values.decode(String.self, forKey: .metered_feature))

        let nested = (try? values.decode(NestedRateLimitDTO.self, forKey: .rateLimit))
            ?? (try? values.decode(NestedRateLimitDTO.self, forKey: .rate_limit))
        primaryWindow = nested?.primary
            ?? (try? values.decode(FlexibleRateWindow.self, forKey: .primary))
        secondaryWindow = nested?.secondary
            ?? (try? values.decode(FlexibleRateWindow.self, forKey: .secondary))

        if primaryWindow == nil {
            primaryWindow = try? FlexibleRateWindow(from: decoder)
        }
    }
}

private struct NestedRateLimitDTO: Decodable {
    var primary: FlexibleRateWindow?
    var secondary: FlexibleRateWindow?

    private enum CodingKeys: String, CodingKey {
        case primary, secondary
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        primary = (try? values.decode(FlexibleRateWindow.self, forKey: .primary))
            ?? (try? values.decode(FlexibleRateWindow.self, forKey: .primaryWindow))
        secondary = (try? values.decode(FlexibleRateWindow.self, forKey: .secondary))
            ?? (try? values.decode(FlexibleRateWindow.self, forKey: .secondaryWindow))
    }
}

struct FlexibleRateWindow: Decodable {
    var usedPercent: Double?
    var windowMinutes: Int?
    var resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case usedPercent, used_percent
        case windowDurationMins, window_duration_mins
        case resetsAt, resets_at, resetAt, reset_at
        case limitWindowSeconds, limit_window_seconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let parsed = FlexibleRateWindow(container: values) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "rate window missing used percent"))
        }
        self = parsed
    }

    private init?(container values: KeyedDecodingContainer<CodingKeys>) {
        usedPercent = Self.flexibleDouble(values, [.usedPercent, .used_percent])
        windowMinutes = Self.flexibleInt(values, [.windowDurationMins, .window_duration_mins])
        if windowMinutes == nil,
           let seconds = Self.flexibleInt(values, [.limitWindowSeconds, .limit_window_seconds]),
           seconds > 0 {
            windowMinutes = seconds / 60
        }
        if let timestamp = Self.flexibleInt(values, [.resetsAt, .resets_at, .resetAt, .reset_at]),
           timestamp > 0 {
            resetsAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        guard let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
    }

    func model(key: String, label: String, defaultMinutes: Int? = nil) -> AccountUsageWindow? {
        guard let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
        return .extra(
            key: key,
            label: label,
            usedPercent: Int(usedPercent.rounded()),
            windowDurationMinutes: windowMinutes ?? defaultMinutes,
            resetsAt: resetsAt
        )
    }

    private static func flexibleDouble(
        _ values: KeyedDecodingContainer<CodingKeys>,
        _ keys: [CodingKeys]
    ) -> Double? {
        for key in keys {
            if let value = try? values.decode(Double.self, forKey: key) { return value }
            if let value = try? values.decode(Int.self, forKey: key) { return Double(value) }
            if let value = try? values.decode(String.self, forKey: key),
               let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    private static func flexibleInt(
        _ values: KeyedDecodingContainer<CodingKeys>,
        _ keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let value = try? values.decode(Int.self, forKey: key) { return value }
            if let value = try? values.decode(Double.self, forKey: key), value.isFinite {
                return Int(value)
            }
            if let value = try? values.decode(String.self, forKey: key),
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }
}

struct CreditDetailsDTO: Decodable {
    var hasCredits: Bool?
    var unlimited: Bool?
    var balance: Double?

    private enum CodingKeys: String, CodingKey {
        case hasCredits, has_credits, unlimited, balance
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = (try? values.decode(Bool.self, forKey: .hasCredits))
            ?? (try? values.decode(Bool.self, forKey: .has_credits))
        unlimited = try? values.decode(Bool.self, forKey: .unlimited)
        if let value = try? values.decode(Double.self, forKey: .balance) {
            balance = value
        } else if let value = try? values.decode(Int.self, forKey: .balance) {
            balance = Double(value)
        } else if let value = try? values.decode(String.self, forKey: .balance) {
            balance = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var model: QuotaCredits? {
        if unlimited == true { return nil }
        guard let balance, balance.isFinite, balance >= 0 else { return nil }
        if hasCredits == false { return nil }
        return QuotaCredits(remaining: balance, label: "Credits")
    }
}

/// One malformed extra limit must not discard its siblings.
struct LossyAdditionalRateLimit: Decodable {
    var value: AdditionalRateLimitDTO?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(AdditionalRateLimitDTO.self)
    }

    static func decodeArray<Key: CodingKey>(
        _ values: KeyedDecodingContainer<Key>,
        keys: [Key]
    ) -> [AdditionalRateLimitDTO]? {
        for key in keys {
            if let decoded = try? values.decode([LossyAdditionalRateLimit].self, forKey: key) {
                let mapped = decoded.compactMap(\.value)
                return mapped.isEmpty ? nil : mapped
            }
        }
        return nil
    }
}
