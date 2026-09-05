import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// The glance, drawn with the Dynamic Island's grammar. On a notch Mac the
/// housing itself is never drawn into: idle shows nothing, `compact` grows a
/// small wing either side (the cat on the left, the one state that matters on
/// the right), and `card` / `expanded` drop below it. Without a notch the same
/// content hangs under the menu bar as a capsule.
struct GlanceView: View {
    @ObservedObject var model: MenuBarModel
    @State private var greet = 0
    @ObservedObject var voice: VoiceChat
    let layout: GlanceLayout

    @State private var hovering = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    private enum Mode: Equatable { case idle, compact, card, expanded }

    private static let motion = Animation.spring(response: 0.36, dampingFraction: 0.8)
    /// User size preset; scales the card and the expanded content only — the
    /// wings are sized by the notch, not by preference.
    private var s: CGFloat { model.glanceScale }
    private var summary: TaskPresentationSummary { model.presentationSummary }
    private var pending: AgentSession? { model.sessions.first { $0.pendingApproval != nil } }

    private var mode: Mode {
        if model.glanceExpanded { return .expanded }
        if model.glanceCard != nil { return .card }
        if voice.isActive { return .compact }
        switch summary.primaryState {
        case .idle, .unassigned: return layout.notch == nil ? .compact : .idle
        default: return .compact
        }
    }

