import SwiftUI
import VibeBuddyKit

/// The phone's settings sheet — deliberately small. The sound-pack controls the
/// spec asks for (play / mute, Quiet mode, a nightly window). No per-sound picker.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SoundPrefs.playSoundKey) private var playSound = true
    @AppStorage(SoundPrefs.quietModeKey) private var quiet = false
    @State private var quietHours = SoundPrefs.quietHours
    @AppStorage(VoiceSettings.regionIntlKey) private var voiceIntl = false
    @AppStorage(VoiceSettings.conversationLanguageKey) private var voiceLanguage = VoiceLanguage.english.rawValue
    @State private var apiKey = ""

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
                    SecureField("Qwen (DashScope) API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Conversation language", selection: $voiceLanguage) {
                        Text("English").tag(VoiceLanguage.english.rawValue)
                        Text("中文").tag(VoiceLanguage.chinese.rawValue)
                    }
                    Toggle("Use international site (dashscope-intl)", isOn: $voiceIntl)
                } header: {
                    Text("Voice companion")
                } footer: {
                    Text("Tap the pet to talk — it knows your sessions and can approve / answer for you. Pick the language you'll speak and it'll reply in. The conversation uses your own Qwen key (kept in the Keychain, never uploaded or committed).")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { apiKey = VoiceSettings.apiKey ?? "" }
            .onChange(of: playSound) { _, _ in reportPrefs() }
            .onChange(of: quiet) { _, _ in reportPrefs() }
            .onChange(of: quietHours) { _, q in SoundPrefs.setQuietHours(q); reportPrefs() }
            .onChange(of: apiKey) { _, v in KeychainStore.set(v, for: VoiceSettings.apiKeyKeychain) }
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
