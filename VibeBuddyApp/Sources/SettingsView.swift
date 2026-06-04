import SwiftUI
import VibeBuddyKit

/// The phone's settings sheet — deliberately small. The sound-pack controls the
/// spec asks for (play / mute, Quiet mode, a nightly window). No per-sound picker.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SoundPrefs.playSoundKey) private var playSound = true
    @AppStorage(SoundPrefs.quietModeKey) private var quiet = false
    @State private var quietHours = SoundPrefs.quietHours
    @AppStorage(VoiceSettings.enabledKey) private var voiceEnabled = false
    @AppStorage(VoiceSettings.regionIntlKey) private var voiceIntl = false
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("提示音", isOn: $playSound)
                    Toggle("专注模式（只保留权限提示）", isOn: $quiet).disabled(!playSound)
                } header: {
                    Text("声音")
                } footer: {
                    Text("每个状态变化配一段简短的内置提示音——需要你、权限、完成、卡住。只有状态边界会响，过程中不打扰。专注模式下只有安全权限会发声，其余静音。")
                }

                Section {
                    Toggle("夜间自动静音", isOn: $quietHours.enabled).disabled(!playSound)
                    if quietHours.enabled {
                        Picker("开始", selection: $quietHours.startHour) { hourTags }
                        Picker("结束", selection: $quietHours.endHour) { hourTags }
                    }
                } header: {
                    Text("夜间")
                } footer: {
                    Text("在这个时间段内自动进入专注模式，只有安全权限会发声。")
                }

                Section {
                    Toggle("语音助手", isOn: $voiceEnabled)
                    SecureField("Qwen (DashScope) API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(!voiceEnabled)
                    Toggle("使用国际站 (dashscope-intl)", isOn: $voiceIntl).disabled(!voiceEnabled)
                } header: {
                    Text("语音助手")
                } footer: {
                    Text("轻点宠物即可语音对话——它知道你的会话，还能帮你批准/回答。语音识别与朗读在本机完成；只有对话用到你的 Qwen Key（存于钥匙串，不上传、不入库）。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
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
