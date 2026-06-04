import Foundation

/// A nightly window during which only approvals make a sound (auto Quiet mode).
/// Shared by Mac and iOS so "is it quiet right now" is decided identically.
public struct QuietHours: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Local hours [0, 23]. A window where `start > end` wraps midnight (22→8).
    public var startHour: Int
    public var endHour: Int

    public init(enabled: Bool = false, startHour: Int = 22, endHour: Int = 8) {
        self.enabled = enabled
        self.startHour = startHour
        self.endHour = endHour
    }

    /// Whether `date`'s local hour falls inside the (possibly midnight-wrapping) window.
    public func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startHour != endHour else { return false }
        let h = calendar.component(.hour, from: date)
        return startHour < endHour
            ? (h >= startHour && h < endHour)        // same-day window
            : (h >= startHour || h < endHour)        // wraps midnight
    }
}
