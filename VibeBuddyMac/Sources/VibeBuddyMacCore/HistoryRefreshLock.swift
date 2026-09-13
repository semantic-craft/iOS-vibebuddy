import Foundation
import Darwin

/// The descriptor stays open for the whole refresh. Never unlink the lock file:
/// another process may already be waiting on that inode.
final class HistoryRefreshLock {
    private let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent(".refresh.lock").path,
                          O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw HistoryToolError.refreshBusy }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
