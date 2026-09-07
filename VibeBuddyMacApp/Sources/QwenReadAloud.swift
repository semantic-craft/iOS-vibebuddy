import AVFoundation
import SwiftUI
import VibeBuddyKit

@MainActor
final class QwenReadAloud: ObservableObject {
    static let enabledKey = "qwenReadAloudEnabled"
    static let modelKey = "qwenReadAloudModel"
    static let voiceKey = "qwenReadAloudVoice"
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    var canSpeak: @MainActor () -> Bool = { true }
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        player?.stop(); player = nil; busy = false
    }

    func speak(_ text: String, validate: @escaping @MainActor () async -> Bool = { true }) {
        guard !busy, canSpeak() else { return }
        let id = UUID(); generation = id
        busy = true; status = "正在合成 Qwen 语音…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == id { self.busy = false; self.task = nil } }
            do {
                guard await validate(), !Task.isCancelled, self.generation == id, self.canSpeak() else { return }
                guard let key = VoiceProvider.qwen.apiKey, !key.isEmpty else {
                    self.status = "请先保存百炼 API Key"; return
                }
                let defaults = UserDefaults.standard
                let data = try await QwenSpeechSynthesis.synthesize(text, apiKey: key,
                    model: defaults.string(forKey: Self.modelKey) ?? QwenSpeechSynthesis.defaultModel,
                    voice: defaults.string(forKey: Self.voiceKey) ?? QwenSpeechSynthesis.defaultVoice,
                    workspaceID: VoiceSettings.qwenWorkspaceID, useIntl: VoiceSettings.useIntl)
                guard await validate(), !Task.isCancelled, self.generation == id, self.canSpeak() else { return }
                let player = try AVAudioPlayer(data: data)
                self.player = player
                guard player.play() else { self.status = "Mac 无法播放音频"; return }
                self.status = "正在播放 Qwen 语音"
                while player.isPlaying && !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                    guard await validate(), !Task.isCancelled, self.generation == id, self.canSpeak() else {
                        player.stop()
                        if self.generation == id { self.player = nil; self.status = "朗读已停止" }
                        return
                    }
                }
                if self.generation == id { self.status = "播放完成"; self.player = nil }
            } catch is CancellationError { }
              catch { if self.generation == id { self.status = "语音合成失败，请检查百炼模型、音色和网络" } }
        }
    }
}

struct QwenReadAloudSettings: View {
    @ObservedObject var reader: QwenReadAloud
    @AppStorage(QwenReadAloud.enabledKey) private var enabled = false
    @AppStorage(QwenReadAloud.modelKey) private var model = QwenSpeechSynthesis.defaultModel
    @AppStorage(QwenReadAloud.voiceKey) private var voice = QwenSpeechSynthesis.defaultVoice
    var body: some View {
        Section("Mac Qwen 朗读") {
            Toggle("自动朗读关注任务的 AI 完成摘要", isOn: $enabled)
            Text("使用百炼生成语音，由 Mac 当前音频输出播放；无需打开麦克风。每次朗读会产生语音合成费用。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("语音合成模型", text: $model)
            Picker("音色", selection: $voice) {
                Text("龙安风悦 · 自然亲切").tag("longanfengyue")
                Text("龙安灵希 · 可爱甜美").tag("longanlingxi")
                Text("龙安元妃 · 角色女声").tag("longanyuanfei")
            }
            HStack {
                Button("试听 Qwen 音色") { reader.speak("你好，我是你的工作伙伴。任务已完成，设备验证仍待进行。") }
                    .disabled(reader.busy)
                Button("停止") { reader.stop() }.disabled(!reader.busy)
            }
            if !reader.status.isEmpty { Text(reader.status).font(.caption) }
        }
        .onChange(of: enabled) { _, value in if !value { reader.stop() } }
        .onChange(of: model) { _, _ in reader.stop() }
        .onChange(of: voice) { _, _ in reader.stop() }
    }
}
