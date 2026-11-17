import Foundation

/// A single key-value entry parsed from YAML frontmatter at the top of a Markdown file.
struct FrontmatterItem: Identifiable, Equatable, Sendable {
    let id: String
    let key: String
    let value: String

    init(key: String, value: String) {
        self.id = key
        self.key = key
        self.value = value
    }
}

/// Supported GitHub / Obsidian-style admonition callouts (`> [!NOTE]`, etc.).
enum CalloutKind: String, CaseIterable, Equatable, Sendable {
    case note
    case tip
    case important
    case warning
    case caution

    init?(marker: String) {
        switch marker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "NOTE", "INFO":
            self = .note
        case "TIP", "HINT":
            self = .tip
        case "IMPORTANT", "ABSTRACT", "SUMMARY":
            self = .important
        case "WARNING", "ATTENTION":
            self = .warning
        case "CAUTION", "DANGER", "ERROR":
            self = .caution
        default:
            return nil
        }
    }

    var displayTitle: String {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        }
    }

    var symbolName: String {
        switch self {
        case .note: return "info.circle"
        case .tip: return "lightbulb"
        case .important: return "exclamationmark.bubble"
        case .warning: return "exclamationmark.triangle"
        case .caution: return "xmark.octagon"
        }
    }
}

enum TableAlignment: Equatable, Sendable {
    case left
    case center
    case right
}

indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case strikethrough([MarkdownInline])
    case highlight([MarkdownInline])
    case code(String)
    case link(label: [MarkdownInline], destination: String)
    case image(alt: String, url: String)
    case softBreak
    case hardBreak

    var plainText: String {
        switch self {
        case .text(let s):
            return s
        case .strong(let children),
             .emphasis(let children),
             .strikethrough(let children),
             .highlight(let children):
            return children.plainText
        case .code(let code):
            return code
        case .link(let label, _):
            return label.plainText
        case .image(let alt, _):
            return alt
        case .softBreak:
            return " "
        case .hardBreak:
            return "\n"
        }
    }
}

extension Array where Element == MarkdownInline {
    var plainText: String {
        map(\.plainText).joined()
    }
}

struct ListItem: Identifiable, Equatable, Sendable {
    let id: String
    let inlines: [MarkdownInline]
    /// `nil` for standard bullets/numbered items, `true`/`false` for task list items `- [x]` / `- [ ]`.
    let checked: Bool?
    /// Approximate zero-based source line index for toggling task checkboxes in local writable documents.
    let sourceLine: Int?
    let children: [MarkdownBlock]

    var plainText: String {
        let head = inlines.plainText
        let tail = children.map(\.plainText).joined(separator: "\n")
        return tail.isEmpty ? head : "\(head)\n\(tail)"
    }
}

indirect enum MarkdownBlock: Identifiable, Equatable, Sendable {
    case heading(id: String, level: Int, anchor: String, inlines: [MarkdownInline], plainText: String)
    case paragraph(id: String, inlines: [MarkdownInline])
    case codeBlock(id: String, language: String?, code: String)
    case mathBlock(id: String, expression: String)
    case blockquote(id: String, alert: CalloutKind?, titleOverride: String?, blocks: [MarkdownBlock])
    case list(id: String, ordered: Bool, startIndex: Int, items: [ListItem])
    case table(id: String, headers: [[MarkdownInline]], alignments: [TableAlignment], rows: [[[MarkdownInline]]])
    case imageBlock(id: String, alt: String, url: String)
    case thematicBreak(id: String)

    var id: String {
        switch self {
        case .heading(let id, _, _, _, _),
             .paragraph(let id, _),
             .codeBlock(let id, _, _),
             .mathBlock(let id, _),
             .blockquote(let id, _, _, _),
             .list(let id, _, _, _),
             .table(let id, _, _, _),
             .imageBlock(let id, _, _),
             .thematicBreak(let id):
            return id
        }
    }

    var plainText: String {
        switch self {
        case .heading(_, _, _, _, let plainText):
            return plainText
        case .paragraph(_, let inlines):
            return inlines.plainText
        case .codeBlock(_, _, let code):
            return code
        case .mathBlock(_, let expression):
            return expression
        case .blockquote(_, _, let titleOverride, let blocks):
            let body = blocks.map(\.plainText).joined(separator: "\n")
            if let titleOverride, !titleOverride.isEmpty {
                return "\(titleOverride)\n\(body)"
            }
            return body
        case .list(_, _, _, let items):
            return items.map(\.plainText).joined(separator: "\n")
        case .table(_, let headers, _, let rows):
            let head = headers.map(\.plainText).joined(separator: " ")
            let body = rows.map { row in
                row.map(\.plainText).joined(separator: " ")
            }.joined(separator: "\n")
            return body.isEmpty ? head : "\(head)\n\(body)"
        case .imageBlock(_, let alt, _):
            return alt
        case .thematicBreak:
            return ""
        }
    }
}

struct HeadingEntry: Identifiable, Equatable, Sendable {
    let id: String
    let level: Int
    let text: String
    let anchor: String
}

struct DocumentStats: Equatable, Sendable {
    let wordCount: Int
    let characterCount: Int
    let lineCount: Int
    let estimatedReadingMinutes: Int
    let headingCount: Int
    let codeBlockCount: Int
}

struct SearchMatch: Identifiable, Equatable, Sendable {
    let id: String
    let blockID: String
    let matchCountInBlock: Int
}

struct MarkdownDocument: Equatable, Sendable {
    let frontmatter: [FrontmatterItem]
    let blocks: [MarkdownBlock]
    let headings: [HeadingEntry]
    let stats: DocumentStats

    static let empty = MarkdownDocument(
        frontmatter: [],
        blocks: [],
        headings: [],
        stats: DocumentStats(
            wordCount: 0,
            characterCount: 0,
            lineCount: 0,
            estimatedReadingMinutes: 1,
            headingCount: 0,
            codeBlockCount: 0
        )
    )

    func searchMatches(for query: String) -> [SearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [SearchMatch] = []
        for block in blocks {
            let text = block.plainText
            guard !text.isEmpty else { continue }
            var count = 0
            var searchStart = text.startIndex
            while let range = text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                count += 1
                searchStart = range.upperBound
            }
            if count > 0 {
                results.append(SearchMatch(id: block.id, blockID: block.id, matchCountInBlock: count))
            }
        }
        return results
    }
}
