import SwiftUI

/// The phone's settings sheet — deliberately small. Just the sound-pack controls
/// the spec asks for (play / mute, Quiet mode). No per-sound picker: less is more.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("playNotificationSound") private var playSound = true
    @AppStorage("quietMode") private var quiet = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("提示音", isOn: $playSound)
                    Toggle("专注模式（只保留权限提示）", isOn: $quiet)
                        .disabled(!playSound)
                } header: {
                    Text("声音")
                } footer: {
                    Text("每个状态变化配一段简短的内置提示音——需要你、权限、完成、卡住。只有状态边界会响，过程中不打扰。专注模式下只有安全权限会发声，其余静音。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
