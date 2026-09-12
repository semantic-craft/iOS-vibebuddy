import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// Settings. Ten pages under five sidebar groups, each page sized to be read
/// without scrolling at the window's default size — the five broad categories
/// this replaced had grown long enough (quota and token spend arrived in one
/// tab) that every one of them scrolled. Chrome lives in `SettingsChrome.swift`.
struct SettingsView: View {
    @ObservedObject var model: MenuBarModel
    @StateObject private var hookSetup = HookSetup()
    @StateObject private var tests = SettingsTestCoordinator()
    /// Lifted out of the voice page so the feature rows and the key rows —
    /// now two separate pages — read the same saved credentials.
    @StateObject private var credentials = SettingsCredentials()
    @State private var selection: SettingsPageID = .general
    /// Which provider's key row is open on the Provider keys page. A feature
    /// row's "No API key yet" pill sets both this and `selection`.
    @State private var expandedAccount: VoiceProvider?

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
            Rectangle().fill(MacTheme.line).frame(width: 1).accessibilityHidden(true)
            page
        }
        .frame(minWidth: 920, minHeight: 760)
        // The buddy's green is the action colour everywhere else; without this
        // every switch and segmented selection falls back to the system accent.
        .tint(MacTheme.accent)
        .modifier(SettingsTestLifecycle(tests: tests))
    }

    @ViewBuilder private var page: some View {
        switch selection {
        case .general:
            GeneralPage(model: model)
        case .notifications:
            NotificationsPage(model: model)
        case .voice:
            VoiceFeaturesPage(model: model, tests: tests, credentials: credentials, reveal: reveal)
        case .providerKeys:
            ProviderKeysPage(tests: tests, credentials: credentials, expanded: $expandedAccount)
        case .phone:
            PhonePage(model: model)
        case .agentCLIs:
            AgentCLIsPage(model: model, setup: hookSetup)
        case .quota:
            PlanAndQuotaPage(model: model)
        case .tokenSpend:
            TokenSpendPage(model: model)
        case .usageSources:
            UsageSourcesPage(model: model)
        case .diagnostics:
            DiagnosticsPage(model: model, setup: hookSetup)
        }
    }

    /// A feature row asking for a key it does not have: go to the key, opened.
    private func reveal(_ provider: VoiceProvider) {
        credentials[provider].load()
        expandedAccount = provider
        selection = .providerKeys
    }
}

// MARK: - Pages and navigation

enum SettingsGroupID: String, CaseIterable, Identifiable {
    case everyday, voice, connections, usage, advanced

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .everyday: "Everyday"
        case .voice: "Voice & models"
        case .connections: "Connections"
        case .usage: "Usage"
        case .advanced: "Advanced"
        }
    }
}

enum SettingsPageID: String, CaseIterable, Identifiable {
    case general, notifications
    case voice, providerKeys
    case phone, agentCLIs
    case quota, tokenSpend, usageSources
    case diagnostics

    var id: String { rawValue }

