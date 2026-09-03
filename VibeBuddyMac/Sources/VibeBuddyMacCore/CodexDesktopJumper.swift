import AppKit
import Foundation
import VibeBuddyKit

/// Jumps to a Codex Desktop session by opening its thread in ChatGPT.app.
///
/// Desktop sessions are observed from `~/.codex/sessions` rollouts, not from a
/// CLI hook, so there is no `TerminalRef` and no window to script. What they do
/// have is a thread id — the rollout's own session id — and ChatGPT.app claims
/// the `codex` URL scheme, which makes `codex://threads/<id>` an exact target:
/// it both raises the app and switches it to that conversation.
///
/// The URL is delivered to ChatGPT.app's bundle rather than handed to a generic
/// `open`. LaunchServices on a machine that has updated ChatGPT a few times
/// keeps several stale claims on `codex:` (this Mac has four), and resolving the
/// scheme by policy could land the jump in a copy that no longer exists.
public enum CodexDesktopJumper {

    /// ChatGPT.app. The bundle id is `com.openai.codex` — the Codex team's, not
    /// the chat app's, which is why it does not read like ChatGPT.
    public static let chatGPTBundleID = "com.openai.codex"

    /// `codex://threads/<id>`, or nil when the id is not one.
    ///
    /// Thread ids are UUIDs. They are checked against a closed allowlist rather
    /// than escaped, on the same principle as the terminal jumper: the value
    /// arrives from a file on disk, and nothing that isn't recognisably an id
    /// should be able to steer a URL we hand to another application.
    static func threadURL(_ threadID: String) -> URL? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        guard !threadID.isEmpty, threadID.count <= 128,
              threadID.allSatisfy(allowed.contains) else { return nil }
        return URL(string: "codex://threads/\(threadID)")
    }

    /// Open a thread and report what that achieved.
    ///
    /// `.focused` is the honest verdict for a success: unlike a terminal, where
    /// raising the app rarely means raising the session's own surface, the URL
    /// names the conversation itself — ChatGPT comes forward showing that thread.
    ///
    /// ChatGPT.app must already be running, exactly as a terminal must: opening
    /// the URL would otherwise launch it, and a jump that starts an app is a
    /// different action from returning to work in progress. Not running, not
    /// installed, or an open that fails all report `.unsupported`, which the UI
    /// words as a thread that couldn't be opened rather than failing silently.
    public static func jump(threadID: String) async -> JumpOutcome {
        guard let url = threadURL(threadID),
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chatGPTBundleID),
              !NSRunningApplication.runningApplications(withBundleIdentifier: chatGPTBundleID).isEmpty
        else { return .unsupported }
        return await open(url, in: application) ? .focused : .unsupported
    }

    /// Hands the URL to one specific application bundle and waits for
    /// LaunchServices to say whether it took it.
    private static func open(_ url: URL, in application: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: application,
                                    configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}
