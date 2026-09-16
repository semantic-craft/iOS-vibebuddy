import Foundation
import CoreServices

public struct HistorySourceChanges: Sendable {
    public var paths: Set<String>
    public var requiresReconciliation: Bool

    public init(paths: Set<String> = [], requiresReconciliation: Bool = false) {
        self.paths = paths
        self.requiresReconciliation = requiresReconciliation
    }
}

@MainActor
public final class HistoryDirectoryWatcher {
    private let roots: [URL]
    private let onChange: (HistorySourceChanges) -> Void
    private let settleDelay: Duration
    private let maximumDelay: Duration
    private let pathLimit: Int
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var activeRoots: [String] = []
    private var pending = HistorySourceChanges()
    private var settle: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var rootReset: Task<Void, Never>?
    private var stopped = false
    private var streamFailed = false

    public init(roots: [URL], settleDelay: Duration = .milliseconds(800),
                maximumDelay: Duration = .seconds(2), pathLimit: Int = 4096,
                onChange: @escaping (HistorySourceChanges) -> Void) {
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.settleDelay = settleDelay
        self.maximumDelay = maximumDelay
        self.pathLimit = max(1, pathLimit)
        self.onChange = onChange
        restart()
        recovery = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                let rootsChanged = self.existingRoots() != self.activeRoots
                if rootsChanged || (!self.activeRoots.isEmpty && self.stream == nil) {
                    self.restart()
                    if rootsChanged { self.enqueue(HistorySourceChanges(requiresReconciliation: true)) }
                }
            }
        }
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        settle?.cancel(); deadline?.cancel(); recovery?.cancel(); rootReset?.cancel()
    }

    public func stop() {
        stopped = true
        settle?.cancel(); deadline?.cancel(); recovery?.cancel(); rootReset?.cancel()
        settle = nil; deadline = nil; recovery = nil; rootReset = nil
        closeStream()
        pending = HistorySourceChanges()
    }

    private func existingRoots() -> [String] {
        roots.compactMap {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue ? $0.path : nil
        }
    }

    private func closeStream() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }

    private func restart() {
        guard !stopped else { return }
        closeStream()
        activeRoots = existingRoots()
        guard !activeRoots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
            MainActor.assumeIsolated {
                let watcher = Unmanaged<HistoryDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                for index in 0..<count { watcher.receive(path: paths[index], flags: flags[index]) }
            }
        }
        stream = FSEventStreamCreate(nil, callback, &context, activeRoots as CFArray,
                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
                                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { reportStreamFailure(); return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if !FSEventStreamStart(stream) {
            closeStream()
            reportStreamFailure()
        } else if streamFailed {
            streamFailed = false
            enqueue(HistorySourceChanges(requiresReconciliation: true))
        }
    }

    private func reportStreamFailure() {
        guard !streamFailed else { return }
        streamFailed = true
        enqueue(HistorySourceChanges(requiresReconciliation: true))
    }

    func receive(path: String, flags: FSEventStreamEventFlags) {
        guard !stopped else { return }
        let recoveryFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        if flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
            rootReset?.cancel()
            rootReset = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.restart()
                self?.rootReset = nil
            }
        }
        if flags & recoveryFlags != 0 {
            enqueue(HistorySourceChanges(requiresReconciliation: true))
            return
        }
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard roots.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else { return }
        if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
            let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
            if flags & structural != 0 { enqueue(HistorySourceChanges(requiresReconciliation: true)) }
        } else {
            enqueue(HistorySourceChanges(paths: [path]))
        }
    }

    private func enqueue(_ changes: HistorySourceChanges) {
        guard !stopped else { return }
        pending.requiresReconciliation = pending.requiresReconciliation || changes.requiresReconciliation
        pending.paths.formUnion(changes.paths)
        if pending.paths.count > pathLimit {
            pending.requiresReconciliation = true
            pending.paths = Set(pending.paths.sorted().prefix(pathLimit))
        }
        settle?.cancel()
        settle = Task { [weak self] in
            guard let delay = self?.settleDelay else { return }
            do { try await Task.sleep(for: delay) } catch { return }
            self?.flush()
        }
        if deadline == nil {
            deadline = Task { [weak self] in
                guard let delay = self?.maximumDelay else { return }
                do { try await Task.sleep(for: delay) } catch { return }
                self?.flush()
            }
        }
    }

    private func flush() {
        guard !stopped else { return }
        settle?.cancel(); deadline?.cancel()
        settle = nil; deadline = nil
        let changes = pending
        pending = HistorySourceChanges()
        onChange(changes)
    }
}
