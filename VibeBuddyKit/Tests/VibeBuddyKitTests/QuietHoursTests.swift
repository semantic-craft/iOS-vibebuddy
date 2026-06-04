import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("QuietHours")
struct QuietHoursTests {

    /// A deterministic UTC calendar + a date at a given UTC hour.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 6, day: 5, hour: hour))!
    }

    @Test("disabled is never quiet")
    func disabled() {
        let q = QuietHours(enabled: false, startHour: 22, endHour: 8)
        #expect(!q.isQuiet(at: date(hour: 2), calendar: cal))
    }

    @Test("a midnight-wrapping window covers late night and early morning")
    func wrapsMidnight() {
        let q = QuietHours(enabled: true, startHour: 22, endHour: 8)
        #expect(q.isQuiet(at: date(hour: 23), calendar: cal))   // late night
        #expect(q.isQuiet(at: date(hour: 2), calendar: cal))    // early morning
        #expect(q.isQuiet(at: date(hour: 22), calendar: cal))   // inclusive start
        #expect(!q.isQuiet(at: date(hour: 8), calendar: cal))   // exclusive end
        #expect(!q.isQuiet(at: date(hour: 12), calendar: cal))  // midday
    }

    @Test("a same-day window stays within the day")
    func sameDay() {
        let q = QuietHours(enabled: true, startHour: 9, endHour: 17)
        #expect(q.isQuiet(at: date(hour: 12), calendar: cal))
        #expect(!q.isQuiet(at: date(hour: 8), calendar: cal))
        #expect(!q.isQuiet(at: date(hour: 17), calendar: cal))  // exclusive end
    }

    @Test("an empty window (start == end) is never quiet")
    func emptyWindow() {
        let q = QuietHours(enabled: true, startHour: 8, endHour: 8)
        #expect(!q.isQuiet(at: date(hour: 8), calendar: cal))
    }
}
