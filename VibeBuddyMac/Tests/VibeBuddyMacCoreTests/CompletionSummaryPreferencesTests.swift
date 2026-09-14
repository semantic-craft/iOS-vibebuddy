import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

struct CompletionSummaryPreferencesTests {
    @Test func styleUpdatePreservesProviderAndRejectsUnreadableConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("preferences.json")
        let original = Data(#"{"enabled":true,"provider":"qwen","modelID":"qwen3.8-flash","language":"zh","qwenUseIntl":true,"qwenWorkspaceID":"example","contentStyle":{"style":"concise","customPrompt":""}}"#.utf8)
        try original.write(to: url)
        let preferences = CompletionSummaryPreferences(fileURL: url)
        #expect(preferences.saveContentStyle(.init(style: .decision)))
        let loaded = CompletionSummaryPreferences(fileURL: url).load()
        #expect(loaded.contentStyle.style == .decision)
        #expect(loaded.enabled && loaded.provider == .qwen && loaded.modelID == "qwen3.8-flash")
        #expect(loaded.language == .chinese && loaded.qwenUseIntl && loaded.qwenWorkspaceID == "example")
        let damaged = Data("incomplete configuration".utf8)
        try damaged.write(to: url)
        #expect(!preferences.saveContentStyle(.init(style: .concise)))
        #expect(try Data(contentsOf: url) == damaged)
    }
}
