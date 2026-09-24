import CoreServices
import Foundation

/// An FSEvents stream over one directory tree that calls `onChange` when a
/// path `relevant` accepts changes (or when FSEvents says it lost track and
/// the tree must be rescanned). A poller uses it as a wake-up, not as the
/// source of truth: it still lists and reads the files itself, so a missed
/// or coalesced event costs latency, never correctness.
///
/// The root does not have to exist yet; FSEvents matches by path, so a tree
/// created later is still reported.
final class DirectoryEventStream: @unchecked Sendable {
    /// What the stream's callback sees. FSEvents owns one reference and drops
    /// it when the stream is released, so a callback in flight never outlives it.
    private final class Handler: @unchecked Sendable {
        let relevant: @Sendable (String) -> Bool
        let onChange: @Sendable () -> Void
        init(relevant: @escaping @Sendable (String) -> Bool, onChange: @escaping @Sendable () -> Void) {
            self.relevant = relevant
            self.onChange = onChange
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "vibebuddy.directory-events", qos: .utility)
    private var stream: FSEventStreamRef?

    /// Nil when FSEvents would not create the stream; the caller keeps polling.
    init?(root: URL, latency: TimeInterval = 0.5,
          relevant: @escaping @Sendable (String) -> Bool,
          onChange: @escaping @Sendable () -> Void) {
        let handler = Unmanaged.passRetained(Handler(relevant: relevant, onChange: onChange))
        var context = FSEventStreamContext(
            version: 0, info: handler.toOpaque(), retain: nil,
            release: { info in info.map { Unmanaged<Handler>.fromOpaque($0).release() } },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: NSArray.self)
            let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagRootChanged)
            for index in 0..<count {
                if flags[index] & rescan != 0
                    || (names[index] as? String).map(handler.relevant) == true {
                    handler.onChange()
                    return
                }
            }
        }
        // NoDefer: the first change after a quiet spell is delivered at once;
        // only a burst is held back to `latency`.
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, options) else {
            handler.release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    /// Stop delivering. Idempotent. Stopped on the stream's own queue, so no
    /// callback is running when it returns. Never called from `onChange`.
    func stop() {
        guard let stream = lock.withLock({ () -> FSEventStreamRef? in
            defer { self.stream = nil }
            return self.stream
        }) else { return }
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
        }
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}
