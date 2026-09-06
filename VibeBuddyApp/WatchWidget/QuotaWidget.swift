import AppIntents
import SwiftUI
import WidgetKit
import VibeBuddyKit

enum QuotaPlatform: String, AppEnum {
    case codex, claude, both
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Platform"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .codex: "Codex", .claude: "Claude", .both: "Codex + Claude"
    ]
    var selection: WatchQuotaSelection { WatchQuotaSelection(rawValue: rawValue)! }
}

enum QuotaPeriod: String, AppEnum {
    case weekly, short
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Window"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .weekly: "Weekly window", .short: "Short window"
    ]
    var kind: QuotaWindowKind { self == .weekly ? .weekly : .short }
}

enum QuotaStyle: String, AppEnum {
    case ring, numbers, segments, dualWindow, countdown
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .ring: "Remaining ring", .numbers: "Numbers first", .segments: "Ten-segment ring",
        .dualWindow: "Two windows", .countdown: "Reset countdown"
    ]
}

struct QuotaConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Quota"
    static let description = IntentDescription("Choose the allowance to show on your watch face.")
    @Parameter(title: "Platform", default: .both) var platform: QuotaPlatform
    @Parameter(title: "Style", default: .ring) var style: QuotaStyle
    @Parameter(title: "Window", default: .weekly) var period: QuotaPeriod
    static var parameterSummary: some ParameterSummary {
        When(\.$style, .equalTo, QuotaStyle.dualWindow) {
            Summary { \.$platform; \.$style }
        } otherwise: {
            Summary { \.$platform; \.$style; \.$period }
        }
    }
}

struct QuotaEntry: TimelineEntry {
    let date: Date
    let configuration: QuotaConfiguration
    let quotas: [ProviderQuota]
}

struct QuotaProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { sample(configuration: QuotaConfiguration()) }
    func snapshot(for configuration: QuotaConfiguration, in context: Context) async -> QuotaEntry {
        if context.isPreview { return sample(configuration: configuration) }
        return QuotaEntry(date: .now, configuration: configuration, quotas: readQuotas())
    }
    func recommendations() -> [AppIntentRecommendation<QuotaConfiguration>] { [] }
    func timeline(for configuration: QuotaConfiguration, in context: Context) async -> Timeline<QuotaEntry> {
        let now = Date()
        let quotas = readQuotas()
        let windows = quotas.filter { configuration.platform.selection.providers.contains($0.provider) }
            .flatMap { quota in
                configuration.style == .dualWindow ? QuotaWindowKind.allCases.map { quota.window($0) } : [quota.window(configuration.period.kind)]
            }
        let boundaries = windows.flatMap { window in
            [window.observedAt?.addingTimeInterval(ProviderQuota.staleAfter), window.resetsAt].compactMap { $0 }
        }.filter { $0 > now }
        let countdownDates = configuration.style == .countdown ? windows.flatMap { reading in
            reading.resetsAt.map { Self.countdownUpdates(from: now, until: $0) } ?? []
        } : []
        let dates = [now] + Set(boundaries + countdownDates).sorted()
        return Timeline(entries: dates.map { QuotaEntry(date: $0, configuration: configuration, quotas: quotas) }, policy: .never)
    }
    // Only local timeline entries: one change per displayed unit, with a finite end.
    static func countdownUpdates(from now: Date, until reset: Date) -> [Date] {
        guard reset > now else { return [] }
        var dates: [Date] = []
        var cursor = now
        while cursor < reset, dates.count < 100 {
            let remaining = reset.timeIntervalSince(cursor)
            if remaining < 60 { dates.append(reset); break }
            let unit: Double = remaining >= 86400 ? 86400 : remaining >= 3600 ? 3600 : 60
            let count = max(1, ceil(remaining / unit))
            let unitBoundary = reset.addingTimeInterval(-(count - 1) * unit)
            let scaleBoundary = reset.addingTimeInterval(-(unit == 86400 ? 86400 : unit == 3600 ? 3600 : 60) + 1)
            let next = max(cursor.addingTimeInterval(1), min(unitBoundary, scaleBoundary))
            dates.append(min(next, reset))
            cursor = next
        }
        return dates
    }
    private func readQuotas() -> [ProviderQuota] {
        guard let state = WatchComplicationStore.loadState()?.state,
              state.sourceID != nil, state.pairingEpoch != nil, state.relay != .noData else { return [] }
        return state.quotas.map { quota in
            var reading = quota
            if state.relay != .live { reading.isCached = true }
            return reading
        }
    }
    private func sample(configuration: QuotaConfiguration) -> QuotaEntry {
        let now = Date()
        return QuotaEntry(date: now, configuration: configuration, quotas: [
            ProviderQuota(provider: .codex, weeklyRemainingPercent: 68, weeklyResetsAt: now.addingTimeInterval(187200), weeklyWindowDurationMinutes: 10080,
                          shortWindowRemainingPercent: 31, shortWindowDurationMinutes: 300, observedAt: now),
            ProviderQuota(provider: .claude, weeklyRemainingPercent: 42, weeklyResetsAt: now.addingTimeInterval(108000), weeklyWindowDurationMinutes: 10080,
                          shortWindowRemainingPercent: 76, shortWindowDurationMinutes: 300, observedAt: now)
        ])
    }
}

