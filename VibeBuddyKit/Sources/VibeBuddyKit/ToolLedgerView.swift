#if os(iOS) || os(macOS)
import SwiftUI

/// The same bounded evidence and scope wording on Mac and phone.
public struct ToolLedgerView: View {
    public let session: AgentSession
    public init(session: AgentSession) { self.session = session }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = session.ledgerSummary {
                Text(summary).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            }
            Text("Observed calls only, not a complete audit. Counts cover up to 50 retained calls; the latest 20 appear below. Cumulative edit volume is not the current Git diff.", bundle: .module)
                .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3)
            if session.ledger?.isEmpty != false {
                Text("No captured tool records. This source may not expose call details.", bundle: .module)
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
            }
            ForEach(session.ledger ?? []) { record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.tool).font(CompanionType.font(12, .semibold))
                        Spacer()
                        Text(record.result == .unconfirmed ? "Unconfirmed" : record.result == .succeeded ? "Succeeded" : "Failed", bundle: .module)
                            .font(CompanionType.font(11))
                    }
                    if let command = record.command { Text(command).font(CompanionType.mono(11)).textSelection(.enabled) }
                    ForEach(record.files, id: \.self) { Text($0).font(CompanionType.mono(10)).textSelection(.enabled) }
                    HStack {
                        Text(record.observedAt, style: .time)
                        Text(record.source)
                        if let code = record.exitCode { Text("Exit \(code)", bundle: .module) }
                    }.font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3)
                    Text(LocalizedStringKey(record.coverage), bundle: .module).font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3)
                }
                .foregroundStyle(CompanionPalette.ink)
                Divider()
            }
        }
    }
}

#endif
