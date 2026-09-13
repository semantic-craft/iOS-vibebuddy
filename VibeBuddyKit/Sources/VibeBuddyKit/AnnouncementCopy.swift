import Foundation

/// Concise speech from existing evidence, explicitly attributed to the agent.
/// Does not turn a turn ending or reported check into independent verification.
public enum AnnouncementCopy {
    public static func text(for session: AgentSession, sound: NotificationSound, language: VoiceLanguage = .english) -> String? {
        let title = session.displayTitle
        if language == .chinese {
            switch sound {
            case .agentDone:
                guard session.status == .done else { return nil }
                let result = session.completionSummary ?? RowPresentation.firstSentence(session.completionText)
                return "\(title)，这一轮结束。" + (result.map { "Agent 报告：" + $0 } ?? "暂时没有可核实的结果摘要。")
            case .needsApproval:
                guard session.status == .needsResponse else { return nil }
                return "\(title) 在等你批准。" + (session.pendingApproval.map { $0.tool + "：" + String($0.commandPreview.prefix(180)) } ?? "请打开任务查看请求。")
            case .needsAnswer:
                guard session.status == .needsResponse else { return nil }
                return "\(title) 在等你。" + (RowPresentation.firstSentence(session.pendingQuestion?.prompt ?? session.summary) ?? "请查看问题或计划决定。")
            case .agentStuck:
                guard session.status == .done, session.failed == true else { return nil }
                return "\(title) 已因问题停止。Agent 报告：" + (RowPresentation.firstSentence(session.summary) ?? "没有错误详情。")
            default: return nil
            }
        }
        switch sound {
        case .agentDone:
            guard session.status == .done else { return nil }
            if let summary = session.completionSummary {
                return "\(title). This turn ended. The agent reports: \(summary)"
            }
            if let result = RowPresentation.firstSentence(session.completionText) {
                return "\(title). This turn ended. The agent reports: \(result)"
            }
            return "\(title). This turn ended. A verified result summary is unavailable."
        case .needsApproval:
            guard session.status == .needsResponse else { return nil }
            let request = session.pendingApproval.map { $0.tool + ": " + String($0.commandPreview.prefix(180)) }
            return "\(title) is waiting for you. Approval needed. \(request ?? "Open the task to see the request.")"
        case .needsAnswer:
            guard session.status == .needsResponse else { return nil }
            let request = RowPresentation.firstSentence(session.pendingQuestion?.prompt ?? session.summary)
            return "\(title) is waiting for you. \(request ?? "Open the task to see the question or plan decision.")"
        case .agentStuck:
            guard session.status == .done, session.failed == true else { return nil }
            return "\(title) stopped with an issue. The agent reports: \(RowPresentation.firstSentence(session.summary) ?? "No error details are available.")"
        default: return nil
        }
    }
}
