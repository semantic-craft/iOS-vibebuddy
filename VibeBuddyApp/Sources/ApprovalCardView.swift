import SwiftUI
import VibeBuddyKit

/// Rich approval detail for the phone: shows the pending tool call by type —
/// the full Bash command, an Edit diff (old→new), a Write preview, or a Read
/// path. Falls back to `commandPreview` when no rich fields are present.
/// Avoids nested vertical scrolling so it sits cleanly inside the List row.
struct ApprovalCardView: View {
    let approval: PendingApproval
    private static let maxDiffLines = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = approval.filePath { pathLabel(path) }
            if let cmd = approval.command {
                codeBlock(cmd)
            } else if let old = approval.oldText {
                diff(old: old, new: approval.newText ?? "")
            } else if let new = approval.newText {
                codeBlock(new)
            } else if approval.filePath == nil {
                codeBlock(approval.commandPreview)
            }
        }
    }

    private func pathLabel(_ path: String) -> some View {
        Label(path, systemImage: "doc.text")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.caption.monospaced())
                .lineLimit(14)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private func diff(old: String, new: String) -> some View {
        let oldLines = capped(old)
        let newLines = capped(new)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(oldLines.lines.enumerated()), id: \.offset) { _, l in
                diffLine("-", l, .red)
            }
            ForEach(Array(newLines.lines.enumerated()), id: \.offset) { _, l in
                diffLine("+", l, .green)
            }
            if oldLines.truncated || newLines.truncated {
                Text("… (truncated)").font(.caption2).foregroundStyle(.secondary).padding(.leading, 6)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
    }

    private func diffLine(_ sign: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sign).foregroundStyle(color)
            Text(text.isEmpty ? " " : text).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .font(.caption2.monospaced())
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(color.opacity(0.12))
    }

    private func capped(_ s: String) -> (lines: [String], truncated: Bool) {
        let all = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if all.count <= Self.maxDiffLines { return (all, false) }
        return (Array(all.prefix(Self.maxDiffLines)), true)
    }
}
