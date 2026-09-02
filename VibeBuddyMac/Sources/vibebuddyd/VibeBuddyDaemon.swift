import Foundation
import VibeBuddyMacCore

/// Headless entry point for Phase B (the menu-bar app wraps this in Phase C).
/// Config via env: VIBEBUDDY_PORT (default 9876), VIBEBUDDY_TOKEN (default "devtoken").
@main
struct VibeBuddyDaemon {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let port = env["VIBEBUDDY_PORT"].flatMap(Int.init) ?? 9876
        let token = env["VIBEBUDDY_TOKEN"] ?? "devtoken"

        let pusher = APNsConfig.load().flatMap { try? APNsPusher(config: $0) }
        let server = VibeBuddyServer(
            store: SessionStore(diagnosticsHome: FileManager.default.homeDirectoryForCurrentUser),
            token: token, port: port, pusher: pusher,
            codexRolloutMonitor: CodexRolloutMonitor())
        FileHandle.standardError.write(Data(
            "vibebuddyd: listening on 0.0.0.0:\(port) (apns: \(pusher != nil ? "on" : "off"))\n".utf8))
        try await server.runService()
    }
}
