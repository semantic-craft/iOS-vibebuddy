import Foundation
import Dispatch
import Darwin
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

    public init() {}

    public mutating func parseLine(_ data: Data, receivedAt: Date) -> HookEvent? {
        guard Self.mightAffectProgress(data) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordType = root["type"] as? String,
              let payload = root["payload"] as? [String: Any]
        else { return nil }

        let timestamp = Self.timestamp(root["timestamp"] as? String) ?? receivedAt

        if recordType == "session_meta" {
            sessionID = payload["id"] as? String
            cwd = payload["cwd"] as? String
            let originator = (payload["originator"] as? String)?.lowercased()
            let source = (payload["source"] as? String)?.lowercased()
            isDesktopSession = originator == "codex desktop" || source == "vscode"
            return nil
        }

        guard let sessionID, isDesktopSession else { return nil }

        if recordType == "event_msg", let eventType = payload["type"] as? String {
            switch eventType {
            case "task_started":
                startTurn(payload["turn_id"] as? String)
                return event(.userPromptSubmit, sessionID: sessionID, timestamp: timestamp)
            case "task_complete":
                finishTurn(payload["turn_id"] as? String)
                guard !turnActive else { return nil }
                return event(.stop, sessionID: sessionID,
                             message: payload["last_agent_message"] as? String,
                             timestamp: timestamp)
            case "turn_aborted":
                finishTurn(payload["turn_id"] as? String)
                guard !turnActive else { return nil }
                return event(.stop, sessionID: sessionID,
                             message: "Turn aborted", timestamp: timestamp)
            case "exec_approval_request":
                return event(.notification, sessionID: sessionID, toolName: "Shell",
                             message: "Permission required for Shell", timestamp: timestamp)
            case "apply_patch_approval_request":
                return event(.notification, sessionID: sessionID, toolName: "File change",
                             message: "Permission required for file change", timestamp: timestamp)
            case "request_user_input", "elicitation_request":
                return event(.notification, sessionID: sessionID,
                             message: "Waiting for your input", timestamp: timestamp)
            case "item_completed":
                guard let item = payload["item"] as? [String: Any],
                      let toolName = Self.completedToolName(item) else { return nil }
                return event(.postToolUse, sessionID: sessionID,
                             toolName: toolName,
                             toolError: Self.itemFailed(item),
                             timestamp: timestamp)
            default:
                return nil
            }
        }

        if recordType == "response_item", let itemType = payload["type"] as? String {
            if Self.toolCallTypes.contains(itemType) {
                let name = Self.startedToolName(payload, itemType: itemType)
                if name.split(separator: "/").last?.lowercased() == "request_user_input" {
                    return event(.notification, sessionID: sessionID, toolName: name,
                                 message: "Waiting for your input", timestamp: timestamp)
                }
                return event(.preToolUse, sessionID: sessionID,
                             toolName: name, timestamp: timestamp)
            }
            if Self.toolOutputTypes.contains(itemType) {
                return event(.postToolUse, sessionID: sessionID,
                             toolName: "Tool", timestamp: timestamp)
            }
            if itemType == "message", payload["phase"] as? String == "final_answer" {
                finishUnknownTurn()
                guard !turnActive else { return nil }
                return event(.stop, sessionID: sessionID, timestamp: timestamp)
            }
        }

        return nil
    }

    private func event(
        _ kind: HookEvent.Kind,
        sessionID: String,
        toolName: String? = nil,
        message: String? = nil,
        toolError: Bool = false,
        timestamp: Date
    ) -> HookEvent {
        HookEvent(kind: kind, sessionID: sessionID, agent: .codex,
                  cwd: cwd, toolName: toolName, message: message,
                  toolError: toolError, timestamp: timestamp)
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

private final class RolloutFileWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let cancelled = DispatchGroup()

    init?(
        file: URL,
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (UInt) -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) {
        let descriptor = Darwin.open(file.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        cancelled.enter()
        source.setEventHandler { [source] in onEvent(source.data.rawValue) }
        source.setCancelHandler { [cancelled] in
            Darwin.close(descriptor)
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
                    if let event = parser.parseLine(line, receivedAt: receivedAt) {
                        events.append(event)
                    }
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
        let events = DispatchSource.FileSystemEvent(rawValue: rawEvents)
        if !events.intersection([.delete, .rename, .revoke]).isEmpty,
           let registration = watchers.removeValue(forKey: path) {
            watcherRecoveryCount += 1
            registration.watcher.cancelAndWait()
        }
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
        var latestRestorable: HookEvent?
        do {
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                cursor.offset += UInt64(chunk.count)
                for event in cursor.consume(chunk, receivedAt: receivedAt)
                where event.kind != .stop && event.kind != .sessionEnd {
                    latestRestorable = event
                }
            }
        } catch {
            return nil
        }
        cursor.checkpoint = checkpoint(file: file, endingAt: cursor.offset)
        let events = cursor.parser.isDesktopSession && cursor.parser.turnActive
            ? latestRestorable.map { [$0] } ?? []
            : []
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
