#if os(iOS) || os(macOS)
import SwiftUI

/// Read-only workspace diff for one session, in Cursor's Changes grammar: a
/// header row of quiet dropdowns (comparison, and a baseline for a branch),
/// the added / deleted counts as coloured words, a `Refresh` pill; then the
/// file list and the selected file's diff. `embedded` drops the sheet's
/// title and `Done` so the same view can sit in the dashboard's tool pane.
public struct WorkspaceChangesView: View {
    public let load: @MainActor (ChangesScope, String?, String?) async -> WorkspaceChanges?
    public let embedded: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var scope: ChangesScope = .uncommitted
    @State private var baseline = ""
    @State private var appliedBaseline = ""
    @State private var selectedFile: String?
    @State private var result: WorkspaceChanges?
    @State private var loading = false
    @State private var refresh = 0
    private var requestKey: String { scope.rawValue + "/" + appliedBaseline + "/" + (selectedFile ?? "") + "/\(refresh)" }

    public init(embedded: Bool = false, load: @escaping @MainActor (ChangesScope, String?, String?) async -> WorkspaceChanges?) {
        self.embedded = embedded
        self.load = load
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !embedded {
                HStack {
                    Text("Workspace changes", bundle: .module).font(CompanionType.font(18, .semibold))
                    Spacer()
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                        .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
                }
            }
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let result {
                        Text("\(result.scope.title) · baseline: \(result.baseline)", bundle: .module)
                            .font(CompanionType.font(11, .medium)).foregroundStyle(CompanionPalette.ink2)
                        Text(LocalizedStringKey(result.attribution), bundle: .module).font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3)
                        Text("Diffs cover tracked files. Untracked files are listed separately without reading their contents. Read only; no comments or changes are sent to the agent.", bundle: .module)
                            .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3)
                        if let reason = result.unavailableReason {
                            Text(LocalizedStringKey(reason), bundle: .module).font(CompanionType.font(13))
                        } else if result.files.isEmpty && result.untrackedFiles.isEmpty {
                            Text(scope == .uncommitted ? "No uncommitted changes" : "No changes in this comparison", bundle: .module)
                                .font(CompanionType.font(13))
                        }
                        ForEach(result.files, id: \.self) { file in
                            Button { selectedFile = file } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text").font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(CompanionPalette.ink2)
                                    Text(file).font(CompanionType.mono(11)).lineLimit(1).truncationMode(.middle)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedFile == file ? CompanionPalette.ink.opacity(0.07) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selectedFile == file ? .isSelected : [])
                        }
                        if !result.untrackedFiles.isEmpty {
                            Text("Untracked · \(result.untrackedFiles.count)", bundle: .module)
                                .font(CompanionType.font(11, .medium)).foregroundStyle(CompanionPalette.ink3)
                                .padding(.top, 4)
                            ForEach(result.untrackedFiles, id: \.self) { file in
                                Text(file).font(CompanionType.mono(11)).foregroundStyle(CompanionPalette.ink2)
                                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    .padding(.horizontal, 8)
                            }
                        }
                        if let diff = result.diff {
                            Divider().padding(.vertical, 4)
                            Text(diff).font(CompanionType.mono(11)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if result.truncated {
                            Text("Display limit reached. This is a bounded excerpt.", bundle: .module)
                                .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
                        }
                    } else if !loading { Text("Could not reach the workspace. Refresh to try again.", bundle: .module) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(embedded ? 16 : 20).background(CompanionPalette.bg).foregroundStyle(CompanionPalette.ink)
        .tint(CompanionPalette.accent)
        .onChange(of: scope) { _ in selectedFile = nil }
        .task(id: requestKey) {
            loading = true; result = nil
            let response = await load(scope, scope == .branch ? appliedBaseline : nil, selectedFile)
            guard !Task.isCancelled else { return }
            result = response; loading = false
        }
    }

    /// `Uncommitted ⌄ · <baseline> Compare · +187 −4 · Refresh`.
    private var header: some View {
        HStack(spacing: 8) {
            CompanionMenuPill(title: scope.title) {
                ForEach(ChangesScope.allCases, id: \.self) { candidate in
                    Button {
                        scope = candidate
                    } label: {
                        if candidate == scope { Label(candidate.title, systemImage: "checkmark") } else { Text(candidate.title) }
                    }
                }
            }
            .accessibilityLabel(String(localized: "Comparison", bundle: .module))
            if scope == .branch {
                TextField(String(localized: "Baseline branch or commit", bundle: .module), text: $baseline)
                    .textFieldStyle(.plain)
                    .font(CompanionType.mono(11))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: 200)
                    .onSubmit(compare)
                Button(String(localized: "Compare", bundle: .module), action: compare)
                    .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
            }
            Spacer(minLength: 4)
            if loading {
                ProgressView().controlSize(.small)
            } else if let result, let added = result.addedLineCount, let deleted = result.deletedLineCount {
                HStack(spacing: 6) {
                    if added > 0 { Text("+\(added)").foregroundStyle(CompanionPalette.accent) }
                    if deleted > 0 { Text("−\(deleted)").foregroundStyle(CompanionPalette.status(.error)) }
                }
                .font(CompanionType.mono(10.5, .medium))
                .accessibilityLabel(String(localized: "\(added) added, \(deleted) deleted", bundle: .module))
            }
            Button(String(localized: "Refresh", bundle: .module)) { selectedFile = nil; refresh += 1 }
                .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
        }
    }

    private func compare() { appliedBaseline = baseline; selectedFile = nil; refresh += 1 }
}

#endif
