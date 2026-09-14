import SwiftUI
import VibeBuddyKit

/// The voice page (ticket 05, `.scratch/iphone-board`): the read-aloud queue
/// above, the live conversation below, and the three keys at the foot —
/// pause, the mic, skip. Closing it changes nothing: the call and the reading
/// carry on, and the strips over the composer keep showing them.
struct VoicePageView: View {
    @EnvironmentObject private var dashboard: DashboardStore
    @State private var showSpeechSettings = false
    @ObservedObject var voice: VoiceChat
    @ObservedObject var announcer: PhoneAnnouncer
    let scopeCount: Int
    let scopeTotal: Int
    let replay: () -> Void
    let openScope: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            PhoneSheetHeader(title: String(localized: "Voice")) { dismiss() } trailing: {
                Button { openScope() } label: {
                    HStack(spacing: 4) {
                        Text(scopeCount == scopeTotal ? String(localized: "Scope: all \(scopeTotal)")
                                                      : String(localized: "Scope: \(scopeCount) of \(scopeTotal)"))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                .accessibilityIdentifier("phone-voice-scope")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button { showSpeechSettings = true } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Summary & speech")
                                Text(dashboard.contentStyleState.map { String(localized: String.LocalizationValue($0.configuration.style.title)) }
                                     ?? String(localized: "Mac content style unavailable"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                    queue
                    conversation
                }
                .padding(.horizontal, PhoneMetrics.gutter)
                .padding(.bottom, 16)
            }
            keys
        }
        .background(CompanionPalette.bg)
        .tint(CompanionPalette.accent)
        .task { await dashboard.loadContentStyle() }
        .sheet(isPresented: $showSpeechSettings) {
            NavigationStack {
                SummarySpeechSettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSpeechSettings = false } } }
            }
            .environmentObject(voice)
            .environmentObject(announcer)
        }
    }

    // MARK: Queue

    @ViewBuilder private var queue: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Read-aloud queue")
                    .font(CompanionType.font(11, .semibold)).kerning(0.3)
                    .foregroundStyle(CompanionPalette.ink3)
                if !announcer.items.isEmpty {
                    Text(verbatim: "\(min(announcer.spokenCount + (announcer.current == nil ? 0 : 1), announcer.items.count)) / \(announcer.items.count)")
                        .font(CompanionType.mono(11)).monospacedDigit()
                        .foregroundStyle(CompanionPalette.ink3)
                }
                Spacer(minLength: 0)
                Text(PhoneReadAloudSelection.load().title)
                    .font(CompanionType.font(10, .medium))
                    .foregroundStyle(CompanionPalette.ink2)

            }
            if announcer.items.isEmpty {
                Text(announcer.status ?? String(localized: "Nothing queued. \"Read pending\" on the inbox reads what is waiting."))
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink3)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(announcer.items.enumerated()), id: \.element.id) { index, item in
                        queueRow(item, index: index)
                        if index < announcer.items.count - 1 { PhoneDivider(leading: 12) }
                    }
                }
                .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: CompanionType.panelRadius))
                .overlay(RoundedRectangle(cornerRadius: CompanionType.panelRadius)
                    .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline))
                if announcer.moreInList > 0 {
                    Text("\(announcer.moreInList) more in the list")
                        .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                }
                if let status = announcer.status {
                    Text(status).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                }
            }
        }
    }

    private func queueRow(_ item: AnnouncementPlan.Item, index: Int) -> some View {
        let isCurrent = announcer.current?.item.id == item.id
        let isDone = !isCurrent && index < announcer.spokenCount
        let state: TaskPresentationState = switch item.sound {
        case .agentStuck: .error
        case .needsAnswer, .needsApproval: .requiresInput
        default: .completeUnread
        }
        return HStack(spacing: 10) {
            StatusDot(state: state, size: PhoneRowMetrics.dot)
            Text(item.title)
                .font(CompanionType.font(13, isCurrent ? .medium : .regular))
                .foregroundStyle(isDone ? CompanionPalette.ink3 : CompanionPalette.ink)
                .strikethrough(isDone, color: CompanionPalette.ink3)
                .lineLimit(1)
            Spacer(minLength: 6)
            if isCurrent {
                Image(systemName: announcer.isPaused ? "pause" : "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CompanionPalette.accent)
            } else {
                Text(isDone ? String(localized: "Read") : String(localized: "Queued"))
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(isCurrent ? CompanionPalette.accent.opacity(0.08) : .clear)
    }

    // MARK: Conversation

    @ViewBuilder private var conversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversation")
                .font(CompanionType.font(11, .semibold)).kerning(0.3)
                .foregroundStyle(CompanionPalette.ink3)
            if voice.transcript.isEmpty {
                Text(voice.phase == .idle
                     ? String(localized: "Tap the mic and say what to do: \"mark payments-api read\", \"tell release-check to skip codesign and rebuild\".")
                     : String(localized: "Listening…"))
                    .font(CompanionType.font(13)).foregroundStyle(CompanionPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(voice.transcript) { turn in
                if turn.role == .user {
                    Text(turn.text)
                        .font(CompanionType.font(14))
                        .foregroundStyle(CompanionPalette.ink)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: CompanionType.panelRadius))
                        .frame(maxWidth: 280, alignment: .trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            BuddyCatFace(mood: .calm, speaking: false, listening: false,
                                         showsBody: false, onDark: colorScheme == .dark)
                                .frame(width: 16, height: BuddyCat.height(forWidth: 16, showsBody: false))
                                .accessibilityHidden(true)
                            Text("Companion").font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                        }
                        Text(turn.text)
                            .font(CompanionType.font(14))
                            .foregroundStyle(CompanionPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                }
            }
            if let error = voice.errorText {
                Text(error).font(CompanionType.font(12)).foregroundStyle(CompanionPalette.status(.error))
            }
        }
    }

    // MARK: Keys

    private var keys: some View {
        VStack(spacing: 6) {
            HStack(spacing: 22) {
                PhoneCircleButton(announcer.isPaused ? "play.fill" : "pause.fill", size: 44, tint: CompanionPalette.ink2) {
                    announcer.togglePause()
                }
                .disabled(!announcer.isBusy)
                .opacity(announcer.isBusy ? 1 : 0.4)
                .accessibilityLabel(announcer.isPaused ? "Resume reading" : "Pause reading")
                Button { voice.toggle() } label: {
                    Image(systemName: micGlyph)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Color.onAccent)
                        .frame(width: 72, height: 72)
                        .background(voice.phase == .idle ? CompanionPalette.ink : CompanionPalette.accent, in: Circle())
                        .overlay(Circle().strokeBorder(CompanionPalette.ink.opacity(0.06), lineWidth: 8).padding(-8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.phase == .idle ? "Start voice conversation" : "End voice conversation")
                .accessibilityIdentifier("phone-voice-mic")
                PhoneCircleButton("forward.end.fill", size: 44, tint: CompanionPalette.ink2) { announcer.skip() }
                    .disabled(!announcer.isBusy)
                    .opacity(announcer.isBusy ? 1 : 0.4)
                    .accessibilityLabel("Skip")
            }
            .padding(.top, 10)
            HStack(spacing: 6) {
                Text(phaseLine).font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink3)
                if announcer.canReplay {
                    Text("·").foregroundStyle(CompanionPalette.ink3)
                    Button("Replay last") { replay() }
                        .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                }
            }
            if let item = announcer.latestItem,
               let session = AnnouncementPlan.stillCurrent(item, in: dashboard.allSessions) {
                Button("Regenerate with current style") {
                    announcer.announce([session], startPaused: voice.phase != .idle,
                                       live: { dashboard.allSessions },
                                       source: { dashboard.speechSourceIdentity },
                           content: { try await dashboard.announcement(for: $0) },
                                       validate: { dashboard.announcementIsCurrent($0) })
                }
                .disabled(dashboard.state != .connected || announcer.isBusy)
                .font(.caption)
            }
            Text("Reading never marks a result read.")
                .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(CompanionPalette.bg)
        .overlay(alignment: .top) { PhoneDivider() }
    }

    /// Half duplex (ADR-0004): the page says which side the microphone is on.
    private var phaseLine: String {
        switch voice.phase {
        case .idle: announcer.isBusy ? String(localized: "Reading · tap the mic to talk") : String(localized: "Tap the mic to talk")
        case .connecting: String(localized: "Connecting…")
        case .recovering: String(localized: "Recovering audio…")
        case .listening: String(localized: "Listening · reading is paused while you talk")
        case .thinking: String(localized: "Thinking…")
        case .speaking: String(localized: "Speaking · mic is off until it finishes")
        }
    }

    private var micGlyph: String {
        switch voice.phase {
        case .idle: "mic"
        case .connecting, .recovering, .thinking: "ellipsis"
        case .listening: "mic.fill"
        case .speaking: "waveform"
        }
    }
}
