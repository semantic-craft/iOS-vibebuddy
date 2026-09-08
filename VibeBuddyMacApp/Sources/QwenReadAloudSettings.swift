import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct QwenReadAloudSettings: View {
    @ObservedObject var reader: QwenReadAloud
    @ObservedObject var voiceChat: VoiceChat
    @ObservedObject var tests: SettingsTestCoordinator
    @Binding var qwenKey: String
    let hasKey: Bool
    let keySaveFailed: Bool
    let sharedProviderIsQwen: Bool
    @AppStorage(QwenReadAloud.enabledKey) private var enabled = false
    @AppStorage(QwenReadAloud.modelKey) private var model = QwenSpeechSynthesis.defaultModel
    @AppStorage(QwenReadAloud.voiceKey) private var voice = QwenSpeechSynthesis.defaultVoice
    @AppStorage(CompletionSummaryConfiguration.enabledKey) private var summariesEnabled = false
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspace = ""

    private var configuration: QwenReadAloud.PreviewConfiguration {
        let value = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(model: model.trimmingCharacters(in: .whitespacesAndNewlines),
                     voice: voice, workspaceID: value.isEmpty ? nil : value, useIntl: intl)
    }
    private var configurationFailure: String? {
        if !hasKey { return "Save your DashScope API key first." }
        if configuration.model.isEmpty { return "Enter a speech synthesis model before previewing." }
        if voice.isEmpty { return "Enter a voice ID or use the language default." }
        let config = CompletionSummaryConfiguration(enabled: true, provider: .qwen, modelID: configuration.model,
            qwenUseIntl: intl, qwenWorkspaceID: workspace)
        if config.configurationFailure != nil { return "Check the Qwen workspace ID in Provider connection." }
        return nil
    }

    var body: some View {
        Section("Read summaries on this Mac") {
            LabeledContent("Read-aloud provider", value: "Qwen")
            Text("Read-aloud always uses Qwen. Changing the shared provider does not change this connection.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Automatically read AI completion summaries for followed tasks", isOn: $enabled)
            if !summariesEnabled {
                Text("Automatic reading needs AI completion summaries to be enabled and successfully generated. Previewing does not enable either feature.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Generate speech with DashScope and play it through your Mac’s current audio output. No microphone is needed. Each reading incurs speech-generation charges.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Speech synthesis model", text: $model)
                .font(.body.monospaced()).autocorrectionDisabled()
            Picker("Read-aloud voice", selection: $voice) {
                Text("Longan Fengyue · Warm and natural").tag("longanfengyue")
                Text("Longan Lingxi · Sweet and cheerful").tag("longanlingxi")
                Text("Longan Yuanfei · Female character voice").tag("longanyuanfei")
                if !["longanfengyue", "longanlingxi", "longanyuanfei"].contains(voice) {
                    Text(verbatim: voice).tag(voice)
                }
            }
            if sharedProviderIsQwen {
                Text("Qwen credentials, region and workspace are shared with the selected provider. Edit them in Provider connection below.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Qwen read-aloud connection") {
                    Text("These Qwen credentials are also used when Qwen is selected for conversation or summaries.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        SecureField("Qwen API key", text: $qwenKey)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        Button("Paste") {
                            guard let value = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
                            qwenKey = value
                        }
                    }
                    Link("Get an API key", destination: VoiceProvider.qwen.apiKeyURL)
                    Toggle("Use Singapore (international) region", isOn: $intl)
                    TextField("Workspace ID — optional; uses the workspace endpoint when set", text: $workspace)
                        .font(.body.monospaced()).autocorrectionDisabled()
                    Link("Find your workspace ID", destination: VoiceProvider.qwenWorkspaceIDURL)
                }
            }
            if keySaveFailed {
                Text("API key could not be saved. Your edit is not stored; edit or paste it again to retry.")
                    .foregroundStyle(.orange)
            }
            if let failure = configurationFailure {
                Text(LocalizedStringKey(failure)).foregroundStyle(.secondary)
            }
            if voiceChat.isActive {
                Text("Stop the current voice conversation or reading before previewing.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Preview Qwen voice", action: preview)
                    .disabled(tests.isBusy || reader.busy || voiceChat.isActive || configurationFailure != nil)
                Button("Stop") { tests.cancel() }
                    .disabled(tests.purpose != .readAloud || !tests.isBusy)
            }
            Text("Preview sends only the sample text to Qwen and may incur a speech-generation charge. It does not enable automatic reading or use the microphone.")
                .font(.caption).foregroundStyle(.secondary)
            if tests.purpose == .readAloud, tests.phase == .running {
                Text("Qwen read-aloud preview").font(.headline)
                if !reader.previewStatus.isEmpty { Text(LocalizedStringKey(reader.previewStatus)).font(.caption) }
            }
            if tests.purpose != .readAloud { Text("Not verified").foregroundStyle(.secondary) }
            SettingsTestFeedback(tests: tests, purpose: .readAloud)
            if reader.automaticBusy || !reader.status.isEmpty {
                Text("Automatic reading").font(.headline)
                if reader.automaticBusy && tests.purpose == .readAloud && tests.isBusy {
                    Text("Automatic reading is queued until the preview finishes.").font(.caption)
                } else if !reader.status.isEmpty {
                    Text(LocalizedStringKey(reader.status)).font(.caption)
                }
                Button("Stop automatic reading") { reader.stopAutomaticReading() }
                    .disabled(!reader.automaticBusy)
            }
        }
        .onChange(of: enabled) { _, on in
            tests.invalidate()
            if !on { reader.stop() } // Preserve the existing explicit opt-out behavior.
        }
        .onChange(of: model) { _, _ in tests.invalidate(); reader.stop() }
        .onChange(of: voice) { _, _ in tests.invalidate(); reader.stop() }
        .onChange(of: [qwenKey, workspace, String(intl)]) { _, _ in tests.invalidate() }
        .onChange(of: voiceChat.isActive) { _, active in
            if active, tests.purpose == .readAloud { tests.cancel() }
        }
        .onDisappear { tests.invalidate() }
    }

    private func preview() {
        guard !tests.isBusy, !reader.busy, !voiceChat.isActive, configurationFailure == nil else { return }
        let config = configuration, key = qwenKey, reader = reader
        let text = NSLocalizedString("Hello, I’m your work companion. The task is complete, and device verification is still pending.", comment: "Synthetic Qwen preview")
        tests.start(.readAloud, timeout: .seconds(35), operation: {
            switch await reader.preview(text, apiKey: key, configuration: config) {
            case .completed:
                return .success(.init(message: "Qwen preview playback completed on this Mac. Confirm that you heard it through the intended output."))
            case .cancelled: return .cancelled
            case .failed(let message): return .failure(message)
            }
        }, cleanup: { await reader.cancelPreview() })
    }
}
