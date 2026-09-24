import SwiftUI

/// Closing this sheet never changes playback or call state.
struct MacVoicePanel: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject private var voice: VoiceChat
    @Environment(\.dismiss) private var dismiss

    init(model: MenuBarModel) {
        self.model = model
        self.voice = model.voiceChat
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Voice and reading").font(MacTheme.font(17, .semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MacSpeechPanel(model: model, openSettings: {
                        NotificationCenter.default.post(name: .openAppSettings, object: SettingsPageID.voice)
                    })
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Voice conversation").font(MacTheme.font(14, .semibold))
                            Spacer()
                            Button(voice.isActive ? "End voice conversation" : "Start voice conversation") { voice.toggle() }
                        }
                        Text(microphoneState).font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                        if !voice.lastUserText.isEmpty {
                            Text("You").font(MacTheme.font(11, .semibold))
                            Text(voice.lastUserText).textSelection(.enabled)
                        }
                        if !voice.lastReply.isEmpty {
                            Text("Buddy").font(MacTheme.font(11, .semibold))
                            Text(voice.lastReply).textSelection(.enabled)
                        }
                        if let held = voice.heldNotice {
                            Label(held, systemImage: "hand.raised")
                                .foregroundStyle(MacTheme.status(.requiresInput)).textSelection(.enabled)
                        }
                        if !voice.actionReceipt.isEmpty {
                            Text("Action receipt").font(MacTheme.font(11, .semibold))
                            Text(voice.actionReceipt).textSelection(.enabled)
                            Text("An action receipt is not confirmation that the agent finished the work.")
                                .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
                        }
                        if let error = voice.errorText {
                            Text(error).foregroundStyle(MacTheme.status(.error)).textSelection(.enabled)
                        }
                        if let notice = voice.endNotice, voice.errorText == nil, !voice.isActive {
                            HStack(alignment: .firstTextBaseline) {
                                Text(notice).foregroundStyle(MacTheme.ink2).textSelection(.enabled)
                                Spacer()
                                Button("Redial") { voice.redial() }
                                    .help("Start a new voice call without the earlier conversation")
                                    .accessibilityIdentifier("mac-voice-redial")
                            }
                        }
                    }
                    .font(MacTheme.font(13)).padding(16)
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .frame(width: 650, height: 620)
        .background(MacTheme.bg).foregroundStyle(MacTheme.ink)
        .accessibilityIdentifier("mac-voice-reading-panel")
        .sheet(isPresented: $voice.showConsent) { VoiceConsentSheet(voice: voice) }
    }

    private var microphoneState: LocalizedStringKey {
        switch voice.phase {
        case .idle: "Microphone off"
        case .listening: "Microphone listening"
        case .speaking: "Buddy speaking · Microphone paused"
        case .thinking: "Thinking…"
        case .connecting: "Connecting…"
        case .recovering: "Recovering…"
        }
    }
}
