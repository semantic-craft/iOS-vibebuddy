import XCTest
import VibeBuddyKit
@testable import VibeBuddyMacCore

final class WorkspaceChangesReaderTests: XCTestCase {
    func testRealRepositoryScopesAndUnavailableDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vibebuddy-changes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "user.name=VibeBuddy Test", "-c", "user.email=test@example.invalid",
                                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        XCTAssertNotNil(WorkspaceChangesReader.read(cwd: root.path, scope: .uncommitted, baseline: nil, file: nil, shared: false).unavailableReason)
        try git(["init"])
        for name in ["a.txt", "b.txt", "space [file].txt"] { try "before\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try git(["add", "."]); try git(["commit", "-m", "Initial test files"]); try git(["branch", "baseline"])
        for name in ["a.txt", "b.txt", "space [file].txt"] { try "after\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let changes = WorkspaceChangesReader.read(cwd: root.path, scope: .uncommitted, baseline: nil, file: "space [file].txt", shared: true)
        XCTAssertEqual(changes.files.count, 3)
        XCTAssertTrue(changes.diff?.contains("+after") == true)
        XCTAssertTrue(changes.attribution.contains("multiple sessions"))
        try git(["add", "a.txt"])
        XCTAssertEqual(WorkspaceChangesReader.read(cwd: root.path, scope: .staged, baseline: nil, file: nil, shared: false).files, ["a.txt"])
        try git(["add", "."]); try git(["commit", "-m", "Change three files"])
        XCTAssertTrue(WorkspaceChangesReader.read(cwd: root.path, scope: .uncommitted, baseline: nil, file: nil, shared: false).files.isEmpty)
        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(WorkspaceChangesReader.read(cwd: root.path, scope: .uncommitted, baseline: nil, file: nil, shared: false).untrackedFiles, ["new.txt"])
        XCTAssertEqual(WorkspaceChangesReader.read(cwd: root.path, scope: .branch, baseline: "baseline", file: nil, shared: false).files.count, 3)
        XCTAssertNotNil(WorkspaceChangesReader.read(cwd: root.path, scope: .branch, baseline: "--output=/tmp/unsafe", file: nil, shared: false).unavailableReason)
    }
}
