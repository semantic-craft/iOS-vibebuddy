import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// A current-session overview. Opening a task delegates reading and all
/// operations to the existing live detail; the hub only navigates.
struct MacInboxHomeView: View {
    let projection: DashboardSessionList
    let recap: Recap?
    let openRecap: () -> Void
    let readPending: () -> Void
    let openFirst: () -> Void
    let openBucket: (DashboardSessionList.StatusFilter?) -> Void
    let openProject: (DashboardSessionList.ProjectScope) -> Void
    let openOlder: () -> Void

    private var summary: TaskPresentationSummary { projection.summary }
    private var needsTitle: LocalizedStringKey {
        summary.requiresInput == 0 && summary.error > 0 ? "Stuck" : "Needs you"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Inbox").font(MacTheme.font(26, .semibold)).foregroundStyle(MacTheme.ink)
                        Spacer()
                        Button(action: readPending) { Label("Read pending", systemImage: "speaker.wave.2") }
                            .accessibilityIdentifier("mac-inbox-read-pending")
                    }
                    HStack(spacing: 16) {
                        Label("\(summary.needsYou) need you", systemImage: "exclamationmark.circle")
                        Label("\(summary.completeUnread) unread", systemImage: "checkmark.circle")
                        Label("\(summary.thinking) working", systemImage: "ellipsis.circle")
                    }
                    .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                    .accessibilityIdentifier("mac-inbox-summary")
                }
                if let first = projection.globalPending.first {
                    Button(action: openFirst) {
                        HStack(spacing: 12) {
                            Image(systemName: first.presentationState.symbolName)
                                .foregroundStyle(MacTheme.status(first.presentationState))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("First up").font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3)
                                Text(first.displayTitle).font(MacTheme.font(15, .semibold)).foregroundStyle(MacTheme.ink)
                                Text(DashboardSidebar.title(.of(first)))
                                    .font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                                    .lineLimit(1).truncationMode(.middle)
                                Text(RowPresentation(session: first).activityOrResult)
                                    .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2).lineLimit(2)
                            }
                            Spacer()
                            Text("1 / \(projection.globalPending.count)").font(MacTheme.mono(11)).foregroundStyle(MacTheme.ink3)
                            Image(systemName: "chevron.right").foregroundStyle(MacTheme.ink3)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .companionCard(MacTheme.bg2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("mac-inbox-first-up")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(summary.thinking > 0 ? "Work is continuing" : "Nothing pending",
                              systemImage: summary.thinking > 0 ? "ellipsis.circle" : "moon.zzz")
                            .font(MacTheme.font(14, .medium)).foregroundStyle(MacTheme.ink)
                        Text(summary.thinking > 0 ? "No decisions or unread results need you right now."
                             : summary.isEmpty && projection.olderCount > 0 ? "Nothing has moved in the last 24 hours."
                             : summary.isEmpty ? "Start a Claude Code or Codex session and it'll show up here."
                             : "Read results remain in All sessions.")
                            .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    bucket("All sessions", count: summary.total, symbol: "line.3.horizontal", filter: nil)
                    bucket("Unread results", count: summary.completeUnread, symbol: "checkmark.circle", filter: .done)
                    bucket(needsTitle, count: summary.needsYou, symbol: "exclamationmark.triangle", filter: .needsYou)
                    bucket("Working", count: summary.thinking, symbol: "ellipsis.circle", filter: .working)
                }
                Button(action: openRecap) {
                    HStack {
                        Label("Recap", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        if let recap {
                            Text("\(recap.entries.count) rounds · \(recap.failedCount) failed")
                        } else {
                            Text("Recap unavailable")
                        }
                        Image(systemName: "chevron.right")
                    }
                    .font(MacTheme.font(12)).padding(14).companionCard(MacTheme.bg2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("mac-inbox-recap")
                if projection.olderCount > 0 {
                    Button(action: openOlder) { Label("Show \(projection.olderCount) older", systemImage: "clock.arrow.circlepath") }
                        .buttonStyle(.borderless).font(MacTheme.font(12))
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Projects").font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
                        Spacer()
                        Text("Pending tasks").font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
                    }
                    ForEach(projection.projects.filter { $0.id != .all }) { project in
                        let title = DashboardSidebar.title(project.id)
                        Button { openProject(project.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(MacTheme.ink3)
                                Text(title).lineLimit(1).truncationMode(.middle).foregroundStyle(MacTheme.ink2)
                                Spacer(minLength: 8)
                                Text("\(project.count)").font(MacTheme.mono(12)).foregroundStyle(MacTheme.ink3)
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(MacTheme.ink3)
                            }
                            .font(MacTheme.font(12)).padding(.vertical, 8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(title)
                        Divider()
                    }
                }
            }
            .padding(24).frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(MacTheme.bg)
        .accessibilityIdentifier("mac-inbox-home")
    }

    private func bucket(_ title: LocalizedStringKey, count: Int, symbol: String,
                        filter: DashboardSessionList.StatusFilter?) -> some View {
        Button { openBucket(filter) } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(MacTheme.ink2)
                HStack {
                    Text(title).font(MacTheme.font(12, .medium)).foregroundStyle(MacTheme.ink)
                    Spacer(minLength: 4)
                    Text("\(count)").font(MacTheme.mono(15, .medium)).foregroundStyle(MacTheme.ink2)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .companionCard(MacTheme.bg3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mac-inbox-bucket-\(filter?.rawValue ?? "all")")
    }
}
