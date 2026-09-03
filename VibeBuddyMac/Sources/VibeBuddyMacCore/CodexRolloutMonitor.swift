import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import VibeBuddyKit

/// Pure, incremental decoder for Codex rollout JSONL. Codex Desktop writes this
/// stream even though it does not execute the user's CLI hooks, making it the
/// authoritative local fallback for desktop task progress.
public struct CodexRolloutParser: Sendable {
    public private(set) var sessionID: String?
    public private(set) var cwd: String?
    public private(set) var isDesktopSession = false
    public private(set) var turnActive = false
    private var activeTurnIDs: Set<String> = []
    private var anonymousTurnCount = 0
    private var pendingCollab: [String: PendingCollab] = [:]
    private var attributedCollabCalls: Set<String> = []
    private var collabChildren: [String: CollabChild] = [:]
    private var collabTopologyDegraded = false

    public init() {}

    public mutating func parseLine(_ data: Data, receivedAt: Date) -> HookEvent? {
        parseEvents(data, receivedAt: receivedAt).first
    }

    public mutating func parseEvents(_ data: Data, receivedAt: Date) -> [HookEvent] {
        guard Self.mightAffectProgress(data) else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordType = root["type"] as? String,
              let payload = root["payload"] as? [String: Any]
        else { return [] }

        let timestamp = Self.timestamp(root["timestamp"] as? String) ?? receivedAt

        if recordType == "session_meta" {
            sessionID = payload["id"] as? String
            cwd = payload["cwd"] as? String
            let originator = (payload["originator"] as? String)?.lowercased()
            let source = (payload["source"] as? String)?.lowercased()
            isDesktopSession = originator == "codex desktop" || source == "vscode"
            return []
        }

        guard let sessionID, isDesktopSession else { return [] }

        if recordType == "event_msg", let eventType = payload["type"] as? String {
            switch eventType {
            case "task_started":
                startTurn(payload["turn_id"] as? String)
                return [event(.userPromptSubmit, sessionID: sessionID, timestamp: timestamp)]
            case "task_complete":
                finishTurn(payload["turn_id"] as? String)
                guard !turnActive else { return [] }
                return [event(.stop, sessionID: sessionID,
                              message: payload["last_agent_message"] as? String,
                              timestamp: timestamp)]
            case "turn_aborted":
                finishTurn(payload["turn_id"] as? String)
                guard !turnActive else { return [] }
                return [event(.stop, sessionID: sessionID,
                              message: "Turn aborted", timestamp: timestamp)]
            case "exec_approval_request":
                return [event(.notification, sessionID: sessionID, toolName: "Shell",
                              message: "Permission required for Shell", timestamp: timestamp)]
            case "apply_patch_approval_request":
                return [event(.notification, sessionID: sessionID, toolName: "File change",
                              message: "Permission required for file change", timestamp: timestamp)]
            case "request_user_input", "elicitation_request":
                return [event(.notification, sessionID: sessionID,
                              message: "Waiting for your input", timestamp: timestamp)]
            case "item_completed":
                guard let item = payload["item"] as? [String: Any] else { return [] }
                return eventsForCompletedItem(item, sessionID: sessionID, timestamp: timestamp)
            default:
                return []
            }
        }

        if recordType == "response_item", let itemType = payload["type"] as? String {
            if Self.toolCallTypes.contains(itemType) {
                return eventsForToolCall(payload, sessionID: sessionID, timestamp: timestamp)
            }
            if Self.toolOutputTypes.contains(itemType) {
                return eventsForToolOutput(payload, sessionID: sessionID, timestamp: timestamp)
            }
            if itemType == "message", payload["phase"] as? String == "final_answer" {
                finishUnknownTurn()
                guard !turnActive else { return [] }
                return [event(.stop, sessionID: sessionID, timestamp: timestamp)]
            }
        }

        return []
    }

    func restorableChildEvents(timestamp: Date) -> [HookEvent] {
        guard let sessionID else { return [] }
        var events: [HookEvent] = []
        if collabTopologyDegraded {
            events.append(event(
                .childLifecycle, sessionID: sessionID, timestamp: timestamp,
                childKind: .task, childAction: .unknown))
        }
        for child in collabChildren.values {
            let action: HookEvent.ChildLifecycleAction
            switch child.status {
            case .running: action = .started
            case .unknown: action = .unknown
            default: continue
            }
            events.append(event(
                .childLifecycle, sessionID: sessionID,
                toolName: child.lastActivity, timestamp: timestamp,
                childID: child.id, childKind: .task,
                childName: child.name, childType: child.type,
                childAction: action))
        }
        return events
    }

