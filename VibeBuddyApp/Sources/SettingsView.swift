import SwiftUI
import VibeBuddyKit

/// The phone's settings sheet. Sound-pack controls the spec asks for (play / mute,
/// Quiet mode, a nightly window) plus the voice companion: a provider picker
/// (Qwen / OpenAI / Gemini) with per-provider Key / Model ID / Voice ID, mirroring
/// the Mac. No per-sound picker.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var voice: VoiceChat
    @EnvironmentObject private var dashboard: DashboardStore
    @AppStorage(SoundPrefs.playSoundKey) private var playSound = true
    @AppStorage(SoundPrefs.quietModeKey) private var quiet = false
    @State private var quietHours = SoundPrefs.quietHours
    @State private var categories = SoundPrefs.categories
    @AppStorage(VoiceSettings.conversationLanguageKey) private var voiceLanguage = VoiceLanguage.english.rawValue
    @AppStorage(VoiceSettings.providerKey) private var provider = VoiceProvider.qwen.rawValue
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if dashboard.observationDiagnostics.isEmpty {
                        Text("No observation diagnostics received from the Mac yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(dashboard.observationDiagnostics) { agent in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(agent.agent.displayName).font(.headline)
                            ForEach(agent.sources) { source in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: source.health.isHealthy
                                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(source.health.isHealthy ? .green : .orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(source.source.displayName) · \(source.health.displayName)")
                                            .fontWeight(.semibold)
                                        Text(source.health.explanation(for: source.source))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if let last = source.lastObservedAt {
                                            Text("Last signal \(last, style: .relative)")
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        if !source.configuredCoverage.isEmpty || !source.observedCoverage.isEmpty {
                                            let configured = source.configuredCoverageDescription
                                            let observed = source.observedCoverageDescription
                                            Text("Coverage: configured \(configured.isEmpty ? "none" : configured); observed \(observed.isEmpty ? "none" : observed)")
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Observation health")
                } footer: {
                    Text("Repairs are only available on the Mac and run only after you press Repair there.")
                }

                Section {
                    ForEach(NotificationCategoryPrefs.displayOrder, id: \.rawValue) { sound in
                        Toggle(sound.categoryTitle, isOn: Binding(
                            get: { categories.isEnabled(sound) },
                            set: { categories.set(sound, enabled: $0) }))
                    }
                } header: {
                    Text("Notify me about")
                } footer: {
                    Text("Off means no banner on your iPhone or Apple Watch for that kind of event, even with sound on. What you keep still goes quiet in Focus mode, except permission prompts.")
                }

                Section {
                    Toggle("Sound", isOn: $playSound)
                    Toggle("Focus mode (only permission cues)", isOn: $quiet).disabled(!playSound)
                } header: {
                    Text("Sound")
                } footer: {
                    Text("Each status change gets a short built-in cue — needs you, permission, done, stuck. Only status boundaries sound; nothing interrupts mid-task. In Focus mode only permission prompts make a sound.")
                }

                Section {
                    Toggle("Auto-mute at night", isOn: $quietHours.enabled).disabled(!playSound)
                    if quietHours.enabled {
                        Picker("Start", selection: $quietHours.startHour) { hourTags }
                        Picker("End", selection: $quietHours.endHour) { hourTags }
                    }
                } header: {
                    Text("Night")
                } footer: {
                    Text("During this window the app auto-enters Focus mode — only permission prompts make a sound.")
                }

                Section {
                    Toggle("Voice companion", isOn: $companionEnabled)
                        .onChange(of: companionEnabled) { _, on in if !on { voice.companionDisabled() } }
                    Picker("Voice provider", selection: $provider) {
                        ForEach(VoiceProvider.allCases, id: \.rawValue) { p in
                            Text(p.display).tag(p.rawValue)
                        }
                    }
                    .onChange(of: provider) { _, _ in voice.reloadProviderIfActive() }
                    Picker("Conversation language", selection: $voiceLanguage) {
                        Text("English").tag(VoiceLanguage.english.rawValue)
                        Text("中文").tag(VoiceLanguage.chinese.rawValue)
                    }
                    .onChange(of: voiceLanguage) { _, _ in voice.reloadProviderIfActive() }
                } header: {
                    Text("Voice companion")
                } footer: {
                    Text("Optional and off by default. When you start a voice conversation, your microphone audio and selected session context (project names, agent type, status, and summaries) are sent directly to your selected provider — Qwen (DashScope), OpenAI, or Gemini (Google) — using your own API key. The key stays in Keychain and nothing passes through a vibebuddy server.")
                }

                // Only the selected provider's credentials show — key + editable
                // Model ID + Voice ID — and they swap as the picker changes. `.id`
                // recreates the section so its fields reload for the new provider.
                if let p = VoiceProvider(rawValue: provider) {
                    ProviderSection(provider: p).id(p.rawValue)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.smooth, value: provider)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: playSound) { _, _ in reportPrefs() }
            .onChange(of: quiet) { _, _ in reportPrefs() }
            .onChange(of: quietHours) { _, q in SoundPrefs.setQuietHours(q); reportPrefs() }
            .onChange(of: categories) { _, c in SoundPrefs.categories = c; reportPrefs() }
        }
    }

    private var hourTags: some View {
        ForEach(0..<24, id: \.self) { h in
            Text(String(format: "%02d:00", h)).tag(h)
        }
    }

    /// Tell the Mac so its background push respects the new prefs.
    private func reportPrefs() {
        if ProcessInfo.processInfo.environment["VIBEBUDDY_SKIP_NOTIFICATIONS"] != "1" {
            PushRegistration.shared.reportPrefs()
        }
    }
}

/// Credentials + editable Model ID and Voice ID for one voice provider. The key
/// lives in the Keychain (per-provider account); model/voice are UserDefaults.
/// blank = the provider's sensible default. Ported from the Mac Settings.
private struct ProviderSection: View {
    let provider: VoiceProvider
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @State private var apiKey = ""
    @State private var model = ""
    @State private var voice = ""

    var body: some View {
        Section {
            field(caption: "API Key — paste your own (kept in the Keychain)",
                  link: "Get an API key", icon: "key", url: provider.apiKeyURL) {
                SecureField("Paste your \(provider.display) key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            field(caption: "Model ID — editable, type any model",
                  link: "Browse available models", icon: "arrow.up.right.square", url: provider.modelsURL) {
                TextField(provider.defaultModel, text: $model)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            field(caption: "Voice ID — editable (blank = auto by language)",
                  link: "Browse available voices", icon: "arrow.up.right.square", url: provider.voicesURL) {
                TextField(exampleVoice, text: $voice)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if provider == .qwen {
                Toggle("Use international site (dashscope-intl)", isOn: $intl)
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
        case .qwen:   return "e.g. Tina / Jennifer"
        case .openai: return "e.g. marin / cedar"
        case .gemini: return "e.g. Puck / Kore"
        }
    }
}
