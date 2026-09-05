import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// The notch glance, Companion style (docs/design/mac-companion-redesign.md).
/// Collapsed: the cat and the needs-you count. Expanded: the cat says one
/// line, then either the pending approval as two big keys or the sessions in
/// the same three state groups as the dashboard.
struct GlanceView: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var voice: VoiceChat
    let mode: GlanceMode
    @State private var greet = 0

    private var s: CGFloat { model.glanceScale }
    private var expanded: Bool { model.glanceExpanded }
    private var groups: SessionGroups { SessionGroups(model.sessions) }
    private var pending: AgentSession? { model.sessions.first { $0.pendingApproval != nil } }
    private var summary: TaskPresentationSummary { model.presentationSummary }

    /// The collapsed pill lives next to the menu bar, so the cat is drawn at a
    /// menu-bar-ish height (60 * 0.4 = 24pt). Expanded it grows, but stays a
    /// header mark rather than the full 60pt card sprite.
    private var petScale: CGFloat { s * (expanded ? 0.7 : 0.4) }

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
                .padding(.horizontal, 22 * s)
                .padding(.vertical, 18 * s)
                .frame(width: 460 * s, alignment: .leading)
        } else {
            content
                .padding(.horizontal, 14 * s)
                .padding(.vertical, 6 * s)
                .fixedSize()
        }
    }

    @ViewBuilder private var content: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 8 * s) {
                HStack(spacing: 12 * s) {
                    pet
                    if voice.isActive { voiceBadge } else { moodHead }
                    Spacer(minLength: 8 * s)
                    Button {
                        model.setShowGlance(false)   // get out of the way; the shortcut or menu brings it back
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12 * s, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22 * s, height: 22 * s)
                            .background(Color.white.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide glance (\(model.toggleGlanceHotkey.displayString))")
                }
                if let p = pending, let a = p.pendingApproval {
                    approvalCard(p, a)
                } else {
                    groupedRows
                }
            }
            .animation(.smooth(duration: 0.18), value: model.jumpFeedback)
        } else {
            HStack(spacing: 10 * s) {
                pet
                if voice.isActive { voiceBadge } else { needsYouBadge }
            }
            .fixedSize()
        }
    }

    private var pet: some View {
        PetFace(state: BuddyState.from(groups, now: Date()),
                voice: .init(voice.phase), greet: greet, bare: true, scale: petScale)
            .onTapGesture { greet += 1; voice.toggle() }   // tap the buddy to talk
    }

    /// Round 5, collapsed: only the needs-you count, as the menu-bar badge does.
    @ViewBuilder private var needsYouBadge: some View {
        let n = MacSummaryCopy.needsYou(summary)
        if n > 0 {
            Text("\(n)")
                .font(.system(size: 12 * s, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8 * s).padding(.vertical, 2 * s)
                .background(MacTheme.status(summary.error > 0 ? .error : .requiresInput), in: Capsule())
                .accessibilityLabel("\(n) need you")
        } else {
            Text("All quiet")
                .font(.system(size: 12 * s, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    /// Round 5, expanded: the cat says one line, the rest sits under it.
    private var moodHead: some View {
        VStack(alignment: .leading, spacing: 1 * s) {
            Text(MacSummaryCopy.moodLine(summary))
                .font(.system(size: 15 * s, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            let rest = MacSummaryCopy.restLine(summary)
            if !rest.isEmpty {
                Text(rest)
                    .font(.system(size: 11 * s, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
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
                .font(.system(size: 13 * s, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let p = voice.activeProvider {
                Text(p.rawValue)
                    .font(.system(size: 10 * s, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }

    /// Round 4, glance: the request, then two equal keys and a link row.
    private func approvalCard(_ p: AgentSession, _ a: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            Divider().overlay(.white.opacity(0.16))
            Text("\(p.project) wants to \(MacSummaryCopy.requestVerb(a))")
                .font(.system(size: 10 * s, weight: .heavy, design: .rounded))
                .textCase(.uppercase).kerning(0.6)
                .foregroundStyle(.white.opacity(0.55))
            ApprovalBody(approval: a, onDark: true)
            HStack(spacing: 10 * s) {
                Button("Approve") { model.decide(a.id, .allow) }
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.status(.completeUnread)), size: .large))
                    .keyboardShortcut("a", modifiers: [])
                Button("Deny") { model.decide(a.id, .deny) }
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.status(.error)), size: .large))
                    .keyboardShortcut("d", modifiers: [])
            }
            HStack(spacing: 6 * s) {
                linkButton("Always") { model.decide(a.id, .alwaysAllow) }
                    .help("Always allow this exact command in future")
                Text("·").foregroundStyle(.white.opacity(0.4))
                linkButton("This session") { model.decide(a.id, .allowSession) }
                    .help("Stop asking for the rest of this run")
                Text("·").foregroundStyle(.white.opacity(0.4))
                linkButton(p.jumpsToDesktopThread ? "Open thread" : "Jump ⏎") { model.jump(p) }
                    .help(p.jumpsToDesktopThread ? "Open this thread in ChatGPT" : "Jump to terminal")
            }
            .font(.system(size: 11 * s, weight: .heavy, design: .rounded))
            if let outcome = model.jumpFeedback[p.id] {
                Text(outcome.macMessage(for: p))
                    .font(.system(size: 10 * s, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
    }

    private func linkButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).underline().foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    /// The three state groups, up to three rows each.
    private var groupedRows: some View {
        let groups = StateGroups(model.sessions)
        return VStack(alignment: .leading, spacing: 6 * s) {
            Divider().overlay(.white.opacity(0.16))
            ForEach(groups.buckets) { group in
                Text("\(group.title) · \(group.sessions.count)")
                    .font(.system(size: 10 * s, weight: .heavy, design: .rounded))
                    .textCase(.uppercase).kerning(0.6)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 2 * s)
                ForEach(group.sessions.prefix(3)) { sess in
                    GlanceSessionRow(session: sess,
                                     feedback: model.jumpFeedback[sess.id],
                                     scale: s) { model.jump(sess) }
                }
            }
        }
    }

    @ViewBuilder private var background: some View {
        // The collapsed pill in notch mode merges with the hardware notch, so it
        // stays pure black; everything else wears the Companion glance ground.
        panelShape.fill(mode == .notch && !expanded ? Color.black : MacTheme.glance)
    }

    /// A pill/notch when collapsed (short), but a rounded rectangle when expanded
    /// so the tall content (session list, approval card) isn't clipped by a
    /// capsule's rounded bottom.
    private var panelShape: AnyShape {
        if expanded { return AnyShape(RoundedRectangle(cornerRadius: 26 * s, style: .continuous)) }
        return mode == .notch ? AnyShape(NotchShape()) : AnyShape(Capsule())
    }
    private var clipShape: AnyShape {
        panelShape
    }
}

/// One session in the expanded glance, summary-first like the dashboard row.
/// Always clickable: the row *is* the jump control, and every session has an
/// honest answer to a click — the ones with no recorded terminal say so
/// instead of ignoring the press.
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
    /// recorded. Quiet on purpose — the glyph owns the row's colour.
    private var targetSymbol: String? {
        guard let ref = session.terminalRef else {
            return session.desktopThreadID != nil ? "bubble.left" : nil
        }
        if ref.hasExactTarget { return "terminal" }
        return (ref.hostBundleId ?? ref.termProgram) != nil ? "macwindow" : nil
    }
    private var subtitle: String {
        feedback?.macMessage(for: session) ?? "\(session.project) · \(ToolActivity.label(for: session))"
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
                StateGlyph(state: session.presentationState, size: 24 * s, onDark: true)
                VStack(alignment: .leading, spacing: 1 * s) {
                    Text(session.summary ?? ToolActivity.label(for: session))
                        .font(.system(size: 13 * s, weight: .heavy, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 10 * s, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(feedback == nil ? 0.55 : 0.85))
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
                RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.18 : (hovering ? 0.09 : 0)))
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
            .padding(.horizontal, -7 * scale)
            .padding(.vertical, -2 * scale)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
            .animation(.smooth(duration: 0.12), value: hovering)
    }
}