    var body: some View {
        Group {
            if let notch = layout.notch {
                island(notch: notch)
            } else if case .pill(let menuBarHeight) = layout {
                capsule.padding(.top, menuBarHeight + 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The panel overlaps the menu bar on purpose; SwiftUI must not inset for it.
        .ignoresSafeArea()
        .animation(Self.motion, value: mode)
        .animation(Self.motion, value: model.glanceCard?.id)
    }

    // MARK: notch layout

    private var topRadius: CGFloat { mode == .compact || mode == .idle ? 6 : 15 }
    private var bottomRadius: CGFloat { mode == .compact || mode == .idle ? 14 : 20 }
    private var cardWidth: CGFloat { 400 * s }

    /// Wings beside the housing plus, in the two tall modes, a body below it. The
    /// black `NotchShape` is the content's own background, so it always spans
    /// exactly what is drawn and its flared top corners meet the menu bar where
    /// the housing does. Uneven wings shift the whole island so the gap between
    /// them stays over the real notch (the offset is zero in the tall modes).
    private func island(notch: NotchGeometry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                wing(leading: true, height: notch.height)
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { leadingWidth = $0 }
                Color.clear.frame(width: notch.width, height: notch.height)
                wing(leading: false, height: notch.height)
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { trailingWidth = $0 }
            }
            if mode == .card, let card = model.glanceCard {
                GlanceEventCard(card: card, model: model, scale: s)
                    .frame(width: max(cardWidth * 0.9, notch.width))
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if mode == .expanded {
                expanded
                    .frame(width: max(cardWidth, notch.width))
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(.horizontal, topRadius)
        .background(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).fill(.black))
        .overlay(voiceRing(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)))
        .contentShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        .offset(x: mode == .compact ? (trailingWidth - leadingWidth) / 2 : 0)
        .onHover(perform: hoverChanged)
        .onTapGesture { if mode == .compact || mode == .idle { model.setGlanceExpanded(true) } }
    }

    @ViewBuilder private func wing(leading: Bool, height: CGFloat) -> some View {
        if mode == .compact {
            Group {
                if leading {
                    PetFace(state: model.buddyState, voice: .init(voice.phase), greet: greet,
                            bare: true, scale: (height - 10) / 60)
                        .onTapGesture { greet += 1; voice.toggle() }   // tap the buddy to talk
                        .padding(.leading, 8).padding(.trailing, 4)
                } else if voice.isActive {
                    voiceBadge.padding(.leading, 6).padding(.trailing, 12)
                } else {
                    countPill(summary.count(for: summary.primaryState), summary.primaryState)
                        .padding(.leading, 8).padding(.trailing, 12)
                }
            }
            .frame(height: height)
            .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: leading ? .trailing : .leading)))
        }
    }

    // MARK: notchless layout

    /// No housing to hide in, so the pill is always there: the cat, every
    /// non-zero count, and the same card / expanded content below.
    private var capsule: some View {
        VStack(spacing: 0) {
            if mode == .card, let card = model.glanceCard {
                GlanceEventCard(card: card, model: model, scale: s)
                    .frame(width: cardWidth * 0.9)
                    .padding(.top, 8 * s)
            } else if mode == .expanded {
                expanded.frame(width: cardWidth).padding(.top, 8 * s)
            } else {
                HStack(spacing: 10) {
                    PetFace(state: model.buddyState, voice: .init(voice.phase), greet: greet,
                            bare: true, scale: 0.36)
                        .onTapGesture { greet += 1; voice.toggle() }
                    if voice.isActive { voiceBadge } else {
                        ForEach([TaskPresentationState.error, .requiresInput, .thinking, .completeUnread], id: \.self) { state in
                            if summary.count(for: state) > 0 { countPill(summary.count(for: state), state) }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .frame(height: 30)
            }
        }
        .background(RoundedRectangle(cornerRadius: mode == .compact ? 15 : 20, style: .continuous)
            .fill(.black.opacity(0.92)))
        .overlay(voiceRing(RoundedRectangle(cornerRadius: mode == .compact ? 15 : 20, style: .continuous)))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onHover(perform: hoverChanged)
        .onTapGesture { if mode == .compact { model.setGlanceExpanded(true) } }
    }

    // MARK: shared pieces

    /// Hover opens after a short dwell (so a pointer crossing the notch to reach
    /// the menu bar doesn't open it) and closes with a little grace once it
    /// leaves. A card holds while hovered instead of opening.
    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        model.setGlanceHeld(inside)
        hoverTask?.cancel()
        if inside {
            if mode == .card { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, hovering else { return }
                model.setGlanceExpanded(true)
            }
        } else {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, !hovering else { return }
                model.setGlanceExpanded(false)
            }
        }
    }

    /// Designed, not neon: a thin tinted border while the voice companion is
    /// live. The voiceBadge spells out Listening/Speaking, the ring only hints.
    @ViewBuilder private func voiceRing<S: Shape>(_ shape: S) -> some View {
        if voice.isActive {
            let tint = voice.isSpeaking ? Color.green : Color.red
            shape.stroke(tint.opacity(0.8), lineWidth: 1.5)
                .shadow(color: tint.opacity(0.28), radius: 3)
        }
    }

    private var voiceBadge: some View {
        let speaking = voice.isSpeaking
        return HStack(spacing: 6) {
            Image(systemName: speaking ? "waveform" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(speaking ? Color.green : Color.red)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: true)
            Text(speaking ? "Speaking" as LocalizedStringKey : "Listening")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .fixedSize()
    }

    /// One glyph + one number. The tinted SF Symbol *is* the non-color
    /// differentiator, so no separate dot.
    private func countPill(_ n: Int, _ state: TaskPresentationState, scale: CGFloat = 1) -> some View {
        HStack(spacing: 3 * scale) {
            Image(systemName: state.symbolName)
                .font(.system(size: 9 * scale, weight: .bold))
                .foregroundStyle(Color(taskStatus: state.colorToken))
            Text("\(n)")
                .font(.system(size: 13 * scale, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(n) \(state.label)")
    }

    /// The tall content: header (cat, every count, close), then the pending
    /// approval if there is one, else the session list — rows are the jump
    /// controls.
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            HStack(spacing: 12 * s) {
                PetFace(state: model.buddyState, voice: .init(voice.phase), greet: greet,
                        bare: true, scale: 0.55 * s)
                    .onTapGesture { greet += 1; voice.toggle() }
                if voice.isActive { voiceBadge } else {
                    ForEach([TaskPresentationState.error, .requiresInput, .thinking, .completeUnread, .idle], id: \.self) { state in
                        if summary.count(for: state) > 0 { countPill(summary.count(for: state), state, scale: s) }
                    }
                }
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
                    Button("Approve") { model.decide(a.id, .allow) }
                        .buttonStyle(GlanceButtonStyle(tint: .green, scale: s))
                    Button("Deny") { model.decide(a.id, .deny) }
                        .buttonStyle(GlanceButtonStyle(tint: .red, scale: s))
                    Button("Always") { model.decide(a.id, .alwaysAllow) }
                        .buttonStyle(GlanceButtonStyle(scale: s))
                        .help("Always allow this exact command in future")
                    Button { model.jump(p) } label: {
                        Label("Jump", systemImage: p.jumpsToDesktopThread ? "bubble.left" : "terminal")
                    }
                    .buttonStyle(GlanceButtonStyle(scale: s))
                    .help(p.jumpsToDesktopThread ? "Open this thread in ChatGPT" : "Jump to terminal")
                }
                if let outcome = model.jumpFeedback[p.id] {
                    Text(outcome.macMessage(for: p))
                        .font(.system(size: 10 * s, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                }
            } else if model.sessions.isEmpty {
                Text("No agent sessions yet")
                    .font(.system(size: 12 * s, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            } else {
                ForEach(model.sessions.prefix(6)) { sess in
                    GlanceSessionRow(session: sess, feedback: model.jumpFeedback[sess.id], scale: s) {
                        model.jump(sess)
                    }
                }
            }
        }
        .padding(.horizontal, 20 * s)
        .padding(.top, 10 * s)
        .padding(.bottom, 16 * s)
        .animation(.smooth(duration: 0.18), value: model.jumpFeedback)
    }
}

/// The event layer: one cue as a card that unfolds from the housing. Actionable
/// cues carry their actions; a hairline along the bottom shows how long the card
/// has left, and stops while the pointer is on it.
private struct GlanceEventCard: View {
    let card: GlanceCard
    @ObservedObject var model: MenuBarModel
    let scale: CGFloat

    private var s: CGFloat { scale }
    private var session: AgentSession { card.session }
    private var live: AgentSession { model.sessions.first { $0.id == session.id } ?? session }

    private var title: LocalizedStringKey {
        switch card.alert.sound {
        case .needsApproval: return "\(session.project) needs approval"
        case .needsAnswer:   return "\(session.project) needs you"
        case .longWaitNudge: return "\(session.project) is still waiting"
        case .agentDone:     return "\(session.project) finished"
        case .agentStuck:    return "\(session.project) stopped"
        case .pairSuccess:   return "Paired"
        }
    }

    private var detail: String {
        switch card.alert.sound {
        case .needsApproval: return session.pendingApproval?.commandPreview ?? session.summary ?? ""
        case .needsAnswer, .longWaitNudge: return session.pendingQuestion?.prompt ?? session.summary ?? ""
        case .agentDone, .agentStuck, .pairSuccess: return session.summary ?? ""
        }
    }

    private var mood: BuddyState {
        switch card.alert.sound {
        case .needsApproval: return .approval
        case .needsAnswer: return .question
        case .longWaitNudge: return .longWait
        case .agentDone, .pairSuccess: return .done
        case .agentStuck: return .stuck
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            HStack(alignment: .top, spacing: 10 * s) {
                PetFace(state: mood, bare: true, scale: 0.5 * s)
                VStack(alignment: .leading, spacing: 3 * s) {
                    HStack(spacing: 6 * s) {
                        Text(title).font(.system(size: 13 * s, weight: .bold)).foregroundStyle(.white)
                        Text(session.agent.displayName)
                            .font(.system(size: 9 * s, weight: .semibold))
                            .padding(.horizontal, 5 * s).padding(.vertical, 1 * s)
                            .background(.white.opacity(0.14), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11 * s, design: card.alert.sound == .needsApproval ? .monospaced : .default))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            if card.isActionable || card.alert.sound == .agentStuck {
                HStack(spacing: 8 * s) {
                    if let a = live.pendingApproval, card.alert.sound == .needsApproval {
                        Button("Approve") { model.decide(a.id, .allow); model.dismissGlanceCard() }
                            .buttonStyle(GlanceButtonStyle(tint: .green, scale: s))
                        Button("Deny") { model.decide(a.id, .deny); model.dismissGlanceCard() }
                            .buttonStyle(GlanceButtonStyle(tint: .red, scale: s))
                    }
                    Button { model.jump(live); model.dismissGlanceCard() } label: {
                        Label("Jump", systemImage: live.jumpsToDesktopThread ? "bubble.left" : "terminal")
                    }
                    .buttonStyle(GlanceButtonStyle(scale: s))
                    .help(live.jumpsToDesktopThread ? "Open this thread in ChatGPT" : "Jump to terminal")
                }
            }
        }
        .padding(.horizontal, 16 * s)
        .padding(.top, 8 * s)
        .padding(.bottom, 12 * s)
        .overlay(alignment: .bottom) { timeline }
    }

    /// The remaining time as a hairline that drains left to right. Reads the
    /// card's deadline, so a hold that pushes the deadline visibly refills it.
    private var timeline: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let remaining = max(0, card.deadline.timeIntervalSince(context.date))
            let fraction = min(1, remaining / card.duration)
            GeometryReader { geo in
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: max(0, (geo.size.width - 32 * s) * fraction), height: 1.5)
                    .padding(.leading, 16 * s)
            }
            .frame(height: 1.5)
        }
        .padding(.bottom, 4 * s)
        .allowsHitTesting(false)
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

/// The glance draws its own buttons. The system `bordered` styles render their
/// chrome through AppKit cells, which in this always-on, never-key panel comes
/// up blank often enough to be unusable; shapes and text always draw. A tinted
/// pill for the primary actions, a translucent one for the rest.
struct GlanceButtonStyle: ButtonStyle {
    var tint: Color? = nil
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 12 * scale)
            .frame(height: 24 * scale)
            .background(
                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                    .fill(tint.map { $0.opacity(configuration.isPressed ? 0.7 : 0.9) } ?? .white.opacity(configuration.isPressed ? 0.26 : 0.14))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous))
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}
