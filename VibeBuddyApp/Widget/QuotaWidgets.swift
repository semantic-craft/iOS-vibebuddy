import AppIntents
import SwiftUI
import WidgetKit
import VibeBuddyKit

// MARK: - Configuration

/// The providers a quota widget can follow. Lives in the extension, not the
/// Kit: App Intents metadata is extracted per target (the Watch does the same).
enum PhoneQuotaProviderChoice: String, AppEnum {
    case codex, claude, cursor, grok, grokBot
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .codex: "Codex", .claude: "Claude", .cursor: "Cursor", .grok: "Grok Build", .grokBot: "Grok Bot"
    ]
    var provider: AccountUsageProvider { AccountUsageProvider(rawValue: rawValue) ?? .claude }
}

struct PhoneQuotaProviderIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage"
    static let description = IntentDescription("Choose whose allowance to show.")
    @Parameter(title: "Provider", default: .claude) var provider: PhoneQuotaProviderChoice
}

// MARK: - Timeline

struct PhoneQuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: PhoneQuotaSnapshot?
    var provider: AccountUsageProvider = .claude
}

/// When a quota widget needs a new face: the countdowns it shows reaching a
/// reset, the reading crossing the one-hour fade, and a quarter-hour step so
/// the age it prints keeps up. The timeline itself is asked for again every
/// half hour — a coarser countdown than the Watch's, for a smaller budget.
enum PhoneQuotaTimeline {
    static let refreshAfter: TimeInterval = 30 * 60

    static func entryDates(snapshot: PhoneQuotaSnapshot?, windows: [QuotaWindow], now: Date) -> [Date] {
        guard let snapshot else { return [now] }
        let boundaries = windows.compactMap(\.resetsAt)
            + QuotaFreshnessRule.fadeDates(snapshot)
            + [now.addingTimeInterval(15 * 60)]
        return [now] + Set(boundaries.filter { $0 > now }).sorted()
    }

    static func timeline(snapshot: PhoneQuotaSnapshot?, windows: [QuotaWindow], provider: AccountUsageProvider = .claude,
                         now: Date = Date()) -> Timeline<PhoneQuotaEntry> {
        let entries = entryDates(snapshot: snapshot, windows: windows, now: now)
            .map { PhoneQuotaEntry(date: $0, snapshot: snapshot, provider: provider) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(refreshAfter)))
    }

    /// Placeholder and gallery preview: the Demo scenario, never a real account.
    static func sample(now: Date = Date()) -> PhoneQuotaSnapshot {
        PhoneQuotaSnapshot(quotas: WatchDemoScenario.normal.quotas(now: now), macName: nil,
                           relayLive: true, savedAt: now, isDemo: true)
    }
}

struct PhoneQuotaProviderTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PhoneQuotaEntry {
        PhoneQuotaEntry(date: Date(), snapshot: PhoneQuotaTimeline.sample())
    }

    func snapshot(for configuration: PhoneQuotaProviderIntent, in context: Context) async -> PhoneQuotaEntry {
        let snapshot = context.isPreview ? PhoneQuotaTimeline.sample() : WidgetQuotaStore.load()
        return PhoneQuotaEntry(date: Date(), snapshot: snapshot, provider: configuration.provider.provider)
    }

    func timeline(for configuration: PhoneQuotaProviderIntent, in context: Context) async -> Timeline<PhoneQuotaEntry> {
        let snapshot = WidgetQuotaStore.load()
        let provider = configuration.provider.provider
        let quota = snapshot?.quotas.first { $0.provider == provider }
        let windows = quota.map { QuotaWidgetWindows.shown($0) } ?? []
        return PhoneQuotaTimeline.timeline(snapshot: snapshot, windows: windows, provider: provider)
    }

    func recommendations() -> [AppIntentRecommendation<PhoneQuotaProviderIntent>] {
        [PhoneQuotaProviderChoice.claude, .codex, .cursor, .grok, .grokBot].map { choice in
            let intent = PhoneQuotaProviderIntent()
            intent.provider = choice
            return AppIntentRecommendation(intent: intent, description: choice.provider.displayName)
        }
    }
}