struct QuotaWidgetView: View {
    let entry: QuotaEntry
    private var now: Date { max(entry.date, Date()) }
    private var providers: [AccountUsageProvider] { entry.configuration.platform.selection.providers }
    private func window(_ provider: AccountUsageProvider, kind: QuotaWindowKind? = nil) -> QuotaWindow {
        entry.quotas.first { $0.provider == provider }?.window(kind ?? entry.configuration.period.kind)
            ?? QuotaWindow(remainingPercent: nil, durationMinutes: nil, resetsAt: nil, observedAt: nil)
    }
    private func label(_ provider: AccountUsageProvider) -> String {
        switch provider {
        case .codex: return "C"
        case .claude: return "CL"
        case .grok: return "G"
        case .cursor: return "Cu"
        }
    }
    private func color(_ provider: AccountUsageProvider) -> Color {
        switch provider {
        case .codex: return .cyan
        case .claude: return .orange
        case .grok: return .indigo
        case .cursor: return .purple
        }
    }
    private func periodLabel(_ reading: QuotaWindow, kind: QuotaWindowKind? = nil) -> String {
        if (kind ?? entry.configuration.period.kind) == .weekly { return String(localized: "Wk") }
        guard let minutes = reading.durationMinutes else { return String(localized: "Short") }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }
    private var differentPeriods: Bool {
        Set(providers.map { periodLabel(window($0)) }).count > 1
    }
    private func rowLabel(_ provider: AccountUsageProvider) -> String {
        differentPeriods ? "\(label(provider)) \(periodLabel(window(provider)))" : label(provider)
    }
    private func value(_ reading: QuotaWindow) -> String {
        let value = reading.currentRemainingPercent(now: now).map { "\($0)%" } ?? "—"
        switch reading.status(now: now) {
        case .stale: return value + "·"
        case .awaitingReset: return "↻"
        default: return value
        }
    }
    private func countdown(_ reading: QuotaWindow) -> String {
        guard reading.status(now: now) != .unavailable else { return "—" }
        guard let reset = reading.resetsAt else { return "—" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "↻" }
        if seconds < 60 { return "<1m" }
        if seconds >= 86400 { return "\(Int(ceil(seconds / 86400)))d" }
        if seconds >= 3600 { return "\(Int(ceil(seconds / 3600)))h" }
        return "\(Int(ceil(seconds / 60)))m"
    }

