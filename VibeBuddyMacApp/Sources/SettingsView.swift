import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// The Cmd+, Settings window: a classic top-tab Preferences layout (deliberately
/// not NavigationSplitView). Consolidates preferences that used to live in the
/// menu-bar popover, plus the configurable Open-Dashboard global hotkey.
struct SettingsView: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            SetupSettings(model: model)
                .tabItem { Label("Setup", systemImage: "checklist") }
            GlanceSettings(model: model)
                .tabItem { Label("Glance", systemImage: "menubar.rectangle") }
            DeviceSettings(model: model)
                .tabItem { Label("Devices", systemImage: "iphone.gen3") }
            NotificationSettings(model: model)
                .tabItem { Label("Notifications", systemImage: "bell") }
            AccountUsageSettings(model: model)
                .tabItem { Label("Usage", systemImage: "gauge.with.dots.needle.50percent") }
            VoiceSettingsTab(model: model)
                .tabItem { Label("Voice", systemImage: "waveform") }
        }
        .frame(width: 500, height: 400)
        .onDisappear { AppActivationPolicy.leave() }
    }
}

/// Onboarding / hook setup (issues 05 + 06): shows which agent CLIs are configured
/// and whether the vibebuddy hook is wired, with install/uninstall (shells out to the
/// bundled, tested Python installers). The actual install touches the user's real CLI
/// configs — so it's only ever an explicit button click here.
private struct SetupSettings: View {
    @ObservedObject var model: MenuBarModel
    @StateObject private var setup = HookSetup()

