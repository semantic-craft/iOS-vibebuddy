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
            if let snapshot = state.snapshot?.excludingExpiredWindows(at: now) {
                if let account = snapshot.accountLabel {
                    Text(account).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                }
                if let detail = snapshot.usageDetail {
                    Text(detail).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                }
                if let available = snapshot.hasAvailableUsage {
                    Text(available ? "Usage available" : "No usage available").font(MacTheme.font(10))
                        .foregroundStyle(available ? MacTheme.ink2 : MacTheme.status(.requiresInput))
                }
                if provider == .grokBot, snapshot.primary == nil, snapshot.usageDetail == nil {
                    Text("Weekly percentage unavailable").foregroundStyle(MacTheme.ink2)
                }
                if provider == .grok, snapshot.primary == nil {
                    if state.unavailableReason != .unknown {
                        Text("Usage is temporarily unavailable").foregroundStyle(MacTheme.ink2)
                    }
                    if let end = snapshot.periodEnd {
                        Text("Period ends \(end.formatted(date: .abbreviated, time: .shortened))")
                            .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    }
                }
                if snapshot.displayWindows.isEmpty {
                    if !(state.snapshot?.displayWindows.isEmpty ?? true) {
                        // Every window this reading had has already reset, so
                        // it says nothing about the current allowance.
                        Label("Window reset · awaiting a new reading",
                              systemImage: "arrow.trianglehead.counterclockwise")
                            .foregroundStyle(MacTheme.ink2)
                    } else if provider != .grok && provider != .grokBot {
                        Label("No quota windows supplied", systemImage: "gauge.with.dots.needle.0percent")
                            .foregroundStyle(MacTheme.ink2)
                    }
                } else {
                    ForEach(snapshot.displayWindows) { window in
                        windowRow(window, now: now)
                    }
                }

                if let credits = snapshot.credits {
                    LabeledContent(credits.label ?? "Credits", value: QuotaPresentation.creditsLine(credits))
                        .font(MacTheme.font(10))
                    if let reset = credits.resetsAt {
                        Text(QuotaPresentation.resetLine(from: reset, now: now))
                            .font(MacTheme.font(10))
                            .foregroundStyle(MacTheme.ink2)
                    }
                }
                if let spend = snapshot.spend, !spend.isEmpty {
                    ForEach(spend) { row in
                        LabeledContent(row.label, value: QuotaPresentation.spendLine(row))
                            .font(MacTheme.font(10))
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
                    .font(MacTheme.font(10))
                }

                HStack(spacing: 5) {
                    Text("Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    if let plan = snapshot.planType, !plan.isEmpty {
                        Text("· \(plan)")
                    }
                    if state.isStale {
                        Text("· Stale").foregroundStyle(MacTheme.status(.requiresInput))
                    }
                }
                .font(MacTheme.font(10))
                .foregroundStyle(MacTheme.ink2)
            }

            if let reason = state.unavailableReason {
                Label(localizedUsageReason(reason, provider: provider), systemImage: reasonIcon(reason))
                    .font(MacTheme.font(10))
                    .foregroundStyle(reason == .collectionDisabled ? MacTheme.ink2 : MacTheme.status(.requiresInput))
                    .fixedSize(horizontal: false, vertical: true)
                if reason != .collectionDisabled, let retry = state.nextRefreshAt, retry > now {
                    Text("Retry \(retry, style: .relative)")
                        .font(MacTheme.font(10))
                        .foregroundStyle(MacTheme.ink3)
                }
            }
    }

    private func windowRow(_ window: AccountUsageWindow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(windowTitle(window)).font(MacTheme.font(10, .semibold))
                Spacer(minLength: 4)
                Text(QuotaPresentation.remainingLine(usedPercent: window.usedPercent))
                    .font(MacTheme.font(10).monospacedDigit())
                    .foregroundStyle(QuotaPresentation.severity(usedPercent: window.usedPercent).tint)
            }
            QuotaBullet(usedPercent: window.usedPercent,
                        pacePercent: Self.pacePercent(window, now: now),
                        height: compact ? 10 : 12)
            if let reset = window.resetsAt {
                Text(QuotaPresentation.resetLine(from: reset, now: now))
                    .font(MacTheme.font(10))
                    .foregroundStyle(MacTheme.ink2)
            } else {
                Text("Reset time unavailable")
                    .font(MacTheme.font(10))
                    .foregroundStyle(MacTheme.ink2)
            }
            if let minutes = window.windowDurationMinutes, minutes >= 60,
               let reset = window.resetsAt,
               let pace = QuotaPresentation.windowPace(
                usedPercent: window.usedPercent,
                resetsAt: reset,
                windowMinutes: minutes,
                now: now
               ) {
                Text(pace.caption)
                    .font(MacTheme.font(10))
                    .foregroundStyle(pace == .spendingFaster ? QuotaPresentation.Severity.warning.tint : MacTheme.ink2)
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
        case .awaitingLiveSample: "dot.radiowaves.left.and.right"
        case .unknown: "exclamationmark.triangle"
        }
    }
}

