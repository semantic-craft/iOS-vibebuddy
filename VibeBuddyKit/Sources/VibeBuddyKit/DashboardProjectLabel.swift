import Foundation

public struct DashboardProjectLabel: Equatable, Sendable {
    public let title: String
    public let parentPath: String?

    /// Pure over its input, and every dashboard body asks for the same
    /// project list several times per evaluation: the last answer is kept.
    private static let memo = Memo()
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var key: [String] = []
        private var value: [String: DashboardProjectLabel]?
        func labels(for projects: [String], compute: ([String]) -> [String: DashboardProjectLabel]) -> [String: DashboardProjectLabel] {
            lock.lock(); defer { lock.unlock() }
            if let value, key == projects { return value }
            let computed = compute(projects)
            key = projects; value = computed
            return computed
        }
    }

    public static func labels(for projects: [String]) -> [String: Self] {
        memo.labels(for: projects, compute: compute)
    }

    private static func compute(_ projects: [String]) -> [String: Self] {
        var labels: [String: Self] = [:]
        var groups: [String: [(path: String, parent: String, suffixes: [String])]] = [:]
        for project in Set(projects) {
            guard project.hasPrefix("/"), project != "/" else {
                labels[project] = Self(title: project, parentPath: nil)
                continue
            }
            let path = project as NSString
            let parent = path.deletingLastPathComponent
            let components = parent.split(separator: "/")
            let suffixes = components.indices.map { components.suffix($0 + 1).joined(separator: "/") }
            groups[path.lastPathComponent, default: []].append((project, parent, suffixes))
        }
        for (title, paths) in groups {
            var counts: [String: Int] = [:]
            for path in paths {
                for suffix in path.suffixes { counts[suffix, default: 0] += 1 }
            }
            for path in paths {
                let suffix = path.suffixes.first { counts[$0] == 1 } ?? path.parent
                labels[path.path] = Self(title: title, parentPath: suffix)
            }
        }
        return labels
    }
}
