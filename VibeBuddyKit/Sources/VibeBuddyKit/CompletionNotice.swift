import Foundation

/// Mac-owned wording decision; never contains the original completion result.
public struct CompletionNotice: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, plain, summary, cancelled }
    public var id: String
    public var deadline: Date
    public var state: State
    public var text: String?
    public init(id: String, deadline: Date, state: State = .pending, text: String? = nil) {
        self.id = id; self.deadline = deadline; self.state = state; self.text = text
    }
}
