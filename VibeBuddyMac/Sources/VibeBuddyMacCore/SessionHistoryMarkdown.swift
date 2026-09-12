import Foundation
import Markdown

public indirect enum HistoryMarkdownBlock: Sendable {
    case paragraph(String), heading(Int, String), code(String, String), quote([HistoryMarkdownBlock])
    case list(Int?, [[HistoryMarkdownBlock]]), table([[String]]), rule
}
public enum SessionHistoryMarkdown {
    public static func parse(_ text: String) -> [HistoryMarkdownBlock] {
        Document(parsing: text).children.map(block)
    }
    private static func inline(_ node: any Markup) -> String { node.children.map { $0.format() }.joined() }
    private static func block(_ node: any Markup) -> HistoryMarkdownBlock {
        switch node {
        case let value as Heading: return .heading(value.level, inline(value))
        case let value as CodeBlock: return .code(value.language ?? "", value.code)
        case let value as BlockQuote: return .quote(value.children.map(block))
        case let value as OrderedList: return .list(Int(value.startIndex), value.children.map { $0.children.map(block) })
        case let value as UnorderedList: return .list(nil, value.children.map { $0.children.map(block) })
        case let value as Markdown.Table:
            return .table([value.head.children.map(inline)] + value.body.children.map { $0.children.map(inline) })
        case is ThematicBreak: return .rule
        case let value as Paragraph: return .paragraph(inline(value))
        default: return .paragraph(node.format())
        }
    }
}
