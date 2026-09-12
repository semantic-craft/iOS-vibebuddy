import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Quota presentation")
struct QuotaPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("remaining shows both leftover and used except at the extremes")
    func remainingLine() {
        #expect(QuotaPresentation.remainingLine(usedPercent: 0) == "100% left")
        #expect(QuotaPresentation.remainingLine(usedPercent: 100) == "0% left · 100% used")
        #expect(QuotaPresentation.remainingLine(usedPercent: 41) == "59% left · 41% used")
        #expect(QuotaPresentation.remainingLine(remainingPercent: 59) == "59% left · 41% used")
    }

    @Test("reset line pairs a countdown with today/tomorrow/absolute time")
    func resetLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let laterToday = now.addingTimeInterval(2 * 3600 + 15 * 60)
        #expect(QuotaPresentation.resetCountdown(from: laterToday, now: now) == "in 2h 15m")
        let line = QuotaPresentation.resetLine(from: laterToday, now: now, calendar: calendar)
        #expect(line.hasPrefix("Resets in 2h 15m · "))
        let tomorrow = now.addingTimeInterval(26 * 3600)
        #expect(QuotaPresentation.resetAbsolute(from: tomorrow, now: now, calendar: calendar)
            .hasPrefix("tomorrow, "))
        #expect(QuotaPresentation.resetCountdown(from: now.addingTimeInterval(-1), now: now) == "now")
    }

    @Test("weekly pace compares used percent to a linear burn")
    func windowPace() {
        let reset = now.addingTimeInterval(4 * 24 * 60 * 60)
        #expect(QuotaPresentation.windowPace(usedPercent: 44, resetsAt: reset, windowMinutes: 10_080, now: now) == .onTrack)
        #expect(QuotaPresentation.windowPace(usedPercent: 90, resetsAt: reset, windowMinutes: 10_080, now: now) == .ahead)
        #expect(QuotaPresentation.windowPace(usedPercent: 5, resetsAt: reset, windowMinutes: 10_080, now: now) == .behind)
    }

    @Test("status-line keys become scoped titles")
    func extraTitles() {
        #expect(QuotaPresentation.extraWindowTitle(fromStatusLineKey: "seven_day_sonnet") == "Sonnet only")
        #expect(QuotaPresentation.scopedOnlyTitle("Fable") == "Fable only")
        #expect(QuotaPresentation.isAllModelsScope("all models"))
        #expect(QuotaPresentation.slug("Example Model Plus") == "example-model-plus")
    }
}