    private func event(
        _ kind: HookEvent.Kind,
        sessionID: String,
        toolName: String? = nil,
        message: String? = nil,
        toolError: Bool = false,
        timestamp: Date,
        childID: String? = nil,
        childKind: ChildAgentKind? = nil,
        childName: String? = nil,
        childType: String? = nil,
        childAction: HookEvent.ChildLifecycleAction? = nil
    ) -> HookEvent {
        HookEvent(kind: kind, sessionID: sessionID, agent: .codex,
                  cwd: cwd, toolName: toolName, message: message,
                  toolError: toolError, timestamp: timestamp,
                  childID: childID, childKind: childKind, childName: childName,
                  childType: childType, childAction: childAction)
    }

    private struct PendingCollab {
        var name: String
        var taskName: String?
        var target: String?
        var agentType: String?
    }

    private struct CollabChild {
        var id: String
        var name: String?
        var type: String?
        var status: ChildAgentStatus
        var lastActivity: String?
    }

    private mutating func eventsForToolCall(
        _ payload: [String: Any],
        sessionID: String,
        timestamp: Date
    ) -> [HookEvent] {
        let itemType = payload["type"] as? String ?? "function_call"
        let name = Self.startedToolName(payload, itemType: itemType)
        if name.split(separator: "/").last?.lowercased() == "request_user_input" {
            return [event(.notification, sessionID: sessionID, toolName: name,
                          message: "Waiting for your input", timestamp: timestamp)]
        }
        let namespace = (payload["namespace"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if namespace?.lowercased() == "collaboration" {
            return eventsForCollabCall(payload, toolName: name, sessionID: sessionID, timestamp: timestamp)
        }
        return [event(.preToolUse, sessionID: sessionID, toolName: name, timestamp: timestamp)]
    }

    private mutating func eventsForCollabCall(
        _ payload: [String: Any],
        toolName: String,
        sessionID: String,
        timestamp: Date
    ) -> [HookEvent] {
        let leaf = (payload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let args = Self.jsonObject(payload["arguments"]) ?? [:]
        let callID = Self.nonEmpty(payload["call_id"] as? String)
        let taskName = args["task_name"] as? String
        let target = args["target"] as? String
        let agentType = args["agent_type"] as? String
        if let callID {
            pendingCollab[callID] = PendingCollab(
                name: leaf, taskName: taskName, target: target, agentType: agentType)
        }

        switch leaf {
        case "spawn_agent":
            return startCollab(
                rawID: taskName, type: agentType, activity: leaf,
                sessionID: sessionID, timestamp: timestamp)
        case "followup_task", "send_message":
            return startCollab(
                rawID: target, type: nil, activity: leaf,
                sessionID: sessionID, timestamp: timestamp)
        case "interrupt_agent":
            return stopCollab(
                rawID: target, activity: leaf, failed: false,
                sessionID: sessionID, timestamp: timestamp)
        case "wait_agent", "wait", "list_agents":
            return [event(.preToolUse, sessionID: sessionID, toolName: toolName, timestamp: timestamp)]
        default:
            return [event(.preToolUse, sessionID: sessionID, toolName: toolName, timestamp: timestamp)]
        }
    }

    private mutating func eventsForToolOutput(
        _ payload: [String: Any],
        sessionID: String,
        timestamp: Date
    ) -> [HookEvent] {
        let callID = Self.nonEmpty(payload["call_id"] as? String)
        guard let callID, let pending = pendingCollab.removeValue(forKey: callID) else {
            return [event(.postToolUse, sessionID: sessionID, toolName: "Tool", timestamp: timestamp)]
        }
        let output = Self.jsonObject(payload["output"])

        switch pending.name {
        case "spawn_agent":
            let raw = (output?["task_name"] as? String) ?? pending.taskName
            return startCollab(
                rawID: raw, type: pending.agentType, activity: pending.name,
                sessionID: sessionID, timestamp: timestamp)
        case "followup_task", "send_message":
            let raw = (output?["target"] as? String) ?? pending.target
            return startCollab(
                rawID: raw, type: pending.agentType, activity: pending.name,
                sessionID: sessionID, timestamp: timestamp)
        case "interrupt_agent":
            return stopCollab(
                rawID: pending.target, activity: pending.name, failed: false,
                sessionID: sessionID, timestamp: timestamp)
        case "wait_agent", "wait":
            var events: [HookEvent] = []
            let timedOut = Self.bool(output?["timed_out"])
            if attributedCollabCalls.contains(callID) {
                // Named receivers already applied; do not guess the rest.
            } else if timedOut != true {
                markTrackedRunningUnknown()
                collabTopologyDegraded = true
                events.append(event(
                    .childLifecycle, sessionID: sessionID, timestamp: timestamp,
                    childKind: .task, childAction: .unknown))
            }
            events.append(event(
                .postToolUse, sessionID: sessionID,
                toolName: "collaboration/\(pending.name)", timestamp: timestamp))
            return events
        case "list_agents":
            var events = eventsForListAgents(output, sessionID: sessionID, timestamp: timestamp)
            events.append(event(
                .postToolUse, sessionID: sessionID,
                toolName: "collaboration/list_agents", timestamp: timestamp))
            return events
        default:
            return [event(
                .postToolUse, sessionID: sessionID,
                toolName: "collaboration/\(pending.name)", timestamp: timestamp)]
        }
    }

    private mutating func eventsForCompletedItem(
        _ item: [String: Any],
        sessionID: String,
        timestamp: Date
    ) -> [HookEvent] {
        if item["type"] as? String == "CollabAgentToolCall" {
            return eventsForCollabItem(item, sessionID: sessionID, timestamp: timestamp)
        }
        guard let toolName = Self.completedToolName(item) else { return [] }
        return [event(.postToolUse, sessionID: sessionID, toolName: toolName,
                      toolError: Self.itemFailed(item), timestamp: timestamp)]
    }

    private mutating func eventsForCollabItem(
        _ item: [String: Any],
        sessionID: String,
        timestamp: Date
    ) -> [HookEvent] {
        let tool = Self.nonEmpty(item["tool"] as? String) ?? "Collaboration"
        let failed = Self.itemFailed(item)
        let receivers = (item["receiver_agents"] as? [String]) ?? []
        let named = receivers.compactMap(Self.collabTaskID)
        if let callID = Self.nonEmpty(item["id"] as? String), !named.isEmpty {
            attributedCollabCalls.insert(callID)
        }
        if !named.isEmpty {
            return named.map { id in
                stopTracked(id: id, activity: failed ? "failed" : tool, failed: failed)
                let child = collabChildren[id]
                return event(
                    .childLifecycle, sessionID: sessionID, toolName: failed ? "failed" : tool,
                    toolError: failed, timestamp: timestamp,
                    childID: id, childKind: .task,
                    childName: child?.name, childType: child?.type,
                    childAction: .stopped)
            }
        }
        return [event(.postToolUse, sessionID: sessionID,
                      toolName: tool == "Collaboration" ? tool : "collaboration/\(tool)",
                      toolError: failed, timestamp: timestamp)]
    }

    private mutating func eventsForListAgents(
        _ output: [String: Any]?,
        sessionID: String,
        timestamp: Date
    ) -> [HookEvent] {
        guard let agents = output?["agents"] as? [[String: Any]] else { return [] }
        var events: [HookEvent] = []
        for agent in agents {
            guard let id = Self.collabTaskID(agent["agent_name"] as? String),
                  let name = Self.collabTaskName(agent["agent_name"] as? String)
            else { continue }
            let action = Self.listAgentAction(agent["agent_status"])
            let activity = "list_agents"
            switch action {
            case .started:
                remember(CollabChild(id: id, name: name, status: .running, lastActivity: activity))
            case .stopped:
                stopTracked(id: id, activity: activity, failed: false)
            case .unknown:
                if var existing = collabChildren[id] {
                    existing.status = .unknown
                    existing.lastActivity = activity
                    collabChildren[id] = existing
                } else {
                    collabChildren[id] = CollabChild(
                        id: id, name: name, status: .unknown, lastActivity: activity)
                }
            case .idled:
                break
            }
            let child = collabChildren[id]
            events.append(event(
                .childLifecycle, sessionID: sessionID, toolName: activity,
                timestamp: timestamp, childID: id, childKind: .task,
                childName: child?.name ?? name, childType: child?.type,
                childAction: action))
        }
        return events
    }

    private static func listAgentAction(_ status: Any?) -> HookEvent.ChildLifecycleAction {
        if let text = (status as? String)?.lowercased() {
            if text == "running" { return .started }
            if ["completed", "interrupted", "failed", "error", "cancelled", "canceled"].contains(text) {
                return .stopped
            }
            return .unknown
        }
        if let object = status as? [String: Any] {
            let keys = Set(object.keys.map { $0.lowercased() })
            if keys.contains("completed") || keys.contains("interrupted") { return .stopped }
            if keys.contains("failed") || keys.contains("error") { return .stopped }
            if keys.contains("running") { return .started }
        }
        return .unknown
    }

    private mutating func startCollab(
        rawID: String?,
        type: String?,
        activity: String,
        sessionID: String,
        timestamp: Date
    ) -> [HookEvent] {
        guard let id = Self.collabTaskID(rawID), let name = Self.collabTaskName(rawID) else {
            collabTopologyDegraded = true
            return [event(
                .childLifecycle, sessionID: sessionID, toolName: activity, timestamp: timestamp,
                childKind: .task, childAction: .started)]
        }
        remember(CollabChild(id: id, name: name, type: Self.nonEmpty(type),
                             status: .running, lastActivity: activity))
        return [event(
            .childLifecycle, sessionID: sessionID, toolName: activity, timestamp: timestamp,
            childID: id, childKind: .task, childName: name, childType: Self.nonEmpty(type),
            childAction: .started)]
    }

    private mutating func stopCollab(
        rawID: String?,
        activity: String,
        failed: Bool,
        sessionID: String,
        timestamp: Date
    ) -> [HookEvent] {
        guard let id = Self.collabTaskID(rawID) else {
            collabTopologyDegraded = true
            return [event(
                .childLifecycle, sessionID: sessionID, toolName: activity, timestamp: timestamp,
                childKind: .task, childAction: .stopped)]
        }
        stopTracked(id: id, activity: activity, failed: failed)
        let child = collabChildren[id]
        return [event(
            .childLifecycle, sessionID: sessionID, toolName: activity,
            toolError: failed, timestamp: timestamp,
            childID: id, childKind: .task,
            childName: child?.name ?? Self.collabTaskName(rawID),
            childType: child?.type, childAction: .stopped)]
    }

    private mutating func remember(_ child: CollabChild) {
        if var existing = collabChildren[child.id] {
            existing.status = child.status
            if let name = child.name { existing.name = name }
            if let type = child.type { existing.type = type }
            if let lastActivity = child.lastActivity { existing.lastActivity = lastActivity }
            collabChildren[child.id] = existing
        } else {
            collabChildren[child.id] = child
        }
    }

    private mutating func stopTracked(id: String, activity: String, failed: Bool) {
        if var existing = collabChildren[id] {
            existing.status = .completed
            existing.lastActivity = failed ? "failed" : activity
            collabChildren[id] = existing
        } else {
            collabChildren[id] = CollabChild(
                id: id, name: Self.collabTaskName(id), status: .completed,
                lastActivity: failed ? "failed" : activity)
        }
    }

    private mutating func markTrackedRunningUnknown() {
        for id in Array(collabChildren.keys) {
            guard var child = collabChildren[id], child.status == .running else { continue }
            child.status = .unknown
            collabChildren[id] = child
        }
    }

    private static func collabTaskID(_ raw: String?) -> String? {
        collabTaskName(raw).map { "task:\($0)" }
    }

    private static func collabTaskName(_ raw: String?) -> String? {
        guard var value = nonEmpty(raw) else { return nil }
        if value.hasPrefix("task:") { value.removeFirst(5) }
        if value == "/root" || value == "root" { return nil }
        if value.hasPrefix("/root/") { value.removeFirst(6) }
        while value.hasPrefix("/") { value.removeFirst() }
        guard !value.isEmpty, value != "root" else { return nil }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func jsonObject(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        if let data = (value as? String)?.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        if let items = value as? [Any] {
            let text = items.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
            if let data = text.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return dict
            }
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = (value as? String)?.lowercased() {
            if text == "true" { return true }
            if text == "false" { return false }
        }
        return nil
    }

    private static let toolCallTypes: Set<String> = [
        "function_call", "custom_tool_call", "local_shell_call", "mcp_tool_call",
    ]

    private static let toolOutputTypes: Set<String> = [
        "function_call_output", "custom_tool_call_output", "local_shell_call_output",
    ]

    /// Rollouts contain large reasoning, message, and tool-output records. Avoid
    /// decoding records that cannot change the three-state session model.
    private static func mightAffectProgress(_ data: Data) -> Bool {
        progressMarkers.contains { data.range(of: $0) != nil }
    }

    private static let progressMarkers: [Data] = [
            #""type":"session_meta""#,
            #""type":"task_started""#,
            #""type":"task_complete""#,
            #""type":"turn_aborted""#,
            #""type":"exec_approval_request""#,
            #""type":"apply_patch_approval_request""#,
            #""type":"request_user_input""#,
            #""type":"elicitation_request""#,
            #""type":"item_completed""#,
            #""type":"function_call""#,
            #""type":"custom_tool_call""#,
            #""type":"local_shell_call""#,
            #""type":"mcp_tool_call""#,
            #""type":"function_call_output""#,
            #""type":"custom_tool_call_output""#,
            #""type":"local_shell_call_output""#,
            #""phase":"final_answer""#,
        ].map { Data($0.utf8) }

    private static func startedToolName(_ payload: [String: Any], itemType: String) -> String {
        let name = (payload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let namespace = (payload["namespace"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String] = [namespace, name].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: "/") }
        return itemType == "local_shell_call" ? "Shell" : "Tool"
    }

    private static func completedToolName(_ item: [String: Any]) -> String? {
        guard let type = item["type"] as? String else { return nil }
        switch type {
        case "CommandExecution": return "Shell"
        case "McpToolCall":
            let server = item["server"] as? String
            let tool = item["tool"] as? String
            let target = [server, tool].compactMap { $0 }.joined(separator: "/")
            return target.isEmpty ? "MCP" : "MCP: \(target)"
        case "FileChange": return "File change"
        case "Extension":
            return (item["action_name"] as? String).map { "Extension: \($0)" } ?? "Extension"
        case "ContextCompaction": return "Context compaction"
        case "FunctionCallOutput": return "Tool"
        case "CollabAgentToolCall":
            return (item["tool"] as? String).map { "collaboration/\($0)" } ?? "Collaboration"
        case "ImageView": return "view_image"
        default: return nil
        }
    }

    private mutating func startTurn(_ turnID: String?) {
        if let turnID, !turnID.isEmpty { activeTurnIDs.insert(turnID) }
        else { anonymousTurnCount += 1 }
        refreshTurnState()
    }

    private mutating func finishTurn(_ turnID: String?) {
        if let turnID, !turnID.isEmpty {
            activeTurnIDs.remove(turnID)
        } else if anonymousTurnCount > 0 {
            anonymousTurnCount -= 1
        } else if activeTurnIDs.count == 1 {
            activeTurnIDs.removeAll()
        }
        refreshTurnState()
    }

    private mutating func finishUnknownTurn() {
        if anonymousTurnCount > 0 { anonymousTurnCount -= 1 }
        else if activeTurnIDs.count == 1 { activeTurnIDs.removeAll() }
        refreshTurnState()
    }

    private mutating func refreshTurnState() {
        turnActive = anonymousTurnCount > 0 || !activeTurnIDs.isEmpty
    }

    private static func itemFailed(_ item: [String: Any]) -> Bool {
        if let exit = item["exit_code"] as? NSNumber, exit.intValue != 0 { return true }
        if let status = (item["status"] as? String)?.lowercased(),
           ["failed", "error", "cancelled", "canceled", "interrupted"].contains(status) {
            return true
        }
        return item["error"] != nil
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

#if canImport(Darwin)
private final class RolloutFileWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let cancelled = DispatchGroup()

    init?(
        file: URL,
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (UInt) -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) {
        let descriptor = open(file.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        cancelled.enter()
        source.setEventHandler { [source] in onEvent(source.data.rawValue) }
        source.setCancelHandler { [cancelled] in
            close(descriptor)
            onCancel()
            cancelled.leave()
        }
        source.resume()
    }

    func cancelAndWait() {
        source.cancel()
        cancelled.wait()
    }
}
#else
/// Linux has no `DispatchSource` kqueue file-system watcher. The initializer
/// returns nil so `ensureWatcher` degrades to the monitor's polling/recovery
/// task, which already exists as the slow-path backstop on macOS.
private final class RolloutFileWatcher: @unchecked Sendable {
    init?(
        file: URL,
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (UInt) -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) {
        return nil
    }

    func cancelAndWait() {}
}
#endif

/// Runtime evidence for the monitor's low-power and resource-lifecycle contract.
public struct CodexRolloutMonitorDiagnostics: Equatable, Sendable {
    public let isRunning: Bool
    public let recoveryTaskRunning: Bool
    public let deliveryTaskRunning: Bool
    public let discoveryPassCount: Int
    public let watcherEventCount: Int
    public let debouncedRefreshCount: Int
    public let watcherRecoveryCount: Int
    public let watchedFileCount: Int
    public let pendingDebounceCount: Int
    public let queuedEventCount: Int
}

/// Watches today's and yesterday's Codex rollout files and emits only appended
/// desktop lifecycle events. File events provide live progress, while a slow
/// discovery pass only finds new rollouts and repairs lost watchers. First
/// discovery restores a currently active turn without replaying old completions.
public actor CodexRolloutMonitor {
    private struct FileIdentity: Equatable, Sendable {
        let volume: UInt64
        let inode: UInt64
    }

    private struct FileState: Sendable {
        let identity: FileIdentity
        let size: UInt64
    }

    private struct Cursor: Sendable {
        var offset: UInt64 = 0
        var remainder = Data()
        var parser = CodexRolloutParser()
        var identity: FileIdentity?
        var checkpoint = Data()

        mutating func consume(_ data: Data, receivedAt: Date) -> [HookEvent] {
            remainder.append(data)
            var events: [HookEvent] = []
            var lineStart = remainder.startIndex
            while let newline = remainder[lineStart...].firstIndex(of: 0x0A) {
                if newline > lineStart {
                    let line = Data(remainder[lineStart..<newline])
                    events.append(contentsOf: parser.parseEvents(line, receivedAt: receivedAt))
                }
                lineStart = remainder.index(after: newline)
                if lineStart == remainder.endIndex { break }
            }
            remainder = lineStart < remainder.endIndex
                ? Data(remainder[lineStart..<remainder.endIndex]) : Data()
            return events
        }
    }

    private struct WatchRegistration: Sendable {
        let id: UUID
        let identity: FileIdentity
        let watcher: RolloutFileWatcher
    }

    private struct DebounceRegistration: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private typealias EventSink = @Sendable (HookEvent) async -> Void

    private let root: URL
    private let discoveryInterval: Duration
    private let debounceInterval: Duration
    private let recoveryWindow: TimeInterval
    private let watcherQueue = DispatchQueue(
        label: "com.vibebuddy.codex-rollout-watchers",
        qos: .utility
    )
    private var cursors: [String: Cursor] = [:]
    private var watchers: [String: WatchRegistration] = [:]
    private var debounceTasks: [String: DebounceRegistration] = [:]
    private var recoveryTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var eventQueue: [HookEvent] = []
    private var eventQueueHead = 0
    private var recoveryGateForTesting: (@Sendable () async -> Void)?
    private var sink: EventSink?
    private var isRunning = false
    private var discoveryPassCount = 0
    private var watcherEventCount = 0
    private var debouncedRefreshCount = 0
    private var watcherRecoveryCount = 0

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        discoveryInterval: Duration = .seconds(30),
        debounceInterval: Duration = .milliseconds(100),
        recoveryWindow: TimeInterval = 30 * 60
    ) {
        self.root = root
        self.discoveryInterval = discoveryInterval
        self.debounceInterval = debounceInterval
        self.recoveryWindow = recoveryWindow
    }

    public func run(store: SessionStore) async {
        await run { event in await store.ingest(event) }
    }

    func run(_ onEvent: @escaping @Sendable (HookEvent) async -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        sink = onEvent
        enqueue(scan(now: Date(), installWatchers: true))

        let interval = discoveryInterval
        recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) }
                catch { return }
                guard let self else { return }
                await self.discoverAndRecover(now: Date())
            }
        }

        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3_600)) }
            catch { break }
        }
        await stop()
    }

    /// One deterministic discovery/recovery pass, public so the file-tail
    /// contract can be tested without timers or a running HTTP server.
    public func poll(now: Date) -> [HookEvent] {
        scan(now: now, installWatchers: isRunning)
    }

    public func diagnostics() -> CodexRolloutMonitorDiagnostics {
        CodexRolloutMonitorDiagnostics(
            isRunning: isRunning,
            recoveryTaskRunning: recoveryTask != nil,
            deliveryTaskRunning: deliveryTask != nil,
            discoveryPassCount: discoveryPassCount,
            watcherEventCount: watcherEventCount,
            debouncedRefreshCount: debouncedRefreshCount,
            watcherRecoveryCount: watcherRecoveryCount,
            watchedFileCount: watchers.count,
            pendingDebounceCount: debounceTasks.count,
            queuedEventCount: eventQueue.count - eventQueueHead
        )
    }

    func invalidateWatcherForTesting(at file: URL) {
        let path = file.path
        watcherRecoveryCount += 1
        watchers.removeValue(forKey: path)?.watcher.cancelAndWait()
        scheduleDebouncedRefresh(path: path)
    }

    func setRecoveryGateForTesting(_ gate: @escaping @Sendable () async -> Void) {
        recoveryGateForTesting = gate
    }

    private func discoverAndRecover(now: Date) async {
        guard isRunning, !Task.isCancelled else { return }
        if let recoveryGateForTesting { await recoveryGateForTesting() }
        guard isRunning, !Task.isCancelled else { return }
        enqueue(scan(now: now, installWatchers: true))
    }

    private func scan(now: Date, installWatchers: Bool) -> [HookEvent] {
        discoveryPassCount += 1
        let files = candidateFiles(now: now)
        let livePaths = Set(files.map(\.path))
        for path in Array(cursors.keys) where !livePaths.contains(path) {
            removeTracking(path: path)
        }
        var emitted: [HookEvent] = []

        for file in files {
            emitted.append(contentsOf: refresh(file: file, now: now, installWatcher: installWatchers))
        }
        return emitted
    }

    private func refresh(file: URL, now: Date, installWatcher: Bool) -> [HookEvent] {
        let path = file.path
        guard let state = Self.fileState(file) else {
            removeTracking(path: path)
            return []
        }

        var emitted: [HookEvent] = []
        if var cursor = cursors[path] {
            let mustReset = cursor.identity != state.identity
                || state.size < cursor.offset
                || !Self.checkpointMatches(cursor, file: file)
            if mustReset {
                if let bootstrapped = Self.bootstrap(file: file, state: state, receivedAt: now) {
                    cursor = bootstrapped.cursor
                    emitted = bootstrapped.events
                } else {
                    removeTracking(path: path)
                    return []
                }
            } else if state.size > cursor.offset,
                      let appended = Self.read(file, from: cursor.offset) {
                cursor.offset += UInt64(appended.count)
                emitted = cursor.consume(appended, receivedAt: now)
                cursor.checkpoint = Self.checkpoint(file: file, endingAt: cursor.offset)
            }
            cursor.identity = state.identity
            cursors[path] = cursor
        } else if let bootstrapped = Self.bootstrap(file: file, state: state, receivedAt: now) {
            cursors[path] = bootstrapped.cursor
            emitted = bootstrapped.events
        }

        if installWatcher { ensureWatcher(for: file, identity: state.identity) }
        return emitted
    }

    private func ensureWatcher(for file: URL, identity: FileIdentity) {
        let path = file.path
        if let existing = watchers[path], existing.identity == identity { return }
        if let old = watchers.removeValue(forKey: path) {
            old.watcher.cancelAndWait()
        }

        let id = UUID()
        guard let watcher = RolloutFileWatcher(
            file: file,
            queue: watcherQueue,
            onEvent: { [weak self] rawEvents in
                Task { await self?.watcherDidSignal(path: path, id: id, rawEvents: rawEvents) }
            },
            onCancel: { [weak self] in
                Task { await self?.watcherDidCancel(path: path, id: id) }
            }
        ) else { return }
        watchers[path] = WatchRegistration(id: id, identity: identity, watcher: watcher)
    }

    private func watcherDidSignal(
        path: String,
        id: UUID,
        rawEvents: UInt
    ) {
        guard isRunning, watchers[path]?.id == id else { return }
        watcherEventCount += 1
        #if canImport(Darwin)
        let events = DispatchSource.FileSystemEvent(rawValue: rawEvents)
        if !events.intersection([.delete, .rename, .revoke]).isEmpty,
           let registration = watchers.removeValue(forKey: path) {
            watcherRecoveryCount += 1
            registration.watcher.cancelAndWait()
        }
        #endif
        scheduleDebouncedRefresh(path: path)
    }

    private func watcherDidCancel(path: String, id: UUID) {
        guard isRunning, watchers[path]?.id == id else { return }
        watchers[path] = nil
        watcherRecoveryCount += 1
        scheduleDebouncedRefresh(path: path)
    }

    private func scheduleDebouncedRefresh(path: String) {
        debounceTasks[path]?.task.cancel()
        let id = UUID()
        let interval = debounceInterval
        let task = Task { [weak self] in
            do { try await Task.sleep(for: interval) }
            catch { return }
            await self?.performDebouncedRefresh(path: path, id: id)
        }
        debounceTasks[path] = DebounceRegistration(id: id, task: task)
    }

    private func performDebouncedRefresh(path: String, id: UUID) async {
        guard isRunning, debounceTasks[path]?.id == id else { return }
        debounceTasks[path] = nil
        debouncedRefreshCount += 1
        let file = URL(fileURLWithPath: path)
        enqueue(refresh(file: file, now: Date(), installWatcher: true))
    }

    private func enqueue(_ events: [HookEvent]) {
        guard isRunning, !events.isEmpty else { return }
        eventQueue.append(contentsOf: events)
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            await self?.drainEventQueue()
        }
    }

    private func drainEventQueue() async {
        while !Task.isCancelled, isRunning, eventQueueHead < eventQueue.count, let sink {
            let event = eventQueue[eventQueueHead]
            eventQueueHead += 1
            await sink(event)
        }
        eventQueue.removeAll(keepingCapacity: isRunning)
        eventQueueHead = 0
        deliveryTask = nil
    }

    private func removeTracking(path: String) {
        cursors[path] = nil
        debounceTasks.removeValue(forKey: path)?.task.cancel()
        if let registration = watchers.removeValue(forKey: path) {
            registration.watcher.cancelAndWait()
        }
    }

    private func stop() async {
        isRunning = false
        let recovery = recoveryTask
        let debounces = debounceTasks.values.map(\.task)
        let delivery = deliveryTask
        recovery?.cancel()
        for task in debounces { task.cancel() }
        delivery?.cancel()

        await recovery?.value
        for task in debounces { await task.value }
        await delivery?.value

        recoveryTask = nil
        debounceTasks.removeAll()
        deliveryTask = nil
        let registrations = Array(watchers.values)
        watchers.removeAll()
        for registration in registrations { registration.watcher.cancelAndWait() }
        eventQueue.removeAll()
        eventQueueHead = 0
        cursors.removeAll()
        recoveryGateForTesting = nil
        sink = nil
    }

    private func candidateFiles(now: Date) -> [URL] {
        let fm = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var files: [URL] = []

        for daysAgo in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayNumber = parts.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", dayNumber), isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            files.append(contentsOf: entries.filter {
                guard $0.lastPathComponent.hasPrefix("rollout-"), $0.pathExtension == "jsonl",
                      let values = try? $0.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate else { return false }
                return now.timeIntervalSince(modified) <= recoveryWindow
            })
        }
        // Retain only active rollouts beyond the recency window. Completed or
        // abandoned files age out, bounding watcher descriptors over time.
        for (path, cursor) in cursors where cursor.parser.turnActive && fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if !files.contains(url) { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func fileState(_ file: URL) -> FileState? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        return FileState(identity: FileIdentity(volume: volume, inode: inode), size: size)
    }

    private static func read(_ file: URL, from offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    private static func bootstrap(
        file: URL,
        state: FileState,
        receivedAt: Date
    ) -> (cursor: Cursor, events: [HookEvent])? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var cursor = Cursor(identity: state.identity)
        var latestParent: HookEvent?
        do {
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                cursor.offset += UInt64(chunk.count)
                for event in cursor.consume(chunk, receivedAt: receivedAt) {
                    if event.kind == .childLifecycle { continue }
                    if event.kind != .stop && event.kind != .sessionEnd {
                        latestParent = event
                    }
                }
            }
        } catch {
            return nil
        }
        cursor.checkpoint = checkpoint(file: file, endingAt: cursor.offset)
        guard cursor.parser.isDesktopSession else { return (cursor, []) }
        var events: [HookEvent] = []
        if cursor.parser.turnActive, let latestParent {
            events.append(latestParent)
        }
        events.append(contentsOf: cursor.parser.restorableChildEvents(timestamp: receivedAt))
        return (cursor, events)
    }

    private static func checkpointMatches(_ cursor: Cursor, file: URL) -> Bool {
        guard !cursor.checkpoint.isEmpty else { return true }
        return checkpoint(file: file, endingAt: cursor.offset) == cursor.checkpoint
    }

    private static func checkpoint(file: URL, endingAt offset: UInt64) -> Data {
        let count = min(UInt64(128), offset)
        guard count > 0, let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset - count)
            return try handle.read(upToCount: Int(count)) ?? Data()
        } catch {
            return Data()
        }
    }
}
