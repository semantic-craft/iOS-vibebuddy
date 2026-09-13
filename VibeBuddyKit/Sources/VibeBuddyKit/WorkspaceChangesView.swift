#if os(iOS) || os(macOS)
import SwiftUI

public struct WorkspaceChangesView: View {
    public let load: @MainActor (ChangesScope, String?, String?) async -> WorkspaceChanges?
    @Environment(\.dismiss) private var dismiss
    @State private var scope: ChangesScope = .uncommitted
    @State private var baseline = ""
    @State private var appliedBaseline = ""
    @State private var selectedFile: String?
    @State private var result: WorkspaceChanges?
    @State private var loading = false
    @State private var refresh = 0
    private var requestKey: String { scope.rawValue + "/" + appliedBaseline + "/" + (selectedFile ?? "") + "/\(refresh)" }
    public init(load: @escaping @MainActor (ChangesScope, String?, String?) async -> WorkspaceChanges?) { self.load = load }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Workspace changes", bundle: .module).font(CompanionType.font(18, .semibold))
                Spacer()
                Button(String(localized: "Done", bundle: .module)) { dismiss() }
            }
            Picker(String(localized: "Comparison", bundle: .module), selection: $scope) {
                ForEach(ChangesScope.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if scope == .branch {
                HStack {
                    TextField(String(localized: "Baseline branch or commit", bundle: .module), text: $baseline)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { appliedBaseline = baseline; selectedFile = nil; refresh += 1 }
                    Button(String(localized: "Compare", bundle: .module)) { appliedBaseline = baseline; selectedFile = nil; refresh += 1 }
                }
            }
            Button(String(localized: "Refresh", bundle: .module)) { selectedFile = nil; refresh += 1 }
            if loading { ProgressView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let result {
                        Text("\(result.scope.title) · baseline: \(result.baseline)", bundle: .module)
                            .font(CompanionType.font(12, .medium))
                        Text(LocalizedStringKey(result.attribution), bundle: .module).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
                        Text("Diffs cover tracked files. Untracked files are listed separately without reading their contents. Read only; no comments or changes are sent to the agent.", bundle: .module)
                            .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3)
                        if let reason = result.unavailableReason {
                            Text(LocalizedStringKey(reason), bundle: .module).font(CompanionType.font(13))
                        } else if result.files.isEmpty && result.untrackedFiles.isEmpty {
                            Text(scope == .uncommitted ? "No uncommitted changes" : "No changes in this comparison", bundle: .module)
                                .font(CompanionType.font(13))
                        }
                        if !result.untrackedFiles.isEmpty {
                            Text("Untracked files · not included in the diff").font(CompanionType.font(12, .medium))
                            ForEach(result.untrackedFiles, id: \.self) { file in
                                Text(file).font(CompanionType.mono(11)).textSelection(.enabled)
                            }
                        }
                        if !result.stat.isEmpty { Text(result.stat).font(CompanionType.mono(11)).textSelection(.enabled) }
                        ForEach(result.files, id: \.self) { file in
                            Button { selectedFile = file } label: {
                                Label(file, systemImage: selectedFile == file ? "doc.text.fill" : "doc.text")
                                    .font(CompanionType.mono(11)).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                        if let diff = result.diff {
                            Divider()
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
        .padding(20).background(CompanionPalette.bg).foregroundStyle(CompanionPalette.ink)
        .tint(CompanionPalette.accent)
        .onChange(of: scope) { _ in selectedFile = nil }
        .task(id: requestKey) {
            loading = true; result = nil
            let response = await load(scope, scope == .branch ? appliedBaseline : nil, selectedFile)
            guard !Task.isCancelled else { return }
            result = response; loading = false
        }
    }
}

#endif
