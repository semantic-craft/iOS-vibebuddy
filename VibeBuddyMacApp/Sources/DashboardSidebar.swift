import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// The dashboard's one sidebar, in the shape of Cursor's main window: the
/// actions on top (New task, Search, Voice), the four libraries, the project
/// filter for whichever library is showing, and at the bottom the account
/// quota and Settings. It replaces the segmented library picker, the buddy
/// header and the window toolbar, so nothing sits in the title bar any more.
struct DashboardSidebar: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var voice: VoiceChat
    @Binding var library: String
    @Binding var projectScope: DashboardSessionList.ProjectScope
    @Binding var historyProject: String?
    let liveProjects: [DashboardSessionList.Project]
    /// History's projects by path, with how many conversations each holds.
    let historyProjects: [(path: String, count: Int)]
    var onNewTask: () -> Void
    var onSearch: () -> Void
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false
    /// The one-line "where voice lives" note shows until the dashboard has been
    /// closed once with it on screen (ADR-0017 §3).
    @AppStorage("dashboard.voiceHintSeen") private var voiceHintSeen = false

    static let width: CGFloat = 216

    private var waiting: Int { model.sessions.filter { $0.status == .needsResponse }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The actions and the libraries never scroll away; only the
            // project list does, so New task stays reachable in any project count.
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(systemName: "plus.square", title: "New task", shortcut: "⌘N", action: onNewTask)
                SidebarRow(systemName: "magnifyingglass", title: "Search", shortcut: "⌘F", action: onSearch)
                voiceRow

                SidebarHeading(title: "Library")
                SidebarRow(systemName: "rectangle.stack", title: "Current tasks",
                           count: waiting, countTint: MacTheme.status(.requiresInput),
                           selected: library == "live") { library = "live" }
                SidebarRow(systemName: "clock", title: "History", selected: library == "history") { library = "history" }
                SidebarRow(systemName: "star", title: "Favorites", selected: library == "favorites") { library = "favorites" }
                SidebarRow(systemName: "chart.bar", title: "Usage", selected: library == "usage") { library = "usage" }
                if library != "usage" { SidebarHeading(title: "Projects") }
            }
            .padding(.horizontal, 8).padding(.top, 10)
            if library != "usage" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) { projectRows }
                        .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
            Spacer(minLength: 0)
            QuotaPlinth(model: model)
            Divider()
            SidebarRow(systemName: "gearshape", title: "Settings", shortcut: "⌘,") {
                NotificationCenter.default.post(name: .openAppSettings, object: nil)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: Self.width).frame(maxHeight: .infinity)
        .background(MacTheme.bg2)
        .sheet(isPresented: $voice.showConsent) { VoiceConsentSheet(voice: voice) }
        .onDisappear { if !companionEnabled { voiceHintSeen = true } }
    }

    // MARK: Voice

    /// The mic is Cursor's small round button, here on its own row: the row
    /// toggles the conversation, the trailing word is its state, and a second
    /// line carries the last exchange or the error. The cat sits beside the
    /// mic only while a conversation is live (ADR-0017 §2–3).
    private var voiceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { voice.toggle() } label: {
                HStack(spacing: 8) {
                    MicGlyph(phase: voice.phase, enabled: companionEnabled)
                    if voice.isActive {
                        PetFace(state: model.buddyState, voice: .init(voice.phase), plain: true, scale: 0.36)
                            .frame(width: 18, height: 18)
                    }
                    Text("Voice").font(MacTheme.font(12, .medium)).foregroundStyle(MacTheme.ink)
                    Spacer(minLength: 4)
                    Text(stateWord).font(MacTheme.mono(10)).foregroundStyle(stateTint).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(SidebarRowStyle(selected: voice.isActive))
            .help(voice.phase == .idle ? "Start voice conversation" : "End voice conversation")
            .accessibilityLabel("Toggle voice companion")
            if let line = secondLine {
                Text(line.text).font(MacTheme.font(10.5))
                    .foregroundStyle(line.isError ? MacTheme.status(.error) : MacTheme.ink2)
                    .lineLimit(2).padding(.horizontal, 8).padding(.bottom, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stateWord: LocalizedStringKey {
        if !companionEnabled { return "Off" }
        switch voice.phase {
        case .idle: return ""
        case .listening: return "Listening…"
        case .speaking: return "Speaking…"
        case .thinking: return "Thinking…"
        case .connecting: return "Connecting…"
        case .recovering: return "Recovering…"
        }
    }

    private var stateTint: Color { voice.phase == .idle ? MacTheme.ink3 : MacTheme.accent }

    private var secondLine: (text: String, isError: Bool)? {
        if let err = voice.errorText { return (err, true) }
        if !voice.lastReply.isEmpty { return (voice.lastReply, false) }
        if !voice.lastUserText.isEmpty { return (voice.lastUserText, false) }
        if !companionEnabled {
            return voiceHintSeen ? nil : (String(localized: "Enable it in Settings › Voice, or tap the mic."), false)
        }
        if voice.phase == .connecting { return (String(localized: "Connecting — wait to speak"), false) }
        if voice.phase == .recovering { return (String(localized: "Recovering audio… tap the mic to end"), false) }
        let n = model.buddySessionIDs.count
        return (n == 0 ? String(localized: "Buddy: all sessions") : String(localized: "Buddy: \(n) selected"), false)
    }

    // MARK: Projects

    @ViewBuilder private var projectRows: some View {
        if library == "live" {
            ForEach(liveProjects) { project in
                // Live projects are named by their path; the row shows the
                // folder, as Cursor does, and keeps the path in the tooltip.
                let full = Self.title(project.id)
                ProjectRow(title: full.hasPrefix("/") ? URL(fileURLWithPath: full).lastPathComponent : full,
                           count: project.count,
                           selected: projectScope == project.id) { projectScope = project.id }
                    .help(full)
            }
        } else {
            ProjectRow(title: String(localized: "All projects"),
                       count: historyProjects.reduce(0) { $0 + $1.count },
                       selected: historyProject == nil) { historyProject = nil }
            ForEach(historyProjects, id: \.path) { project in
                ProjectRow(title: project.path.isEmpty ? String(localized: "Unknown project")
                                                       : URL(fileURLWithPath: project.path).lastPathComponent,
                           count: project.count, selected: historyProject == project.path) { historyProject = project.path }
                    .help(project.path)
            }
        }
    }

    static func title(_ scope: DashboardSessionList.ProjectScope) -> String {
        switch scope {
        case .all: String(localized: "All projects")
        case .unknown: String(localized: "Unknown project (unassigned)")
        case .project(let name): name
        }
    }
}

// MARK: - Pieces

/// Cursor's sidebar row: a line glyph, the name, and on the right a count or a
/// shortcut in the mono face. Selection is a soft ink wash, never the accent.
struct SidebarRow: View {
    let systemName: String
    let title: LocalizedStringKey
    var count: Int = 0
    var countTint: Color = MacTheme.ink3
    var shortcut: String? = nil
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? MacTheme.accent : MacTheme.ink2).frame(width: 14)
                Text(title).font(MacTheme.font(12, .medium)).foregroundStyle(selected ? MacTheme.accentText : MacTheme.ink).lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(MacTheme.mono(10, .medium)).foregroundStyle(countTint)
                } else if let shortcut {
                    Text(shortcut).font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ProjectRow: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(MacTheme.font(12)).foregroundStyle(selected ? MacTheme.accentText : MacTheme.ink2)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(count)").font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Section label in the mono face, uppercase and tracked, as Cursor sets
/// "Projects" and "Repositories".
struct SidebarHeading: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title).font(MacTheme.mono(10, .medium)).foregroundStyle(MacTheme.ink3)
            .textCase(.uppercase).kerning(0.6)
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
    }
}

