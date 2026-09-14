import Foundation
import VibeBuddyKit

public final class CompletionSummaryPreferences: @unchecked Sendable {
    private struct Stored: Codable {
        var enabled: Bool
        var provider: String?
        var modelID: String
        var language: String
        var qwenUseIntl: Bool
        var qwenWorkspaceID: String?
        var contentStyle: ContentStyleConfiguration

        var configuration: CompletionSummaryConfiguration {
            .init(enabled: enabled, provider: provider.flatMap(VoiceProvider.init(rawValue:)),
                  modelID: modelID, language: VoiceLanguage(rawValue: language) ?? .english,
                  qwenUseIntl: qwenUseIntl, qwenWorkspaceID: qwenWorkspaceID, contentStyle: contentStyle)
        }
    }
    private let url: URL
    private let lock = NSLock()

    public init(fileURL: URL) { url = fileURL }

    public func load() -> CompletionSummaryConfiguration {
        lock.withLock { read()?.configuration ?? .init() }
    }

    public func saveContentStyle(_ style: ContentStyleConfiguration) -> Bool {
        lock.withLock {
            guard style.isValid else { return false }
            let existing = read()
            guard existing != nil || !FileManager.default.fileExists(atPath: url.path) else { return false }
            var stored = existing ?? Stored(enabled: false, provider: nil, modelID: "", language: VoiceLanguage.english.rawValue,
                                             qwenUseIntl: false, contentStyle: .default)
            stored.contentStyle = style
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(stored)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return true
            } catch { return false }
        }
    }

    private func read() -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }
}
