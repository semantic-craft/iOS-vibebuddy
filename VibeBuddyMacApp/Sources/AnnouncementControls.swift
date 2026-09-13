import SwiftUI
import VibeBuddyKit

struct AnnouncementControls: View {
    @ObservedObject var reader: ReadAloud
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
            Button { reader.togglePause() } label: {
                Image(systemName: reader.paused ? "play.fill" : "pause.fill")
            }.help(reader.paused ? "Resume announcements" : "Pause announcements")
            Button { reader.skip() } label: { Image(systemName: "forward.end.fill") }
                .help("Skip announcement").disabled(!reader.automaticBusy)
            Button { reader.replayLatest() } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Replay previous result").disabled(!reader.canReplay)
            if reader.hasMoreResults {
                Image(systemName: "text.badge.plus").help("More results remain in the unread list")
            }
        }
        .buttonStyle(.plain).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
        .help(reader.status)
        if !reader.status.isEmpty {
            Text(LocalizedStringKey(reader.status)).font(CompanionType.font(9))
                .foregroundStyle(CompanionPalette.ink3).lineLimit(1).frame(maxWidth: 125)
                .help(reader.status)
        }
        }
    }
}
