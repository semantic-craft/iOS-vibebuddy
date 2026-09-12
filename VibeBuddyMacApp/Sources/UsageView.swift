import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

struct AccountUsageSummaryView: View {
    let provider: AccountUsageProvider
    let state: AccountUsageState
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                summary(now: context.date)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func summary(now: Date) -> some View {
            if let snapshot = state.snapshot?.excludingExpiredGrokWindows(at: now) {
                if let account = snapshot.accountLabel {
                    Text(account).font(.caption).foregroundStyle(.secondary)
                }
                if let detail = snapshot.usageDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let available = snapshot.hasAvailableUsage {
                    Text(available ? "Usage available" : "No usage available").font(.caption)
                        .foregroundStyle(available ? Color.secondary : Color.orange)
                }
                if provider == .grokBot, snapshot.primary == nil, snapshot.usageDetail == nil {
                    Text("Weekly percentage unavailable").foregroundStyle(.secondary)
                }
                if provider == .grok, snapshot.primary == nil {
                    if state.unavailableReason != .unknown {
                        Text("Usage is temporarily unavailable").foregroundStyle(.secondary)
                    }
                    if let end = snapshot.periodEnd {
                        Text("Period ends \(end.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if snapshot.displayWindows.isEmpty {
                    if provider != .grok && provider != .grokBot {
                        Label("No quota windows supplied", systemImage: "gauge.with.dots.needle.0percent")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(snapshot.displayWindows) { window in
                        windowRow(window, now: now)
                    }
                }

                if let credits = snapshot.credits {
                    LabeledContent(credits.label ?? "Credits", value: QuotaPresentation.creditsLine(credits))
                        .font(.caption)
                    if let reset = credits.resetsAt {
                        Text(QuotaPresentation.resetLine(from: reset, now: now))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let spend = snapshot.spend, !spend.isEmpty {
                    ForEach(spend) { row in
                        LabeledContent(row.label, value: QuotaPresentation.spendLine(row))
                            .font(.caption)
                    }
                }

                if !compact, snapshot.latestDailyTokens != nil || snapshot.lifetimeTokens != nil {
                    HStack(spacing: 12) {
                        if let tokens = snapshot.latestDailyTokens {
                            LabeledContent("Latest day", value: tokens.formatted())
                        }
                        if let tokens = snapshot.lifetimeTokens {
                            LabeledContent("Lifetime", value: tokens.formatted())
                        }
                    }
                    .font(.caption)
                }

                HStack(spacing: 5) {
                    Text("Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    if let plan = snapshot.planType, !plan.isEmpty {
                        Text("· \(plan)")
                    }
                    if state.isStale {
                        Text("· Stale").foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if let reason = state.unavailableReason {
                Label(reason.displayText(provider: provider), systemImage: reasonIcon(reason))
                    .font(.caption)
                    .foregroundStyle(reason == .collectionDisabled ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if reason != .collectionDisabled, let retry = state.nextRefreshAt, retry > now {
                    Text("Retry \(retry, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
    }

    private func windowRow(_ window: AccountUsageWindow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(windowTitle(window)).font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text(QuotaPresentation.remainingLine(usedPercent: window.usedPercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(QuotaPresentation.severity(usedPercent: window.usedPercent).tint)
            }
            QuotaBullet(usedPercent: window.usedPercent,
                        pacePercent: Self.pacePercent(window, now: now),
                        height: compact ? 10 : 12)
            if let reset = window.resetsAt {
                Text(QuotaPresentation.resetLine(from: reset, now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Reset time unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let minutes = window.windowDurationMinutes, minutes >= 60,
               let reset = window.resetsAt,
               let pace = QuotaPresentation.weeklyPace(
                usedPercent: window.usedPercent,
                resetsAt: reset,
                windowMinutes: minutes,
                now: now
               ) {
                Text(pace.caption)
                    .font(.caption2)
                    .foregroundStyle(pace == .ahead ? QuotaPresentation.Severity.warning.tint : Color.secondary)
            }
        }
    }

    /// Where even spending would have reached by now — the bullet's tick.
    static func pacePercent(_ window: AccountUsageWindow, now: Date) -> Int? {
        guard let minutes = window.windowDurationMinutes, let reset = window.resetsAt else { return nil }
        return QuotaPresentation.pacePercent(resetsAt: reset, windowMinutes: minutes, now: now)
    }

    private func windowTitle(_ window: AccountUsageWindow) -> String {
        if provider == .grok, window.kind == .secondary { return "Extra usage" }
        if let label = window.label { return label }
        guard let minutes = window.windowDurationMinutes else {
            switch window.kind {
            case .primary: return "Primary window"
            case .secondary: return "Secondary window"
            case .extra: return "Extra window"
            }
        }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080)-week window" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day window" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour window" }
        return "\(minutes)-minute window"
    }

    private func reasonIcon(_ reason: AccountUsageUnavailableReason) -> String {
        switch reason {
        case .collectionDisabled: "pause.circle"
        case .notLoggedIn: "person.crop.circle.badge.exclamationmark"
        case .offline: "wifi.slash"
        case .rateLimited: "hourglass"
        case .timedOut: "clock.badge.exclamationmark"
        case .incompatibleFormat: "questionmark.app.dashed"
        case .providerUnavailable: "terminal"
        case .cachedData, .notYetLoaded: "arrow.clockwise"
        case .unknown: "exclamationmark.triangle"
        }
    }
}

/// What each account has left. The live meters are the point of the page, so
/// the only setting on it is the threshold that turns them into an alert.
struct PlanAndQuotaPage: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("accountUsageAlertThreshold") private var alertThreshold = 90

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        SettingsPageScaffold(SettingsPageID.quota.title, subtitle: SettingsPageID.quota.subtitle) {
            SettingsSection("Alerts",
                            footnote: "One threshold applies to every provider. Alerts identify the provider, respect Quiet mode and Quiet hours, and are not repeated after restart.") {
                SettingsRow("Quota alert",
                            detail: "Warn me when any window crosses this much of its allowance.") {
                    Picker("", selection: $alertThreshold) {
                        Text("Off").tag(0)
                        Text("80%").tag(80)
                        Text("90%").tag(90)
                        Text("95%").tag(95)
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Quota alert threshold")
                }
            }

            SettingsSection("Current usage",
                            footnote: "Read from each vendor's own local login — nothing is copied to storage or logged.",
                            boxed: false) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(AccountUsageProvider.allCases, id: \.self) { provider in
                        QuotaPanel(provider: provider, state: model.usageState(for: provider))
                    }
                }
            }
        }
    }
}

/// One provider's own panel on the quota page.
private struct QuotaPanel: View {
    let provider: AccountUsageProvider
    let state: AccountUsageState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: provider.displayName)
                .font(SettingsChrome.font(13, .bold))
                .foregroundStyle(MacTheme.ink)
            AccountUsageSummaryView(provider: provider, state: state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(MacTheme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cardRadius, style: .continuous))
    }
}

/// What this Mac has spent locally, and the per-session budget that warns about
/// it. Distinct from the quota page: this is read from transcripts on disk, not
/// from any account.
struct TokenSpendPage: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("notifyOnNeedsResponse") private var notify = true
    @AppStorage("sessionBudgetUSD") private var budgetUSD = 0.0

    var body: some View {
        SettingsPageScaffold(SettingsPageID.tokenSpend.title,
                             subtitle: SettingsPageID.tokenSpend.subtitle) {
            SettingsSection("Alerts") {
                SettingsRow("Budget alert per session",
                            detail: "A gentle heads-up when a session's estimated spend crosses this amount. Cost is a rough estimate from token usage.") {
                    Picker("", selection: $budgetUSD) {
                        Text("Off").tag(0.0)
                        Text("$1").tag(1.0)
                        Text("$2").tag(2.0)
                        Text("$5").tag(5.0)
                        Text("$10").tag(10.0)
                        Text("$20").tag(20.0)
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!notify)
                    .accessibilityLabel("Budget alert per session")
                }
            }

            SettingsSection("Local spend", boxed: false) {
                VStack(alignment: .leading, spacing: 0) {
                    TokenConsumptionSummaryView(snapshot: model.tokenConsumption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(MacTheme.bg2)
                .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cardRadius, style: .continuous))
            }
        }
    }
}

/// Where the quota and spend numbers are read from, and the logins they need.
struct UsageSourcesPage: View {
    @ObservedObject var model: MenuBarModel
    @State private var cursorCookie: String = CursorSessionCookieStore.loadManual() ?? ""
    @State private var cursorCookieMode: CursorCookieSourceMode = CursorCookieSourceSettings.mode()
    @State private var cursorImportMessage: String?
    @State private var grokBotAuthorization: String?
    @State private var isAuthorizingGrokBot = false
    @FocusState private var cursorCookieFocused: Bool

    var body: some View {
        SettingsPageScaffold(SettingsPageID.usageSources.title,
                             subtitle: SettingsPageID.usageSources.subtitle) {
            SettingsSection("Collect usage from",
                            footnote: "Codex reads its official local app-server. Claude runs the official read-only /usage command. Grok asks its own agent process for the billing summary. Cursor reads its selected CLI login, local app login, or browser/manual Cookie. Turning a source off leaves session monitoring and notifications running.") {
                SettingsGrid(items: AccountUsageProvider.allCases.map { provider in
                    SettingsGrid.Item(id: provider.rawValue, verbatim: provider.displayName) {
                        Toggle("", isOn: Binding(
                            get: { model.isUsageCollectionEnabled(provider) },
                            set: { model.setUsageCollectionEnabled($0, provider: provider) }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                })
            }

            SettingsSection("Grok Bot") {
                SettingsRow("Account access",
                            detailText: grokBotAuthorization
                            ?? String(localized: "Reads the active official Grok Bot account. Background refresh never opens a Keychain prompt. Expired login must be renewed in Grok Bot.")) {
                    Button("Authorize…") {
                        guard E2ERunConfiguration.current == nil else { return }
                        isAuthorizingGrokBot = true
                        Task {
                            defer { isAuthorizingGrokBot = false }
                            do {
                                _ = try await GrokBotLocalAccount.load(allowPrompt: true)
                                _ = try await GrokBotLocalAccount.load()
                                grokBotAuthorization = String(localized: "Access authorized. Enable collection and refresh Grok Bot usage.")
                            } catch {
                                grokBotAuthorization = String(localized: "Background access unavailable. Sign in to Grok Bot and authorize Keychain access for future reads.")
                            }
                        }
                    }
                    .disabled(isAuthorizingGrokBot || E2ERunConfiguration.current != nil)
                }
            }

            SettingsSection("Cursor session",
                            footnote: "Paste mode stores the Cookie in a Keychain slot separate from browser import. Browser import reads Safari/Chrome/Firefox cookies for cursor.com (may prompt for Keychain or Full Disk Access); refresh writes the imported slot only when the value changes and falls back to the manual Cookie.") {
                SettingsRow("Login source", detailText: cursorModeDetail) {
                    Picker("", selection: $cursorCookieMode) {
                        ForEach(CursorCookieSourceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Cursor login source")
                    .onChange(of: cursorCookieMode) { _, mode in
                        CursorCookieSourceSettings.setMode(mode)
                    }
                }

                if cursorCookieMode == .manual {
                    SettingsRow("Cookie header from cursor.com") {
                        HStack(spacing: 8) {
                            cookieField(prompt: "Cookie header from cursor.com")
                            Button("Paste") {
                                guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
                                let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { return }
                                cursorCookie = trimmed
                                CursorSessionCookieStore.saveManual(trimmed)
                            }
                            .accessibilityIdentifier("paste-cursorCookie")
                        }
                    }
                } else if cursorCookieMode == .browserAuto {
                    SettingsRow("Browser import", detailText: cursorImportMessage) {
                        Button("Import now") {
                            guard E2ERunConfiguration.current == nil else { return }
                            cursorImportMessage = nil
                            Task {
                                do {
                                    let header = try await Task.detached(priority: .utility) {
                                        try CursorBrowserCookieImporter().importSessionCookieHeader(allowKeychainPrompt: true)
                                    }.value
                                    if let status = CursorSessionCookieStore.saveImportedIfChanged(header), status != 0 {
                                        cursorImportMessage = String(localized: "Could not save the imported session (Keychain error \(status)).")
                                        return
                                    }
                                    cursorImportMessage = String(localized: "Imported a Cursor session cookie from the browser.")
                                } catch {
                                    cursorImportMessage = String(localized: "No usable Cursor session found in the browser. Paste a Cookie header, or sign in at cursor.com and try again.")
                                }
                            }
                        }
                        .disabled(E2ERunConfiguration.current != nil)
                        .accessibilityIdentifier("import-cursorCookie")
                    }
                    SettingsRow("Manual fallback Cookie") {
                        cookieField(prompt: "Manual fallback Cookie")
                    }
                }
            }
        }
    }

    private func cookieField(prompt: LocalizedStringKey) -> some View {
        SecureField(prompt, text: $cursorCookie)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .frame(width: 176)
            .focused($cursorCookieFocused)
            .accessibilityLabel(prompt)
            .onSubmit { CursorSessionCookieStore.saveManual(cursorCookie) }
            .onChange(of: cursorCookieFocused) { _, focused in
                if !focused { CursorSessionCookieStore.saveManual(cursorCookie) }
            }
    }

    private var cursorModeDetail: String {
        switch cursorCookieMode {
        case .cursorCLI:
            String(localized: "Uses only Cursor CLI login; the desktop app is not required. Run cursor-agent login if signed out or expired.")
        case .cursorApp:
            String(localized: "Uses the account signed in to Cursor on this Mac. If the session expires, sign in again in Cursor and refresh.")
        case .manual:
            String(localized: "Stored in a Keychain slot separate from browser import.")
        default:
            String(localized: "Reads Safari/Chrome/Firefox cookies for cursor.com, with the manual Cookie as a fallback.")
        }
    }
}

struct TokenConsumptionSummaryView: View {
    let snapshot: TokenConsumptionSnapshot?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if let snapshot {
                ForEach(snapshot.windows) { window in
                    windowBlock(window)
                }
                Text("Updated \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let warnings = snapshot.warnings, !warnings.isEmpty {
                    Text(warnings.prefix(2).joined(separator: "\n"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text("From local Claude Code transcripts and Codex rollouts. Estimates only — not an invoice. Distinct from account quota remaining.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Waiting for the first local scan", systemImage: "chart.bar")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func windowBlock(_ window: TokenConsumptionWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.kind.title).font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                if window.counts.isEmpty {
                    Text("No spend").foregroundStyle(.secondary)
                } else {
                    Text("\(TokenConsumptionSnapshot.formatUSD(window.counts.estimatedUSD)) · \(TokenConsumptionSnapshot.formatTokens(window.counts.totalTokens))")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            if !window.counts.isEmpty {
                Text("\(TokenConsumptionSnapshot.formatTokens(window.counts.billedTokens)) billed · \(TokenConsumptionSnapshot.formatTokens(window.counts.cachedInputTokens)) cache · \(window.counts.sessionCount) sessions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                rowList("By agent", window.byAgent)
                rowList("By model", compact ? Array(window.byModel.prefix(4)) : window.byModel)
                rowList("By project", compact ? Array(window.byProject.prefix(4)) : window.byProject)
            }
        }
    }

    @ViewBuilder private func rowList(_ title: String?, _ rows: [TokenConsumptionRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack {
                        Text(row.label).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(TokenConsumptionSnapshot.formatTokens(row.counts.totalTokens)) · \(TokenConsumptionSnapshot.formatUSD(row.counts.estimatedUSD))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
            }
        }
    }
}
