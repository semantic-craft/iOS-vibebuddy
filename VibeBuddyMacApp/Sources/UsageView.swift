import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

struct AccountUsageSummaryView: View {
    let provider: AccountUsageProvider
    let state: AccountUsageState
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            if let snapshot = state.snapshot?.excludingExpiredGrokWindows(at: Date()) {
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
                if snapshot.windows.isEmpty {
                    if provider != .grok && provider != .grokBot {
                        Label("No quota windows supplied", systemImage: "gauge.with.dots.needle.0percent")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(snapshot.windows) { window in
                        windowRow(window)
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
                if reason != .collectionDisabled, let retry = state.nextRefreshAt, retry > Date() {
                    Text("Retry \(retry, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func windowRow(_ window: AccountUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(windowTitle(window)).font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text(provider == .grokBot ? "\(window.usedPercent)% used · \(100 - window.usedPercent)% left" : "\(window.usedPercent)% used")
                    .font(.caption.monospacedDigit())
            }
            ProgressView(value: Double(window.usedPercent), total: 100)
                .tint(window.usedPercent >= 90 ? .orange : .accentColor)
            if let reset = window.resetsAt {
                Text("Resets \(reset, style: .relative) · \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Reset time unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func windowTitle(_ window: AccountUsageWindow) -> String {
        if provider == .grok, window.kind == .secondary { return "Extra usage" }
        if let label = window.label { return label }
        guard let minutes = window.windowDurationMinutes else {
            return window.kind == .primary ? "Primary window" : "Secondary window"
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
struct AccountUsageSettings: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("accountUsageAlertThreshold") private var alertThreshold = 90
    @State private var cursorCookie: String = CursorSessionCookieStore.loadManual() ?? ""
    @State private var cursorCookieMode: CursorCookieSourceMode = CursorCookieSourceSettings.mode()
    @State private var cursorImportMessage: String?
    /// What the user is typing right now — never the stored key, which is
    /// written once and never read back.
    @State private var cloudAPIKeyDraft: String = ""
    @State private var cloudAPIKeySaved = false
    @State private var grokBotAuthorization: String?
    @State private var isAuthorizingGrokBot = false
    @FocusState private var cursorCookieFocused: Bool

    var body: some View {
        Group {
            Section {
                ForEach(AccountUsageProvider.allCases, id: \.self) { provider in
                    Toggle("Collect \(provider.displayName) usage", isOn: Binding(
                        get: { model.isUsageCollectionEnabled(provider) },
                        set: { model.setUsageCollectionEnabled($0, provider: provider) }
                    ))
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Codex reads its official local app-server. Claude runs the official read-only /usage command without session persistence or hooks. Grok asks its own agent process for the billing summary and falls back to the CLI billing proxy with the local login token when needed. Cursor reads its selected CLI login, local app login, or browser/manual Cookie. Local login credentials are never copied to storage. No account IDs or raw responses are logged. Turning a source off leaves session monitoring and notifications running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Grok Bot") {
                Button("Authorize Grok Bot account access…") {
                    guard E2ERunConfiguration.current == nil else { return }
                    isAuthorizingGrokBot = true
                    Task {
                        defer { isAuthorizingGrokBot = false }
                        do {
                            _ = try await GrokBotLocalAccount.load(allowPrompt: true)
                            _ = try await GrokBotLocalAccount.load()
                            grokBotAuthorization = "Access authorized. Enable collection and refresh Grok Bot usage."
                        } catch {
                            grokBotAuthorization = "Background access unavailable. Sign in to Grok Bot and authorize Keychain access for future reads."
                        }
                    }
                }
                .disabled(isAuthorizingGrokBot || E2ERunConfiguration.current != nil)
                Text(grokBotAuthorization ?? "Reads the active official Grok Bot account. Background refresh never opens a Keychain prompt. Expired login must be renewed in Grok Bot.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Login source", selection: $cursorCookieMode) {
                    ForEach(CursorCookieSourceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: cursorCookieMode) { _, mode in
                    CursorCookieSourceSettings.setMode(mode)
                }

                if cursorCookieMode == .cursorCLI {
                    Text("Uses only Cursor CLI login; the desktop app is not required. Run cursor-agent login if signed out or expired. If Keychain access is unavailable, unlock the login Keychain or select another login source.").font(.caption)
                } else if cursorCookieMode == .cursorApp {
                    Text("Uses the account signed in to Cursor on this Mac. If the session expires, sign in again in Cursor and refresh.").font(.caption)
                } else if cursorCookieMode == .manual {
                    SecureField("Cookie header from cursor.com", text: $cursorCookie)
                        .textFieldStyle(.roundedBorder)
                        .focused($cursorCookieFocused)
                        .onSubmit { CursorSessionCookieStore.saveManual(cursorCookie) }
                        .onChange(of: cursorCookieFocused) { _, focused in
                            if !focused {
                                CursorSessionCookieStore.saveManual(cursorCookie)
                            }
                        }
                    Button("Paste Cookie") {
                        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
                        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        cursorCookie = trimmed
                        CursorSessionCookieStore.saveManual(trimmed)
                    }
                    .accessibilityIdentifier("paste-cursorCookie")
                } else {
                    Button("Import Cookie from browser now") {
                        guard E2ERunConfiguration.current == nil else { return }
                        cursorImportMessage = nil
                        Task {
                        do {
                            let header = try await Task.detached(priority: .utility) {
                                try CursorBrowserCookieImporter().importSessionCookieHeader(allowKeychainPrompt: true)
                            }.value
                            if let status = CursorSessionCookieStore.saveImportedIfChanged(header), status != 0 {
                                cursorImportMessage = "Could not save the imported session (Keychain error \(status))."
                                return
                            }
                            cursorImportMessage = "Imported a Cursor session cookie from the browser."
                        } catch {
                            cursorImportMessage = "No usable Cursor session found in the browser. Paste a Cookie header, or sign in at cursor.com and try again."
                        }
                    }
                    }
                    .disabled(E2ERunConfiguration.current != nil)
                    .accessibilityIdentifier("import-cursorCookie")
                    if let cursorImportMessage {
                        Text(cursorImportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SecureField("Manual fallback Cookie", text: $cursorCookie)
                        .textFieldStyle(.roundedBorder)
                        .focused($cursorCookieFocused)
                        .onSubmit { CursorSessionCookieStore.saveManual(cursorCookie) }
                        .onChange(of: cursorCookieFocused) { _, focused in
                            if !focused {
                                CursorSessionCookieStore.saveManual(cursorCookie)
                            }
                        }
                }
            } header: {
                Text("Cursor session")
            } footer: {
                Text("Paste mode stores the Cookie in a Keychain slot separate from browser import. Browser import reads Safari/Chrome/Firefox cookies for cursor.com (may prompt for Keychain or Full Disk Access); refresh writes the imported slot only when the value changes and falls back to the manual Cookie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The third Cursor credential (ADR-0017): a Cloud Agents API key,
            // separate from the session Cookie above and from the CLI's own
            // login. Written once, never read back into the field.
            Section {
                HStack(spacing: 8) {
                    SecureField("Cursor API key", text: $cloudAPIKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 170)
                        .accessibilityLabel("Cursor API key")
                        .onSubmit { saveCloudAPIKey() }
                    Button("Save") { saveCloudAPIKey() }
                        .disabled(cloudAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("save-cursorCloudAPIKey")
                    Button("Remove") {
                        CursorCloudAPIKeyStore.save(nil)
                        cloudAPIKeyDraft = ""
                        cloudAPIKeySaved = CursorCloudAPIKeyStore.isConfigured()
                    }
                    .disabled(!cloudAPIKeySaved)
                    .accessibilityIdentifier("remove-cursorCloudAPIKey")
                }
                Text(cloudKeyDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Cursor cloud agents")
            } footer: {
                Text("A Cloud Agents API key from cursor.com/dashboard/api. Separate from the session Cookie above and from the cursor-agent CLI's own login — none of the three substitutes for another. Stored in its own Keychain slot and used only to read the live state of cloud agents (bc-… chats), start their next run and cancel one. Without it, cloud agents stay stored-history rows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { cloudAPIKeySaved = CursorCloudAPIKeyStore.isConfigured() }

            Section("Quota alert") {
                Picker("Quota alert", selection: $alertThreshold) {
                    Text("Off").tag(0)
                    Text("80%").tag(80)
                    Text("90%").tag(90)
                    Text("95%").tag(95)
                }
                Text("One threshold applies to every provider. Alerts identify the provider, respect quiet mode and quiet hours, and are not repeated after restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Current usage") {
                ForEach(AccountUsageProvider.allCases, id: \.self) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(provider.displayName).font(.headline)
                        AccountUsageSummaryView(
                            provider: provider,
                            state: model.usageState(for: provider)
                        )
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

extension AccountUsageSettings {
    /// Whether a key is stored — asked of the Keychain by **metadata only**, so
    /// reading this page never decrypts the key and never raises an
    /// authorization prompt. The key itself is never read back into the field:
    /// it is written once and thereafter only replaced or removed.
    var cloudKeyDetail: String {
        cloudAPIKeySaved
            ? String(localized: "A key is saved. Type a new one to replace it.")
            : String(localized: "No key saved. Cloud agents show as stored history only.")
    }

    func saveCloudAPIKey() {
        let trimmed = cloudAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        CursorCloudAPIKeyStore.save(trimmed)
        // Drop the draft the moment it is stored: nothing keeps the key in the
        // view hierarchy, and nothing prints it.
        cloudAPIKeyDraft = ""
        cloudAPIKeySaved = CursorCloudAPIKeyStore.isConfigured()
    }
}