/// The threshold that turns a quota window into an alert, and the way to the
/// readings themselves. The meters are read in one place only — the
/// dashboard's plinth and its Usage page (ADR-0017 §6) — so this page links
/// there instead of repeating them.
struct PlanAndQuotaPage: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("accountUsageAlertThreshold") private var alertThreshold = 90

    var body: some View {
        SettingsPageScaffold(SettingsPageID.quota.title, subtitle: SettingsPageID.quota.subtitle) {
            SettingsSection("Alerts",
                            footnote: "One threshold applies to every provider. Enabled quota alerts ignore Quiet mode and Quiet hours. Their sound follows each device's Sound setting. Alerts identify the provider and are not repeated after restart.") {
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
                    .accessibilityIdentifier("quota-alert-threshold")
                }
            }

            SettingsSection("Current usage",
                            footnote: "Account allowance comes from each provider. Local token estimates are separate from your actual bill.") {
                SettingsRow("Windows, resets and pace",
                            detail: "Every provider's live meters are on the dashboard's Usage page.") {
                    Button("Open Usage") { DashboardRoute.open(.usage) }
                        .accessibilityIdentifier("open-usage-page")
                }
            }
        }
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
            SettingsSection("Alerts",
                            footnote: notify ? nil : "Enable notifications to change budget alerts.") {
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
                    .accessibilityIdentifier("session-budget-usd")
                }
            }

            SettingsSection("Estimated local cost", boxed: false) {
                VStack(alignment: .leading, spacing: 0) {
                    TokenConsumptionSummaryView(snapshot: model.tokenConsumption, showsBreakdowns: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(MacTheme.bg2)
                .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cardRadius, style: .continuous))
            }

            SettingsSection("Details") {
                SettingsRow("Token usage by agent, model and project",
                            detail: "View both time windows and all breakdowns in the Usage report.") {
                    Button("Open usage report") { DashboardRoute.open(.usage) }
                        .accessibilityIdentifier("open-token-usage-report")
                }
            }
        }
    }
}