struct PhoneQuotaOverviewTimeline: TimelineProvider {
    func placeholder(in context: Context) -> PhoneQuotaEntry {
        PhoneQuotaEntry(date: Date(), snapshot: PhoneQuotaTimeline.sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (PhoneQuotaEntry) -> Void) {
        completion(PhoneQuotaEntry(date: Date(), snapshot: context.isPreview ? PhoneQuotaTimeline.sample() : WidgetQuotaStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PhoneQuotaEntry>) -> Void) {
        let snapshot = WidgetQuotaStore.load()
        let windows = (snapshot?.quotas ?? []).map { $0.displayWindow(preferring: .weekly) }
        completion(PhoneQuotaTimeline.timeline(snapshot: snapshot, windows: windows))
    }
}

// MARK: - Widgets

struct PhoneQuotaProviderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetQuotaStore.providerKind, intent: PhoneQuotaProviderIntent.self,
                               provider: PhoneQuotaProviderTimeline()) { entry in
            PhoneQuotaProviderView(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("One provider's remaining allowance and when it resets.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct PhoneQuotaOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetQuotaStore.overviewKind, provider: PhoneQuotaOverviewTimeline()) { entry in
            PhoneQuotaOverviewView(entry: entry)
        }
        .configurationDisplayName("Usage overview")
        .description("Every provider's weekly allowance at a glance.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Shared pieces

/// Which windows a widget draws for one provider: the headline window the
/// Watch strip also uses, and at most one more.
enum QuotaWidgetWindows {
    static func headline(_ quota: ProviderQuota) -> QuotaWindow {
        quota.displayWindow(preferring: .weekly)
    }

    /// The short window; without one, the next independent pool (Cursor's
    /// second billing bucket); otherwise nothing. Scoped windows never.
    static func second(_ quota: ProviderQuota) -> QuotaWindow? {
        let headline = headline(quota)
        var others = quota.otherWindows ?? []
        if let index = others.firstIndex(where: { $0.label == headline.label && $0.resetsAt == headline.resetsAt
                                               && $0.remainingPercent == headline.remainingPercent }) {
            others.remove(at: index)
        }
        let short = quota.window(.short)
        let candidates = (short == headline ? [] : [short]) + others
        return candidates.first { $0.remainingPercent != nil }
    }

    static func shown(_ quota: ProviderQuota) -> [QuotaWindow] {
        [headline(quota)] + [second(quota)].compactMap { $0 }
    }

    /// `7d`, `5h`, `30d`: the key beside a widget bar.
    static func key(_ window: QuotaWindow) -> String {
        guard let minutes = window.durationMinutes else { return "—" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// `7-day`, or the pool's own name (`Cursor Models`) when it has one.
    static func name(_ window: QuotaWindow) -> String {
        if let label = window.label, !label.isEmpty { return label }
        guard let minutes = window.durationMinutes else { return String(localized: "Window") }
        if minutes % 1440 == 0 { return String(localized: "\(minutes / 1440)-day") }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60)-hour") }
        return String(localized: "\(minutes)-minute")
    }

    /// `4d 2h`, `2h 10m`, `35m`: the countdown after a `↻`.
    static func countdown(_ window: QuotaWindow, now: Date) -> String? {
        guard let reset = window.resetsAt else { return nil }
        let seconds = reset.timeIntervalSince(now)
        if seconds <= 0 { return String(localized: "now") }
        let total = max(1, Int(ceil(seconds / 60)))
        let days = total / 1440, hours = (total / 60) % 24, minutes = total % 60
        if days > 0 { return hours > 0 ? String(localized: "\(days)d \(hours)h") : String(localized: "\(days)d") }
        if hours > 0 { return minutes > 0 ? String(localized: "\(hours)h \(minutes)m") : String(localized: "\(hours)h") }
        return String(localized: "\(minutes)m")
    }

    static func abbreviation(_ provider: AccountUsageProvider) -> String {
        switch provider {
        case .codex: return "C"
        case .claude: return "CL"
        case .cursor: return "Cu"
        case .grok: return "G"
        case .grokBot: return "GB"
        }
    }
}

/// The provider's mark in a small bg2 tile. Brand colour lives here only;
/// every bar takes the threshold colour (PLAN §2.2).
private struct QuotaMark: View {
    let provider: AccountUsageProvider
    var size: CGFloat = 18

    var body: some View {
        SVGPathShape(provider.agentKind.brandMark)
            .fill(provider.agentKind.brandColor)
            .frame(width: size * 0.62, height: size * 0.62)
            .frame(width: size, height: size)
            .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A bullet on the home screen, or its empty track when there is no reading.
private struct WidgetBullet: View {
    let window: QuotaWindow?
    let now: Date
    let height: CGFloat
    let faded: Bool

    var body: some View {
        if let window, let remaining = window.currentRemainingPercent(now: now) {
            let pace = window.durationMinutes.flatMap { minutes in
                window.resetsAt.flatMap { QuotaPresentation.pacePercent(resetsAt: $0, windowMinutes: minutes, now: now) }
            }
            QuotaBullet(usedPercent: 100 - remaining, pacePercent: pace, height: height)
                .opacity(faded ? 0.45 : 1)
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline)
                .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .frame(height: height)
        }
    }
}

private func percentText(_ window: QuotaWindow?, now: Date) -> (String, Color) {
    guard let remaining = window?.currentRemainingPercent(now: now) else { return ("—", CompanionPalette.ink3) }
    return ("\(remaining)%", QuotaPresentation.severity(usedPercent: 100 - remaining).tint)
}

private struct QuotaWidgetEmpty: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Text("—").font(CompanionType.fixedFont(16, .semibold))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage").font(CompanionType.fixedFont(13, .semibold))
                Text("Pair your Mac in Vibebuddy").font(CompanionType.fixedFont(11)).opacity(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage")
                    .font(CompanionType.fixedFont(11, .semibold))
                    .foregroundStyle(CompanionPalette.ink3)
                Spacer(minLength: 0)
                Text("Pair your Mac")
                    .font(CompanionType.fixedFont(14, .bold))
                    .foregroundStyle(CompanionPalette.ink)
                Text("Open Vibebuddy to start.")
                    .font(CompanionType.fixedFont(12))
                    .foregroundStyle(CompanionPalette.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 13)
        }
    }
}

private extension View {
    /// White ground on the home screen; the system's translucent disc or
    /// plate on the lock screen, where the widget draws in white.
    func quotaWidgetBackground(_ family: WidgetFamily) -> some View {
        containerBackground(for: .widget) {
            switch family {
            case .accessoryCircular, .accessoryRectangular, .accessoryInline: AccessoryWidgetBackground()
            default: CompanionPalette.bg
            }
        }
    }
}

// MARK: - One provider (small, lock screen)

struct PhoneQuotaProviderView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PhoneQuotaEntry

    private var now: Date { max(entry.date, Date()) }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.quotas.isEmpty {
                let quota = snapshot.quotas.first { $0.provider == entry.provider }
                switch family {
                case .accessoryRectangular: rectangular(snapshot, quota: quota)
                case .accessoryCircular: circular(snapshot, quota: quota)
                default: small(snapshot, quota: quota)
                }
            } else {
                QuotaWidgetEmpty()
            }
        }
        .quotaWidgetBackground(family)
        .widgetURL(entry.snapshot?.quotas.isEmpty == false ? VibeBuddyDeepLink.quotaURL(entry.provider) : nil)
    }

    private func small(_ snapshot: PhoneQuotaSnapshot, quota: ProviderQuota?) -> some View {
        let quotas = quota.map { [$0] } ?? []
        let faded = QuotaFreshnessRule.faded(snapshot, quotas: quotas, now: now)
        let headline = quota.map(QuotaWidgetWindows.headline)
        let second = quota.flatMap(QuotaWidgetWindows.second)
        let (value, tint) = percentText(headline, now: now)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                QuotaMark(provider: entry.provider)
                Text(entry.provider.displayName).lineLimit(1)
                Spacer(minLength: 4)
                if let age = QuotaFreshnessRule.age(snapshot, quotas: quotas, now: now) { Text(age).lineLimit(1) }
            }
            .font(CompanionType.fixedFont(11, .semibold))
            .foregroundStyle(CompanionPalette.ink3)
            Text(value)
                .font(CompanionType.fixedFont(34, .heavy))
                .tracking(-1)
                .monospacedDigit()
                .foregroundStyle(tint)
                .padding(.top, 8)
            Group {
                if quota == nil {
                    Text("Not provided by this Mac")
                } else if let headline {
                    let countdown = QuotaWidgetWindows.countdown(headline, now: now)
                    Text(countdown.map { "\(QuotaWidgetWindows.name(headline)) · ↻ \($0)" } ?? QuotaWidgetWindows.name(headline))
                }
            }
            .font(CompanionType.fixedFont(12))
            .foregroundStyle(CompanionPalette.ink2)
            .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if let headline {
                VStack(spacing: 6) {
                    barRow(headline, showsPercent: false, faded: faded)
                    if let second { barRow(second, showsPercent: true, faded: faded) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    private func barRow(_ window: QuotaWindow, showsPercent: Bool, faded: Bool) -> some View {
        HStack(spacing: 8) {
            Text(QuotaWidgetWindows.key(window))
                .font(CompanionType.fixedFont(11, .semibold))
                .foregroundStyle(CompanionPalette.ink3)
                .frame(width: 24, alignment: .leading)
            WidgetBullet(window: window, now: now, height: 8, faded: faded)
            if showsPercent {
                let (value, _) = percentText(window, now: now)
                Text(value)
                    .font(CompanionType.fixedFont(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(CompanionPalette.ink)
            }
        }
    }

    /// Lock screen, rectangular: this provider's headline window over a
    /// white bar, and the other of Codex / Claude underneath.
    private func rectangular(_ snapshot: PhoneQuotaSnapshot, quota: ProviderQuota?) -> some View {
        let headline = quota.map(QuotaWidgetWindows.headline)
        let otherProvider: AccountUsageProvider = entry.provider == .claude ? .codex : .claude
        let other = snapshot.quotas.first { $0.provider == otherProvider }.map(QuotaWidgetWindows.headline)
        let faded = QuotaFreshnessRule.faded(snapshot, quotas: quota.map { [$0] } ?? [], now: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(entry.provider.displayName) \(headline.map(QuotaWidgetWindows.name) ?? "")").lineLimit(1)
                Spacer(minLength: 4)
                Text(percentText(headline, now: now).0).monospacedDigit()
            }
            .font(CompanionType.fixedFont(13, .semibold))
            AccessoryBar(window: headline, now: now)
                .opacity(faded ? 0.45 : 1)
            HStack(spacing: 4) {
                Text("\(otherProvider.displayName) \(percentText(other, now: now).0)").lineLimit(1)
                Spacer(minLength: 4)
                if let countdown = headline.flatMap({ QuotaWidgetWindows.countdown($0, now: now) }) {
                    Text("↻ \(countdown)").lineLimit(1)
                }
            }
            .font(CompanionType.fixedFont(11))
            .monospacedDigit()
            .opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Lock screen, circular: a ring of what is left around the provider's
    /// abbreviation — the Watch's labels.
    private func circular(_ snapshot: PhoneQuotaSnapshot, quota: ProviderQuota?) -> some View {
        let headline = quota.map(QuotaWidgetWindows.headline)
        let remaining = headline?.currentRemainingPercent(now: now)
        let faded = QuotaFreshnessRule.faded(snapshot, quotas: quota.map { [$0] } ?? [], now: now)
        return ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 4).padding(3)
            if let remaining, remaining > 0 {
                Circle().trim(from: 0, to: CGFloat(remaining) / 100)
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
                    .opacity(faded ? 0.45 : 1)
                    .widgetAccentable()
            }
            VStack(spacing: 0) {
                Text(QuotaWidgetWindows.abbreviation(entry.provider))
                    .font(CompanionType.fixedFont(10, .semibold))
                Text(remaining.map { "\($0)%" } ?? "—")
                    .font(CompanionType.fixedFont(12, .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The lock screen's monochrome bar: white spent share over a faint track,
/// with the pace tick. Threshold colour cannot survive the accessory tint.
private struct AccessoryBar: View {
    let window: QuotaWindow?
    let now: Date

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let remaining = window?.currentRemainingPercent(now: now)
            let pace = window.flatMap { window in
                window.durationMinutes.flatMap { minutes in
                    window.resetsAt.flatMap { QuotaPresentation.pacePercent(resetsAt: $0, windowMinutes: minutes, now: now) }
                }
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.white.opacity(0.22))
                if let remaining {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.white)
                        .frame(width: max(2, width * CGFloat(100 - remaining) / 100))
                        .padding(.vertical, 2)
                        .widgetAccentable()
                }
                if let pace {
                    Rectangle().fill(.white.opacity(0.7))
                        .frame(width: 2)
                        .offset(x: width * CGFloat(pace) / 100 - 1)
                }
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Every provider (medium)

struct PhoneQuotaOverviewView: View {
    let entry: PhoneQuotaEntry
    private var now: Date { max(entry.date, Date()) }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.quotas.isEmpty {
                content(snapshot)
            } else {
                QuotaWidgetEmpty()
            }
        }
        .quotaWidgetBackground(.systemMedium)
        .widgetURL(entry.snapshot?.quotas.isEmpty == false ? VibeBuddyDeepLink.quotaURL(nil) : nil)
    }

    private func content(_ snapshot: PhoneQuotaSnapshot) -> some View {
        let fadedProviders = QuotaFreshnessRule.fadedProviders(snapshot, now: now)
        let mac = snapshot.macName ?? (snapshot.isDemo ? String(localized: "Demo") : "Mac")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Usage · \(mac)").lineLimit(1)
                Spacer(minLength: 4)
                if let age = QuotaFreshnessRule.age(snapshot, quotas: snapshot.quotas, now: now) { Text(age) }
            }
            .font(CompanionType.fixedFont(11, .semibold))
            .foregroundStyle(CompanionPalette.ink3)
            Spacer(minLength: 6)
            VStack(spacing: 5) {
                ForEach(AccountUsageProvider.allCases) { provider in
                    row(provider, quota: snapshot.quotas.first { $0.provider == provider },
                        faded: fadedProviders.contains(provider))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
    }

    private func row(_ provider: AccountUsageProvider, quota: ProviderQuota?, faded: Bool) -> some View {
        let window = quota.map(QuotaWidgetWindows.headline)
        let (value, tint) = percentText(window, now: now)
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                QuotaMark(provider: provider, size: 16)
                Text(provider.displayName)
                    .font(CompanionType.fixedFont(11, .medium))
                    .foregroundStyle(quota == nil ? CompanionPalette.ink3 : CompanionPalette.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 80, alignment: .leading)
            WidgetBullet(window: window, now: now, height: 9, faded: faded)
            Text(value)
                .font(CompanionType.fixedFont(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews (the four prototype states)

private enum QuotaWidgetPreview {
    static let now = Date()
    static var live: PhoneQuotaSnapshot {
        var snapshot = PhoneQuotaTimeline.sample(now: now)
        snapshot.macName = "Studio Mac"
        snapshot.isDemo = false
        return snapshot
    }
    static var unreachable: PhoneQuotaSnapshot {
        var snapshot = live
        snapshot.relayLive = false
        snapshot.quotas = snapshot.quotas.map { quota in
            var quota = quota
            quota.observedAt = now.addingTimeInterval(-18 * 60)
            return quota
        }
        return snapshot
    }
    static var nearLimit: PhoneQuotaSnapshot {
        var snapshot = live
        snapshot.quotas = snapshot.quotas.map { quota in
            var quota = quota
            if quota.provider == .claude { quota.weeklyRemainingPercent = 6 }
            if quota.provider == .codex { quota.shortWindowRemainingPercent = 18 }
            if quota.provider == .grok { quota.weeklyRemainingPercent = 4 }
            return quota
        }
        return snapshot
    }
    static func entries() -> [PhoneQuotaEntry] {
        [live, unreachable, nearLimit].map { PhoneQuotaEntry(date: now, snapshot: $0) }
            + [PhoneQuotaEntry(date: now, snapshot: nil)]
    }
}

#Preview("Small", as: .systemSmall) {
    PhoneQuotaProviderWidget()
} timeline: {
    for entry in QuotaWidgetPreview.entries() { entry }
}

#Preview("Medium", as: .systemMedium) {
    PhoneQuotaOverviewWidget()
} timeline: {
    for entry in QuotaWidgetPreview.entries() { entry }
}

#Preview("Rectangular", as: .accessoryRectangular) {
    PhoneQuotaProviderWidget()
} timeline: {
    for entry in QuotaWidgetPreview.entries() { entry }
}

#Preview("Circular", as: .accessoryCircular) {
    PhoneQuotaProviderWidget()
} timeline: {
    for entry in QuotaWidgetPreview.entries() { entry }
}