    var body: some View {
        Form {
            Section("Observation health") {
                if model.observationDiagnostics.isEmpty {
                    Text("Checking Claude and Codex sources…")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.observationDiagnostics) { agent in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(agent.agent.displayName).font(.headline)
                        ForEach(agent.sources) { source in
                            observationRow(agent: agent.agent, source: source)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }

            Section {
                if model.lifecycleTimeline.isEmpty {
                    Text("No recent lifecycle transitions.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.lifecycleTimeline.prefix(20)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(entry.agent.displayName)
                                    Text("·")
                                    Text(LocalizedStringKey(entry.eventDisplayName))
                                }
                                .fontWeight(.semibold)
                                HStack(spacing: 4) {
                                    Text(entry.source.displayName)
                                    Text("·")
                                    Text("Session …\(entry.sessionSuffix)")
                                    Text("·")
                                    Text(LocalizedStringKey(entry.resultDisplayName))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text(entry.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack {
                    Button("Clear lifecycle timeline", role: .destructive) {
                        model.clearLifecycleJournal()
                    }
                    .disabled(model.lifecycleTimeline.isEmpty && !model.lifecycleJournalClearFailed)
                    if model.lifecycleJournalClearFailed {
                        Text("Could not remove the journal from disk.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Recent lifecycle")
            } footer: {
                Text("Stored locally for up to 7 days (maximum 250 transitions). Includes normalized state and source metadata only — never prompts, reasoning, message text, tool input, or tool output.")
                    .font(.caption)
            }

            Section {
                if setup.statuses.isEmpty {
                    Text("No agent CLIs detected yet.").foregroundStyle(.secondary)
                }
                ForEach(setup.statuses, id: \.name) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.hookInjected ? "checkmark.circle.fill"
                              : (s.configured ? "exclamationmark.triangle.fill" : "minus.circle"))
                            .foregroundStyle(s.hookInjected ? .green : (s.configured ? .orange : .secondary))
                        Text(s.name).bold()
                        Spacer()
                        Text(s.hookInjected ? "hooked"
                             : (s.configured ? "configured · not hooked" : "not installed"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Agent CLIs") }

            HStack {
                Button("Install / repair hooks") { setup.install() }.disabled(setup.running)
                Button("Uninstall") { setup.uninstall() }.disabled(setup.running)
                if setup.running { ProgressView().controlSize(.small) }
            }
            Text("Wires (or removes) the vibebuddy hook in every detected CLI's config (~/.claude/settings.json …) via the bundled installer. Reversible. Re-run after installing a new CLI.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Codex Desktop is monitored automatically from its local rollout stream. Codex CLI hooks still require explicit trust: start a fresh CLI session, run /hooks, review the VibeBuddy entries, and trust them.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Section {
                Toggle("Always ask the phone first", isOn: Binding(
                    get: { model.alwaysAskPhone },
                    set: { model.setAlwaysAskPhone($0) }))
            } header: { Text("Approvals and questions") } footer: {
                Text("Off: while you are at the Mac — the session's terminal or Codex Desktop in front, screen unlocked, input within the last two minutes — the agent's own prompt takes the answer, the phone shows a read-only card, and ordinary reminders stay on the Mac. Leaving, locking, or going idle restores the reminder; the card stays read-only. On: every prompt waits for the phone even at the desk.")
                    .font(.caption)
            }

            Section {
                Toggle("Use the Codex app-server daemon", isOn: Binding(
                    get: { model.codexAppServerEnabled },
                    set: { model.setCodexAppServerEnabled($0) }))
                Text(codexAppServerStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("Codex daemon") } footer: {
                Text("Reads every Codex thread (Desktop, CLI, agents) from the shared local app-server over its unix control socket, read-only. When off or unavailable, the rollout stream and hooks cover Codex as before.")
                    .font(.caption)
            }

            if !setup.lastOutput.isEmpty {
                ScrollView {
                    Text(setup.lastOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
        }
        // Every other tab is `.grouped`; Setup was the one plain `Form`, and on
        // macOS only the grouped style puts the form in a scroll view. Setup is
        // also the only tab taller than the window's fixed 400pt frame, so the
        // unscrollable form was laid out over-tall and centre-clipped: the whole
        // "Observation health" section sat above the top edge, unreachable.
        .formStyle(.grouped)
        .onAppear { setup.refresh() }
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
            return text
        }
        if let error = d.lastError { return "Not connected — \(error)" }
        return "Waiting for the daemon (start Codex Desktop or the CLI)."
    }

    @ViewBuilder
    private func observationRow(
        agent: AgentKind,
        source: ObservationSourceDiagnostic
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: source.health.isHealthy
                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(source.health.isHealthy ? .green : .orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(source.source.displayName).fontWeight(.semibold)
                    Text("· \(source.health.displayName)")
                        .foregroundStyle(.secondary)
                }
                Text(source.health.explanation(for: source.source))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = source.lastObservedAt {
                    Text("Last signal \(last, style: .relative)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if !source.configuredCoverage.isEmpty || !source.observedCoverage.isEmpty {
                    let configured = source.configuredCoverageDescription
                    let observed = source.observedCoverageDescription
                    Text("Coverage: configured \(configured.isEmpty ? "none" : configured); observed \(observed.isEmpty ? "none" : observed)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if source.source == .hook, source.health.needsHookRepair {
                Button("Repair") { setup.repair(agent) }
                    .disabled(setup.running)
                    .help("Runs the bundled idempotent installer and preserves your other hooks.")
            }
        }
    }
}

private extension LifecycleJournalEntry {
    var sessionSuffix: String { String(sessionID.suffix(8)) }

    var resultDisplayName: String {
        guard let status else { return "Removed" }
        switch status {
        case .needsResponse:
            return waitKind == .permission ? "Needs permission" : "Needs response"
        case .working: return "Working"
        case .done: return "Done"
        }
    }

    var eventDisplayName: String {
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

private extension ObservationHealth {
    var needsHookRepair: Bool {
        switch self {
        case .eventsMissing, .asyncIncompatible, .sourceUnreadable, .unknownVersion: true
        case .healthy, .temporarilySilent, .notInstalled: false
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var showHideIconNote = false

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))

            Toggle("Show icon in menu bar", isOn: Binding(
                get: { showMenuBarIcon },
                set: { on in showMenuBarIcon = on; if !on { showHideIconNote = true } }))
            if showHideIconNote {
                Text("Hidden. You can still open the Dashboard with \(model.openDashboardHotkey.displayString) — it has a Settings button.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 4)

            LabeledContent("Open Dashboard") {
                HotkeyRecorderView(current: model.openDashboardHotkey, onRecord: model.setHotkey)
            }
            Text("A global shortcut that opens the Dashboard from anywhere. Hyper (⌃⌥⇧⌘) combos recommended.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Toggle Glance") {
                HotkeyRecorderView(current: model.toggleGlanceHotkey, onRecord: model.setGlanceHotkey)
            }
            Text("Show/hide the floating glance from the keyboard — handy on a notchless screen where it would otherwise sit on top of your work.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            Picker("Clean up idle sessions after", selection: Binding(
                get: { model.idleTimeoutHours }, set: { model.setIdleTimeout($0) })) {
                Text("30 min").tag(0.5)
                Text("1 hour").tag(1.0)
                Text("2 hours").tag(2.0)
                Text("4 hours").tag(4.0)
                Text("8 hours").tag(8.0)
                Text("24 hours").tag(24.0)
                Text("Never").tag(0.0)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GlanceSettings: View {
    @ObservedObject var model: MenuBarModel
    var body: some View {
        Form {
            Toggle("Show glance", isOn: Binding(
                get: { model.showGlance }, set: { model.setShowGlance($0) }))
            Picker("Size", selection: Binding(
                get: { model.glanceScale }, set: { model.setGlanceScale($0) })) {
                Text("Small").tag(CGFloat(0.8))
                Text("Medium").tag(CGFloat(1.0))
                Text("Large").tag(CGFloat(1.2))
            }
            .pickerStyle(.segmented)
            .disabled(!model.showGlance)
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("notifyOnNeedsResponse") private var notify = true
    @AppStorage("playNotificationSound") private var sound = true
    @AppStorage("quietMode") private var quiet = false
    @AppStorage("sessionBudgetUSD") private var budgetUSD = 0.0
    @State private var quietHours = NotificationSettings.loadQuietHours()
    @State private var categories = NotificationCategoryPrefs.loadMac()

    var body: some View {
        Form {
            Section {
                LabeledContent("Local authorization") {
                    Text(model.notificationDeliveryHealth.authorization.rawValue)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("APNs") {
                    Text(model.notificationDeliveryHealth.apnsConfigured ? "configured" : "not configured")
                        .foregroundStyle(.secondary)
                }
                // Configured but with nothing registered is the silent failure:
                // every push goes nowhere and only the missing `apns` rows below
                // would ever say so. Call it out where it is read.
                LabeledContent("Registered devices") {
                    let count = model.deviceRegistry.count
                    let dead = count == 0 && model.notificationDeliveryHealth.apnsConfigured
                    Text(count == 0 ? "none" : "\(count)")
                        .foregroundStyle(dead ? Color.orange : .secondary)
                }
                if let last = model.deviceRegistry.lastRegisteredAt {
                    HStack(spacing: 4) {
                        Text("Last registered")
                        Text(last, style: .relative)
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                } else if model.notificationDeliveryHealth.apnsConfigured {
                    Text("No phone has uploaded a push token. Open the iPhone app on the same network; it re-registers on every connection.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let last = model.notificationDeliveryHealth.lastAttempt {
                    LabeledContent("Last attempt") {
                        Text(last.outcome.rawValue)
                            .foregroundStyle(last.outcome == .failed ? Color.orange : .secondary)
                    }
                    HStack(spacing: 4) {
                        Text(last.channel.rawValue)
                        if let sound = last.sound {
                            Text("·")
                            Text(sound)
                        }
                        if let session = last.sessionID {
                            Text("·")
                            Text("Session …\(session.suffix(8))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(last.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else {
                    Text("No attempts yet.")
                        .foregroundStyle(.secondary)
                }
                if let failure = model.notificationDeliveryHealth.latchedFailure {
                    Text("failed · \(failure.failureReason ?? "unknown")")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(model.recentNotificationDeliveries.prefix(5)) { entry in
                    HStack(spacing: 6) {
                        Text(entry.outcome.rawValue)
                            .fontWeight(.semibold)
                            .foregroundStyle(entry.outcome == .skipped ? Color.secondary : .primary)
                        Text(entry.channel.rawValue)
                            .foregroundStyle(.secondary)
                        if let sound = entry.sound {
                            Text("·")
                            Text(sound)
                                .foregroundStyle(.secondary)
                        }
                        // A skip is only useful if it says which switch, or which
                        // missing phone, kept the cue from going out.
                        if let reason = entry.failureReason {
                            Text("·")
                            Text(reason)
                                .foregroundStyle(entry.outcome == .failed ? Color.orange : .secondary)
                        }
                        Spacer(minLength: 4)
                        Text(entry.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            } header: {
                Text("Delivery health")
            } footer: {
                Text("Honest outcomes only: attempted, scheduled, accepted, failed, skipped. A local banner is scheduled; APNs 2xx is accepted by Apple's servers. Neither is proof the device showed it. Skipped means the cue was earned and deliberately not said here — the reason beside it says which switch, which missing phone, or which attention level; phonePosted means the phone had already shown it itself, and phone rows are what the phone reported.")
                    .font(.caption)
            }

            Section {
                Toggle("Show notifications", isOn: $notify)
                Toggle("Play sound", isOn: $sound).disabled(!notify)
            } footer: {
                Text("A short, built-in cue for each state change — needs you, approval, finished, or stuck. Only boundaries ring; ongoing work stays silent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(NotificationCategoryPrefs.displayOrder, id: \.rawValue) { category in
                    Toggle(category.categoryTitle, isOn: Binding(
                        get: { categories.isEnabled(category) },
                        set: { categories.set(category, enabled: $0) }))
                }
            } header: {
                Text("Notify me about")
            } footer: {
                Text("Disabled categories never notify. Quiet mode and Quiet hours silence session alerts except silent approvals and questions. Enabled quota alerts are unaffected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!notify)
            Section {
                Toggle("Quiet mode (quota unaffected)", isOn: $quiet).disabled(!notify)
            } footer: {
                Text("Quiet mode keeps approvals and questions silent and suppresses other session alerts. Enabled quota alerts still follow the Sound setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Budget alert per session", selection: $budgetUSD) {
                    Text("Off").tag(0.0)
                    Text("$1").tag(1.0)
                    Text("$2").tag(2.0)
                    Text("$5").tag(5.0)
                    Text("$10").tag(10.0)
                    Text("$20").tag(20.0)
                }.disabled(!notify)
            } footer: {
                Text("A gentle heads-up when a session's estimated spend crosses this amount. Cost is a rough estimate from token usage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Quiet hours", isOn: $quietHours.enabled).disabled(!notify)
                if quietHours.enabled {
                    Picker("From", selection: $quietHours.startHour) { hourTags }
                    Picker("To", selection: $quietHours.endHour) { hourTags }
                }
            } footer: {
                Text("Automatically enter Quiet mode during this nightly window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: quietHours) { _, q in NotificationSettings.saveQuietHours(q) }
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

private struct VoiceSettingsTab: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage(VoiceSettings.conversationLanguageKey) private var language = VoiceLanguage.english.rawValue
    @AppStorage(VoiceSettings.providerKey) private var provider = VoiceProvider.qwen.rawValue
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Voice companion", isOn: $companionEnabled)
                    .onChange(of: companionEnabled) { _, on in if !on { model.voiceChat.companionDisabled() } }
                Picker("Voice provider", selection: $provider) {
                    ForEach(VoiceProvider.allCases, id: \.rawValue) { p in
                        Text(p.display).tag(p.rawValue)
                    }
                }
                .onChange(of: provider) { _, _ in model.voiceChat.reloadProviderIfActive() }
                Picker("Conversation language", selection: $language) {
                    Text("English").tag(VoiceLanguage.english.rawValue)
                    Text("中文").tag(VoiceLanguage.chinese.rawValue)
                }
                .onChange(of: language) { _, _ in model.voiceChat.reloadProviderIfActive() }
            } header: {
                Text("Companion")
            } footer: {
                Text("Tap the buddy to talk — it knows your sessions and can approve / answer for you. Pick the provider whose key you've filled in below. Switching applies instantly if the buddy is already listening.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Only the selected provider's credentials show — key + editable
            // Model ID + Voice ID — and they swap as the picker changes. `.id`
            // recreates the section so its fields reload for the new provider.
            if let p = VoiceProvider(rawValue: provider) {
                ProviderSection(provider: p)
                    .id(p.rawValue)
            }
        }
        .formStyle(.grouped)
        .animation(.smooth, value: provider)
    }
}

/// Credentials + editable Model ID and Voice ID for one voice provider. The key
/// lives in the Keychain (per-provider account); model/voice are UserDefaults.
private struct ProviderSection: View {
    let provider: VoiceProvider
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspaceID = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var voice = ""

    var body: some View {
        Section {
            // API key
            field(caption: "API Key — paste your own (kept in the Keychain)",
                  link: "Get an API key", icon: "key", url: provider.apiKeyURL) {
                SecureField("Paste your \(provider.display) key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            // Model ID — clearly editable
            field(caption: "Model ID — editable, type any model",
                  link: "Browse available models", icon: "arrow.up.right.square", url: provider.modelsURL) {
                TextField(provider.defaultModel, text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
            }
            // Voice ID — clearly editable
            field(caption: "Voice ID — editable (blank = auto by language)",
                  link: "Browse available voices", icon: "arrow.up.right.square", url: provider.voicesURL) {
                TextField(exampleVoice, text: $voice)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
            }
            if provider == .qwen {
                field(caption: "Workspace ID — optional; uses the workspace endpoint when set",
                      link: "Find your workspace ID", icon: "arrow.up.right.square", url: VoiceProvider.qwenWorkspaceIDURL) {
                    TextField("e.g. llm-xxxxxxxx", text: $workspaceID)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                }
                Toggle("Use Singapore (international) region", isOn: $intl)
            }
        } header: {
            Text(provider.display)
        }
        .onAppear {
            apiKey = provider.apiKey ?? ""
            model = UserDefaults.standard.string(forKey: VoiceSettings.modelKey(provider)) ?? ""
            voice = UserDefaults.standard.string(forKey: VoiceSettings.voiceKey(provider)) ?? ""
        }
        .onChange(of: apiKey) { _, v in KeychainStore.set(v, for: provider.keychainAccount) }
        .onChange(of: model) { _, v in UserDefaults.standard.set(v, forKey: VoiceSettings.modelKey(provider)) }
        .onChange(of: voice) { _, v in UserDefaults.standard.set(v, forKey: VoiceSettings.voiceKey(provider)) }
    }

    /// One labelled, clearly-editable field with a click-through link to the
    /// provider's list of valid values.
    @ViewBuilder
    private func field<F: View>(caption: LocalizedStringKey, link: LocalizedStringKey, icon: String, url: URL,
                                @ViewBuilder _ input: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            input()
            Link(destination: url) {
                Label(link, systemImage: icon).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var exampleVoice: String {
        switch provider {
        case .qwen:   return "e.g. longanqian / longanlufeng"
        case .openai: return "e.g. marin / cedar"
        case .gemini: return "e.g. Puck / Kore"
        }
    }
}

private struct DeviceSettings: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        Form {
            Section {
                LabeledContent("This Mac") {
                    Text(model.macDisplayName)
                        .font(.body.weight(.medium))
                }
                LabeledContent("Pairing address") {
                    Text(model.pairingAddress)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let phone = model.pairedPhone {
                    LabeledContent("Paired phone") {
                        Text(phone.name)
                            .font(.body.weight(.medium))
                    }
                    if !phone.subtitle.isEmpty {
                        LabeledContent("Device") {
                            Text(phone.subtitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Last seen") {
                        Text(phone.lastSeen, style: .relative)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Push") {
                        Label(phone.pushRegistered ? "Registered" as LocalizedStringKey : "Pending",
                              systemImage: phone.pushRegistered ? "bell.badge.fill" : "bell.slash")
                            .foregroundStyle(phone.pushRegistered ? .green : .secondary)
                    }
                    Button(role: .destructive) {
                        model.forgetPairedPhone()
                    } label: {
                        Label("Forget phone", systemImage: "iphone.slash")
                    }
                    .help("Stops pushes to this phone and refuses its re-registration until you show the pairing QR again.")
                } else {
                    Label("No phone paired", systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
            (recording ? Text("Press a combo…") : Text(verbatim: current.displayString))
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 84)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlColor)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(recording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
            Button(recording ? "Cancel" as LocalizedStringKey : "Record") { recording ? stop() : start() }
            if hint {
                Text("needs a modifier").font(.caption2).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
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
