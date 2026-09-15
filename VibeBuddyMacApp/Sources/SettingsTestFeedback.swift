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
                case .unverified: EmptyView()
                case .running:
                    HStack {
                        ProgressView().controlSize(.small)
                        switch purpose {
                        case .voice: Text("Testing connection…")
                        case .summary: Text("Generating sample…")
                        case .readAloud: Text("Preparing or playing preview…")
                        }
                        Button("Cancel") { tests.cancel() }
                    }
                case .cancelled:
                    Group {
                        switch purpose {
                        case .voice: Text("Connection test cancelled.")
                        case .summary: Text("Sample generation cancelled.")
                        case .readAloud: Text("Preview stopped.")
                        }
                    }
                    .foregroundStyle(MacTheme.ink2)
                case .succeeded, .failed:
                    if let outcome = tests.outcome {
                        switch outcome {
                        case .cancelled: EmptyView()
                        case .failure(let message):
                            Label(LocalizedStringKey(message), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(MacTheme.status(.requiresInput))
                        case .success(let output):
                            Label(LocalizedStringKey(output.message), systemImage: "checkmark.circle")
                                .foregroundStyle(MacTheme.accent)
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

struct SettingsOperationAvailability: View {
    @ObservedObject var tests: SettingsTestCoordinator
    let purpose: SettingsTestCoordinator.Purpose
    let reading: Bool

    var body: some View {
        Group {
            if tests.isBusy {
                if tests.phase == .running, tests.purpose != purpose {
                    Text("Another voice settings operation is running. Wait for it to finish or cancel it before trying this action.")
                }
            } else if reading {
                Text("Reading is in progress. Wait for it to finish or stop reading before trying this action.")
            }
        }
        .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
    }
}
