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

    /// The collapsed pill lives next to the menu bar, so the cat is drawn at a
    /// menu-bar-ish height (60 * 0.4 = 24pt). Expanded it grows, but stays a
    /// header mark rather than the full 60pt card sprite.
    private var petScale: CGFloat { s * (expanded ? 0.65 : 0.4) }

    var body: some View {
        shell
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

    /// Expanded is a fixed-width card (the session rows need a stable column);
    /// collapsed **hugs its content** — a hard-coded width is what used to
    /// squeeze a two-digit count into a two-line "1 / 0".
    @ViewBuilder private var shell: some View {
        if expanded {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20 * s)
                .padding(.vertical, 16 * s)
                .frame(width: 440 * s, alignment: .leading)
        } else {
            content
                .padding(.horizontal, 13 * s)
                .padding(.vertical, 5 * s)
                .fixedSize()
        }
    }

    @ViewBuilder private var content: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 8 * s) {
                HStack(spacing: 8 * s) {
                    counts
                    Spacer(minLength: 8 * s)
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
                        if a.isAnswerable {
                        Button("Approve") { model.decide(a.id, .allow) }
                            .tint(.green).buttonStyle(.borderedProminent).controlSize(.regular)
                        Button("Deny") { model.decide(a.id, .deny) }
                            .tint(.red).buttonStyle(.borderedProminent).controlSize(.regular)
                        Button("Always") { model.decide(a.id, .alwaysAllow) }
                            .tint(.white).buttonStyle(.bordered).controlSize(.regular)
                            .help("Always allow this exact command in future")
                        } else {
                            Label("Answer in the prompt", systemImage: "keyboard")
                                .font(.system(size: 11 * s)).foregroundStyle(.white.opacity(0.8))
                        }
                        Button { model.jump(p) } label: {
                            Label("Jump", systemImage: p.jumpsToDesktopThread ? "bubble.left" : "terminal")
                        }
                        .tint(.white).buttonStyle(.bordered).controlSize(.regular)
                        .help(p.jumpsToDesktopThread ? "Open this thread in ChatGPT" : "Jump to terminal")
                    }
                    if let outcome = model.jumpFeedback[p.id] {
                        Text(outcome.macMessage(for: p))
                            .font(.system(size: 10 * s, weight: .medium))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                } else {
                    ForEach(model.sessions.prefix(6)) { sess in
                        GlanceSessionRow(session: sess,
                                         feedback: model.jumpFeedback[sess.id],
                                         scale: s) { model.jump(sess) }
                    }
                }
            }
            .animation(.smooth(duration: 0.18), value: model.jumpFeedback)
        } else {
            counts
        }
    }

    private var counts: some View {
        HStack(spacing: (expanded ? 14 : 10) * s) {
            PetFace(state: BuddyState.from(groups, now: Date()),
                    speaking: voice.isSpeaking, listening: voice.isListening, bare: true, scale: petScale)
                .onTapGesture { voice.toggle() }   // tap the buddy to talk
            if voice.isActive { voiceBadge } else {
                ForEach([TaskPresentationState.error, .requiresInput, .thinking, .completeUnread, .idle], id: \.self) { state in
                    if model.presentationSummary.count(for: state) > 0 {
                        countPill(model.presentationSummary.count(for: state), state)
                    }
                }
            }
        }
        .fixedSize()
    }

    /// When the realtime voice is live, the counts give way to a clear status
    /// badge so it's obvious from the notch that the buddy is listening/talking.
    private var voiceBadge: some View {
        let speaking = voice.isSpeaking
        return HStack(spacing: 6 * s) {
            Image(systemName: speaking ? "waveform" : "mic.fill")
                .font(.system(size: 13 * s, weight: .semibold))
                .foregroundStyle(speaking ? Color.green : Color.red)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: true)
            Text(speaking ? "Speaking" as LocalizedStringKey : "Listening")
                .font(.system(size: 13 * s, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let p = voice.activeProvider {
                Text(p.rawValue)
                    .font(.system(size: 10 * s, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }

    /// One glyph + one number per status. The tinted SF Symbol *is* the
    /// non-color differentiator (what `TaskStatusIndicator` only showed under
    /// Differentiate Without Color), so the separate dot was pure width.
    private func countPill(_ n: Int, _ state: TaskPresentationState) -> some View {
        HStack(spacing: 3 * s) {
            Image(systemName: state.symbolName)
                .font(.system(size: 9 * s, weight: .bold))
                .foregroundStyle(Color(taskStatus: state.colorToken))
            Text("\(n)")
                .font(.system(size: 13 * s, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)   // never wrap "10" into "1"/"0"
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(n) \(state.label)")
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

/// One session in the expanded glance. Always clickable: the row *is* the jump
/// control, and every session has an honest answer to a click — the ones with no
/// recorded terminal say so instead of ignoring the press.
private struct GlanceSessionRow: View {
    let session: AgentSession
    let feedback: JumpOutcome?
    let scale: CGFloat
    let jump: () -> Void

    @State private var hovering = false

    private var s: CGFloat { scale }

    /// How precisely this row's click can land, told at a glance:
    /// `terminal` = its own pane/tab, `bubble.left` = its Codex Desktop thread,
    /// `macwindow` = only the app around it, nothing = no target was ever
    /// recorded. Quiet on purpose — the status dot owns the row's colour.
    private var targetSymbol: String? {
        guard let ref = session.terminalRef else {
            return session.desktopThreadID != nil ? "bubble.left" : nil
        }
        if ref.hasExactTarget { return "terminal" }
        return (ref.hostBundleId ?? ref.termProgram) != nil ? "macwindow" : nil
    }

    private var subtitle: String {
        feedback?.macMessage(for: session) ?? ToolActivity.label(for: session)
    }

    private var helpText: String {
        switch targetSymbol {
        case "terminal": return "Jump to this session's terminal"
        case "bubble.left": return "Open this thread in ChatGPT"
        case "macwindow": return "Bring this session's app to the front"
        default: return "No terminal recorded for this session"
        }
    }

    var body: some View {
        Button(action: jump) {
            HStack(spacing: 8 * s) {
                TaskStatusIndicator(session.presentationState, size: 8 * s)
                VStack(alignment: .leading, spacing: 1 * s) {
                    HStack(spacing: 5 * s) {
                        Text(session.project).font(.system(size: 13 * s, weight: .semibold))
                        Text(session.agent.displayName)
                            .font(.system(size: 9 * s, weight: .semibold))
                            .padding(.horizontal, 5 * s).padding(.vertical, 1 * s)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    Text(subtitle)
                        .font(.system(size: 10 * s, weight: .medium))
                        .foregroundStyle(.white.opacity(feedback == nil ? 0.62 : 0.85))
                        .contentTransition(.opacity)
                }
                .foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 4 * s)
                if let symbol = targetSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11 * s))
                        .foregroundStyle(.white.opacity(hovering ? 0.75 : 0.45))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GlanceRowButtonStyle(scale: s, hovering: hovering))
        .onHover { hovering = $0 }
        .help(helpText)
    }
}

/// Tactile, not decorative: the row lifts slightly under the pointer and dips
/// under the press, so it reads as a control while adding no colour of its own.
/// Negative outer padding keeps the text aligned with the card's other rows
/// while the highlight bleeds past them.
private struct GlanceRowButtonStyle: ButtonStyle {
    let scale: CGFloat
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7 * scale)
            .padding(.vertical, 4 * scale)
            .background(
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.18 : (hovering ? 0.09 : 0)))
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            .padding(.horizontal, -7 * scale)
            .padding(.vertical, -2 * scale)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
            .animation(.smooth(duration: 0.12), value: hovering)
    }
}
