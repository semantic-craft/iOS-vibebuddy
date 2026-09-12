import SwiftUI

struct SettingsTestFeedback: View {
    @ObservedObject var tests: SettingsTestCoordinator
    let purpose: SettingsTestCoordinator.Purpose

    var body: some View {
        Group {
            if tests.isBusy && tests.phase != .running {
                Label("Finishing the previous test…", systemImage: "hourglass")
                    .foregroundStyle(MacTheme.ink2)
            }
            if tests.purpose == purpose {
                switch tests.phase {
                case .unverified: Text("Not verified")
                case .running:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Testing…")
                        Button("Cancel") { tests.cancel() }
                    }
                case .cancelled: Text("Test cancelled.").foregroundStyle(MacTheme.ink2)
                case .succeeded, .failed:
                    if let outcome = tests.outcome {
                        switch outcome {
                        case .cancelled: EmptyView()
                        case .failure(let message):
                            Label(LocalizedStringKey(message), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        case .success(let output):
                            Label(LocalizedStringKey(output.message), systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                            if let text = output.text {
                                Text(text).textSelection(.enabled)
                                    .accessibilityIdentifier("completionSummaryTestResult")
                                Text("Check that the summary still says device verification is pending.")
                                    .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                            }
                            if !output.details.isEmpty {
                                DisclosureGroup("Test details") {
                                    ForEach(output.details, id: \.self) { Text(verbatim: $0) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
