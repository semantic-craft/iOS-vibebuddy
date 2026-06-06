import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct GlanceView: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var voice: VoiceChat
    let mode: GlanceMode

    private var s: CGFloat { model.glanceScale }
    private var expanded: Bool { model.glanceExpanded }
    private var groups: SessionGroups { SessionGroups(model.sessions) }
    private var pending: AgentSession? { model.sessions.first { $0.pendingApproval != nil } }
    private var width: CGFloat { (expanded ? 440 : 300) * s }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .padding(.horizontal, 20 * s).padding(.vertical, (expanded ? 16 : 9) * s)
            .frame(width: width, alignment: expanded ? .leading : .center)
            .background(background)
            .clipShape(clipShape)
            .overlay {
                if voice.isActive {
                    // Designed, not neon: a thin muted-tint border + a single soft
                    // tinted shadow (per swiftui-taste). The voiceBadge spells out
                    // Listening/Speaking, so the border only needs to hint.
                    let tint = voice.isSpeaking ? Color.green : Color.red
                    panelShape.stroke(tint.opacity(0.8), lineWidth: 1.5 * s)
                        .shadow(color: tint.opacity(0.28), radius: 3 * s)
                }
            }
            .onHover { hovering in
                model.setGlanceExpanded(hovering)
            }
    }

    @ViewBuilder private var content: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 8 * s) {
                HStack(spacing: 8 * s) {
                    counts
                    Button {
                        model.setShowGlance(false)   // get out of the way; the shortcut or menu brings it back
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12 * s, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22 * s, height: 22 * s)
                            .background(Color.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide glance (\(model.toggleGlanceHotkey.displayString))")
                }
                if let p = pending, let a = p.pendingApproval {
                    Divider().overlay(.white.opacity(0.2))
                    Text(p.project).font(.system(size: 13 * s, weight: .bold)).foregroundStyle(.white)
                    Text(a.commandPreview).font(.system(size: 11 * s, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                    HStack(spacing: 8 * s) {
                        Button("Approve") { model.decide(a.id, .allow) }
                            .tint(.green).buttonStyle(.borderedProminent).controlSize(.regular)
                        Button("Deny") { model.decide(a.id, .deny) }
                            .tint(.red).buttonStyle(.borderedProminent).controlSize(.regular)
                        Button("Always") { model.decide(a.id, .alwaysAllow) }
                            .tint(.white).buttonStyle(.bordered).controlSize(.regular)
                            .help("Always allow this exact command in future")
                        if p.terminalRef != nil {
                            Button { model.jump(p) } label: {
                                Label("Jump", systemImage: "terminal")
                            }
                            .tint(.white).buttonStyle(.bordered).controlSize(.regular)
                            .help("Jump to terminal")
                        }
                    }
                } else {
                    ForEach(model.sessions.prefix(6)) { sess in
                        let canJump = sess.terminalRef != nil
                        Button { model.jump(sess) } label: {
                            HStack(spacing: 8 * s) {
                                Circle().fill(color(sess.status)).frame(width: 8 * s, height: 8 * s)
                                Text(sess.project).font(.system(size: 13 * s)).foregroundStyle(.white).lineLimit(1)
                                if canJump {
                                    Spacer(minLength: 0)
                                    Image(systemName: "terminal")      // click the row to focus its terminal
                                        .font(.system(size: 11 * s))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canJump)
                        .help(canJump ? "Jump to terminal" : "")
                    }
                }
            }
        } else {
            counts
        }
    }

    private var counts: some View {
        HStack(spacing: 16 * s) {
            PetFace(state: BuddyState.from(groups, now: Date()),
                    speaking: voice.isSpeaking, listening: voice.isListening, bare: true, scale: s)
                .onTapGesture { voice.toggle() }   // tap the buddy to talk
            if voice.isActive { voiceBadge } else {
                countPill(groups.needsResponse.count, .orange)
                countPill(groups.working.count, .blue)
                countPill(groups.done.count, .green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// When the realtime voice is live, the counts give way to a clear status
    /// badge so it's obvious from the notch that the buddy is listening/talking.
    private var voiceBadge: some View {
        let speaking = voice.isSpeaking
        return HStack(spacing: 8 * s) {
            Image(systemName: speaking ? "waveform" : "mic.fill")
                .font(.system(size: 15 * s, weight: .semibold))
                .foregroundStyle(speaking ? Color.green : Color.red)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: true)
            Text(speaking ? "Speaking" as LocalizedStringKey : "Listening")
                .font(.system(size: 15 * s, weight: .semibold))
                .foregroundStyle(.white)
            if let p = voice.activeProvider {
                Text(p.rawValue)
                    .font(.system(size: 11 * s, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func countPill(_ n: Int, _ c: Color) -> some View {
        HStack(spacing: 7 * s) {
            Circle().fill(c).frame(width: 11 * s, height: 11 * s)
            Text("\(n)").font(.system(size: 17 * s, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        }
    }

    private func color(_ s: SessionStatus) -> Color {
        switch s {
        case .needsResponse: .orange
        case .working: .blue
        case .done: .green
        }
    }

    @ViewBuilder private var background: some View {
        panelShape.fill(.black)
    }

    /// A pill/notch when collapsed (short), but a rounded rectangle when expanded
    /// so the tall content (session list, approval card) isn't clipped by a
    /// capsule's rounded bottom.
    private var panelShape: AnyShape {
        if expanded { return AnyShape(RoundedRectangle(cornerRadius: 22 * s, style: .continuous)) }
        return mode == .notch ? AnyShape(NotchShape()) : AnyShape(Capsule())
    }

    private var clipShape: AnyShape {
        panelShape
    }
}

/// Mac color mapping for the shared `BuddyAccent` (kept identical to iOS).
func macBuddyColor(_ accent: BuddyAccent) -> Color {
    switch accent {
    case .alert:     .orange
    case .curious:   .blue
    case .impatient: .pink
    case .busy:      .blue
    case .worry:     .red
    case .good:      .green
    case .calm:      .gray
    }
}
