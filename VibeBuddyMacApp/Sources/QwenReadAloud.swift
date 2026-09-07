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
        busy = true; status = "Generating Qwen speech…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == id { self.busy = false; self.task = nil } }
            do {
                guard await validate(), !Task.isCancelled, self.generation == id, self.canSpeak() else { return }
                guard let key = VoiceProvider.qwen.apiKey, !key.isEmpty else {
                    self.status = "Save your DashScope API key first."; return
                }
                let defaults = UserDefaults.standard
                let data = try await QwenSpeechSynthesis.synthesize(text, apiKey: key,
                    model: defaults.string(forKey: Self.modelKey) ?? QwenSpeechSynthesis.defaultModel,
                    voice: defaults.string(forKey: Self.voiceKey) ?? QwenSpeechSynthesis.defaultVoice,
                    workspaceID: VoiceSettings.qwenWorkspaceID, useIntl: VoiceSettings.useIntl)
                guard await validate(), !Task.isCancelled, self.generation == id, self.canSpeak() else { return }
                let player = try AVAudioPlayer(data: data)
                self.player = player
                guard player.play() else { self.status = "Your Mac could not play the audio."; return }
                self.status = "Playing Qwen speech"
                while player.isPlaying && !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(100))
                    guard await validate(), !Task.isCancelled, self.generation == id, self.canSpeak() else {
                        player.stop()
                        if self.generation == id { self.player = nil; self.status = "Read-aloud stopped" }
                        return
                    }
                }
                if self.generation == id { self.status = "Playback complete"; self.player = nil }
            } catch is CancellationError { }
              catch { if self.generation == id { self.status = "Speech generation failed. Check your DashScope model, voice and connection." } }
        }
    }
}

struct QwenReadAloudSettings: View {
    @ObservedObject var reader: QwenReadAloud
    @AppStorage(QwenReadAloud.enabledKey) private var enabled = false
    @AppStorage(QwenReadAloud.modelKey) private var model = QwenSpeechSynthesis.defaultModel
    @AppStorage(QwenReadAloud.voiceKey) private var voice = QwenSpeechSynthesis.defaultVoice
    var body: some View {
        Section("Mac Qwen Read Aloud") {
            Toggle("Automatically read AI completion summaries for followed tasks", isOn: $enabled)
            Text("Generate speech with DashScope and play it through your Mac’s current audio output. No microphone is needed. Each reading incurs speech-generation charges.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Speech synthesis model", text: $model)
            Picker("Read-aloud voice", selection: $voice) {
                Text("Longan Fengyue · Warm and natural").tag("longanfengyue")
                Text("Longan Lingxi · Sweet and cheerful").tag("longanlingxi")
                Text("Longan Yuanfei · Female character voice").tag("longanyuanfei")
            }
            HStack {
                Button("Preview Qwen voice") { reader.speak(NSLocalizedString("Hello, I’m your work companion. The task is complete, and device verification is still pending.", comment: "Qwen voice preview spoken in the app language")) }
                    .disabled(reader.busy)
                Button("Stop") { reader.stop() }.disabled(!reader.busy)
            }
            if !reader.status.isEmpty { Text(LocalizedStringKey(reader.status)).font(.caption) }
        }
        .onChange(of: enabled) { _, value in if !value { reader.stop() } }
        .onChange(of: model) { _, _ in reader.stop() }
        .onChange(of: voice) { _, _ in reader.stop() }
    }
}