/// Hover lifts the row a shade of ink; selection is the Settings sidebar's
/// green wash, so both windows mark "you are here" the same way.
struct SidebarRowStyle: ButtonStyle {
    var selected: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ground(configuration.isPressed), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering = $0 }
    }
    private func ground(_ pressed: Bool) -> Color {
        if selected { return MacTheme.accent.opacity(0.14) }
        if pressed { return MacTheme.ink.opacity(0.07) }
        return hovering ? MacTheme.ink.opacity(0.04) : .clear
    }
}

/// The mic as Cursor draws it in the composer: a 20pt disc, filled with the
/// accent while a conversation is live, quiet ground otherwise.
struct MicGlyph: View {
    let phase: VoiceChat.Phase
    let enabled: Bool
    var body: some View {
        Image(systemName: glyph)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(phase == .idle ? MacTheme.ink2 : MacTheme.bg)
            .frame(width: 20, height: 20)
            .background(phase == .idle ? MacTheme.bg3 : MacTheme.accent, in: Circle())
            .overlay(Circle().strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline))
    }
    private var glyph: String {
        if !enabled { return "mic.slash" }
        switch phase {
        case .idle: return "mic"
        case .listening: return "mic.fill"
        case .speaking: return "waveform"
        case .connecting, .recovering, .thinking: return "ellipsis"
        }
    }
}

/// Cursor's filter chip: outlined at rest, accent-filled when on.
struct FilterChip: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(MacTheme.font(10.5, .medium))
                .foregroundStyle(selected ? MacTheme.bg : MacTheme.ink2)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(selected ? MacTheme.accent : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? .clear : MacTheme.line, lineWidth: CompanionType.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The "iOS-vibebuddy ⌄" kind of dropdown pill Cursor uses for model and
/// project pickers: outlined, quiet, a chevron at the end.
struct MenuPill<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu(content: content) {
            HStack(spacing: 4) {
                Text(title).font(MacTheme.font(10.5, .medium)).foregroundStyle(MacTheme.ink2).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(MacTheme.ink3)
            }
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
    }
}

/// An empty pane that stays out of the way: a small glyph, a title at body
/// size and one line of guidance, centred, with no card behind it. Replaces
/// the system `ContentUnavailableView`, whose display-size title outweighed
/// the list beside it.
struct QuietEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var systemName = "sidebar.right"
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemName).font(.system(size: 22, weight: .light)).foregroundStyle(MacTheme.ink3)
                .padding(.bottom, 4)
            Text(title).font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
            Text(message).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}
