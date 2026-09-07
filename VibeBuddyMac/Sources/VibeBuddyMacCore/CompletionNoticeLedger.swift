import Foundation
import VibeBuddyKit

/// Decisions are committed before starting paid work. Restart never repeats it.
struct CompletionNoticeLedger {
    let url: URL
    var notices: [String: CompletionNotice]
    private var available = true
    init(url: URL) {
        self.url = url
        notices = [:]
        do { notices = try JSONDecoder().decode([String: CompletionNotice].self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
        catch { available = false }
        for key in notices.keys where notices[key]?.state == .pending { notices[key]?.state = .plain }
    }
    mutating func save(_ notice: CompletionNotice) -> Bool {
        guard available else { return false }
        var next = notices.filter { $0.value.deadline > Date().addingTimeInterval(-7 * 86400) }
        next[notice.id] = notice
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(next)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            notices = next
            return true
        } catch { return false }
    }
}
