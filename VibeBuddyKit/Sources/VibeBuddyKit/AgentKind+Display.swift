import Foundation

public extension AgentKind {
    /// Map a hook `?agent=` source string (or alias) to a kind. Unknown sources
    /// fall back to Claude Code, the most common hook-compatible shape.
    static func fromSource(_ source: String?) -> AgentKind {
        switch source?.lowercased() {
        case "codex":                                   return .codex
        case "qwen", "qwen-code", "qwencode":           return .qwen
        case "kimi", "kimi-code", "kimicode":           return .kimi
        case "antigravity", "gemini":                   return .antigravity
        case "grok", "grok-build", "grokbuild":         return .grok
        case "opencode":                                return .opencode
        case "copilot", "githubcopilot", "github-copilot": return .copilot
        case "claude", "claudecode", "claude-code":     return .claudeCode
        default:                                        return .claudeCode
        }
    }

    /// Human-readable name for the UI.
    var displayName: String {
        switch self {
        case .claudeCode:  return "Claude Code"
        case .codex:       return "Codex"
        case .qwen:        return "Qwen Code"
        case .kimi:        return "Kimi Code"
        case .antigravity: return "Antigravity"
        case .grok:        return "Grok"
        case .opencode:    return "OpenCode"
        case .copilot:     return "GitHub Copilot"
        }
    }

    /// A short label for tight spaces (session rows, badges).
    var shortName: String {
        switch self {
        case .claudeCode:  return "Claude"
        case .codex:       return "Codex"
        case .qwen:        return "Qwen"
        case .kimi:        return "Kimi"
        case .antigravity: return "Antigravity"
        case .grok:        return "Grok"
        case .opencode:    return "OpenCode"
        case .copilot:     return "Copilot"
        }
    }

    /// SF Symbol used as the agent's glyph.
    var symbolName: String {
        switch self {
        case .claudeCode:  return "sparkle"
        case .codex:       return "chevron.left.forwardslash.chevron.right"
        case .qwen:        return "q.circle"
        case .kimi:        return "k.circle"
        case .antigravity: return "arrow.up.forward.circle"
        case .grok:        return "bolt.circle"
        case .opencode:    return "curlybraces"
        case .copilot:     return "person.2.circle"
        }
    }
}
