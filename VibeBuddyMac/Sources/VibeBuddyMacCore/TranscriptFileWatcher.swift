import Foundation

/// One file, one `DispatchSource`, an 800 ms settle — the same shape Wake
/// uses for its transcript roots, narrowed to the transcript that is open.
/// A rename or delete (Codex rewrites rollouts on resume) reopens the path
/// after a beat rather than watching a dead descriptor. While the path is
/// absent, its parent keeps observing replacement creation (the scoped recovery
/// pattern also used by CodexBar's ConfigFileWatcher).
@MainActor
public final class TranscriptFileWatcher {
    public let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var settle: Task<Void, Never>?

    public init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        open()
    }

    deinit { source?.cancel(); settle?.cancel() }

    private func open() {
        let file = URL(fileURLWithPath: path)
        let watchingParent = !FileManager.default.fileExists(atPath: path)
        let watchedPath = watchingParent ? file.deletingLastPathComponent().path : path
        let descriptor = Darwin.open(watchedPath, O_EVTONLY)
        guard descriptor >= 0 else {
            // A parent can disappear too. Keep recovery scoped to this reader.
            settle = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.open()
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            let events = source?.data ?? []
            if watchingParent || events.contains(.rename) || events.contains(.delete) {
                self.source?.cancel(); self.source = nil
                self.settle?.cancel()
                self.settle = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self else { return }
                    self.open()
                    self.onChange()
                }
                return
            }
            self.settle?.cancel()
            self.settle = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                self?.onChange()
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        self.source = source
    }
}
