import SwiftUI
import VibeBuddyKit

/// The phone's settings sheet. Sound-pack controls the spec asks for (play / mute,
/// Quiet mode, a nightly window) plus the voice companion: a provider picker
/// (Qwen / OpenAI / Gemini) with per-provider Key / Model ID / Voice ID, mirroring
/// the Mac. No per-sound picker.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var voice: VoiceChat
    @AppStorage(SoundPrefs.playSoundKey) private var playSound = true
    @AppStorage(SoundPrefs.quietModeKey) private var quiet = false
    @State private var quietHours = SoundPrefs.quietHours
    @AppStorage(VoiceSettings.conversationLanguageKey) private var voiceLanguage = VoiceLanguage.english.rawValue
    @AppStorage(VoiceSettings.providerKey) private var provider = VoiceProvider.qwen.rawValue

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Tap the pet to talk — it holds a live voice conversation that knows your sessions and can approve / answer for you. Pick the provider whose key you've filled in below; switching applies instantly if it's already listening. The conversation uses your own key (kept in the Keychain, never uploaded or committed).")
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
    private func field<F: View>(caption: String, link: String, icon: String, url: URL,
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