/// Where the quota and spend numbers are read from, and the logins they need.
struct UsageSourcesPage: View {
    @ObservedObject var model: MenuBarModel
    var openAgentSettings: () -> Void = {}
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
                            footnote: "Turning a source off stops its account quota collection only. Session monitoring, session notifications and local token estimates continue.") {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 0) {
                        ForEach(AccountUsageProvider.allCases, id: \.self) { provider in
                            SettingsRow(verbatim: provider == .grok ? String(localized: "Grok Build account quota") : provider.displayName,
                                        detail: sourceDescription(provider) + "\n" + sourceStatus(provider, now: context.date)) {
                                Toggle(provider.displayName, isOn: Binding(
                                    get: { model.isUsageCollectionEnabled(provider) },
                                    set: { model.setUsageCollectionEnabled($0, provider: provider) }))
                                    .labelsHidden().toggleStyle(.switch)
                                    .accessibilityLabel(provider == .grok ? Text("Show Grok Build account quota") : Text("Collect account usage from \(provider.displayName)"))
                                    .accessibilityIdentifier("usage-source-\(provider.rawValue)")
                            }
                        }
                    }
                }
            }

            SettingsSection("Grok Build session monitoring") {
                SettingsRow("Session connection", detail: "Account quota does not connect Grok Build sessions. Enable monitoring in Agent connections.") {
                    Button("Set up Grok Build monitoring", action: openAgentSettings)
                        .accessibilityIdentifier("open-grok-monitoring")
                }
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
                            footnote: cursorModeFootnote) {
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

    private func sourceDescription(_ provider: AccountUsageProvider) -> String {
        switch provider {
        case .codex:
            String(localized: "Reads account allowance from the official local Codex app-server.")
        case .claude:
            String(localized: "Reads Claude Code's live usage feed, with the official read-only /usage command as a fallback.")
        case .grok:
            String(localized: "Reads the billing summary from the local Grok agent process.")
        case .grokBot:
            String(localized: "Reads the active official Grok Bot account. Account access is configured below.")
        case .cursor:
            cursorModeDetail
        }
    }

    private func sourceStatus(_ provider: AccountUsageProvider, now: Date) -> String {
        guard model.isUsageCollectionEnabled(provider) else {
            return String(localized: "Account usage collection is off.")
        }
        let state = model.usageState(for: provider)
        if let reason = state.unavailableReason {
            return localizedUsageReason(reason, provider: provider)
        }
        if let snapshot = state.snapshot {
            if state.isStale { return String(localized: "Showing an older reading; waiting for a refresh.") }
            if !snapshot.displayWindows.isEmpty,
               snapshot.excludingExpiredWindows(at: now).displayWindows.isEmpty {
                return String(localized: "Window reset · awaiting a new reading")
            }
            return String(localized: "Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return String(localized: "Waiting for the first account reading.")
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

    private var cursorModeFootnote: LocalizedStringKey? {
        switch cursorCookieMode {
        case .cursorCLI, .cursorApp:
            nil
        case .manual:
            "Paste mode stores the Cookie in a Keychain slot separate from browser import. Replace it here when the session expires."
        case .browserAuto:
            "Browser import may request Keychain or Full Disk Access. Refresh saves the imported Cookie only when it changes and uses the manual fallback if browser import is unavailable."
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
        case .browserAuto:
            String(localized: "Reads Safari/Chrome/Firefox cookies for cursor.com, with the manual Cookie as a fallback.")
        }
    }
}

struct TokenConsumptionSummaryView: View {
    let snapshot: TokenConsumptionSnapshot?
    var compact = false
    var showsBreakdowns = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if let snapshot {
                Text("Estimated cost at token list prices, not your actual bill or subscription charge.")
                    .font(MacTheme.font(10))
                    .foregroundStyle(MacTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(snapshot.windows) { window in
                    windowBlock(window)
                }
                Text("Updated \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(MacTheme.font(10))
                    .foregroundStyle(MacTheme.ink2)
                if let warnings = snapshot.warnings, !warnings.isEmpty {
                    Text((showsBreakdowns ? warnings : Array(warnings.prefix(2))).joined(separator: "\n"))
                        .font(MacTheme.font(10))
                        .foregroundStyle(MacTheme.status(.requiresInput))
                }
                Text("From local Claude Code transcripts and Codex rollouts. Dollars are list price for the tokens read, not what a subscription charges. Distinct from account quota remaining.")
                    .font(MacTheme.font(10))
                    .foregroundStyle(MacTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Waiting for the first local scan", systemImage: "chart.bar")
                    .foregroundStyle(MacTheme.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func windowBlock(_ window: TokenConsumptionWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(window.kind.title)).font(MacTheme.font(10, .semibold))
                Spacer(minLength: 4)
                if window.counts.isEmpty {
                    Text("No local usage").foregroundStyle(MacTheme.ink2)
                } else {
                    Text("\(TokenConsumptionSnapshot.formatTokens(window.counts.totalTokens)) · est. \(TokenConsumptionSnapshot.formatUSD(window.counts.estimatedUSD))")
                        .monospacedDigit()
                }
            }
            .font(MacTheme.font(10))
            if !window.counts.isEmpty {
                Text("\(TokenConsumptionSnapshot.formatTokens(window.counts.billedTokens)) non-cached · \(TokenConsumptionSnapshot.formatTokens(window.counts.cachedInputTokens)) cache · \(window.counts.sessionCount) sessions")
                    .font(MacTheme.font(10))
                    .foregroundStyle(MacTheme.ink2)
                if showsBreakdowns {
                    rowList("By agent", window.byAgent)
                    rowList("By model", compact ? Array(window.byModel.prefix(4)) : window.byModel)
                    rowList("By project", compact ? Array(window.byProject.prefix(4)) : window.byProject)
                }
            }
        }
    }

    @ViewBuilder private func rowList(_ title: String?, _ rows: [TokenConsumptionRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(LocalizedStringKey(title)).font(MacTheme.font(10, .semibold)).foregroundStyle(MacTheme.ink2)
                }
                ForEach(rows) { row in
                    HStack {
                        Text(row.label).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text("\(TokenConsumptionSnapshot.formatTokens(row.counts.totalTokens)) · est. \(TokenConsumptionSnapshot.formatUSD(row.counts.estimatedUSD))")
                            .monospacedDigit()
                            .foregroundStyle(MacTheme.ink2)
                    }
                    .font(MacTheme.font(10))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private func localizedUsageReason(_ reason: AccountUsageUnavailableReason, provider: AccountUsageProvider) -> String {
    switch reason {
    case .collectionDisabled: String(localized: "Collection is turned off")
    case .cachedData: String(localized: "Showing cached data while refreshing")
    case .notYetLoaded: String(localized: "Waiting for the first refresh")
    case .awaitingLiveSample: String(localized: "Waiting for a \(provider.displayName) session to report")
    case .providerUnavailable:
        provider == .grokBot
            ? String(localized: "Grok Bot usage service is unavailable")
            : String(localized: "\(provider.displayName) CLI is unavailable")
    case .notLoggedIn: String(localized: "\(provider.displayName) is not signed in")
    case .offline: String(localized: "Offline")
    case .rateLimited: String(localized: "Usage service is rate limited")
    case .timedOut: String(localized: "Usage refresh timed out")
    case .incompatibleFormat: String(localized: "\(provider.displayName) returned an unsupported format")
    case .unknown: String(localized: "Usage is temporarily unavailable")
    }
}
