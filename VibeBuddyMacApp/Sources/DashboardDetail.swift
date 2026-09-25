import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// Shows the pending tool call and its available approval actions.
struct RequestCard: View {
    let session: AgentSession
    let approval: PendingApproval
    @ObservedObject var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentAvatar(agent: session.agent)
                VStack(alignment: .leading, spacing: 1) {
                    (Text(session.project).fontWeight(.bold) + Text(" wants to \(MacSummaryCopy.requestVerb(approval))"))
                        .font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
                    Text([approval.tool, session.summary].compactMap { $0 }.joined(separator: " · "))
                        .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3).lineLimit(1)
                }
            }
            ApprovalBody(approval: approval)
            if ApprovalEligibility.approval(for: session) == nil {
                // Capability does not establish whether the person is present.
                Label(WaitHandling.resolve(for: session).message, systemImage: "keyboard")
                    .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                if session.canJump {
                    Button(session.jumpsToDesktopThread ? "Open thread" : "Jump ⏎") { model.jump(session) }
                        .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent)))
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { ApprovalActionRow(approval: approval, model: model) }
                    VStack(alignment: .leading, spacing: 8) { ApprovalActionRow(approval: approval, model: model) }
                }
                if let rule = approval.suggestedRule {
                    Text("Always allow adds \(rule) to Claude's own permission rules — the same rule the terminal dialog offers.")
                        .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if session.agent == .grok, let mode = approval.permissionMode, mode != "bypassPermissions" {
                Label {
                    Text("Grok will still ask in the terminal after Allow (permission mode: \(mode)). Set permission_mode = \"always-approve\" to approve from here.")
                } icon: {
                    Image(systemName: "terminal")
                }
                .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
            }
        }
    }
}

/// `Approve ▾` and `Deny`, with their single-key shortcuts, at the small pill
/// size every other key on the dashboard uses. Jump is in the title bar, not
/// repeated here.
private struct ApprovalActionRow: View {
    let approval: PendingApproval
    @ObservedObject var model: MenuBarModel

    var body: some View {
        SplitApproveButton(
            approve: { model.decide(approval.id, .allow) },
            always: { model.decide(approval.id, .alwaysAllow) },
            session: { model.decide(approval.id, .allowSession) },
            allowsPersistentDecision: approval.canPersistDecision, size: .small)
            // The `a` shortcut's carrier is invisible, so it is hidden from
            // VoiceOver too: an unnamed button that approves is a trap.
            .background { Button("") { model.decide(approval.id, .allow) }.keyboardShortcut("a", modifiers: []).opacity(0).accessibilityHidden(true) }
        Button("Deny") { model.decide(approval.id, .deny) }
            .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
            .keyboardShortcut("d", modifiers: [])
    }
}
