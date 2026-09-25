import SwiftUI
import VibeBuddyKit

struct AnnouncementControls: View {
    @ObservedObject var reader: ReadAloud
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 1) {
            Button { reader.togglePause() } label: { key(reader.paused ? "play.fill" : "pause.fill") }
                .help(reader.paused ? "Resume announcements" : "Pause announcements")
                .accessibilityLabel(reader.paused ? "Resume announcements" : "Pause announcements")
            Button { reader.skip() } label: { key("forward.end.fill") }
                .help("Skip announcement").disabled(!reader.automaticBusy)
                .accessibilityLabel("Skip announcement")
            Button { reader.replayLatest() } label: { key("arrow.counterclockwise") }
                .help("Replay previous result").disabled(!reader.canReplay)
                .accessibilityLabel("Replay previous result")
            if reader.hasMoreResults {
                Image(systemName: "text.badge.plus").help("More results remain in the unread list")
                    .accessibilityLabel("More results remain in the unread list")
            }
        }
        .buttonStyle(.plain).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
        .help(reader.status)
        if !reader.status.isEmpty {
            Text(LocalizedStringKey(reader.status)).font(CompanionType.font(10))
                .foregroundStyle(CompanionPalette.ink3).lineLimit(1).frame(maxWidth: 125)
                .help(reader.status)
        }
        }
    }

    /// An 11pt glyph in a 20pt target (HIG: macOS controls ≥ 20pt).
    private func key(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }
}
