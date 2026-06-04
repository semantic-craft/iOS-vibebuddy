import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct GlanceView: View {
    @ObservedObject var model: MenuBarModel
    let mode: GlanceMode
    @State private var expanded = false

    private var groups: SessionGroups { SessionGroups(model.sessions) }
    private var pending: AgentSession? { model.sessions.first { $0.pendingApproval != nil } }

    var body: some View {
        content
            .padding(.horizontal, 14).padding(.vertical, expanded ? 12 : 5)
            .frame(maxWidth: expanded ? 360 : 200)
            .background(background)
            .clipShape(clipShape)
            .onHover { hovering in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { expanded = hovering }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 8) {
                counts
                if let p = pending, let a = p.pendingApproval {
                    Divider().overlay(.white.opacity(0.2))
                    Text(p.project).font(.caption.bold()).foregroundStyle(.white)
                    Text(a.commandPreview).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                    HStack {
                        Button("Approve") { model.decide(a.id, approve: true) }.tint(.green)
                        Button("Deny") { model.decide(a.id, approve: false) }.tint(.red)
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    ForEach(model.sessions.prefix(6)) { s in
                        HStack(spacing: 6) {
                            Circle().fill(color(s.status)).frame(width: 6, height: 6)
                            Text(s.project).font(.caption).foregroundStyle(.white).lineLimit(1)
                        }
                    }
                }
            }
        } else {
            counts
        }
    }

    private var counts: some View {
        HStack(spacing: 12) {
            countPill(groups.needsResponse.count, .orange)
            countPill(groups.working.count, .blue)
            countPill(groups.done.count, .green)
        }
    }
    private func countPill(_ n: Int, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(n)").font(.callout.monospacedDigit()).foregroundStyle(.white)
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
        if mode == .notch {
            NotchShape().fill(.black)
        } else {
            Capsule().fill(.black.opacity(0.92))
        }
    }
    private var clipShape: AnyShape {
        mode == .notch ? AnyShape(NotchShape()) : AnyShape(Capsule())
    }
}