    var group: SettingsGroupID {
        switch self {
        case .general, .notifications: .everyday
        case .voice, .providerKeys: .voice
        case .phone, .agentCLIs: .connections
        case .quota, .tokenSpend, .usageSources: .usage
        case .diagnostics: .advanced
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .voice: "Voice"
        case .providerKeys: "Provider keys"
        case .phone: "Phone & remote"
        case .agentCLIs: "Agent CLIs"
        case .quota: "Plan & quota"
        case .tokenSpend: "Token spend"
        case .usageSources: "Usage sources"
        case .diagnostics: "Diagnostics"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .general: "Startup, shortcuts and the Glance"
        case .notifications: "What rings, and when it stays quiet"
        case .voice: "Conversation, summaries and reading aloud"
        case .providerKeys: "One key per provider, shared by every feature"
        case .phone: "Pairing and remote access"
        case .agentCLIs: "Hooks, daemons and who answers first"
        case .quota: "What each account has left"
        case .tokenSpend: "What this Mac has spent locally"
        case .usageSources: "Where the numbers are read from"
        case .diagnostics: "Health, delivery and recent transitions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell"
        case .voice: "waveform"
        case .providerKeys: "key"
        case .phone: "iphone.gen3"
        case .agentCLIs: "terminal"
        case .quota: "gauge.with.dots.needle.50percent"
        case .tokenSpend: "chart.bar"
        case .usageSources: "dot.radiowaves.left.and.right"
        case .diagnostics: "stethoscope"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPageID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SettingsGroupID.allCases) { group in
                        Text(group.title)
                            .font(SettingsChrome.font(10.5, .bold))
                            .tracking(0.7)
                            .textCase(.uppercase)
                            .foregroundStyle(MacTheme.ink3)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                            .padding(.bottom, 5)
                        ForEach(SettingsPageID.allCases.filter { $0.group == group }) { page in
                            item(page)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: SettingsChrome.sidebarWidth)
        .background(MacTheme.bg2)
        .accessibilityLabel("Settings categories")
    }

    private func item(_ page: SettingsPageID) -> some View {
        let selected = page == selection
        return Button { selection = page } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(MacTheme.font(13))
                    .frame(width: 16)
                    .foregroundStyle(selected ? MacTheme.accent : MacTheme.ink2)
                Text(page.title)
                    .font(SettingsChrome.font(13, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? MacTheme.accent : MacTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 31)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? MacTheme.accent.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Everyday

private struct GeneralPage: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("showMenuBarTaskStatus") private var showMenuBarTaskStatus = false
    @State private var showHideIconNote = false

    var body: some View {
        SettingsPageScaffold(SettingsPageID.general.title, subtitle: SettingsPageID.general.subtitle) {
            SettingsSection("Startup & menu bar",
                            footnote: showHideIconNote
                            ? "Hidden. You can still open the Dashboard with \(model.openDashboardHotkey.displayString) — it has a Settings button."
                            : nil) {
                SettingsRow("Launch at Login") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin },
                                             set: { model.setLaunchAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Show icon in menu bar",
                            detail: "A fixed shortcut to the Dashboard and Settings. Live status and alerts appear in the Glance.") {
                    Toggle("", isOn: Binding(
                        get: { showMenuBarIcon },
                        set: { on in showMenuBarIcon = on; if !on { showHideIconNote = true } }))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Show task status in menu bar",
                            detail: "Add a status dot and the primary task count beside the cat icon.") {
                    Toggle("", isOn: $showMenuBarTaskStatus)
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!showMenuBarIcon)
                }
            }

            SettingsSection("Shortcuts") {
                SettingsRow("Open Dashboard",
                            detail: "Works from any app. Hyper (⌃⌥⇧⌘) combos recommended.") {
                    HotkeyRecorderView(current: model.openDashboardHotkey, onRecord: model.setHotkey)
                }
                SettingsRow("Toggle Glance",
                            detail: "Show or hide the floating glance from the keyboard — handy on a notchless screen where it would otherwise sit on top of your work.") {
                    HotkeyRecorderView(current: model.toggleGlanceHotkey, onRecord: model.setGlanceHotkey)
                }
            }

            SettingsSection("Glance") {
                SettingsRow("Show glance", detail: "The floating status card that sits near the notch.") {
                    Toggle("", isOn: Binding(get: { model.showGlance },
                                             set: { model.setShowGlance($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Size") {
                    Picker("", selection: Binding(get: { model.glanceScale },
                                                  set: { model.setGlanceScale($0) })) {
                        Text("Small").tag(CGFloat(0.8))
                        Text("Medium").tag(CGFloat(1.0))
                        Text("Large").tag(CGFloat(1.2))
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    .disabled(!model.showGlance)
                    .accessibilityLabel("Glance size")
                }
            }

            SettingsSection("Sessions") {
                SettingsRow("Clean up idle sessions after",
                            detail: "Idle sessions leave the Dashboard once this much time passes.") {
                    Picker("", selection: Binding(get: { model.idleTimeoutHours },
                                                  set: { model.setIdleTimeout($0) })) {
                        Text("30 min").tag(0.5)
                        Text("1 hour").tag(1.0)
                        Text("2 hours").tag(2.0)
                        Text("4 hours").tag(4.0)
                        Text("8 hours").tag(8.0)
                        Text("24 hours").tag(24.0)
                        Text("Never").tag(0.0)
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityLabel("Clean up idle sessions after")
                }
            }
        }
    }
}

private struct NotificationsPage: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("notifyOnNeedsResponse") private var notify = true
    @AppStorage("playNotificationSound") private var sound = true
    @AppStorage("quietMode") private var quiet = false
    @State private var quietHours = NotificationsPage.loadQuietHours()
    @State private var categories = NotificationCategoryPrefs.loadMac()

    var body: some View {
        SettingsPageScaffold(SettingsPageID.notifications.title,
                             subtitle: SettingsPageID.notifications.subtitle) {
            SettingsSection("Delivery",
                            footnote: "A short, built-in cue for each state change — needs you, approval, finished, or stuck. Only boundaries ring; ongoing work stays silent.") {
                SettingsRow("Show notifications") {
                    Toggle("", isOn: $notify).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Play sound") {
                    Toggle("", isOn: $sound).labelsHidden().toggleStyle(.switch).disabled(!notify)
                }
            }

            SettingsSection("Notify me about",
                            footnote: "Disabled categories never notify. Quiet mode and Quiet hours silence session alerts except silent approvals and questions. Enabled quota alerts are unaffected.") {
                SettingsGrid(items: NotificationCategoryPrefs.displayOrder.map { category in
                    SettingsGrid.Item(id: category.rawValue, text: Text(category.categoryTitle)) {
                        Toggle("", isOn: Binding(
                            get: { categories.isEnabled(category) },
                            set: { categories.set(category, enabled: $0) }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                })
                .disabled(!notify)
            }

            SettingsSection("Quiet",
                            footnote: "Quiet mode keeps approvals and questions silent and suppresses other session alerts. Enabled quota alerts still follow the Sound setting.") {
                SettingsRow("Quiet mode",
                            detail: "Approvals and questions stay silent; other session alerts are suppressed.") {
                    Toggle("", isOn: $quiet).labelsHidden().toggleStyle(.switch).disabled(!notify)
                }
                SettingsRow("Quiet hours", detail: "Enter Quiet mode automatically each night.") {
                    Toggle("", isOn: $quietHours.enabled).labelsHidden().toggleStyle(.switch).disabled(!notify)
                }
                if quietHours.enabled {
                    SettingsRow("Window") {
                        HStack(spacing: 8) {
                            Picker("", selection: $quietHours.startHour) { hourTags }
                                .labelsHidden().fixedSize().accessibilityLabel("Quiet hours start")
                            Text(verbatim: "→").foregroundStyle(MacTheme.ink3)
                            Picker("", selection: $quietHours.endHour) { hourTags }
                                .labelsHidden().fixedSize().accessibilityLabel("Quiet hours end")
                        }
                        .disabled(!notify)
                    }
                }
            }
        }
        .onChange(of: quietHours) { _, q in NotificationsPage.saveQuietHours(q) }
        .onChange(of: categories) { _, c in c.save() }
    }

    private var hourTags: some View {
        ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
    }

    private static func loadQuietHours() -> QuietHours {
        guard let data = UserDefaults.standard.data(forKey: "quietHours"),
              let q = try? JSONDecoder().decode(QuietHours.self, from: data) else { return QuietHours() }
        return q
    }

    private static func saveQuietHours(_ q: QuietHours) {
        if let data = try? JSONEncoder().encode(q) { UserDefaults.standard.set(data, forKey: "quietHours") }
    }
}

// MARK: - Connections

private struct PhonePage: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        SettingsPageScaffold(SettingsPageID.phone.title, subtitle: SettingsPageID.phone.subtitle) {
            SettingsSection("Pairing") {
                SettingsRow("Pair a phone", detail: "Scan the QR code in the vibebuddy iOS app.") {
                    Button(model.pairingInProgress ? "Cancel pairing" : "Pair a phone") {
                        if model.pairingInProgress { model.endPairing() } else { model.beginPairing() }
                    }
                    .disabled(model.changingPairing || (!model.pairingInProgress && model.pairing == nil))
                }
                if model.pairingInProgress {
                    SettingsBlockRow {
                        if let qr = model.qrImage {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(nsImage: qr).interpolation(.none).resizable()
                                    .frame(width: 176, height: 176).padding(12).background(.white)
                                    .accessibilityLabel("Pairing QR code")
                                Text("Scan this in the vibebuddy iOS app within 2 minutes.")
                                    .font(SettingsChrome.font(12.5)).foregroundStyle(MacTheme.ink2)
                            }
                        } else {
                            Text("Pairing is not ready.")
                                .font(SettingsChrome.font(12.5)).foregroundStyle(MacTheme.ink2)
                        }
                    }
                }
                if let phone = model.pairedPhone {
                    SettingsRow(verbatim: phone.name,
                                detail: phone.confirmed
                                ? String(localized: "Saved pairing. Live connection status unavailable.")
                                : String(localized: "Registered before pairing confirmation was recorded. Choose Pair a phone to confirm, or forget it.")) {
                        HStack(spacing: 8) {
                            SettingsPill(phone.pushRegistered ? "Push registered" : "Push pending",
                                         tone: phone.pushRegistered ? .ok : .neutral)
                            Button(role: .destructive) { model.forgetPairedPhone() } label: {
                                Text("Forget")
                            }
                            .disabled(model.changingPairing)
                            .help("Stops pushes and forgets all registered phones until you choose Pair a phone again.")
                        }
                    }
                    if !phone.subtitle.isEmpty {
                        SettingsRow("Device") { SettingsValue(verbatim: phone.subtitle) }
                    }
                    SettingsRow("Last seen") {
                        SettingsValue(Text(phone.lastSeen, style: .relative))
                    }
                } else {
                    SettingsRow("Paired phone") {
                        SettingsValue("No phone paired")
                    }
                }
            }

            SettingsSection("Connection",
                            footnote: "Connect Mac and iPhone to the same tailnet. For Headscale, use this Mac’s 100.x.x.x address.") {
                SettingsRow("Use Tailscale for remote access") {
                    Toggle("", isOn: $model.useTailscale)
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(model.pairingInProgress || model.changingPairing)
                }
                if model.useTailscale {
                    SettingsRow("Tailscale address",
                                detailText: model.pairing == nil
                                ? String(localized: "Enter a valid Tailscale address.") : nil) {
                        TextField("100.x.x.x or Mac name.ts.net", text: $model.tailscaleHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 176)
                            .disabled(model.pairingInProgress || model.changingPairing)
                            .accessibilityLabel("Tailscale address")
                    }
                }
                SettingsRow("This Mac") { SettingsValue(verbatim: model.macDisplayName) }
                SettingsRow("Pairing address") {
                    SettingsValue(verbatim: model.pairingAddress, monospaced: true)
                }
            }
        }
    }
}

private struct AgentCLIsPage: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var setup: HookSetup

    var body: some View {
        SettingsPageScaffold(SettingsPageID.agentCLIs.title, subtitle: SettingsPageID.agentCLIs.subtitle) {
            SettingsSection("Hooks") {
                if setup.statuses.isEmpty {
                    SettingsRow("Agent CLIs") { SettingsValue("No agent CLIs detected yet") }
                } else {
                    SettingsGrid(items: setup.statuses.map { status in
                        SettingsGrid.Item(id: status.name, verbatim: status.name) {
                            SettingsPill(status.hookInjected ? "hooked"
                                         : (status.configured ? "not hooked" : "not installed"),
                                         tone: status.hookInjected ? .ok
                                         : (status.configured ? .warn : .neutral))
                        }
                    })
                }
            }

            SettingsSection("Maintenance",
                            footnote: "Wires (or removes) the vibebuddy hook in every detected CLI's config (~/.claude/settings.json …) via the bundled installer. Reversible. Re-run after installing a new CLI. Codex Desktop is monitored automatically from its local rollout stream; Codex CLI hooks still require explicit trust — start a fresh CLI session, run /hooks, review the VibeBuddy entries, and trust them.") {
                SettingsRow("Hook installation",
                            detail: "Touches the CLI configs on this Mac, so it only ever runs from this button.") {
                    HStack(spacing: 8) {
                        if setup.running { ProgressView().controlSize(.small) }
                        Button("Install / repair") { setup.install() }.disabled(setup.running)
                        Button("Uninstall") { setup.uninstall() }.disabled(setup.running)
                    }
                }
            }

            SettingsSection("Behaviour") {
                SettingsRow("Always ask the phone first",
                            detail: "Off: while you are at the Mac the agent's own prompt takes the answer and the phone shows a read-only card. On: every prompt waits for the phone even at the desk.") {
                    Toggle("", isOn: Binding(get: { model.alwaysAskPhone },
                                             set: { model.setAlwaysAskPhone($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Use the Codex app-server daemon",
                            detail: "Reads every Codex thread (Desktop, CLI, agents) from the shared local app-server over its unix control socket, read-only. When off, the rollout stream and hooks cover Codex as before.") {
                    Toggle("", isOn: Binding(get: { model.codexAppServerEnabled },
                                             set: { model.setCodexAppServerEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Observe Grok Bot tasks",
                            detail: "Read task status from the signed-in Grok Bot app. Replies and approvals stay in Grok Bot. Off by default.") {
                    Toggle("", isOn: Binding(get: { model.grokBotEnabled },
                                             set: { model.setGrokBotEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onAppear { setup.refresh() }
    }
}

// MARK: - Advanced

private struct DiagnosticsPage: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var setup: HookSetup

    var body: some View {
        SettingsPageScaffold(SettingsPageID.diagnostics.title,
                             subtitle: SettingsPageID.diagnostics.subtitle) {
            SettingsSection("Observation health") {
                if model.observationDiagnostics.isEmpty {
                    SettingsRow("Sources") { SettingsValue("Checking Claude and Codex sources…") }
                } else {
                    ForEach(model.observationDiagnostics) { agent in
                        ForEach(agent.sources) { source in
                            SettingsBlockRow {
                                observationRow(agent: agent.agent, source: source)
                            }
                        }
                    }
                }
            }

            SettingsSection("Codex daemon") {
                SettingsBlockRow {
                    Text(verbatim: codexAppServerStatus)
                        .font(SettingsChrome.font(12.5))
                        .foregroundStyle(MacTheme.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsSection("Delivery health",
                            footnote: "Honest outcomes only: attempted, scheduled, accepted, failed, skipped. A local banner is scheduled; APNs 2xx is accepted by Apple's servers. Neither is proof the device showed it.") {
                SettingsGrid(items: [
                    SettingsGrid.Item(id: "auth", title: "Local authorization") {
                        SettingsValue(verbatim: model.notificationDeliveryHealth.authorization.rawValue)
                    },
                    SettingsGrid.Item(id: "apns", title: "APNs") {
                        SettingsValue(model.notificationDeliveryHealth.apnsConfigured
                                      ? "configured" : "not configured")
                    },
                    SettingsGrid.Item(id: "devices", title: "Registered devices") {
                        let count = model.deviceRegistry.count
                        let dead = count == 0 && model.notificationDeliveryHealth.apnsConfigured
                        SettingsPill(verbatim: count == 0 ? "none" : "\(count)",
                                     tone: dead ? .warn : .neutral)
                    },
                    SettingsGrid.Item(id: "missed", title: "Missed this week") {
                        SettingsValue(verbatim: "\(model.missedThisWeek.count)")
                    }
                ])
                if let last = model.notificationDeliveryHealth.lastAttempt {
                    SettingsRow("Last attempt",
                                detailText: lastAttemptDetail(last)) {
                        SettingsPill(verbatim: last.outcome.rawValue,
                                     tone: last.outcome == .failed ? .warn : .neutral)
                    }
                } else {
                    SettingsRow("Last attempt") { SettingsValue("No attempts yet") }
                }
                if let failure = model.notificationDeliveryHealth.latchedFailure {
                    SettingsRow("Latched failure") {
                        SettingsPill(verbatim: failure.failureReason ?? "unknown", tone: .critical)
                    }
                }
            }

            SettingsSection("Recent lifecycle",
                            footnote: "Stored locally for up to 7 days (maximum 250 transitions). Normalized state and source metadata only — never prompts, reasoning, message text, tool input, or tool output.") {
                if model.lifecycleTimeline.isEmpty {
                    SettingsRow("Timeline") { SettingsValue("No recent lifecycle transitions") }
                } else {
                    ForEach(model.lifecycleTimeline.prefix(6)) { entry in
                        SettingsRow(verbatim: "\(entry.agent.displayName) · \(String(localized: entry.eventDisplayName))",
                                    detail: "\(entry.source.displayName) · Session …\(entry.sessionSuffix) · \(String(localized: entry.resultDisplayName))") {
                            SettingsValue(Text(entry.timestamp, style: .relative))
                        }
                    }
                }
                SettingsRow("Journal",
                            detailText: model.lifecycleJournalClearFailed
                            ? String(localized: "Could not remove the journal from disk.") : nil) {
                    Button(role: .destructive) { model.clearLifecycleJournal() } label: {
                        Text("Clear timeline")
                    }
                    .disabled(model.lifecycleTimeline.isEmpty && !model.lifecycleJournalClearFailed)
                }
            }

            if !setup.lastOutput.isEmpty {
                SettingsSection("Hook operation output") {
                    SettingsBlockRow {
                        Text(verbatim: setup.lastOutput)
                            .font(MacTheme.mono(11.5))
                            .textSelection(.enabled)
                            .foregroundStyle(MacTheme.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onAppear { setup.refresh() }
    }

    private func lastAttemptDetail(_ last: NotificationDeliveryRecord) -> String {
        var parts = [last.channel.rawValue]
        if let sound = last.sound { parts.append(sound) }
        if let session = last.sessionID { parts.append("Session …\(session.suffix(8))") }
        return parts.joined(separator: " · ")
    }

    private var codexAppServerStatus: String {
        let d = model.codexAppServerDiagnostics
        guard d.enabled else { return "Off — Codex is observed from the rollout stream and hooks." }
        if d.connected {
            var text = "Connected"
            if let agent = d.serverUserAgent { text += " · \(agent.split(separator: " (").first.map(String.init) ?? agent)" }
            text += " · \(d.subscribedThreads) thread\(d.subscribedThreads == 1 ? "" : "s") subscribed"
            if !d.serverRequestsSeen.isEmpty {
                text += " · approval requests seen: \(Set(d.serverRequestsSeen).sorted().joined(separator: ", "))"
            }
            // A daemon left running across a Codex update speaks an older
            // protocol than this Mac expects, and nothing else says so.
            if let drift = ObservationHealthDetector.codexAppServerVersionDrift(
                home: E2ERunConfiguration.current?.file("agents") ?? FileManager.default.homeDirectoryForCurrentUser,
                serverUserAgent: d.serverUserAgent) {
                text += "\n⚠︎ \(drift.explanation)"
            }
            return text
        }
        if let error = d.lastError { return "Not connected — \(error)" }
        return "Waiting for the daemon (start Codex Desktop or the CLI)."
    }

    @ViewBuilder
    private func observationRow(agent: AgentKind, source: ObservationSourceDiagnostic) -> some View {
        let issue = agent == .codex && source.source == .hook
            ? ObservationHealthDetector.codexHookConfigurationIssue(
                home: E2ERunConfiguration.current?.file("agents") ?? FileManager.default.homeDirectoryForCurrentUser,
                hook: source, now: Date(),
                hookTrust: model.codexAppServerDiagnostics.hookTrust) : nil
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: issue != nil ? "exclamationmark.triangle.fill" : source.diagnosticIcon)
                .foregroundStyle(issue != nil ? .orange : source.diagnosticColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: agent.displayName)
                        .font(SettingsChrome.font(13, .semibold))
                    Text(verbatim: "· \(source.source.displayName)")
                        .font(SettingsChrome.font(13))
                        .foregroundStyle(MacTheme.ink2)
                    Text(verbatim: "· \(issue?.displayName ?? source.diagnosticTitle)")
                        .font(SettingsChrome.font(12.5))
                        .foregroundStyle(MacTheme.ink2)
                }
                Text(verbatim: issue?.explanation ?? source.diagnosticExplanation)
                    .font(SettingsChrome.font(11.5))
                    .foregroundStyle(MacTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = source.lastObservedAt {
                    Text("Last signal \(Text(last, style: .relative))")
                        .font(SettingsChrome.font(11.5))
                        .foregroundStyle(MacTheme.ink3)
                }
                if source.source == .statusline, source.reasonCode == "optionalSourceNotConfigured" {
                    Button("Enable status line information") { setup.enableStatusLine() }
                        .disabled(setup.running)
                        .help("Preserves your current status line and its backup.")
                }
            }
            Spacer(minLength: 8)
            if source.source == .hook, issue == nil, source.canRepairConfiguration {
                Button("Repair") { setup.repair(agent) }
                    .disabled(setup.running)
                    .help("Runs the bundled idempotent installer and preserves your other hooks.")
            }
        }
    }
}

private extension LifecycleJournalEntry {
    var sessionSuffix: String { String(sessionID.suffix(8)) }

    var resultDisplayName: String.LocalizationValue {
        guard let status else { return "Removed" }
        switch status {
        case .needsResponse:
            return waitKind == .permission ? "Needs permission" : "Needs response"
        case .working: return "Working"
        case .done: return "Done"
        }
    }

    var eventDisplayName: String.LocalizationValue {
        switch event {
        case "sessionStart": return "Session started"
        case "userPromptSubmit": return "Turn started"
        case "preToolUse": return "Tool started"
        case "postToolUse": return "Tool finished"
        case "notification": return "Attention requested"
        case "stop": return "Turn stopped"
        case "sessionEnd": return "Session ended"
        case "sessionMetadataChanged": return "Metadata changed"
        case "approvalRequested": return "Approval requested"
        case "approvalResolved": return "Approval resolved"
        case "questionResolved": return "Question resolved"
        case "sessionReconciled": return "Session reconciled"
        default: return "Lifecycle changed"
        }
    }
}

/// Both device settings surfaces edit the same saved companion endpoint. The
/// menu-bar popover still shows it as a plain stack of controls.
struct TailscalePairingSettings: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        Toggle("Use Tailscale for remote access", isOn: $model.useTailscale)
            .disabled(model.pairingInProgress || model.changingPairing)
        if model.useTailscale {
            TextField("100.x.x.x or Mac name.ts.net", text: $model.tailscaleHost)
                .textFieldStyle(.roundedBorder)
                .disabled(model.pairingInProgress || model.changingPairing)
            Text("Connect Mac and iPhone to the same tailnet. For Headscale, use this Mac’s 100.x.x.x address.")
                .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
            if model.pairing == nil {
                Text("Enter a valid Tailscale address.").foregroundStyle(.orange)
            }
        }
    }
}

/// Records a global shortcut. While recording, a local event monitor swallows
/// the next key combo (the Settings window has focus, so a local monitor is
/// enough — no Accessibility permission). Bare keys (no modifier) are rejected
/// so the shortcut can't shadow ordinary typing; Esc cancels.
struct HotkeyRecorderView: View {
    let current: Hotkey
    let onRecord: (Hotkey) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint = false

    var body: some View {
        HStack(spacing: 8) {
            if hint {
                Text("needs a modifier").font(MacTheme.font(10)).foregroundStyle(.red)
            }
            (recording ? Text("Press a combo…") : Text(verbatim: current.displayString))
                .font(MacTheme.mono(12.5))
                .frame(minWidth: 84)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(MacTheme.bg3))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(recording ? MacTheme.accent : MacTheme.line, lineWidth: 1))
            Button(recording ? "Cancel" as LocalizedStringKey : "Record") { recording ? stop() : start() }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier == NSUserInterfaceItemIdentifier("com.vibebuddy.settings") else { return }
            // AppWindows retains the hosting controller after close, so view
            // disappearance alone cannot own the local keyboard monitor cleanup.
            stop()
        }
    }

    private func start() {
        hint = false
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil   // swallow the key while recording
        }
    }

    private func stop() {
        recording = false
        hint = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }   // Escape cancels
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let hk = Hotkey(keyCode: UInt32(event.keyCode),
                        cocoaModifiers: mods.rawValue,
                        displayKey: Self.keyLabel(for: event))
        guard hk.hasModifier else { hint = true; return }   // keep recording, show hint
        onRecord(hk)
        stop()
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49:  return "Space"
        case 36:  return "Return"
        case 48:  return "Tab"
        case 51:  return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let c = event.charactersIgnoringModifiers ?? ""
            return c.isEmpty ? "Key\(event.keyCode)" : c.uppercased()
        }
    }
}
