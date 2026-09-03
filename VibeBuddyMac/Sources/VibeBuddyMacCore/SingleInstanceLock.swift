#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// A process-local owner for an advisory file lock. Keep the returned object
/// alive for as long as the app should be treated as the primary instance.
public final class SingleInstanceLock: @unchecked Sendable {
    public let lockFileURL: URL
    private let fd: CInt

    private init(fd: CInt, lockFileURL: URL) {
        self.fd = fd
        self.lockFileURL = lockFileURL
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }

    public static func acquire(lockFileURL: URL) throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(
            at: lockFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixError(errno) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            writeOwnerPID(to: fd)
            return SingleInstanceLock(fd: fd, lockFileURL: lockFileURL)
        }
        let err = errno
        close(fd)
        if err == EWOULDBLOCK || err == EAGAIN { return nil }
        throw posixError(err)
    }

    public static func defaultLockFileURL(filename: String = "mac-app.lock") throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return base.appendingPathComponent("vibebuddy", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private static func writeOwnerPID(to fd: CInt) {
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        let data = Data("\(getpid())\n".utf8)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(fd, base, buffer.count)
        }
    }

    private static func posixError(_ code: CInt) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