    @ViewBuilder private var figures: some View {
        VStack(spacing: 0) {
            ForEach(providers) { provider in
                Text("\(rowLabel(provider)) \(value(window(provider)))")
                    .font(.system(size: providers.count == 1 ? 15 : 11, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1)
            }
            if !differentPeriods, let provider = providers.first {
                Text(periodLabel(window(provider))).font(.system(size: 10)).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func rings(segmented: Bool) -> some View {
        ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
            let reading = window(provider)
            let inset = CGFloat(index) * 5 + 2
            let remaining = CGFloat(reading.currentRemainingPercent(now: now) ?? 0) / 100
            let tint = color(provider).opacity(reading.status(now: now) == .stale ? 0.4 : 1)
            if segmented {
                ForEach(0..<10) { segment in
                    let start = CGFloat(segment) / 10 + 0.012
                    let end = CGFloat(segment + 1) / 10 - 0.012
                    Circle().trim(from: start, to: end).stroke(.secondary.opacity(0.2), lineWidth: 3)
                        .rotationEffect(.degrees(-90)).padding(inset)
                    let fraction = min(1, max(0, remaining * 10 - CGFloat(segment)))
                    if fraction > 0 {
                        Circle().trim(from: start, to: start + (end - start) * fraction)
                            .stroke(tint, lineWidth: 3).rotationEffect(.degrees(-90)).padding(inset).widgetAccentable()
                    }
                }
            } else {
                Circle().stroke(.secondary.opacity(0.2), lineWidth: 3).padding(inset)
                if remaining > 0 {
                    Circle().trim(from: 0, to: remaining)
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(inset).widgetAccentable()
                }
            }
        }
    }

    private var dualWindows: some View {
        VStack(spacing: 1) {
            ForEach(providers) { provider in
                // Each provider gets its own duration labels; unequal short windows remain truthful.
                HStack(spacing: 2) {
                    Text(label(provider)).fontWeight(.bold)
                    VStack(spacing: 0) {
                        ForEach(QuotaWindowKind.allCases, id: \.self) { kind in
                            let reading = window(provider, kind: kind)
                            Text("\(periodLabel(reading, kind: kind)) \(value(reading))")
                        }
                    }
                }
            }
        }.font(.system(size: 10, design: .rounded)).monospacedDigit().lineLimit(1)
    }

    private var countdowns: some View {
        VStack(spacing: 0) {
            ForEach(providers) { provider in
                let reading = window(provider)
                Text("\(label(provider)) \(countdown(reading))")
                    .font(.system(size: providers.count == 1 ? 15 : 12, weight: .semibold, design: .rounded))
                Text("\(periodLabel(reading)) \(value(reading))")
                    .font(.system(size: 10, design: .rounded))
            }
        }.monospacedDigit().lineLimit(1)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                switch entry.configuration.style {
                case .ring, .segments:
                    rings(segmented: entry.configuration.style == .segments)
                    figures
                case .numbers: figures
                case .dualWindow: dualWindows
                case .countdown: countdowns
                }
            }.frame(width: size, height: size).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .widgetURL(entry.configuration.platform.selection.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    private var accessibilitySummary: String {
        providers.map { provider in
            let kinds = entry.configuration.style == .dualWindow ? QuotaWindowKind.allCases : [entry.configuration.period.kind]
            return kinds.map { kind in
            let reading = window(provider, kind: kind)
            let status: String
            switch reading.status(now: now) {
            case .live: status = String(localized: "Remaining")
            case .stale: status = String(localized: "Cached reading")
            case .unavailable: status = String(localized: "Window unavailable")
            case .awaitingReset: status = String(localized: "Reset reached · awaiting update")
            }
            let reset = reading.resetsAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Reset time unknown")
            return "\(provider.displayName), \(periodLabel(reading, kind: kind)), \(status), \(value(reading)), \(String(localized: "Reset")): \(reset)"
            }.joined(separator: "; ")
        }.joined(separator: "; ")
    }
}

struct QuotaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WatchComplicationStore.quotaKind, intent: QuotaConfiguration.self, provider: QuotaProvider()) {
            QuotaWidgetView(entry: $0)
        }
        .configurationDisplayName("Quota")
        .description("Codex and Claude remaining allowance.")
        .supportedFamilies([.accessoryCircular])
    }
}
