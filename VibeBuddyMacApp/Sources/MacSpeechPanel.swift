import SwiftUI
import VibeBuddyKit

/// Voice-page controls for the existing reader; closing the page owns no audio.
struct MacSpeechPanel: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject private var reader: ReadAloud
    @ObservedObject private var voice: VoiceChat
    @ObservedObject private var tests: SettingsTestCoordinator
    @ObservedObject private var credentials: SettingsCredentials
    let openSettings: () -> Void

    init(model: MenuBarModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.reader = model.readAloud
        self.voice = model.voiceChat
        self.tests = model.settingsTests
        self.credentials = model.settingsCredentials
        self.openSettings = openSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ContentStylePicker()
            Text("Changes apply to all summary entries. Edit custom instructions in Settings.")
                .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
            ReadAloudPreferences(reader: reader, voiceChat: voice, tests: tests, credentials: credentials)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Read pending").font(CompanionType.font(14, .medium))
                    Text("All current pending tasks").font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                }
                Spacer()
                Button("Read pending") { model.readPending() }
                    .disabled(voice.isActive || tests.isBusy)
            }
            if let current = reader.currentItem {
                Text("Current announcement").font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                Text(current.title).font(CompanionType.font(13)).textSelection(.enabled)
            }
            if !reader.pendingItems.isEmpty {
                Text("Up next").font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                ForEach(reader.pendingItems) { item in
                    Text(item.title).font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                        .lineLimit(2).help(item.title)
                }
            }
            HStack(spacing: 8) {
                Button(reader.paused ? "Resume reading" : "Pause reading") { reader.togglePause() }
                    .disabled(!reader.automaticBusy || voice.isActive)
                Button("Skip") { reader.skip() }.disabled(reader.currentItem == nil)
                Button("Replay previous result") { reader.replayLatest() }.disabled(!reader.canReplay || voice.isActive)
                Button("Stop reading") { reader.stop() }.disabled(!reader.busy)
            }
            .controlSize(.small)
            if !reader.status.isEmpty {
                Text(LocalizedStringKey(reader.status)).font(CompanionType.font(12))
                    .foregroundStyle(CompanionPalette.ink2).textSelection(.enabled)
            }
            if reader.hasMoreResults {
                Text("More pending tasks remain available in the task list.")
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
            }
            Text("Listening does not mark results read. Voice pauses manual reading until you resume.")
                .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
            Button("Read-aloud settings", action: openSettings).buttonStyle(.link)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.bg2)
    }
}
