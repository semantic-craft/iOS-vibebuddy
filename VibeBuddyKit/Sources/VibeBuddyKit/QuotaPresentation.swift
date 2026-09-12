import Foundation

/// Credits remaining on an account pool (prepaid, monthly cap, reset credits).
/// Optional on the wire so older phones ignore it.
public struct QuotaCredits: Codable, Equatable, Sendable {
    public var remaining: Double
    public var limit: Double?
    public var remainingPercent: Int?
    public var resetsAt: Date?
    public var label: String?

    public init(
        remaining: Double,
        limit: Double? = nil,
        remainingPercent: Int? = nil,
        resetsAt: Date? = nil,
        label: String? = nil
    ) {
        self.remaining = remaining
        self.limit = limit
        self.remainingPercent = remainingPercent.flatMap { (0...100).contains($0) ? $0 : nil }
        self.resetsAt = resetsAt
        self.label = label
    }
}

/// One billed or estimated spend figure. Not an invoice.
public struct QuotaSpend: Codable, Equatable, Sendable, Identifiable {
    public var label: String
    public var amount: Double
    public var currencyCode: String

    public var id: String { label }

    public init(label: String, amount: Double, currencyCode: String = "USD") {
        self.label = label
        self.amount = amount
        self.currencyCode = currencyCode
    }
}

/// How a weekly window is tracking against a linear burn to reset.
public enum QuotaPace: String, Sendable {
    case onTrack
    case ahead
    case behind

    public var caption: String {
        switch self {
        case .onTrack: return "On track for this window"
        case .ahead: return "Ahead of this window's pace"
        case .behind: return "Behind this window's pace"
        }
    }
}

/// Local remaining/reset wording. English like the rest of the usage surfaces;
/// not CodexBar's localization stack.
public enum QuotaPresentation {
    public static func remainingLine(usedPercent: Int) -> String {
        let remaining = max(0, min(100, 100 - usedPercent))
        if remaining == 0 { return "0% left · \(usedPercent)% used" }
        if remaining == 100 { return "100% left" }
        return "\(remaining)% left · \(usedPercent)% used"
    }

    public static func remainingLine(remainingPercent: Int) -> String {
        remainingLine(usedPercent: max(0, min(100, 100 - remainingPercent)))
    }

    public static func resetCountdown(from date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        let totalMinutes = max(1, Int(ceil(seconds / 60)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 {
            if hours > 0 { return "in \(days)d \(hours)h" }
            return "in \(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h"
        }
        return "in \(totalMinutes)m"
    }

    public static func resetAbsolute(from date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow, \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    public static func resetLine(from date: Date, now: Date, calendar: Calendar = .current) -> String {
        let countdown = resetCountdown(from: date, now: now)
        if countdown == "now" { return "Resets now" }
        return "Resets \(countdown) · \(resetAbsolute(from: date, now: now, calendar: calendar))"
    }

    public static func creditsLine(_ credits: QuotaCredits) -> String {
        let number = creditsNumber(credits.remaining)
        if let limit = credits.limit, limit > 0 {
            return "\(number) / \(creditsNumber(limit)) left"
        }
        return "\(number) left"
    }

    public static func creditsLine(_ credits: QuotaCredits?) -> String? {
        credits.map(creditsLine)
    }

    /// CodexBar-style stable id fragment: letters and digits, dashes between.
    public static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func scopedOnlyTitle(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Scoped week" : "\(trimmed) only"
    }

    /// `seven_day_sonnet` → `Sonnet only`.
    public static func extraWindowTitle(fromStatusLineKey key: String) -> String {
        var name = key
        let lowered = key.lowercased()
        for prefix in ["seven_day_", "five_hour_", "seven-day-", "five-hour-"] where lowered.hasPrefix(prefix) {
            name = String(key.dropFirst(prefix.count))
            break
        }
        let words = name.split { $0 == "_" || $0 == "-" }
            .map { $0.lowercased().capitalized }
            .joined(separator: " ")
        return scopedOnlyTitle(words.isEmpty ? key : words)
    }

    public static func isAllModelsScope(_ name: String) -> Bool {
        slug(name) == "all-models" || slug(name).hasSuffix("-all-models")
    }

    public static func spendLine(_ spend: QuotaSpend) -> String {
        spend.amount.formatted(.currency(code: spend.currencyCode).locale(Locale(identifier: "en_US")))
    }

    public static func weeklyPace(
        usedPercent: Int,
        resetsAt: Date,
        windowMinutes: Int,
        now: Date
    ) -> QuotaPace? {
        guard windowMinutes > 0, resetsAt > now else { return nil }
        let duration = TimeInterval(windowMinutes * 60)
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining <= duration else { return nil }
        let elapsed = max(0, duration - remaining)
        if elapsed == 0 { return usedPercent == 0 ? .onTrack : nil }
        let expected = (elapsed / duration) * 100
        let delta = Double(usedPercent) - expected
        if abs(delta) <= 6 { return .onTrack }
        return delta > 0 ? .ahead : .behind
    }

    public static func creditsNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value >= 100 ? 0 : 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
